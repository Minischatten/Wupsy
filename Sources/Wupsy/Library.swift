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
        didSet { if oldValue != playbackStatus { recordPlayback(.status(playbackStatus)) } }
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
            reapply()
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
    private var renaming = false
    @Published var importing = false
    @Published private(set) var preparing = false
    @Published private(set) var active: Wallpaper?
    @Published private(set) var usingOptimizedVideo = false
    private(set) var renderers: [Renderer] = []
    @Published private(set) var pauseReason: PauseReason?
    var onPlaybackCommand: ((WallpaperPlaybackCommand) -> Void)?
    var isLibraryReadable: Bool { storageLoadError == nil }
    private var conditions = PlaybackConditions()
    private var preparation: Task<Void, Never>?
    private var generation = UUID()
    private var pendingApply: WallpaperApplyRequest?
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
    private let scenePreparation: (Wallpaper) async throws -> PreparedScenePlayback
    init(
        maintenance: MaintenanceCoordinator? = nil,
        storage: URL? = nil, defaults: UserDefaults = .standard, restoreOnLaunch: Bool = true,
        targetScreens: @escaping () -> [NSScreen] = { NSScreen.screens },
        rendererStart: @escaping @MainActor (Renderer, Int) throws -> Void = { renderer, _ in
            renderer.setPaused(false)
        },
        scenePreparation: @escaping (Wallpaper) async throws -> PreparedScenePlayback = {
            try await ScenePlayback.prepare(for: $0)
        }
    ) {
        self.maintenance = maintenance ?? .shared
        self.targetScreens = targetScreens
        self.rendererStart = rendererStart
        self.scenePreparation = scenePreparation
        self.storage =
            storage
            ?? ProductPaths.current.library
        managedStore = ManagedWallpaperStore(storage: self.storage)
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
        selected =
            defaults.string(forKey: "selectedWallpaper").flatMap(UUID.init(uuidString:))
            ?? items.first?.id
        favorites = Set(
            (defaults.stringArray(forKey: "favorites") ?? []).compactMap(UUID.init(uuidString:)))
        let workspace = NSWorkspace.shared.notificationCenter
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
        Task { @MainActor in request?.finish(.superseded) }
        preparation?.cancel()
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
                        let item = try await managedStore.importWallpaper(url, existing: items)
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
            let receipt = try await managedStore.saveWSSAs(snapshot)
            // Merge only this UUID; do not replace a newer in-memory library with a stale list.
            let item = receipt.project.handle.wallpaper
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            } else {
                items.append(item)
            }
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
            let receipt = try await managedStore.publishWSSDraft(snapshot)
            let item = receipt.project.handle.wallpaper
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            } else {
                items.append(item)
            }
            // Deliberately preserve selection, active playback and playlist state.
            let prepared = await ImageLoader.shared.committedWSS(
                item,
                basis: receipt.project.diskBasis, resources: receipt.project.resources)
            NotificationCenter.default.post(name: .wssPreviewCommitted, object: item.id)
            return WSSSaveAsReceipt(
                operationID: receipt.operationID, project: receipt.project,
                warnings: receipt.warnings
                    + (prepared
                        ? []
                        : [EditorText.thumbnailWarning.text]))

        }
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
            item.kind == .scene
        else { throw WSSEditorOpenError.unavailable }
        return try managedStore.resolve(item)
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
            let saved = try await managedStore.rename(wallpaperID: wallpaperID, newTitle: title)
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
        _ item: Wallpaper, source: WallpaperApplySource = .manual
    ) -> WallpaperApplyRequest {
        guard !maintenanceStopped, maintenance.allowsMutation else {
            let request = WallpaperApplyRequest()
            request.finish(.superseded)
            return request
        }

        if source == .manual { onPlaybackCommand?(.manualApply) }
        if pendingApply != nil { stopPlayback(preserveSelection: true) }
        let request = WallpaperApplyRequest()
        if removingWallpaper == item.id {
            reject(request, ProductText.operationWait.text)
            return request
        }
        guard item.kind == .scene || FileManager.default.fileExists(atPath: item.path) else {
            reject(
                request, ProductText.wallpaperMissing.text)
            return request
        }
        stopPlayback(preserveSelection: true)
        pendingApply = request
        request.cancel = { [weak self, weak request] in
            guard let self, let request, self.pendingApply === request else { return }
            self.stopPlayback(preserveSelection: true)
        }
        active = item
        updatePolicy()
        return request

    }
    private func reject(_ request: WallpaperApplyRequest, _ text: String) {
        message = text
        request.finish(.failed(ImportFailure.message(text)))
    }
    private func showProductError(_ detail: String, presentation: ProductText) {
        message = detail
        messagePresentation = presentation.text
    }
    private func failPreparation(_ error: Error) {
        showProductError(error.localizedDescription, presentation: .playbackError)
        pendingApply?.finish(.failed(error))
        pendingApply = nil
        stopPlayback(preserveSelection: true)
    }
    private func rendererFailed(_ diagnostic: RuntimeDiagnostic, ticket: UUID) {
        let text = diagnostic.technicalDescription
        guard generation == ticket else { return }
        if startingRenderers {
            startupError = startupError ?? text
        } else {
            // Resume can report a synchronous load error inside updatePolicy's
            // renderer loop. Defer policy mutation to avoid reentrant unpausing.
            Task { @MainActor [weak self] in
                guard let self, self.generation == ticket else { return }
                self.showProductError(text, presentation: .playbackError)
                self.messagePresentation = diagnostic.localized()
                self.recordPlayback(.diagnostic(diagnostic))
                self.manuallyPaused = true
            }
        }
    }
    private func prepare(_ item: Wallpaper) {
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
                    let optimizer = VideoOptimizer()
                    let scenePlayback =
                        item.kind == .scene
                        ? try await scenePreparation(item) : nil
                    let url = try await optimizer.preparedURL(for: item, profile: quality)
                    try Task.checkCancellation()
                    guard generation == ticket else { return }
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
                            onError: { [weak self] error in
                                self?.rendererFailed(error, ticket: ticket)
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
                    defaults.set(item.id.uuidString, forKey: "activeWallpaper")
                    pendingApply?.finish(.accepted)
                    pendingApply = nil
                    updatePolicy()
                } catch {
                    guard generation == ticket, !Task.isCancelled else { return }
                    failPreparation(error)
                }

            }
        }
        if let preparation { runtimeTasks.track(preparation) }

    }
    // Shared native player/window construction. Refresh never enters apply() or emits a playlist command.
    private func makeRenderer(
        _ item: Wallpaper, screen: NSScreen, mediaURL: URL, quality: QualityProfile,
        playback: PreparedScenePlayback?, ticket: UUID,
        onError: @escaping (RuntimeDiagnostic) -> Void
    ) -> Renderer {
        Renderer(
            maintenance: maintenance, wallpaper: item, screen: screen, mediaURL: mediaURL,
            profile: quality,
            initiallyPaused: true, scenePlayback: playback, sceneFPS: sceneFPS,
            sceneRenderResolution: sceneRenderResolution,
            onEvent: { [weak self] event in
                guard let self, self.generation == ticket else { return }
                self.recordPlayback(.diagnostic(event))
            }, onDiagnostic: onError, onError: { onError(.failure($0)) })
    }

    private func refreshActiveWallpaper(id: UUID, playback: PreparedScenePlayback) throws {
        guard !maintenanceStopped, maintenance.allowsMutation else { return }

        guard let item = active, item.id == id else { return }
        let previousGeneration = generation
        let ticket = UUID()
        let available = targetScreens()
        let screens = allDisplays ? available : Array(available.prefix(1))
        guard !screens.isEmpty else {
            throw ImportFailure.message(ProductText.noDisplay.text)
        }
        var replacements: [Renderer] = []
        var installing = true
        var startupFailure: String?
        do {
            for (index, screen) in screens.enumerated() {
                let renderer = makeRenderer(
                    item, screen: screen, mediaURL: item.url, quality: profile,
                    playback: playback, ticket: ticket,
                    onError: { [weak self] text in
                        if installing {
                            startupFailure = text.technicalDescription
                        } else {
                            self?.rendererFailed(text, ticket: ticket)
                        }
                    })
                replacements.append(renderer)
                try rendererStart(renderer, index)
                if let startupFailure { throw ImportFailure.message(startupFailure) }
            }
            guard active?.id == id, generation == previousGeneration else {
                throw CancellationError()
            }
            // Keep a paused desktop paused; no policy or playlist transition is emitted.
            for renderer in replacements { renderer.setPaused(pauseReason != nil) }
            if let startupFailure { throw ImportFailure.message(startupFailure) }
        } catch {
            installing = false
            for renderer in replacements { retire(renderer) }
            throw error
        }
        let old = renderers
        generation = ticket
        preparation?.cancel()
        preparation = nil
        preparing = false
        renderers = replacements
        installing = false
        for renderer in old { retire(renderer) }
        pendingApply?.finish(.accepted)
        pendingApply = nil

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

        guard let item = active else { return }
        let request = pendingApply
        pendingApply = nil
        stopPlayback(preserveSelection: true)
        pendingApply = request
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
                    let warning = try await managedStore.remove(existing, existing: items)
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
        stopPlayback(preserveSelection: preserveSelection)

    }
    private func stopPlayback(preserveSelection: Bool = false) {
        pendingApply?.finish(.superseded)
        pendingApply = nil
        if !preserveSelection { defaults.removeObject(forKey: "activeWallpaper") }
        generation = UUID()
        preparation?.cancel()
        preparation = nil
        preparing = false
        for renderer in renderers { retire(renderer) }
        renderers.removeAll()
        active = nil
        usingOptimizedVideo = false
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

            stop()
            do {
                try VideoOptimizer().trim(to: 0)
                Task { await ImageLoader.shared.clear() }
            } catch { showProductError(error.localizedDescription, presentation: .cacheError) }

        }
    }
    @objc private func screenSleep() {
        conditions.sleeping = true
        updatePolicy()
    }
    @objc private func screenWake() {
        conditions.sleeping = false
        updatePolicy()
    }
    @objc private func sessionInactive() {
        conditions.inactive = true
        updatePolicy()
    }
    @objc private func sessionActive() {
        conditions.inactive = false
        updatePolicy()
    }
    @objc private func displaysChanged() { reapply() }
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
        if reason != nil, preparing {
            generation = UUID()
            preparation?.cancel()
            preparation = nil
            preparing = false
        }
        for renderer in renderers { renderer.setPaused(reason != nil) }
        guard let active else {
            playbackStatus = .ready
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
