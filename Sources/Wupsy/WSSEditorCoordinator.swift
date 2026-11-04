import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor protocol WSSEditorWindow: AnyObject {
    func focus()
    func close()
    func replaceDocument(_ document: WSSEditorDocument, onClose: @escaping () -> Void) throws
}
extension WSSEditorWindow {
    func replaceDocument(_ document: WSSEditorDocument, onClose: @escaping () -> Void) throws {
        throw WSSSaveAsError.invalid
    }
}

@MainActor final class WSSEditorCoordinator: ObservableObject {
    typealias Load = (Wallpaper) async throws -> WSSLoadedEditorProject
    typealias MakeWindow = (WSSEditorDocument, @escaping () -> Void) throws -> any WSSEditorWindow
    private struct Pending {
        let token: UUID
        let task: Task<Void, Error>
    }
    private struct Session {
        let document: WSSEditorDocument
        let window: any WSSEditorWindow
        let observation: AnyCancellable
    }
    private let onTermination: () -> Void
    typealias SaveAs = (WSSSaveAsSnapshot) async throws -> WSSSaveAsReceipt
    private let saveAs: SaveAs?
    private let publishDraft: SaveAs?
    var presentCreationError: ((Error) async -> Void)?
    var chooseNewImage: (() async -> URL?)?
    @Published private(set) var creatingWallpaper = false
    private var creationTask: Task<Void, Never>?
    private let draftPreparation = WSSDraftPreparation()
    private let save: WSSEditorDocument.Save?
    @Published private(set) var quitting = false
    private let lookup: (UUID) throws -> Wallpaper
    private let load: Load
    private let makeWindow: MakeWindow
    private var pending: [UUID: Pending] = [:]
    private var saveAsReservations: Set<UUID> = []
    private var sessions: [UUID: Session] = [:]
    private let presentation: WSSEditorAppPresentation?
    private let keyWindow: @MainActor () -> NSWindow?
    private var terminated = false
    private var maintenanceClosed = false
    let maintenance: MaintenanceCoordinator
    private var activeSaveAs = 0
    private var saveAsWaiters: [CheckedContinuation<Void, Never>] = []
    private let documentDrains = RuntimeTaskDrain()
    private var terminationObserver: NSObjectProtocol?
    private var focusObservers: [NSObjectProtocol] = []
    private var commandContext: [ObjectIdentifier?] = []
    @Published private(set) var editorHasFocus = false
    var openIDs: Set<UUID> { Set(sessions.keys) }

