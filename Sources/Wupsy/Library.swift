import AppKit
import IOKit.ps
import SwiftUI

@MainActor final class Library: NSObject, ObservableObject {
    @Published var items: [Wallpaper] = []
    @Published var selected: UUID? {
        didSet {
            if revertingPreference { return }
            guard !maintenanceStopped, let admission = try? maintenance.beginMutation() else {
                revertingPreference = true
                selected = oldValue
                revertingPreference = false
                return
            }
            defer { admission.finish() }
            defaults.set(selected?.uuidString, forKey: "selectedWallpaper")
        }
    }
    @Published private(set) var favorites: Set<UUID> = []
    @Published var message: String? { didSet { messagePresentation = nil } }
    @Published private(set) var messagePresentation: String?
    @Published var importFailureReport: ImportFailureReport?
    @Published private(set) var playbackStatus: LibraryPlaybackStatus = .ready {
        didSet {
            if oldValue != playbackStatus { recordPlayback(.status(playbackStatus)) }
            desktopPerformance?.reconcile()
        }
    }
    var status: String { playbackStatus.title }
    @Published private(set) var playbackEvents: [PlaybackActivity] = []
    @Published var manuallyPaused = false {
        didSet {
            if revertingPreference { return }
            guard !maintenanceStopped, let admission = try? maintenance.beginMutation() else {
                revertingPreference = true
                manuallyPaused = oldValue
                revertingPreference = false
                return
            }
            defer { admission.finish() }

            defaults.set(manuallyPaused, forKey: "manuallyPaused")
            updatePolicy()
        }
    }
    private var clearingManualPauseForApply = false
    @Published var conserve = true {
        didSet {
            if revertingPreference { return }
            guard !maintenanceStopped, let admission = try? maintenance.beginMutation() else {
                revertingPreference = true
                conserve = oldValue
                revertingPreference = false
                return
            }
            defer { admission.finish() }

            defaults.set(conserve, forKey: "conserve")
            updatePolicy()
        }
    }
    @Published var pauseOnBattery = true {
        didSet {
            if revertingPreference { return }
            guard !maintenanceStopped, let admission = try? maintenance.beginMutation() else {
                revertingPreference = true
                pauseOnBattery = oldValue
                revertingPreference = false
                return
            }
            defer { admission.finish() }

            defaults.set(pauseOnBattery, forKey: "pauseOnBattery")
            updatePolicy()
        }
    }
    @Published var allDisplays = true {
        didSet {
            if revertingPreference { return }
            guard !maintenanceStopped, let admission = try? maintenance.beginMutation() else {
                revertingPreference = true
                allDisplays = oldValue
                revertingPreference = false
                return
            }
            defer { admission.finish() }

            defaults.set(allDisplays, forKey: "allDisplays")
            displaysChanged()
        }
    }
    @Published var profile: QualityProfile = .original {
        didSet {
            if revertingPreference { return }
            guard !maintenanceStopped, let admission = try? maintenance.beginMutation() else {
                revertingPreference = true
                profile = oldValue
                revertingPreference = false
                return
            }
            defer { admission.finish() }

            defaults.set(profile.rawValue, forKey: "profile")
            reapply()
        }
    }
    @Published var sceneRenderResolution: SceneRenderResolution = .hiDPI {
        didSet {
            if revertingPreference { return }
            guard !maintenanceStopped, let admission = try? maintenance.beginMutation() else {
                revertingPreference = true
                sceneRenderResolution = oldValue
                revertingPreference = false
                return
            }
            defer { admission.finish() }

            defaults.set(
                sceneRenderResolution.rawValue, forKey: SceneRenderResolution.preferenceKey)
            for renderer in renderers { renderer.setSceneRenderResolution(sceneRenderResolution) }
        }
    }
    @Published var sceneFPS = 30 {
        didSet {
            if revertingPreference { return }
            guard !maintenanceStopped, let admission = try? maintenance.beginMutation() else {
                revertingPreference = true
                sceneFPS = oldValue
                revertingPreference = false
                return
            }
            defer { admission.finish() }

            defaults.set(sceneFPS, forKey: "sceneFPS")
            if active?.kind == .scene { reapply() }
        }
    }
    private var revertingPreference = false
    lazy var livePreview = WSSLibraryPreviewOwner(maintenance: maintenance)
    let maintenance: MaintenanceCoordinator
    private var maintenanceStopped = false
    private let runtimeTasks = RuntimeTaskDrain()
    private let rendererTasks = RuntimeTaskDrain()
    private let edits = LibraryEditQueue()
    private let beforeLibraryPublication: (String) async -> Void
    private var renaming = false
    @Published var importing = false
    @Published private(set) var preparing = false
    @Published private(set) var active: Wallpaper?
    @Published private(set) var usingOptimizedVideo = false
    private(set) var renderers: [Renderer] = [] {
        didSet { desktopPerformance?.reconcile() }
    }
    private var desktopPerformance: DesktopPerformancePanel?

    func openPerformancePanel() {
        if desktopPerformance == nil {
            desktopPerformance = DesktopPerformancePanel(
                defaults: defaults, targets: { [weak self] in self?.performanceTargets() ?? [] },
                status: { [weak self] in self?.playbackStatus.title })
        }
        desktopPerformance?.open()
    }

    func closePerformancePanel() { desktopPerformance?.close() }