    init(
        maintenance: MaintenanceCoordinator? = nil,
        lookup: @escaping (UUID) throws -> Wallpaper, save: WSSEditorDocument.Save? = nil,
        saveAs: SaveAs? = nil, publishDraft: SaveAs? = nil,
        onTermination: @escaping () -> Void = {},
        load: Load? = nil, makeWindow: MakeWindow? = nil,
        presentation: WSSEditorAppPresentation? = nil,
        keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp?.keyWindow }
    ) {
        self.maintenance = maintenance ?? .shared
        self.keyWindow = keyWindow
        self.presentation = presentation
        self.onTermination = onTermination
        self.save = save
        self.saveAs = saveAs
        self.publishDraft = publishDraft
        self.lookup = lookup
        let loader = WSSEditorProjectLoader()
        self.load = load ?? { try await loader.load($0) }
        self.makeWindow = makeWindow ?? { WSSEditorWindowController(document: $0, onClose: $1) }
        WupsyDelegate.editorCoordinator = self
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.shutdown() } }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            focusObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] notification in
                    MainActor.assumeIsolated {
                        if name == NSWindow.didBecomeKeyNotification {
                            self?.editorHasFocus =
                                Self.document(in: notification.object as? NSWindow) != nil
                        } else if Self.document(in: notification.object as? NSWindow) != nil {
                            self?.editorHasFocus = false
                        }
                    }
                })
        }
        focusObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let window = self.keyWindow()
                    let context = [
                        window.map(ObjectIdentifier.init),
                        window?.firstResponder.map(ObjectIdentifier.init),
                        window?.attachedSheet.map(ObjectIdentifier.init),
                    ]
                    if context != self.commandContext {
                        self.commandContext = context
                        self.objectWillChange.send()
                    }
                }
            })

    }
    deinit {
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }
    var canCreateWallpaper: Bool {
        !terminated && !maintenanceClosed && maintenance.allowsNewOperations && !quitting
            && !creatingWallpaper && publishDraft != nil
            && NSApp?.modalWindow == nil && NSApp?.keyWindow?.attachedSheet == nil
            && (activeCommands?.permitsDocumentCommands ?? true)
    }
    func newWallpaper() async { await newWallpaper(onFirstSave: nil) }

    /// Optional presentation follow-up for this draft's first successful library publication.
    func newWallpaper(onFirstSave: ((UUID) -> Void)?) async {
        guard !maintenanceClosed, maintenance.allowsMutation else { return }
        (try? await maintenance.withMutationAsync {

            guard canCreateWallpaper, activeDocument?.finishEditing() ?? true else { return }
            creatingWallpaper = true
            defer {
                creatingWallpaper = false
                creationTask = nil
            }
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let url: URL?
                    if let chooseNewImage {
                        url = await chooseNewImage()
                    } else {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.png, .jpeg]
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        panel.prompt = EditorText.newWallpaperPanel.text
                        NSApp.activate(ignoringOtherApps: true)
                        url = await withTaskCancellationHandler(
                            operation: {
                                await withCheckedContinuation { continuation in
                                    let parent = [NSApp.keyWindow, NSApp.mainWindow].compactMap {
                                        $0
                                    }
                                    .first { $0.isVisible && $0.canBecomeMain }
                                    if let parent {
                                        panel.beginSheetModal(for: parent) { result in
                                            continuation.resume(
                                                returning: result == .OK ? panel.url : nil)
                                        }
                                    } else {
                                        panel.begin { result in
                                            continuation.resume(
                                                returning: result == .OK ? panel.url : nil)
                                        }
                                    }
                                }
                            }, onCancel: { Task { @MainActor in panel.cancel(nil) } })
                    }
                    guard let url else { return }
                    try Task.checkCancellation()
                    let project = try await draftPreparation.create(image: url)
                    do {
                        try Task.checkCancellation()
                        guard !terminated, !maintenanceClosed, !quitting, maintenance.allowsMutation
                        else { throw CancellationError() }
                        let id = project.handle.id
                        guard sessions[id] == nil, pending[id] == nil else {
                            throw WSSSaveAsError.collision
                        }
                        let document = WSSEditorDocument(project: project, save: save)
                        if let publishDraft {
                            document.publishDraft = { snapshot in
                                let receipt = try await publishDraft(snapshot)
                                onFirstSave?(receipt.project.handle.id)
                                return receipt
                            }
                        }
                        configureSaveAs(document)
                        let window: any WSSEditorWindow
                        do {
                            window = try makeWindow(document) { [weak self] in
                                self?.windowClosed(wallpaperID: id)
                            }
                        } catch {
                            document.close()
                            documentDrains.track(
                                Task { await document.closeAndDrainForMaintenance() })
                            await document.waitForDraftCleanup()
                            throw error
                        }
                        sessions[id] = Session(
                            document: document, window: window,
                            observation: document.objectWillChange.sink { [weak self] _ in
                                self?.objectWillChange.send()
                            })
                        if let session = sessions[id] { present(session) }
                    } catch {
                        try project.handle.draftOwner?.discard()
                        throw error
                    }
                } catch is CancellationError {} catch {
                    guard !terminated else { return }
                    if let presentCreationError {
                        await presentCreationError(error)
                        return
                    }
                    let alert = NSAlert()
                    alert.messageText = EditorText.createError.text
                    alert.informativeText = EditorErrorPresentation.message(error)
                    if let window = NSApp?.keyWindow {
                        await alert.beginSheetModal(for: window)
                    } else {
                        alert.runModal()
                    }
                }
            }
            creationTask = task
            await task.value

        })
    }
    func open(wallpaperID id: UUID) async throws {
        guard !maintenanceClosed else { throw MaintenanceError.restartRequired }
        try await maintenance.withMutationAsync {

            guard !terminated, !maintenanceClosed, !quitting, maintenance.allowsMutation else {
                throw CancellationError()
            }
            guard !saveAsReservations.contains(id) else { throw WSSSaveAsError.busy }
            if let session = sessions[id] {
                present(session)
                return
            }
            if let request = pending[id] {
                try await request.task.value
                return
            }
            let wallpaper = try lookup(id)
            guard wallpaper.id == id, wallpaper.managed != nil, wallpaper.kind == .scene else {
                throw WSSEditorOpenError.unavailable
            }
            let token = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                do {
                    let project = try await load(wallpaper)
                    try Task.checkCancellation()
                    guard !terminated, !quitting, pending[id]?.token == token else {
                        throw CancellationError()
                    }
                    let current = try lookup(id)
                    guard current.id == wallpaper.id, current.managed == wallpaper.managed,
                        current.root == wallpaper.root, current.path == wallpaper.path,
                        current.sceneSource == wallpaper.sceneSource
                    else { throw WSSEditorOpenError.unavailable }
                    let document = WSSEditorDocument(project: project, save: save)
                    configureSaveAs(document)
                    let window = try makeWindow(document) { [weak self] in
                        self?.windowClosed(wallpaperID: id)
                    }
                    sessions[id] = Session(
                        document: document, window: window,
                        observation: document.objectWillChange.sink { [weak self] _ in
                            self?.objectWillChange.send()
                        })
                    pending[id] = nil
                    if let session = sessions[id] { present(session) }
                } catch {
                    if pending[id]?.token == token { pending[id] = nil }
                    throw error
                }
            }
            pending[id] = Pending(token: token, task: task)
            try await task.value

        }
    }
    private func present(_ session: Session) {
        let focus = { [weak self] in
            guard let self, !self.terminated, !session.document.closed,
                self.sessions.values.contains(where: { $0.document === session.document })
            else { return }
            session.window.focus()
        }
        if let presentation {
            presentation.synchronize(hasEditors: !sessions.isEmpty, present: focus)
        } else {
            focus()
        }
    }
    private func configureSaveAs(_ document: WSSEditorDocument) {
        document.maintenance = maintenance
        guard saveAs != nil else { return }
        document.requestSaveAs = { [weak self, weak document] in
            guard let self, let document else { return false }
            return await self.saveAs(document: document)
        }
    }
    func saveAs(document: WSSEditorDocument) async -> Bool {
        guard !maintenanceClosed, maintenance.allowsMutation else { return false }
        return
            (try? await maintenance.withMutationAsync {

                activeSaveAs += 1
                defer {
                    activeSaveAs -= 1
                    if activeSaveAs == 0 {
                        let waiters = saveAsWaiters
                        saveAsWaiters.removeAll()
                        for waiter in waiters { waiter.resume() }
                    }
                }
                let sourceID = document.project.handle.id
                guard document.canSaveAs, !terminated, !quitting,
                    sessions[sourceID]?.document === document, let saveAs
                else { return false }
                document.saveAsBusy = true
                var reserved: UUID?
                defer { if let reserved { saveAsReservations.remove(reserved) } }
                defer {
                    document.saveAsBusy = false
                    document.interactionLocked = false
                }
                do {
                    let receipt: WSSSaveAsReceipt
                    if let committed = document.committedCopy {
                        guard committed.revision == document.state.workingRevision else {
                            await document.presentMessage?(
                                EditorText.copyAlreadyCreated.text,
                                EditorText.copyAlreadyCreatedHint.text
                            )
                            return false
                        }
                        receipt = committed.receipt
                        document.interactionLocked = true
                    } else {
                        let defaultName = try lookup(sourceID).title + " Copy"
                        guard let name = await document.chooseSaveAsName?(defaultName) else {
                            return false
                        }
                        _ = try WSSSaveAsSnapshot.title(name)
                        guard !document.closed, !terminated, !quitting,
                            sessions[sourceID]?.document === document,
                            document.finishEditing(), !document.importingImage, !document.saving
                        else { return false }
                        document.interactionLocked = true
                        let snapshot = try WSSSaveAsSnapshot(
                            document: document.state.workingModel, state: document.state,
                            source: document.project.handle, name: name)
                        reserved = snapshot.destinationID
                        saveAsReservations.insert(snapshot.destinationID)
                        receipt = try await saveAs(snapshot)
                        // Retain the committed result before any fallible editor takeover.
                        document.committedCopy = (receipt, snapshot.revision)
                    }
                    guard !terminated, !document.closed, !quitting,
                        let session = sessions[sourceID], session.document === document,
                        sessions[receipt.project.handle.id] == nil,
                        pending[receipt.project.handle.id] == nil
                    else { throw WSSSaveAsError.invalid }
                    let target = try lookup(receipt.project.handle.id)
                    let expected = receipt.project.handle.wallpaper
                    guard target.id == expected.id, target.managed == expected.managed,
                        target.sceneSource == expected.sceneSource, target.path == expected.path,
                        target.root == expected.root
                    else { throw WSSSaveAsError.invalid }
                    let replacement = WSSEditorDocument(project: receipt.project, save: save)
                    replacement.playing = document.playing
                    let index = document.selectedLayer
                    if replacement.identity.layers.indices.contains(index) {
                        if let address = document.effectAddress,
                            replacement.identity.layers[index].effects.indices.contains(
                                address.effectIndex)
                        {
                            replacement.selection = .effect(
                                replacement.identity.layers[index].id,
                                replacement.identity.layers[index].effects[address.effectIndex])
                        } else {
                            replacement.selection = .layer(replacement.identity.layers[index].id)
                        }
                    }
                    configureSaveAs(replacement)
                    replacement.saveAsBusy = true
                    replacement.interactionLocked = true
                    defer {
                        replacement.saveAsBusy = false
                        replacement.interactionLocked = false
                    }
                    let targetID = receipt.project.handle.id
                    do {
                        try session.window.replaceDocument(replacement) { [weak self] in
                            self?.windowClosed(wallpaperID: targetID)
                        }
                    } catch {
                        replacement.close()
                        throw error
                    }
                    sessions.removeValue(forKey: sourceID)
                    sessions[targetID] = Session(
                        document: replacement, window: session.window,
                        observation: replacement.objectWillChange.sink { [weak self] _ in
                            self?.objectWillChange.send()
                        })
                    document.close()
                    documentDrains.track(Task { await document.closeAndDrainForMaintenance() })
                    if !receipt.warnings.isEmpty {
                        await replacement.presentMessage?(
                            EditorText.copyWarning.text, receipt.warnings.joined(separator: "\n"))
                    }
                    return true
                } catch {
                    if document.committedCopy != nil {
                        await document.presentMessage?(
                            EditorText.copyCreated.text,
                            EditorText.copySwitchHint.text
                        )
                    } else {
                        let message: String
                        if let error = error as? WSSSaveAsError {
                            message = EditorText.saveAsDetail(error)
                        } else {
                            message = EditorErrorPresentation.message(WSSSaveAsError.invalid)
                        }
                        await document.presentMessage?(EditorText.copyError.text, message)
                    }
                    return false
                }

            }) ?? false
    }
    private func windowClosed(wallpaperID id: UUID) {
        if let document = sessions.removeValue(forKey: id)?.document {
            document.close()
            documentDrains.track(Task { await document.closeAndDrainForMaintenance() })
        }
        if !terminated { presentation?.synchronize(hasEditors: !sessions.isEmpty) }
    }
    func close(wallpaperID id: UUID) {
        pending[id]?.task.cancel()
        guard !quitting, sessions[id]?.document.saveAsBusy != true else { return }
        sessions[id]?.window.close()
    }
    static func document(in window: NSWindow?) -> WSSEditorDocument? {
        var candidate = window
        while let window = candidate {
            if let controller = window.windowController as? WSSEditorWindowController {
                return controller.editorDocument
            }
            candidate = window.parent
        }
        return nil
    }
    var activeDocument: WSSEditorDocument? { Self.document(in: keyWindow()) }
    var activeCommands: WSSEditorCommands? { .inWindow(keyWindow()) }
    enum MaintenanceCloseResult: Equatable { case approved, cancelled, failure }
    private func cancelAndDrainPending() async {
        let creation = creationTask
        let requests = pending.values.map(\.task)
        creation?.cancel()
        for request in requests { request.cancel() }
        await creation?.value
        for request in requests { _ = try? await request.value }
        if activeSaveAs > 0 {
            await withCheckedContinuation { saveAsWaiters.append($0) }
        }
    }
    // Before the normal-mutation drain: cancel dialogs/open/create tasks which
    // otherwise need user input. Do not permanently terminate or close documents.
    func cancelPendingForMaintenance() async throws {
        guard maintenance.state == .restoreFreezing, !quitting, !terminated,
            !maintenanceClosed
        else { throw MaintenanceError.invalidTransition }
        quitting = true
        defer { quitting = false }
        await cancelAndDrainPending()
    }
    private func resolveAllChanges() async -> Bool {
        await cancelAndDrainPending()
        let documents = sessions.sorted { $0.key.uuidString < $1.key.uuidString }.map {
            $0.value.document
        }
        let originalLocks = documents.map { $0.saving ? false : $0.operationInteractionLocked }
        defer {
            for (document, locked) in zip(documents, originalLocks) {
                document.interactionLocked = locked
            }
        }
        guard documents.allSatisfy({ !$0.isResolvingClose && $0.finishEditing() }) else {
            return false
        }
        for document in documents { document.interactionLocked = true }
        for document in documents {
            guard await document.resolveChanges() else { return false }
        }
        return true
    }
    func approveTermination() async -> Bool {
        if maintenance.state == .restartRequired { return true }
        guard !quitting, activeSaveAs == 0 else { return false }
        quitting = true
        defer { quitting = false }
        return await resolveAllChanges()
    }
    func resolveAndCloseAllForMaintenance(
        beforeClosing: () -> Bool = { true }
    ) async -> MaintenanceCloseResult {
        guard !terminated, !maintenanceClosed, !quitting else { return .failure }
        quitting = true
        let initiallyOpen = sessions.values.map(\.document)
        let originalMaintenanceLocks = initiallyOpen.map(\.maintenanceInteractionLocked)
        for document in initiallyOpen { document.maintenanceInteractionLocked = true }
        defer {
            quitting = false
            for (document, locked) in zip(initiallyOpen, originalMaintenanceLocks) {
                document.maintenanceInteractionLocked = locked
            }
        }
        do {
            return try await maintenance.resolveEditors {
                guard await self.resolveAllChanges() else { return .cancelled }
                await self.maintenance.drainMutations()
                guard beforeClosing() else { return .cancelled }
                self.maintenanceClosed = true
                self.presentation?.cancelPendingPresentation()
                let approved = self.sessions
                self.sessions.removeAll()
                for session in approved.values {
                    // Mark closed before NSWindow.close so Don't Save is not prompted twice.
                    session.document.close()
                    session.window.close()
                    await session.document.closeAndDrainForMaintenance()
                }
                await self.documentDrains.cancelAndDrain()
                return .approved
            }
        } catch { return .failure }
    }
    func finishTermination() async {
        let documents = sessions.values.map(\.document)
        await cancelAndDrainPending()
        let creation = creationTask
        shutdown()
        await creation?.value
        for document in documents { await document.closeAndDrainForMaintenance() }
        await documentDrains.cancelAndDrain()
    }
    func shutdown() {
        guard !terminated else { return }
        terminated = true
        creationTask?.cancel()
        presentation?.cancelPendingPresentation()
        onTermination()
        for request in pending.values { request.task.cancel() }
        // Pending entries remove themselves only when their tasks actually end.
        let existing = sessions
        sessions.removeAll()
        for session in existing.values {
            session.document.close()
            session.window.close()
        }
    }
}

@MainActor
final class WSSEditorWindowController: NSWindowController, NSWindowDelegate, WSSEditorWindow,
    NSToolbarDelegate, NSToolbarItemValidation
{
    private(set) var editorDocument: WSSEditorDocument
    private var observation: AnyCancellable?
    private var approvedClose = false
    private var closing = false
    private var onClose: (() -> Void)?
    private let sizePreferences: WSSEditorWindowSize
    private var adjustingWindowSize = false
    private var suppressUserResize = false
    private var userResizing = false
    private var fullScreenTransition = false
    init(
        document: WSSEditorDocument, onClose: @escaping () -> Void,
        sizePreferences: WSSEditorWindowSize = .init()
    ) {
        self.sizePreferences = sizePreferences
        editorDocument = document
        self.onClose = onClose
        let window = WSSEditorNativeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        window.editorDocument = document
        window.title = EditorText.windowTitle.format(document.project.handle.wallpaper.title)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.isRestorable = false
        window.tabbingMode = .disallowed
        // Full-frame autosaving stays off: only the shared user-selected size is persisted.
        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "WSSEditor")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        let visible =
            (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        constrainWindow(to: visible, restoringSize: true)
        // Construct native canvases only after the final initial frame is known.
        window.contentView = NSHostingView(rootView: WSSEditorView(document: document))
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        bindDocument(document)
    }
    /// Screen adjustments never write preferences or reload another editor's latest size.
    func constrainWindow(to visible: NSRect, restoringSize: Bool = false) {
        guard let window, !adjustingWindowSize, !fullScreenTransition,
            !window.styleMask.contains(.fullScreen),
            visible.width.isFinite, visible.height.isFinite,
            visible.width > 0, visible.height > 0
        else { return }
        let minimum = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: WSSEditorWindowSize.minimumContent)
        ).size
        let effectiveMinimum = WSSEditorWindowSize.bounded(
            minimum, available: visible.size, minimum: .zero)
        adjustingWindowSize = true
        if userResizing { suppressUserResize = true }
        defer { adjustingWindowSize = false }
        window.contentMinSize =
            window.contentRect(
                forFrameRect: NSRect(origin: .zero, size: effectiveMinimum)
            ).size
        let frame =
            restoringSize
            ? sizePreferences.initialFrame(in: visible, minimum: minimum)
            : WSSEditorWindowSize.constrained(window.frame, to: visible, minimum: minimum)
        if frame != window.frame {
            window.setFrame(frame, display: window.isVisible)
        }
    }
    private func constrainWindowToCurrentScreen() {
        guard let screen = window?.screen ?? NSScreen.main else { return }
        constrainWindow(to: screen.visibleFrame)
    }
    @objc private func screenParametersChanged(_ notification: Notification) {
        constrainWindowToCurrentScreen()
    }
    func windowDidChangeScreen(_ notification: Notification) { constrainWindowToCurrentScreen() }
    func windowWillStartLiveResize(_ notification: Notification) {
        userResizing = true
        suppressUserResize =
            adjustingWindowSize || fullScreenTransition
            || window?.styleMask.contains(.fullScreen) == true
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        defer { userResizing = false }
        guard userResizing, let window, !suppressUserResize, !adjustingWindowSize,
            !fullScreenTransition,
            !window.styleMask.contains(.fullScreen)
        else { return }
        sizePreferences.recordUserSize(window.frame.size)
    }
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        if !adjustingWindowSize, !fullScreenTransition, !window.styleMask.contains(.fullScreen) {
            sizePreferences.recordUserSize(newFrame.size)
        }
        return true
    }
    func windowWillEnterFullScreen(_ notification: Notification) { fullScreenTransition = true }
    func windowDidEnterFullScreen(_ notification: Notification) { fullScreenTransition = false }
    func windowWillExitFullScreen(_ notification: Notification) { fullScreenTransition = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        fullScreenTransition = false
        constrainWindowToCurrentScreen()
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { fullScreenTransition = false }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { fullScreenTransition = false }

    private func bindDocument(_ document: WSSEditorDocument) {
        let window = self.window
        observation = document.$snapshot.sink { [weak window, weak document] snapshot in
            guard let document else { return }
            window?.isDocumentEdited =
                snapshot.state.isDirty || document.project.handle.origin == .draft
            window?.title = EditorText.windowTitle.format(document.project.handle.wallpaper.title)
        }
        document.finishInput = { [weak window] in window?.makeFirstResponder(nil) ?? true }
        document.chooseFirstSaveName = { [weak self] proposedName in
            guard let window = self?.window else { return nil }
            return await WSSWallpaperNameRequest.present(
                title: EditorText.saveWallpaper.text, proposedName: proposedName, window: window)
        }
        document.chooseSaveAsName = { [weak self] proposedName in
            guard let window = self?.window else { return nil }
            return await WSSWallpaperNameRequest.present(
                title: EditorText.saveWallpaperAs.text, proposedName: proposedName, window: window)
        }
        document.chooseMaskFile = { [weak self] in
            guard let window = self?.window else { return nil }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.png, .jpeg]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.title = EditorText.maskImportPanel.text
            panel.prompt = EditorText.maskImportPanel.text
            panel.message = EditorText.maskImportHint.text
            return await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { result in
                    continuation.resume(returning: result == .OK ? panel.url : nil)
                }
            }
        }
        document.chooseImageFile = { [weak self] in
            guard let window = self?.window else { return nil }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.png, .jpeg]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.prompt = EditorText.chooseImage.text
            return await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { result in
                    continuation.resume(returning: result == .OK ? panel.url : nil)
                }
            }
        }
        document.presentMessage = { [weak self] title, detail in
            guard let window = self?.window else { return }
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            alert.addButton(withTitle: ProductText.ok.text)
            _ = await alert.beginSheetModal(for: window)
        }
        document.chooseClose = { [weak self] in
            guard let window = self?.window else { return .cancel }
            let alert = NSAlert()
            alert.messageText = EditorText.closeTitle.text
            alert.informativeText =
                EditorText.closeHint.text
            alert.addButton(withTitle: ProductText.save.text)
            alert.addButton(withTitle: EditorText.dontSave.text)
            alert.addButton(withTitle: ProductText.cancel.text).keyEquivalent = "\u{1b}"
            switch await alert.beginSheetModal(for: window) {
            case .alertFirstButtonReturn: return .save
            case .alertSecondButtonReturn: return .discard
            default: return .cancel
            }
        }
    }
    func replaceDocument(_ document: WSSEditorDocument, onClose: @escaping () -> Void) throws {
        guard let window, !closing, !approvedClose, !editorDocument.closed else {
            throw WSSSaveAsError.invalid
        }
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            return view.subviews.lazy.compactMap { find(type, in: $0) }.first
        }
        if let content = window.contentView {
            document.initialCanvasZoom =
                find(WSSCanvasScrollView.self, in: content)?.presentationZoom
            let preview = find(WSSPreviewHost.self, in: content)
            document.initialPreviewTime = preview?.surface.player?.elapsed ?? 0
            document.previewExpanded = preview?.expandedWindow != nil
        }
        // Shutdown A before constructing B's native surfaces: no parallel player,
        // no old dismantle/shutdown callback is ever rebound to B.
        observation?.cancel()
        editorDocument.close()
        window.contentView = nil
        editorDocument = document
        self.onClose = onClose
        (window as? WSSEditorNativeWindow)?.editorDocument = document
        window.title = EditorText.windowTitle.format(document.project.handle.wallpaper.title)
        window.isDocumentEdited = false
        window.contentView = NSHostingView(rootView: WSSEditorView(document: document))
        bindDocument(document)
        window.makeFirstResponder(window.contentView)
        window.makeKeyAndOrderFront(nil)
        // Finish the inherited presentation before takeover completes. A queued
        // viewDidMoveToWindow task is not a completion signal for this operation.
        window.contentView?.layoutSubtreeIfNeeded()
        if document.previewExpanded, let content = window.contentView {
            find(WSSPreviewHost.self, in: content)?.expand()
        }
    }
    private static let saveItem = NSToolbarItem.Identifier("wss.save")
    private static let saveAsItem = NSToolbarItem.Identifier("wss.saveAs")
    private static let revertItem = NSToolbarItem.Identifier("wss.revert")
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.saveItem, Self.saveAsItem, Self.revertItem, .flexibleSpace]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.saveItem, Self.saveAsItem, Self.revertItem, .flexibleSpace]
    }
    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        if id == Self.saveItem {
            item.label = ProductText.save.text
            item.image = NSImage(
                systemSymbolName: "square.and.arrow.down",
                accessibilityDescription: EditorText.saveWallpaperAX.text)
            item.action = #selector(saveEditor(_:))
        } else if id == Self.saveAsItem {
            item.label = EditorText.saveAs.text
            item.toolTip = EditorText.saveAsHelp.text
            item.image = NSImage(
                systemSymbolName: "square.and.arrow.down.on.square",
                accessibilityDescription: EditorText.saveCopyAX.text)
            item.action = #selector(saveAsEditor(_:))
        } else if id == Self.revertItem {
            item.label = EditorText.revert.text
            item.image = NSImage(
                systemSymbolName: "arrow.uturn.backward",
                accessibilityDescription: EditorText.revert.text)
            item.action = #selector(revertEditor(_:))
        } else {
            return nil
        }
        return item
    }
    private var commands: WSSEditorCommands {
        WSSEditorCommands(document: editorDocument, window: window)
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == Self.saveItem { return commands.canPerform(.save) }
        if item.itemIdentifier == Self.saveAsItem { return commands.canPerform(.saveAs) }
        return commands.canPerform(.revert)
    }
    @objc private func saveEditor(_ sender: Any?) { commands.perform(.save) }
    @objc private func saveAsEditor(_ sender: Any?) { commands.perform(.saveAs) }
    @objc private func revertEditor(_ sender: Any?) { commands.perform(.revert) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func focus() {
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        editorDocument.undoManager
    }
    func windowDidResignKey(_ notification: Notification) {
        editorDocument.endTrailInteraction()
        editorDocument.endRainSlider()
        editorDocument.endSlider()
        editorDocument.endImageSlider()
    }
    override func close() {
        if approvedClose || editorDocument.closed {
            super.close()
            return
        }
        window?.performClose(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if approvedClose || editorDocument.closed { return true }
        guard !closing, !editorDocument.saveAsBusy, !editorDocument.interactionLocked else {
            return false
        }
        guard editorDocument.finishEditing() else { return false }
        if !editorDocument.isDirty && !editorDocument.saving { return true }
        closing = true
        Task { [weak self] in
            guard let self else { return }
            if await editorDocument.resolveChanges() {
                approvedClose = true
                close()
            }
            closing = false
        }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let callback = onClose
        onClose = nil
        callback?()
        window?.contentView = nil
    }
}

// Explicit responder targets also work when no SwiftUI text control has focus.
final class WSSEditorNativeWindow: NSWindow {
    weak var editorDocument: WSSEditorDocument?
    override var undoManager: UndoManager? { editorDocument?.undoManager }
    private func handleCanvasZoom(_ event: NSEvent) -> Bool {
        // Plain field editors keep their text/selection; zoom does not end editing.
        // Rich-text views retain their own font-size equivalents.
        if let text = firstResponder as? NSTextView, text.isRichText && !text.isFieldEditor {
            return false
        }
        guard let action = WSSCanvasZoomCommand.decode(event) else { return false }
        return editorDocument?.canvasZoomCommand?(action) == true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleCanvasZoom(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        if handleCanvasZoom(event) { return }
        // Track Space without consuming text-field input. A subsequent Canvas down
        // must still pan when the Canvas did not own the preceding key-down.
        if event.type == .keyDown || event.type == .keyUp, event.keyCode == 49 {
            editorDocument?.canvasSpaceDown = event.type == .keyDown
        }
        // SwiftUI's native List can consume Escape before cancelOperation reaches
        // the window. Route Canvas-tool Escape at this editor's boundary;
        // field editors keep their own cancel/validation semantics.
        if event.type == .keyDown, event.keyCode == 53,
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
            !(firstResponder is NSTextView),
            editorDocument?.cancelPaintInteraction() == true
                || editorDocument?.cancelTransformInteraction() == true
        {
            return
        }
        super.sendEvent(event)
    }
    override func cancelOperation(_ sender: Any?) {
        if editorDocument?.cancelPaintInteraction() != true
            && editorDocument?.cancelTransformInteraction() != true
        {
            super.cancelOperation(sender)
        }
    }
    // Use the standard Edit > Delete responder action. Text responders consume it
    // first; structural editing is only the editor window's fallback.
    @objc func delete(_ sender: Any?) {
        guard let document = editorDocument else { return }
        WSSEditorCommands(document: document, window: self).perform(.delete)
    }
    @objc func undo(_ sender: Any?) {
        guard let document = editorDocument,
            WSSEditorCommands(document: document, window: self).permitsDocumentCommands,
            document.finishEditing()
        else { return }
        document.undoManager.undo()
    }
    @objc func redo(_ sender: Any?) {
        guard let document = editorDocument,
            WSSEditorCommands(document: document, window: self).permitsDocumentCommands,
            document.finishEditing()
        else { return }
        document.undoManager.redo()
    }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(delete(_:)) {
            return editorDocument.map {
                WSSEditorCommands(document: $0, window: self).canPerform(.delete)
            } == true
        }
        if menuItem.action == #selector(undo(_:)) {
            return editorDocument.map {
                WSSEditorCommands(document: $0, window: self).permitsDocumentCommands
            } == true
                && editorDocument?.undoManager.canUndo == true
        }
        if menuItem.action == #selector(redo(_:)) {
            return editorDocument.map {
                WSSEditorCommands(document: $0, window: self).permitsDocumentCommands
            } == true
                && editorDocument?.undoManager.canRedo == true
        }
        return super.validateMenuItem(menuItem)
    }
}