    private func performanceTargets() -> [(DesktopPerformancePanel.Choice, Renderer)] {
        let screens = targetScreens()
        return screens.enumerated().compactMap { index, screen in
            let id = DesktopPerformancePanel.DisplayID(screen)
            guard
                let renderer = renderers.first(where: {
                    !$0.stopped && DesktopPerformancePanel.DisplayID($0.screen) == id
                })
            else { return nil }
            let name =
                screens.filter { $0.localizedName == screen.localizedName }.count > 1
                ? ProductText.performanceDisplayName.format(screen.localizedName, Int64(index + 1))
                : screen.localizedName
            return (.init(id: id, name: name), renderer)
        }
    }
    @Published private(set) var pauseReason: PauseReason?
    var onPlaybackCommand: ((WallpaperPlaybackCommand) -> Void)?
    var isLibraryReadable: Bool { storageLoadError == nil }
    private var conditions = PlaybackConditions()
    private var preparation: Task<Void, Never>?
    private var generation = UUID()
    private var displayReconciliationPending = false
    private var displayPreparation: Task<Void, Never>?
    private var displayPreparationID = UUID()
    private var disconnectedSceneTime: Double = 0
    private var deferredFrozenApply: (wallpaper: Wallpaper, request: WallpaperApplyRequest)?
    private var pendingApply: WallpaperApplyRequest?
    private var transitionRequest: WallpaperApplyRequest?
    private var transitionTask: Task<Void, Never>?
    private var replacementPreparationID: UUID?
    private var startingRenderers = false
    private var startupError: String?
    private var memoryRecovery: Task<Void, Never>?
    private var pressureRecovery = MemoryPressureRecovery()
    private var pressureSource: DispatchSourceMemoryPressure?
    private var powerSource: CFRunLoopSource?
    private let wssSaveValidator = WSSManifestSaveValidator()
    private let managedStore: ManagedWallpaperStore
    private var storageLoadError: String?
    private var removingWallpaper: UUID?
    var backupStorage: URL { storage }
    var backupPreferences: LibraryBackupPreferences {
        get throws { try LibraryBackupPreferences(defaults: defaults) }
    }
    private let storage: URL
    private let defaults: UserDefaults
    private let targetScreens: () -> [NSScreen]
    private let rendererStart: @MainActor (Renderer, Int) throws -> Void
    private let draftPreview: ((WSSLoadedEditorProject) async -> Bool)?
    private let scenePreparation: (Wallpaper) async throws -> PreparedScenePlayback
    private let makeVideoOptimizer: @MainActor () -> VideoOptimizer
    init(
        maintenance: MaintenanceCoordinator? = nil,
        beforeLibraryPublication: @escaping (String) async -> Void = { _ in },
        beforeMovePersistence: @escaping () throws -> Void = {},
        storage: URL? = nil, defaults: UserDefaults = .standard, restoreOnLaunch: Bool = true,
        targetScreens: @escaping () -> [NSScreen] = { NSScreen.screens },
        rendererStart: @escaping @MainActor (Renderer, Int) throws -> Void = { renderer, _ in
            renderer.setPaused(false)
        },
        scenePreparation: @escaping (Wallpaper) async throws -> PreparedScenePlayback = {
            try await ScenePlayback.prepare(for: $0)
        },
        makeVideoOptimizer: @escaping @MainActor () -> VideoOptimizer = { VideoOptimizer() },
        draftPreview: ((WSSLoadedEditorProject) async -> Bool)? = nil
    ) {
        self.beforeLibraryPublication = beforeLibraryPublication
        self.maintenance = maintenance ?? .shared
        self.targetScreens = targetScreens
        self.rendererStart = rendererStart
        self.scenePreparation = scenePreparation
        self.draftPreview = draftPreview
        self.makeVideoOptimizer = makeVideoOptimizer
        self.storage =
            storage
            ?? ProductPaths.current.library
        managedStore = ManagedWallpaperStore(
            storage: self.storage, beforeMovePersistence: beforeMovePersistence)
        self.defaults = defaults
        super.init()
        if FileManager.default.fileExists(atPath: self.storage.path) {
            do {
                items = try managedStore.load()
            } catch {
                storageLoadError =
                    "Could not read library.json safely: \(error.localizedDescription)"
                message = storageLoadError
                messagePresentation = ProductText.libraryLoadError.text
            }
        }
        conserve = defaults.object(forKey: "conserve") as? Bool ?? true
        pauseOnBattery = defaults.object(forKey: "pauseOnBattery") as? Bool ?? true
        allDisplays = defaults.object(forKey: "allDisplays") as? Bool ?? true
        profile =
            QualityProfile(rawValue: defaults.string(forKey: "profile") ?? "original") ?? .original
        sceneRenderResolution = SceneRenderResolution.stored(in: defaults)
        let savedSceneFPS = defaults.integer(forKey: "sceneFPS")
        sceneFPS = [24, 30, 60].contains(savedSceneFPS) ? savedSceneFPS : 30
        selected = LibraryOrder.initialSelection(
            defaults.string(forKey: "selectedWallpaper").flatMap(UUID.init(uuidString:)), in: items)
        favorites = Set(
            (defaults.stringArray(forKey: "favorites") ?? []).compactMap(UUID.init(uuidString:)))
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(systemSleep), name: NSWorkspace.willSleepNotification,
            object: nil)
        workspace.addObserver(
            self, selector: #selector(systemWake), name: NSWorkspace.didWakeNotification,
            object: nil)
        workspace.addObserver(
            self, selector: #selector(screenSleep), name: NSWorkspace.screensDidSleepNotification,
            object: nil)
        workspace.addObserver(
            self, selector: #selector(screenWake), name: NSWorkspace.screensDidWakeNotification,
            object: nil)
        workspace.addObserver(
            self, selector: #selector(sessionInactive),
            name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(sessionActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(updatePolicy), name: .NSProcessInfoPowerStateDidChange,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(updatePolicy),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let pressure = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self, weak pressure] in
            guard let self, let pressure else { return }
            let event = pressure.data
            if event.contains(.critical) {
                self.pressureRecovery.critical()
                self.conditions.memoryPressure = true
                Task { await ImageLoader.shared.clear() }
                self.updatePolicy()
                self.startMemoryRecovery()
            } else {
                if event.contains(.warning) { Task { await ImageLoader.shared.clear() } }
                if self.conditions.memoryPressure { self.startMemoryRecovery() }
            }
        }
        pressure.activate()
        pressureSource = pressure
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<Library>.fromOpaque(context).takeUnretainedValue().updatePolicy()
            }
        }
        powerSource = IOPSNotificationCreateRunLoopSource(
            callback, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        manuallyPaused = defaults.bool(forKey: "manuallyPaused")
        updatePolicy()
        if storage == nil, restoreOnLaunch { restorePlayback() }
    }
    /// Shared startup path; custom-storage tests can restore without using user data.
    func restorePlayback() {
        if let id = defaults.string(forKey: "activeWallpaper").flatMap(UUID.init(uuidString:)),
            let item = items.first(where: { $0.id == id })
        {
            apply(item, source: .restoration)
        }
    }
    deinit {
        let request = pendingApply
        let transition = transitionRequest
        Task { @MainActor in
            request?.finish(.superseded)
            transition?.finish(.superseded)
        }
        preparation?.cancel()
        transitionTask?.cancel()
        pressureSource?.cancel()
        memoryRecovery?.cancel()
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    func recordPlayback(_ event: PlaybackActivity.Event, at time: Date = Date()) {
        playbackEvents.append(PlaybackActivity(time: time, event: event))
        if playbackEvents.count > 50 { playbackEvents.removeFirst(playbackEvents.count - 50) }
    }
    private func startMemoryRecovery() {
        guard memoryRecovery == nil else { return }
        memoryRecovery = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                if self.pressureRecovery.check(
                    level: MemoryPressureRecovery.currentLevel(),
                    now: ProcessInfo.processInfo.systemUptime)
                {
                    self.conditions.memoryPressure = false
                    self.memoryRecovery = nil
                    self.recordPlayback(.diagnostic(.memoryRecovered))
                    self.updatePolicy()
                    return
                }
            }
        }
    }
    func importFiles() { importFiles(onSuccess: nil) }

    /// The caller may reveal the last successfully imported item after the batch finishes.
    func importFiles(onSuccess: ((UUID) -> Void)?) {
        guard !maintenanceStopped, maintenance.allowsMutation else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = ProductText.importAction.text
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls, onSuccess: onSuccess)

    }
    func importURLs(_ urls: [URL], onSuccess: ((UUID) -> Void)? = nil) {
        guard !maintenanceStopped, maintenance.allowsMutation else { return }

        guard !importing, !renaming else {
            message = ProductText.operationWait.text
            return
        }
        guard storageLoadError == nil else {
            message = storageLoadError
            messagePresentation = ProductText.libraryLoadError.text
            return
        }
        guard !maintenanceStopped, let admission = try? maintenance.beginMutation() else { return }
        importing = true
        Task {
            defer { admission.finish() }
            await MaintenanceOperation.$id.withValue(admission.id) {

                var importedID: UUID?
                var errors: [ImportFailurePresentation] = []
                for url in urls {
                    do {
                        try await edits.acquire()
                        defer { edits.release() }
                        let item = try await managedStore.importWallpaper(url, existing: items)
                        await beforeLibraryPublication("import")
                        items.append(item)
                        selected = item.id
                        importedID = item.id
                    } catch {
                        errors.append(ImportFailurePresentation(source: url, error: error))
                    }
                }
                importing = false
                if !errors.isEmpty { importFailureReport = ImportFailureReport(failures: errors) }
                if let importedID { onSuccess?(importedID) }

            }
        }

    }
    func saveWSSAs(
        _ snapshot: WSSSaveAsSnapshot, preview: ((WSSLoadedEditorProject) async -> Bool)? = nil
    ) async throws -> WSSSaveAsReceipt {
        guard !maintenanceStopped else { throw MaintenanceError.restartRequired }
        return try await maintenance.withMutationAsync {

            if storageLoadError != nil { throw WSSSaveAsError.library }
            let receipt = try await edits.withEdit {
                let receipt = try await managedStore.saveWSSAs(snapshot)
                await beforeLibraryPublication("saveWSSAs")
                let item = receipt.project.handle.wallpaper
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index] = item
                } else {
                    items.append(item)
                }
                return receipt
            }
            let item = receipt.project.handle.wallpaper
            selected = item.id
            let success: Bool
            if let preview {
                success = await preview(receipt.project)
            } else {
                success = await ImageLoader.shared.committedWSS(
                    item, basis: receipt.project.diskBasis, resources: receipt.project.resources)
            }
            NotificationCenter.default.post(name: .wssPreviewCommitted, object: item.id)
            return WSSSaveAsReceipt(
                operationID: receipt.operationID, project: receipt.project,
                warnings: receipt.warnings
                    + (success
                        ? []
                        : [
                            EditorText.copyPreviewWarning.text
                        ]))

        }
    }

    func publishWSSDraft(_ snapshot: WSSSaveAsSnapshot) async throws -> WSSSaveAsReceipt {
        guard !maintenanceStopped else { throw MaintenanceError.restartRequired }
        return try await maintenance.withMutationAsync {

            guard storageLoadError == nil else { throw WSSSaveAsError.library }
            let receipt = try await edits.withEdit {
                let receipt = try await managedStore.publishWSSDraft(snapshot)
                await beforeLibraryPublication("publishWSSDraft")
                let item = receipt.project.handle.wallpaper
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index] = item
                } else {
                    items.append(item)
                }
                return receipt
            }
            let item = receipt.project.handle.wallpaper
            var warnings = receipt.warnings
            if snapshot.publication.replacement != nil {
                warnings += completeImageReplacement(receipt.project)
            }
            // Thumbnail work cannot repeat or roll back committed publication.
            let prepared: Bool
            if let draftPreview {
                prepared = await draftPreview(receipt.project)
            } else {
                prepared = await defaultCommittedDraftPreview(receipt.project)
            }
            NotificationCenter.default.post(name: .wssPreviewCommitted, object: item.id)
            return WSSSaveAsReceipt(
                operationID: receipt.operationID, project: receipt.project,
                warnings: warnings + (prepared ? [] : [EditorText.thumbnailWarning.text]))

        }
    }

    private func completeImageReplacement(_ project: WSSLoadedEditorProject) -> [String] {
        let item = project.handle.wallpaper
        guard !maintenanceStopped, maintenance.allowsMutation,
            active?.id == item.id && active?.kind == .image
                || renderers.contains(where: {
                    $0.wallpaper.id == item.id && $0.wallpaper.kind == .image
                }),
            items.first(where: { $0.id == item.id }) == item
        else { return [] }
        do {
            // A newer editor save must never be replaced by this older receipt.
            try project.diskBasis.verify(project.handle)
            if active?.id == item.id && (pendingApply != nil || preparing || renderers.isEmpty) {
                retargetPreparation(to: item)
            } else {
                try refreshActiveWallpaper(
                    id: item.id, playback: .init(wss: project.resources), committedItem: item)
            }
            return []
        } catch is CancellationError {
            // A newer action wins; the saved project is still authoritative.
            return []
        } catch {
            return [EditorText.desktopWarning.format(EditorErrorPresentation.message(error))]
        }
    }

    // Preserve the original request/outcome and playlist transition. No apply(),
    // manual command, preference write, Stop or intermediate ready state.
    private func retargetPreparation(to item: Wallpaper) {
        generation = UUID()
        preparation?.cancel()
        preparation = nil
        active = item
        replacementPreparationID = item.id
        if let pauseReason {
            preparing = false
            playbackStatus = .paused(pauseReason)
        } else {
            prepare(item)
        }
    }

    private func defaultCommittedDraftPreview(_ project: WSSLoadedEditorProject) async -> Bool {
        await ImageLoader.shared.committedWSS(
            project.handle.wallpaper,
            basis: project.diskBasis, resources: project.resources)
    }

    // Explicit editor save; only an already-active UUID may refresh after commit.
    func saveWSSManifest(_ snapshot: WSSSaveSnapshot) async throws -> WSSSaveReceipt {
        guard !maintenanceStopped else { throw MaintenanceError.restartRequired }
        return try await maintenance.withMutationAsync {

            let item: Wallpaper
            do { item = try wallpaperForEditor(id: snapshot.diskBasis.identity.wallpaperID) } catch
            {
                throw WSSSaveError.targetDisappeared
            }
            let handle = try WSSExistingProjectResolver.resolve(item)
            let candidate = try await wssSaveValidator.prepare(snapshot, handle: handle)
            let receipt = try await managedStore.commitWSSManifest(candidate)
            let completed = completeWSSSave(receipt, playback: candidate.playback)
            if case .committed = receipt.outcome, let playback = candidate.playback {
                await ImageLoader.shared.committedWSS(
                    item, basis: receipt.diskBasis, resources: playback.resources)
                NotificationCenter.default.post(name: .wssPreviewCommitted, object: item.id)
            }
            return completed

        }
    }

    // A post-commit playback failure remains a committed save, with a separate warning.
    func completeWSSSave(_ receipt: WSSSaveReceipt, playback: PreparedScenePlayback?)
        -> WSSSaveReceipt
    {
        let id = receipt.snapshot.diskBasis.identity.wallpaperID
        guard case .committed(let warnings) = receipt.outcome, active?.id == id,
            let playback
        else { return receipt }
        do {
            try refreshActiveWallpaper(id: id, playback: playback)
            return receipt
        } catch {
            return WSSSaveReceipt(
                snapshot: receipt.snapshot, diskBasis: receipt.diskBasis,
                outcome: .committed(
                    warnings: warnings + [
                        EditorText.desktopWarning.format(EditorErrorPresentation.message(error))
                    ]))
        }
    }

    func wallpaperForEditor(id: UUID) throws -> Wallpaper {
        if let storageLoadError { throw ImportFailure.message(storageLoadError) }
        guard removingWallpaper != id, items.filter({ $0.id == id }).count == 1,
            let item = items.first(where: { $0.id == id }), item.managed != nil,
            item.canOpenInEditor
        else { throw WSSEditorOpenError.unavailable }
        return try managedStore.resolve(item)
    }

    /// Placement is expressed in the reversed, visible library order.
    func move(wallpaperID: UUID, relativeTo targetID: UUID, placement: LibraryMovePlacement)
        async throws
    {
        guard !maintenanceStopped else { throw MaintenanceError.restartRequired }
        try await maintenance.withMutationAsync {
            if let storageLoadError { throw ImportFailure.message(storageLoadError) }
            try await edits.withEdit {
                let committed = try await managedStore.move(
                    wallpaperID: wallpaperID, relativeTo: targetID, placement: placement)
                // The queue remains held through publication; no older append/receipt can follow it.
                await beforeLibraryPublication("move")
                if items != committed { items = committed }
            }
        }
    }

    func rename(wallpaperID: UUID, newTitle: String) async throws {
        guard !maintenanceStopped else { throw MaintenanceError.restartRequired }
        return try await maintenance.withMutationAsync {

            let title = try WallpaperTitle.normalized(newTitle)
            if let storageLoadError { throw ImportFailure.message(storageLoadError) }
            guard !importing, !renaming else {
                throw ImportFailure.message(ProductText.operationWait.text)
            }
            guard items.filter({ $0.id == wallpaperID }).count == 1 else {
                throw ImportFailure.message(
                    ProductText.wallpaperAmbiguous.text)
            }
            renaming = true
            defer { renaming = false }
            try await edits.acquire()
            defer { edits.release() }
            let saved = try await managedStore.rename(wallpaperID: wallpaperID, newTitle: title)
            await beforeLibraryPublication("rename")
            // Publish only after persistence. Never replace playback resources or requests.
            if let index = items.firstIndex(where: { $0.id == wallpaperID }),
                items[index].title != saved.title
            {
                items[index].title = saved.title
            }
            if active?.id == wallpaperID, active?.title != saved.title {
                active?.title = saved.title
            }

        }
    }

    /// Existing UI callers may discard the handle; automatic callers await its outcome.
    @discardableResult func apply(
        _ requested: Wallpaper, source: WallpaperApplySource = .manual
    ) -> WallpaperApplyRequest {
        let item = currentPlaybackRecord(requested)
        guard !maintenanceStopped, maintenance.allowsMutation else {
            let request = WallpaperApplyRequest()
            request.finish(.superseded)
            return request
        }

        if source == .manual { onPlaybackCommand?(.manualApply) }
        cancelDisplayPreparation()
        let releasesFrozenCoverage =
            transitionRequest != nil && renderers.contains(where: \.hasFrozenScene)
        cancelTransition()
        if pendingApply != nil { stopPlayback(preserveSelection: true) }
        let request = WallpaperApplyRequest()
        if removingWallpaper == item.id {
            reject(request, ProductText.operationWait.text)
            if releasesFrozenCoverage { updatePolicy() }
            return request
        }
        guard item.kind == .scene || FileManager.default.fileExists(atPath: item.path) else {
            reject(
                request, ProductText.wallpaperMissing.text)
            if releasesFrozenCoverage { updatePolicy() }
            return request
        }
        if source == .manual, manuallyPaused {
            deferredFrozenApply?.request.finish(.superseded)
            deferredFrozenApply = nil
            clearingManualPauseForApply = true
            manuallyPaused = false
            clearingManualPauseForApply = false
        } else if manuallyPaused, !renderers.isEmpty, renderers.allSatisfy(\.hasFrozenScene) {
            deferredFrozenApply?.request.finish(.superseded)
            deferredFrozenApply = (item, request)
            request.cancel = { [weak self, weak request] in
                guard let self, let request, deferredFrozenApply?.request === request else {
                    return
                }
                deferredFrozenApply = nil
                request.finish(.superseded)
            }
            return request
        }
        startApply(item, request: request)
        return request
    }

    private func startApply(_ item: Wallpaper, request: WallpaperApplyRequest) {
        if pauseReason == nil, !renderers.isEmpty,
            item.kind == .image || item.kind == .scene,
            renderers.allSatisfy({ $0.wallpaper.kind == .image || $0.wallpaper.kind == .scene })
        {
            prepareTransition(to: item, request: request)
            return
        }
        stopPlayback(preserveSelection: true)
        pendingApply = request
        request.cancel = { [weak self, weak request] in
            guard let self, let request, self.pendingApply === request else { return }
            self.stopPlayback(preserveSelection: true)
        }
        active = item
        updatePolicy()
    }

    private func cancelTransition() {
        guard let request = transitionRequest else { return }
        transitionRequest = nil
        transitionTask?.cancel()
        transitionTask = nil
        preparing = false
        request.finish(.superseded)
    }

    private func prepareTransition(to item: Wallpaper, request: WallpaperApplyRequest) {
        guard let admission = try? maintenance.beginMutation(kind: .runtime) else {
            request.finish(.superseded)
            return
        }
        let ticket = UUID()
        let previous = renderers
        let available = targetScreens()
        let topology = WSSDesktopRefreshTargets.topology(available)
        let screens = allDisplays ? available : Array(available.prefix(1))
        let quality = profile
        let resolution = sceneRenderResolution
        transitionRequest = request
        preparing = true
        playbackStatus = .preparing(quality)
        request.cancel = { [weak self, weak request] in
            guard let self, let request, self.transitionRequest === request else { return }
            self.cancelTransition()
            self.updatePolicy()
        }
        let task = Task { [self] in
            defer { admission.finish() }
            await MaintenanceOperation.$id.withValue(admission.id) {
                var candidates: [Renderer] = []
                var candidateFailure: RuntimeDiagnostic?
                defer { for renderer in candidates { retire(renderer) } }
                do {
                    guard !screens.isEmpty else {
                        throw ImportFailure.message(ProductText.noDisplay.text)
                    }
                    let scene = item.kind == .scene ? try await scenePreparation(item) : nil
                    try Task.checkCancellation()
                    var stillBytes = 0
                    for (index, screen) in screens.enumerated() {
                        let renderer = makeRenderer(
                            item, screen: screen, mediaURL: item.url, quality: quality,
                            playback: scene, ticket: ticket,
                            onError: {
                                [weak self, weak transition = request] diagnostic, renderer in
                                guard let self else { return }
                                if let transition, self.transitionRequest === transition,
                                    self.generation != ticket
                                {
                                    candidateFailure = candidateFailure ?? diagnostic
                                } else {
                                    self.rendererFailed(
                                        diagnostic, ticket: ticket, renderer: renderer)
                                }
                            })
                        candidates.append(renderer)
                        if scene != nil {
                            let size = renderer.transitionRasterSize
                            stillBytes += Int(size.width) * Int(size.height) * 4
                            guard stillBytes <= 128 * 1024 * 1024 else {
                                throw ImportFailure.message(ProductText.playbackError.text)
                            }
                        }
                        try await renderer.prepareTransition()
                        try Task.checkCancellation()
                        try rendererStart(renderer, index)
                        if let candidateFailure { throw candidateFailure }
                    }
                    guard transitionRequest === request, maintenance.allowsMutation else {
                        throw CancellationError()
                    }
                    guard topology == WSSDesktopRefreshTargets.topology(targetScreens()),
                        resolution == sceneRenderResolution
                    else { throw ImportFailure.message(EditorText.desktopTopologyChanged.text) }
                    guard currentPlaybackRecord(item) == item, previous.count == renderers.count,
                        zip(previous, renderers).allSatisfy({ $0 === $1 })
                    else { throw CancellationError() }

                    generation = ticket
                    renderers = candidates
                    active = item
                    usingOptimizedVideo = false
                    for renderer in candidates {
                        let display = WSSDesktopRefreshTargets.number(renderer.screen)
                        let old = previous.first {
                            $0.screen === renderer.screen
                                || (display != nil
                                    && WSSDesktopRefreshTargets.number($0.screen) == display)
                        }
                        renderer.presentTransition(above: old)
                    }
                    candidates.removeAll()
                    for renderer in previous { retire(renderer) }
                    transitionRequest = nil
                    transitionTask = nil
                    preparing = false
                    defaults.set(item.id.uuidString, forKey: "activeWallpaper")
                    request.finish(.accepted)
                    updatePolicy()
                } catch {
                    guard transitionRequest === request else { return }
                    transitionRequest = nil
                    transitionTask = nil
                    preparing = false
                    if error is CancellationError {
                        request.finish(.superseded)
                    } else {
                        presentWallpaperFailure(error, item: item, operation: .playbackError)
                        request.finish(.failed(error))
                    }
                    updatePolicy()
                }
            }
        }
        transitionTask = task
        runtimeTasks.track(task)
    }
    private func currentPlaybackRecord(_ requested: Wallpaper) -> Wallpaper {
        if requested.kind == .image,
            let current = items.first(where: { $0.id == requested.id }), current.kind == .scene
        {
            return current
        }
        return requested
    }
    private func reject(_ request: WallpaperApplyRequest, _ text: String) {
        message = text
        request.finish(.failed(ImportFailure.message(text)))
    }
    private func showProductError(_ detail: String, presentation: ProductText) {
        message = detail
        messagePresentation = presentation.text
    }
    func presentWallpaperFailure(_ error: Error, item: Wallpaper, operation: ProductText) {
        if WSSFailurePresentation(error) != nil || error is WallpaperImportDiagnostic {
            message = nil
            importFailureReport = ImportFailureReport(
                failures: [.init(source: item.url, error: error, wallpaperTitle: item.title)],
                heading: operation == .playbackError
                    ? ProductText.wallpaperPlaybackFailed.text : ProductText.editorOpenError.text)
        } else {
            showProductError(error.localizedDescription, presentation: operation)
        }
    }

    private func failPreparation(_ error: Error, item: Wallpaper) {
        presentWallpaperFailure(error, item: item, operation: .playbackError)
        pendingApply?.finish(.failed(error))
        pendingApply = nil
        stopPlayback(preserveSelection: true)
    }
    private func rendererFailed(_ diagnostic: RuntimeDiagnostic, ticket: UUID, renderer: Renderer) {
        let text = diagnostic.technicalDescription
        guard generation == ticket, !renderer.stopped else { return }
        if startingRenderers {
            startupError = startupError ?? text
        } else {
            // Resume can report a synchronous load error inside updatePolicy's
            // renderer loop. Defer policy mutation to avoid reentrant unpausing.
            Task { @MainActor [weak self, weak renderer] in
                guard let self, let renderer, !renderer.stopped, self.generation == ticket else {
                    return
                }
                // While a replacement is prepared, this generation still owns the
                // outgoing windows. Its runtime errors must not pause the replacement.
                guard self.transitionRequest == nil else { return }
                self.showProductError(text, presentation: .playbackError)
                self.messagePresentation = diagnostic.localized()
                self.recordPlayback(.diagnostic(diagnostic))
                if !renderer.hasTransitionStill { self.manuallyPaused = true }
            }
        }
    }
    private func prepare(_ item: Wallpaper) {
        let afterImageReplacement = replacementPreparationID == item.id
        guard !maintenanceStopped, let admission = try? maintenance.beginMutation(kind: .runtime)
        else { return }

        let ticket = UUID()
        generation = ticket
        let quality = profile
        let scenePreparation = self.scenePreparation
        preparing = true
        playbackStatus = .preparing(quality)
        preparation = Task { [self] in
            defer { admission.finish() }
            await MaintenanceOperation.$id.withValue(admission.id) {

                do {
                    let optimizer = makeVideoOptimizer()
                    let scenePlayback =
                        item.kind == .scene
                        ? try await scenePreparation(item) : nil
                    let url = try await optimizer.preparedURL(
                        for: item, profile: quality,
                        protectedURLs: { [weak self] in self?.renderers.map(\.mediaURL) ?? [] })
                    try Task.checkCancellation()
                    guard generation == ticket else { return }
                    let current = currentPlaybackRecord(item)
                    if current != item {
                        retargetPreparation(to: current)
                        return
                    }
                    let available = targetScreens()
                    let screens = allDisplays ? available : Array(available.prefix(1))
                    guard !screens.isEmpty else {
                        throw ImportFailure.message(ProductText.noDisplay.text)
                    }
                    usingOptimizedVideo = url != item.url
                    startingRenderers = true
                    startupError = nil
                    defer { startingRenderers = false }
                    for (index, screen) in screens.enumerated() {
                        let renderer = makeRenderer(
                            item, screen: screen, mediaURL: url, quality: quality,
                            playback: scenePlayback, ticket: ticket,
                            onError: { [weak self] error, renderer in
                                self?.rendererFailed(error, ticket: ticket, renderer: renderer)
                            })
                        renderers.append(renderer)
                        try rendererStart(renderer, index)
                        guard generation == ticket, !Task.isCancelled else { return }
                        if let startupError { throw ImportFailure.message(startupError) }
                    }
                    // All targets have accepted synchronous startup. Async decoding,
                    // navigation and later runtime health remain Renderer responsibilities.
                    preparation = nil
                    preparing = false
                    replacementPreparationID = nil
                    defaults.set(item.id.uuidString, forKey: "activeWallpaper")
                    pendingApply?.finish(.accepted)
                    pendingApply = nil
                    updatePolicy()
                } catch {
                    guard generation == ticket, !Task.isCancelled else { return }
                    failPreparation(error, item: item)
                    if afterImageReplacement, WSSFailurePresentation(error) == nil,
                        !(error is WallpaperImportDiagnostic)
                    {
                        let warning = EditorText.desktopWarning.format(
                            EditorErrorPresentation.message(error))
                        message = warning
                        messagePresentation = warning
                    }
                }

            }
        }
        if let preparation { runtimeTasks.track(preparation) }

    }
    // Shared native player/window construction. Refresh never enters apply() or emits a playlist command.
    private func makeRenderer(
        _ item: Wallpaper, screen: NSScreen, mediaURL: URL, quality: QualityProfile,
        playback: PreparedScenePlayback?, ticket: UUID,
        onError: @escaping (RuntimeDiagnostic, Renderer) -> Void
    ) -> Renderer {
        weak var owner: Renderer?
        let renderer = Renderer(
            maintenance: maintenance, wallpaper: item, screen: screen, mediaURL: mediaURL,
            profile: quality,
            initiallyPaused: true, scenePlayback: playback, sceneFPS: sceneFPS,
            sceneRenderResolution: sceneRenderResolution,
            onEvent: { [weak self] event in
                guard let self, let owner, !owner.stopped, self.generation == ticket else { return }
                self.recordPlayback(.diagnostic(event))
            },
            onDiagnostic: { diagnostic in
                guard let owner, !owner.stopped else { return }
                onError(diagnostic, owner)
            },
            onError: { message in
                guard let owner, !owner.stopped else { return }
                onError(.failure(message), owner)
            })
        owner = renderer
        return renderer
    }

    private func refreshActiveWallpaper(
        id: UUID, playback: PreparedScenePlayback, committedItem: Wallpaper? = nil
    ) throws {
        guard !maintenanceStopped, maintenance.allowsMutation else { return }
        let previous = active
        guard previous?.id == id || renderers.contains(where: { $0.wallpaper.id == id }) else {
            return
        }
        guard let item = committedItem ?? items.first(where: { $0.id == id }) ?? previous,
            item.id == id, item.kind == .scene
        else { throw ScenePlaybackError.notSceneWallpaper }
        cancelDisplayPreparation()
        if pendingApply != nil || preparing || renderers.isEmpty {
            guard previous?.id == id else { throw CancellationError() }
            retargetPreparation(to: item)
            return
        }
        let ticket = generation
        let available = targetScreens()
        let topology = WSSDesktopRefreshTargets.topology(available)
        let targets = try WSSDesktopRefreshTargets.select(
            id: id, renderers: renderers, screens: available)
        guard !targets.isEmpty else { return }
        var replacements: [(Int, Renderer)] = []
        var installing = true
        var startupFailure: String?
        func verifyCurrent() throws {
            guard !maintenanceStopped, maintenance.allowsMutation,
                active == previous, generation == ticket, transitionRequest == nil
            else { throw CancellationError() }
            guard topology == WSSDesktopRefreshTargets.topology(targetScreens()) else {
                throw ImportFailure.message(EditorText.desktopTopologyChanged.text)
            }
            if let startupFailure { throw ImportFailure.message(startupFailure) }
        }
        do {
            for target in targets {
                try verifyCurrent()
                let renderer = makeRenderer(
                    item, screen: target.screen, mediaURL: item.url,
                    quality: profile, playback: playback, ticket: ticket,
                    onError: { [weak self] diagnostic, renderer in
                        if installing {
                            startupFailure = diagnostic.technicalDescription
                        } else {
                            self?.rendererFailed(diagnostic, ticket: ticket, renderer: renderer)
                        }
                    })
                renderer.deferPresentation()
                replacements.append((target.index, renderer))
                try rendererStart(renderer, target.index)
                try verifyCurrent()
            }
            for (_, renderer) in replacements { renderer.setPaused(pauseReason != nil) }
            try verifyCurrent()
        } catch {
            installing = false
            for (_, renderer) in replacements { retire(renderer) }
            throw error
        }
        let old = targets.map(\.renderer)
        // Keep the action generation: unaffected renderer callbacks remain valid.
        // Retired renderer lifetimes suppress their own delayed diagnostics.
        for (index, renderer) in replacements { renderers[index] = renderer }
        if previous?.id == id {
            active = item
            usingOptimizedVideo = false
        }
        installing = false
        for (_, renderer) in replacements { renderer.presentPreparedContent() }
        for renderer in old { retire(renderer) }
    }

    func toggleFavorite(_ item: Wallpaper) {
        guard !maintenanceStopped, maintenance.allowsMutation else { return }
        try? maintenance.withMutation {

            if favorites.contains(item.id) {
                favorites.remove(item.id)
            } else {
                favorites.insert(item.id)
            }
            defaults.set(favorites.map(\.uuidString), forKey: "favorites")

        }
    }
    /// Rebuild the current target without creating or completing a new external request.
    private func reapply() {
        guard !maintenanceStopped, maintenance.allowsMutation else { return }
        if transitionRequest != nil {
            cancelTransition()
            if let active { prepareTransition(to: active, request: WallpaperApplyRequest()) }
            return
        }

        guard let item = active else { return }
        let request = pendingApply
        let replacementID = replacementPreparationID
        pendingApply = nil
        stopPlayback(preserveSelection: true)
        pendingApply = request
        replacementPreparationID = replacementID
        active = item
        updatePolicy()

    }
    func canRemove(_ item: Wallpaper?) -> Bool {
        guard let item else { return false }
        return !maintenanceStopped && maintenance.allowsNewOperations
            && !importing && !renaming && storageLoadError == nil
            && items.contains { $0.id == item.id }
    }
    func remove(_ item: Wallpaper) {
        guard !maintenanceStopped, maintenance.allowsMutation else { return }

        guard !importing, !renaming else {
            message = ProductText.operationWait.text
            return
        }
        guard storageLoadError == nil else {
            message = storageLoadError
            messagePresentation = ProductText.libraryLoadError.text
            return
        }
        guard let existing = items.first(where: { $0.id == item.id }) else { return }
        let backupLease: LibraryMutationBarrier.Lease
        do { backupLease = try LibraryMutationBarrier.shared.mutation() } catch {
            showProductError(error.localizedDescription, presentation: .operationWait)
            return
        }
        guard !maintenanceStopped, let admission = try? maintenance.beginMutation() else { return }
        removingWallpaper = existing.id
        if active?.id == existing.id { stopPlayback() }
        importing = true
        Task {
            defer { admission.finish() }
            await MaintenanceOperation.$id.withValue(admission.id) {

                defer { withExtendedLifetime(backupLease) {} }
                do {
                    try await edits.acquire()
                    defer { edits.release() }
                    let warning = try await managedStore.remove(existing, existing: items)
                    await beforeLibraryPublication("remove")
                    onPlaybackCommand?(.remove(existing.id))
                    items.removeAll { $0.id == existing.id }
                    favorites.remove(existing.id)
                    defaults.set(favorites.map(\.uuidString), forKey: "favorites")
                    if selected == existing.id { selected = nil }
                    if let warning {
                        showProductError(warning, presentation: .removeCleanupWarning)
                    }
                } catch { showProductError(error.localizedDescription, presentation: .removeError) }
                removingWallpaper = nil
                importing = false

            }
        }

    }
    func stop(preserveSelection: Bool = false) {
        guard preserveSelection || (!maintenanceStopped && maintenance.allowsMutation) else {
            return
        }

        onPlaybackCommand?(preserveSelection ? .shutdown : .stop)
        stopPlayback(preserveSelection: preserveSelection, clearManualPause: !preserveSelection)

    }
    private func stopPlayback(preserveSelection: Bool = false, clearManualPause: Bool = false) {
        cancelDisplayPreparation()
        disconnectedSceneTime = 0
        displayReconciliationPending = false
        cancelTransition()
        replacementPreparationID = nil
        pendingApply?.finish(.superseded)
        pendingApply = nil
        deferredFrozenApply?.request.finish(.superseded)
        deferredFrozenApply = nil
        if !preserveSelection { defaults.removeObject(forKey: "activeWallpaper") }
        generation = UUID()
        preparation?.cancel()
        preparation = nil
        preparing = false
        for renderer in renderers { retire(renderer) }
        renderers.removeAll()
        active = nil
        usingOptimizedVideo = false
        if clearManualPause, manuallyPaused { manuallyPaused = false }
        playbackStatus = .stopped
    }
    private func retire(_ renderer: Renderer) {
        renderer.stop()
        let task = Task { await renderer.stopAndDrainForMaintenance() }
        rendererTasks.track(task)
    }
    func stopAndDrainForMaintenance() async {
        // Finish accepted imports/saves and their preference/model continuations
        // before the terminal flag starts rejecting even previously accepted work.
        await maintenance.drainMutations()
        maintenanceStopped = true
        await livePreview.shutdownAndDrain()
        stop(preserveSelection: true)
        memoryRecovery?.cancel()
        pressureSource?.cancel()
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        await runtimeTasks.cancelAndDrain()
        await rendererTasks.cancelAndDrain()
        await memoryRecovery?.value
        await maintenance.drain()
    }
    func clearCache() {
        guard !maintenanceStopped, maintenance.allowsMutation else { return }
        try? maintenance.withMutation {

            guard !preparing else {
                message = ProductText.operationWait.text
                return
            }
            do {
                try makeVideoOptimizer().trim(to: 0, excluding: renderers.map(\.mediaURL))
            } catch { showProductError(error.localizedDescription, presentation: .cacheError) }

        }
    }
    private func cancelDisplayPreparation() {
        displayPreparationID = UUID()
        displayPreparation?.cancel()
        displayPreparation = nil
    }

    private func enabledScreens() -> [NSScreen] {
        let screens = targetScreens()
        return allDisplays ? screens : Array(screens.prefix(1))
    }

    @objc func displaysChanged() {
        guard !maintenanceStopped, maintenance.allowsMutation, let item = active else { return }
        guard item.sceneSource == .nativeWSS, pendingApply == nil else {
            reapply()
            return
        }
        let releasesFrozenCoverage =
            transitionRequest != nil
            && renderers.contains(where: \.hasFrozenScene)
        if transitionRequest != nil { cancelTransition() }
        guard !preparing else {
            reapply()
            return
        }
        reconcileDesktopDisplays(item)
        if releasesFrozenCoverage { updatePolicy() }
    }

    private func reconcileDesktopDisplays(
        _ item: Wallpaper, prepared: PreparedScenePlayback? = nil
    ) {
        let targets = enabledScreens()
        let current = renderers
        let matches = WSSDesktopRefreshTargets.matchSlots(
            current: current.map { DesktopPerformancePanel.DisplayID($0.screen) },
            target: targets.map { DesktopPerformancePanel.DisplayID($0) })
        let retained = Set(matches.compactMap { $0 })
        let template = current.compactMap { $0.scene as? WSSStaticPlayer }.first
        let source = prepared ?? template.map { PreparedScenePlayback(wss: $0.resources) }
        if let template { disconnectedSceneTime = template.elapsed }
        let reasons = conditions.reasons(conserve: conserve, pauseOnBattery: pauseOnBattery)
        let mayPrepare = Renderer.canRetainScene(for: reasons) && !conditions.surfaceUnavailable
        let missing = matches.contains(nil)
        if !missing { cancelDisplayPreparation() }

        for (index, renderer) in current.enumerated() where !retained.contains(index) {
            retire(renderer)
        }
        var result: [Renderer] = []
        let ticket = generation
        for (screen, index) in zip(targets, matches) {
            if let index {
                let renderer = current[index]
                renderer.updateScreen(screen)
                result.append(renderer)
            } else if mayPrepare, let source {
                let renderer = makeRenderer(
                    item, screen: screen, mediaURL: item.url, quality: profile,
                    playback: source, ticket: ticket,
                    onError: { [weak self] error, renderer in
                        self?.rendererFailed(error, ticket: ticket, renderer: renderer)
                    })
                renderer.startDesktopSlot(
                    offset: disconnectedSceneTime, reasons: reasons, surfaceAvailable: true)
                result.append(renderer)
            }
        }
        if result.map(ObjectIdentifier.init) != current.map(ObjectIdentifier.init) {
            renderers = result
        }
        displayReconciliationPending = result.count != targets.count || targets.isEmpty
        if reasons.isEmpty {
            playbackStatus = result.isEmpty ? .ready : .playing(displayCount: result.count)
        }

        if mayPrepare, missing, source == nil, displayPreparation == nil,
            defaults.string(forKey: "activeWallpaper") == item.id.uuidString,
            let admission = try? maintenance.beginMutation(kind: .runtime)
        {
            let id = displayPreparationID
            displayPreparation = Task { [weak self] in
                defer { admission.finish() }
                await MaintenanceOperation.$id.withValue(admission.id) {
                    guard let self else { return }
                    defer {
                        if self.displayPreparationID == id { self.displayPreparation = nil }
                    }
                    do {
                        let prepared = try await self.scenePreparation(item)
                        guard !Task.isCancelled, self.displayPreparationID == id,
                            self.generation == ticket, self.active == item,
                            self.transitionRequest == nil
                        else { return }
                        self.reconcileDesktopDisplays(item, prepared: prepared)
                    } catch {
                        guard !Task.isCancelled, self.displayPreparationID == id,
                            self.generation == ticket, self.active == item
                        else { return }
                        self.presentWallpaperFailure(error, item: item, operation: .playbackError)
                    }
                }
            }
            if let displayPreparation { runtimeTasks.track(displayPreparation) }
        }
    }

    @objc func systemSleep() {
        conditions.systemSleeping = true
        updatePolicy()
    }
    @objc func systemWake() {
        conditions.systemSleeping = false
        updatePolicy()
    }
    @objc func screenSleep() {
        conditions.sleeping = true
        updatePolicy()
    }
    @objc func screenWake() {
        conditions.sleeping = false
        updatePolicy()
    }
    @objc func sessionInactive() {
        conditions.inactive = true
        updatePolicy()
    }
    @objc func sessionActive() {
        conditions.inactive = false
        updatePolicy()
    }
    @objc func updatePolicy() {
        guard !maintenanceStopped, maintenance.allowsMutation else { return }

        conditions.manual = manuallyPaused
        conditions.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        conditions.hot = [.serious, .critical].contains(ProcessInfo.processInfo.thermalState)
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        {
            conditions.onBattery = (type as String) == kIOPSBatteryPowerValue
        }
        let reason = conditions.reason(conserve: conserve, pauseOnBattery: pauseOnBattery)
        if pauseReason != reason { pauseReason = reason }
        // Apply will either replace the renderers or keep their frozen coverage during preparation.
        if clearingManualPauseForApply { return }
        if reason != nil { cancelTransition() }
        if reason != nil, preparing {
            generation = UUID()
            preparation?.cancel()
            preparation = nil
            preparing = false
        }
        let reasons = conditions.reasons(conserve: conserve, pauseOnBattery: pauseOnBattery)
        if !Renderer.canRetainScene(for: reasons) || conditions.surfaceUnavailable {
            cancelDisplayPreparation()
        }
        for renderer in renderers where !(transitionRequest != nil && renderer.hasFrozenScene) {
            renderer.applyPauseReasons(reasons, surfaceAvailable: !conditions.surfaceUnavailable)
        }
        if reason == nil, let deferred = deferredFrozenApply {
            deferredFrozenApply = nil
            startApply(currentPlaybackRecord(deferred.wallpaper), request: deferred.request)
            return
        }
        guard let active else {
            playbackStatus = .ready
            return
        }
        if displayReconciliationPending, active.sceneSource == .nativeWSS,
            pendingApply == nil, transitionRequest == nil, !preparing,
            defaults.string(forKey: "activeWallpaper") == active.id.uuidString
        {
            reconcileDesktopDisplays(active)
            if let reason { playbackStatus = .paused(reason) }
            return
        }
        if let reason {
            playbackStatus = .paused(reason)
            return
        }
        if renderers.isEmpty, !preparing {
            prepare(active)
            return
        }
        if !preparing {
            playbackStatus = .playing(displayCount: renderers.count)
        }

    }
}
