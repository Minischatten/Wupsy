import AppKit
import Combine
import Foundation

enum PlaylistPlaybackMode: String, Codable, CaseIterable {
    case inOrder
    case shuffle

    var title: String {
        self == .inOrder ? ProductText.playlistInOrder.text : ProductText.playlistShuffle.text
    }
}

struct PlaylistDefinition: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var wallpaperIDs: [UUID] = []
    var intervalSeconds = 900
    var playbackMode: PlaylistPlaybackMode = .inOrder

    private enum CodingKeys: String, CodingKey {
        case id, name, wallpaperIDs, intervalSeconds, playbackMode
    }

    init(
        id: UUID = UUID(), name: String, wallpaperIDs: [UUID] = [],
        intervalSeconds: Int = 900, playbackMode: PlaylistPlaybackMode = .inOrder
    ) {
        self.id = id
        self.name = name
        self.wallpaperIDs = wallpaperIDs
        self.intervalSeconds = intervalSeconds
        self.playbackMode = playbackMode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        wallpaperIDs = try values.decode([UUID].self, forKey: .wallpaperIDs)
        intervalSeconds = try values.decode(Int.self, forKey: .intervalSeconds)
        playbackMode =
            values.contains(.playbackMode)
            ? try values.decode(PlaylistPlaybackMode.self, forKey: .playbackMode) : .inOrder
    }

    static let intervalValues = [5, 10, 60, 300, 900, 1800, 3600, 7200, 21600, 86400]
    static var intervals: [(seconds: Int, title: String)] {
        intervalValues.map { ($0, intervalTitle($0)) }
    }
    static func intervalTitle(_ seconds: Int, language: String? = nil) -> String {
        if seconds < 60 {
            return ProductText.intervalTestSeconds.format(Int64(seconds), language: language)
        }
        if seconds < 3600 {
            return ProductText.intervalMinutes.format(Int64(seconds / 60), language: language)
        }
        return ProductText.intervalHours.format(Int64(seconds / 3600), language: language)
    }

}

struct PlaylistPlaybackState: Codable, Equatable {
    var playlistID: UUID
    var enabled: Bool
    var currentWallpaperID: UUID?
}

struct PlaylistCollectionState: Codable, Equatable {
    var version = 1
    var definitions: [PlaylistDefinition] = []
    var playback: PlaylistPlaybackState?

    func validate() throws {
        guard version == 1, definitions.count <= 1_000,
            Set(definitions.map(\.id)).count == definitions.count,
            definitions.reduce(0, { $0 + $1.wallpaperIDs.count }) <= 10_000
        else { throw ImportFailure.message("Invalid or unsupported playlists data.") }
        for definition in definitions {
            guard try WallpaperTitle.normalized(definition.name) == definition.name,
                Set(definition.wallpaperIDs).count == definition.wallpaperIDs.count,
                PlaylistDefinition.intervalValues.contains(definition.intervalSeconds)
            else { throw ImportFailure.message("Invalid playlist definition.") }
        }
        if let playback {
            guard let definition = definitions.first(where: { $0.id == playback.playlistID }),
                playback.currentWallpaperID.map({ definition.wallpaperIDs.contains($0) }) ?? true,
                !playback.enabled || definition.wallpaperIDs.count >= 2
            else { throw ImportFailure.message("Invalid playlist playback reference.") }
        }
    }
}

/// Only the new collection format is supported. No legacy file is consulted.
struct WallpaperPlaylistStore {
    static var defaultURL: URL {
        ProductPaths.current.playlists
    }
    static let byteLimit = 1024 * 1024
    let url: URL
    private let rootWasSymlink: Bool

    init(url: URL) {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        rootWasSymlink =
            (try? FileManager.default.attributesOfItem(atPath: parent.path)[.type])
            as? FileAttributeType == .typeSymbolicLink
        self.url = parent.resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
    }
    private func checkPaths() throws {
        try LibraryMetadataRecovery.requireReadable(root: url.deletingLastPathComponent())
        guard !rootWasSymlink else { throw ImportFailure.message("Unsafe playlists storage root.") }
        try ManagedWallpaperStore.checkPath(url.deletingLastPathComponent())
        try ManagedWallpaperStore.checkPath(url)
    }
    func load() throws -> PlaylistCollectionState {
        try checkPaths()
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.byteLimit else {
            throw ImportFailure.message("Playlists data is too large.")
        }
        let state = try JSONDecoder().decode(
            PlaylistCollectionState.self, from: Data(contentsOf: url))
        try state.validate()
        return state
    }
    func save(_ state: PlaylistCollectionState) throws {
        try state.validate()
        let data = try JSONEncoder().encode(state)
        guard data.count <= Self.byteLimit else {
            throw ImportFailure.message("Playlists data is too large.")
        }
        try checkPaths()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

@MainActor protocol PlaylistScheduling {
    var now: TimeInterval { get }
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void)
        -> AnyCancellable
}

@MainActor final class PlaylistScheduler: PlaylistScheduling {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void)
        -> AnyCancellable
    {
        let task = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
        return AnyCancellable { task.cancel() }
    }
}

/// One collection, one confirmed playback, one request and at most one timer.
@MainActor final class WallpaperPlaylist: ObservableObject {
    @Published private(set) var state = PlaylistCollectionState()
    @Published private(set) var selectedPlaylistID: UUID?
    @Published private(set) var pendingActivationID: UUID?
    @Published private(set) var pendingWallpaperID: UUID?
    @Published private(set) var suspended = false
    @Published private(set) var recovering = false
    // Diagnostic detail remains available to tests and internal inspection.
    @Published private(set) var error: String? { didSet { errorPresentation = nil } }
    @Published private var errorPresentation: String?
    var presentedError: String? {
        error == nil ? nil : errorPresentation ?? ProductText.playlistActionError.text
    }
    private var available: [UUID: Wallpaper] = [:]
    private var excluded: Set<UUID> = []
    private let store: WallpaperPlaylistStore
    private let scheduler: any PlaylistScheduling
    private let defaults: UserDefaults
    private let apply: @MainActor (Wallpaper) -> WallpaperApplyRequest
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: AnyCancellable?
    private var deadline: TimeInterval?
    private var remaining: TimeInterval = 0
    private var operation: Task<Void, Never>?
    private var request: WallpaperApplyRequest?
    private var generation = UUID()
    private var storageReadable = true
    private var runtimeStopped = false
    private var shuttingDown = false
    private let shuffle: ([UUID]) -> [UUID]
    private struct ShuffleBag: Equatable {
        let token = UUID()
        let playlistID: UUID
        var remainingIDs: [UUID]
    }
    private var shuffleBag: ShuffleBag?

    func canSetPlaybackMode(_ id: UUID) -> Bool {
        canEditDefinition(id) && !(id == activePlaylistID && pendingWallpaperID != nil)
    }

    /// A missing bag starts a partial round with Current already consumed.
    private func nextCandidate(_ id: UUID, current: UUID?) -> UUID? {
        guard let value = definition(id), !value.wallpaperIDs.isEmpty else { return nil }
        guard value.playbackMode == .shuffle else {
            let index = current.flatMap { value.wallpaperIDs.firstIndex(of: $0) }
            return value.wallpaperIDs[index.map { ($0 + 1) % value.wallpaperIDs.count } ?? 0]
        }
        if shuffleBag?.playlistID != id {
            shuffleBag = ShuffleBag(
                playlistID: id, remainingIDs: shuffle(value.wallpaperIDs.filter { $0 != current }))
        } else if shuffleBag?.remainingIDs.isEmpty == true {
            var ids = shuffle(value.wallpaperIDs)
            if ids.count >= 2, ids.first == current { ids.swapAt(0, 1) }
            shuffleBag = ShuffleBag(playlistID: id, remainingIDs: ids)
        }
        return shuffleBag?.remainingIDs.first
    }

    private struct Recovery {
        let playback: PlaylistPlaybackState
        let remaining: TimeInterval
    }
    private enum Purpose {
        case rotation(UUID)
        case activation(UUID, Recovery?)
        case recovery(Recovery, String)
    }

    private let maintenance: MaintenanceCoordinator
    private let runtimeTasks = RuntimeTaskDrain()
    var canEdit: Bool { storageReadable && !shuttingDown && maintenance.allowsMutation }
    var activePlaylistID: UUID? {
        guard !runtimeStopped, state.playback?.enabled == true else { return nil }
        return state.playback?.playlistID
    }
    var status: String { localizedStatus() }
    func localizedStatus(language: String? = nil) -> String {
        if let presentedError { return presentedError }
        if recovering { return ProductText.playlistRecovering.localized(language: language) }
        if let id = pendingActivationID {
            return ProductText.playlistActivating.format(
                definition(id)?.name ?? ProductText.playlistDefault.localized(language: language),
                language: language)
        }
        guard let id = activePlaylistID else {
            return ProductText.rotationOff.localized(language: language)
        }
        let name = definition(id)?.name ?? ProductText.playlistDefault.localized(language: language)
        if pendingWallpaperID != nil {
            return ProductText.playlistWaiting.format(name, language: language)
        }
        let resource: ProductText =
            suspended
            ? .playlistPaused
            : definition(id)?.playbackMode == .shuffle ? .playlistShuffling : .playlistPlayingOrder
        return resource.format(name, language: language)
    }
    func definition(_ id: UUID) -> PlaylistDefinition? { state.definitions.first { $0.id == id } }
    func canEditDefinition(_ id: UUID) -> Bool {
        canEdit && definition(id) != nil
            && (pendingActivationID == nil || (id != pendingActivationID && id != activePlaylistID))
    }
    func canDelete(_ id: UUID) -> Bool {
        canEditDefinition(id) && !(id == activePlaylistID && pendingWallpaperID != nil)
    }
    func canActivate(_ id: UUID) -> Bool {
        guard canEdit, let value = definition(id), value.wallpaperIDs.count >= 2 else {
            return false
        }
        return value.wallpaperIDs.allSatisfy { available[$0] != nil }
    }

    init(
        library: Library, storage: URL, defaults: UserDefaults = .standard,
        scheduler: (any PlaylistScheduling)? = nil, restoreOnLaunch: Bool = true,
        apply: (@MainActor (Wallpaper) -> WallpaperApplyRequest)? = nil,
        shuffle: @escaping ([UUID]) -> [UUID] = { $0.shuffled() }
    ) {
        maintenance = library.maintenance
        self.shuffle = shuffle
        store = WallpaperPlaylistStore(url: storage)
        self.defaults = defaults
        self.scheduler = scheduler ?? PlaylistScheduler()
        self.apply =
            apply ?? { [weak library] wallpaper in
                guard let library else {
                    let request = WallpaperApplyRequest()
                    request.finish(.superseded)
                    return request
                }
                return library.apply(wallpaper, source: .automatic)
            }
        refreshAvailable(library.items)
        do {
            guard library.isLibraryReadable else {
                throw ImportFailure.message(
                    "The library must be readable before editing playlists.")
            }
            let loaded = try store.load()
            let cleaned = cleanedState(loaded)
            if cleaned != loaded { try store.save(cleaned) }
            state = cleaned
        } catch {
            storageReadable = false
            runtimeStopped = true
            self.error = "Could not load playlists safely: \(error.localizedDescription)"
            self.errorPresentation = ProductText.playlistLoadError.text
        }
        let savedSelection = defaults.string(forKey: "selectedPlaylistID").flatMap(
            UUID.init(uuidString:))
        select(
            savedSelection.flatMap { definition($0)?.id } ?? activePlaylistID
                ?? state.definitions.first?.id)
        library.onPlaybackCommand = { [weak self] command in
            switch command {
            case .manualApply, .stop: self?.disableAll()
            case .shutdown: self?.shutdown()
            case .remove(let id): self?.excludeWallpaper(id)
            }
        }
        library.$items.dropFirst().sink { [weak self] items in self?.updateLibrary(items) }.store(
            in: &subscriptions)
        library.$preparing.combineLatest(library.$pauseReason).sink {
            [weak self] preparing, reason in
            self?.setSuspended(preparing || reason != nil)
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink {
            [weak self] _ in
            self?.shutdown()
        }.store(in: &subscriptions)
        let unresolved = state.definitions.contains { value in
            value.wallpaperIDs.contains { available[$0] == nil }
        }
        if unresolved {
            runtimeStopped = true
            error = "Playlist references are unresolved; membership has been preserved."
            self.errorPresentation = ProductText.playlistReferencesError.text
        }
        if restoreOnLaunch, storageReadable, !unresolved {
            if let id = activePlaylistID, let value = definition(id) {
                pendingActivationID = id
                beginApply(
                    state.playback?.currentWallpaperID ?? nextCandidate(id, current: nil)
                        ?? value.wallpaperIDs[0],
                    purpose: .activation(id, nil))
            } else {
                library.restorePlayback()
            }
        }
    }
    deinit {
        timer?.cancel()
        operation?.cancel()
    }

    func select(_ id: UUID?) {
        guard !shuttingDown, let admission = try? maintenance.beginMutation() else { return }
        defer { admission.finish() }

        selectedPlaylistID = id.flatMap { definition($0)?.id }
        defaults.set(selectedPlaylistID?.uuidString, forKey: "selectedPlaylistID")

    }
    /// UI actions share one error surface; dialogs may catch throwing operations themselves.
    func perform(_ action: () throws -> Void) {
        do { try action() } catch {
            self.error = error.localizedDescription
            self.errorPresentation =
                (error as? ProductCoreError)?.resource.text ?? ProductText.playlistActionError.text
        }
    }
    private func commit(_ next: PlaylistCollectionState) throws {
        let admission = try maintenance.beginMutation()
        defer { admission.finish() }

        let backupLease =
            next.definitions != state.definitions
            ? try LibraryMutationBarrier.shared.mutation() : nil
        defer { withExtendedLifetime(backupLease) {} }
        guard canEdit else {
            throw ProductCoreError(.playlistUnavailable)
        }
        guard next != state else { return }
        try store.save(next)
        state = next

    }
    @discardableResult func createPlaylist(name: String) throws -> UUID {
        let value = PlaylistDefinition(name: try WallpaperTitle.normalized(name))
        var next = state
        next.definitions.append(value)
        try commit(next)
        select(value.id)
        return value.id
    }
    func renamePlaylist(id: UUID, newName: String) throws {
        let name = try WallpaperTitle.normalized(newName)
        guard let index = state.definitions.firstIndex(where: { $0.id == id }) else {
            throw missing()
        }
        var next = state
        next.definitions[index].name = name
        try commit(next)
    }
    func deletePlaylist(id: UUID) throws {
        guard canDelete(id), let index = state.definitions.firstIndex(where: { $0.id == id }) else {
            throw ProductCoreError(.playlistWaitDelete)
        }
        let wasActive = activePlaylistID == id
        var next = state
        next.definitions.remove(at: index)
        if next.playback?.playlistID == id { next.playback = nil }
        try commit(next)
        if wasActive { invalidateWork() }
        if selectedPlaylistID == id {
            select(
                next.definitions.isEmpty
                    ? nil : next.definitions[min(index, next.definitions.count - 1)].id)
        }
    }
    private func missing() -> ProductCoreError { ProductCoreError(.playlistMissing) }
    private func edit(_ id: UUID, _ change: (inout PlaylistDefinition) throws -> Void) throws {
        guard canEditDefinition(id),
            let index = state.definitions.firstIndex(where: { $0.id == id })
        else {
            throw ProductCoreError(.playlistWaitEdit)
        }
        let previous = state
        var next = state
        try change(&next.definitions[index])
        next = cleanedState(next)
        try commit(next)
        reconcile(previous)
    }
    func add(_ wallpaperID: UUID, to playlistID: UUID) throws {
        guard available[wallpaperID] != nil else {
            throw ProductCoreError(.playlistItemUnavailable)
        }
        try edit(playlistID) { value in
            if !value.wallpaperIDs.contains(wallpaperID) { value.wallpaperIDs.append(wallpaperID) }
        }
    }
    func remove(_ wallpaperID: UUID, from playlistID: UUID) throws {
        try edit(playlistID) { $0.wallpaperIDs.removeAll { $0 == wallpaperID } }
    }
    func move(_ wallpaperID: UUID, by offset: Int, in playlistID: UUID) throws {
        try edit(playlistID) { value in
            guard let index = value.wallpaperIDs.firstIndex(of: wallpaperID),
                value.wallpaperIDs.indices.contains(index + offset)
            else { return }
            value.wallpaperIDs.swapAt(index, index + offset)
        }
    }
    func move(fromOffsets source: IndexSet, toOffset destination: Int, in playlistID: UUID) throws {
        try edit(playlistID) { value in
            let ids = value.wallpaperIDs
            guard !source.isEmpty, source.allSatisfy({ ids.indices.contains($0) }),
                (0...ids.count).contains(destination)
            else { return }
            let moving = source.map { ids[$0] }
            var reordered = ids.enumerated().filter { !source.contains($0.offset) }.map(\.element)
            reordered.insert(
                contentsOf: moving, at: destination - source.filter { $0 < destination }.count)
            value.wallpaperIDs = reordered
        }
    }
    @discardableResult func acceptDrop(
        _ item: PlaylistReorderItem, before target: UUID?, in playlistID: UUID
    ) -> Bool {
        guard item.sourcePlaylistID == playlistID, canEditDefinition(playlistID),
            let ids = definition(playlistID)?.wallpaperIDs,
            let source = ids.firstIndex(of: item.wallpaperID)
        else { return false }
        let destination: Int
        if let target {
            guard let index = ids.firstIndex(of: target) else { return false }
            destination = index
        } else {
            destination = ids.count
        }
        do {
            try move(fromOffsets: IndexSet(integer: source), toOffset: destination, in: playlistID)
            return true
        } catch {
            self.error = error.localizedDescription
            self.errorPresentation =
                (error as? ProductCoreError)?.resource.text ?? ProductText.playlistActionError.text
            return false
        }
    }
    func setPlaybackMode(playlistID: UUID, mode: PlaylistPlaybackMode) throws {
        guard canSetPlaybackMode(playlistID) else {
            throw ProductCoreError(.playlistWaitMode)
        }
        guard definition(playlistID)?.playbackMode != mode else { return }
        try edit(playlistID) { $0.playbackMode = mode }
        if shuffleBag?.playlistID == playlistID { shuffleBag = nil }
    }
    func setInterval(_ seconds: Int, for playlistID: UUID) throws {
        guard PlaylistDefinition.intervalValues.contains(seconds) else {
            throw ProductCoreError(.playlistIntervalError)
        }
        try edit(playlistID) { $0.intervalSeconds = seconds }
        if activePlaylistID == playlistID {
            freezeTimer()
            remaining = TimeInterval(seconds)
            armTimer()
        }
    }
    func activatePlaylist(id: UUID) {
        guard canActivate(id), let value = definition(id) else {
            error =
                "Add at least two different, uniquely available library wallpapers before activating this playlist."
            self.errorPresentation = ProductText.playlistMinimum.text
            return
        }
        if pendingActivationID == id || (activePlaylistID == id && pendingActivationID == nil) {
            return
        }
        freezeTimer()
        let recovery = activePlaylistID.flatMap { _ in state.playback }.flatMap {
            playback -> Recovery? in
            guard let current = playback.currentWallpaperID, available[current] != nil else {
                return nil
            }
            return Recovery(playback: playback, remaining: remaining)
        }
        invalidateWork()
        error = nil
        pendingActivationID = id
        let target = activePlaylistID == id ? state.playback?.currentWallpaperID : nil
        beginApply(
            target ?? nextCandidate(id, current: nil) ?? value.wallpaperIDs[0],
            purpose: .activation(id, recovery))
    }
    func deactivatePlaylist(id: UUID) {
        guard activePlaylistID == id || pendingActivationID == id else { return }
        disableAll()
    }
    private func disableAll() {
        // Invalidate even if storage is unwritable, so manual Apply/Stop always wins.
        invalidateWork()
        var next = state
        next.playback?.enabled = false
        do {
            try commit(next)
            runtimeStopped = false
        } catch {
            runtimeStopped = true
            self.error = error.localizedDescription
            self.errorPresentation =
                (error as? ProductCoreError)?.resource.text ?? ProductText.playlistActionError.text
        }
    }
    private func refreshAvailable(_ items: [Wallpaper]) {
        let groups = Dictionary(grouping: items, by: \.id)
        available = groups.compactMapValues { $0.count == 1 ? $0.first : nil }.filter {
            !excluded.contains($0.key)
        }
    }
    private func cleanedState(_ value: PlaylistCollectionState) -> PlaylistCollectionState {
        var result = value
        for index in result.definitions.indices {
            // Only a confirmed successful Library.remove may permanently prune IDs.
            // Missing/duplicate items or a readable but damaged [] index are not deletions.
            result.definitions[index].wallpaperIDs.removeAll { excluded.contains($0) }
        }
        if let playback = result.playback {
            if let value = result.definitions.first(where: { $0.id == playback.playlistID }) {
                if let current = playback.currentWallpaperID, !value.wallpaperIDs.contains(current)
                {
                    result.playback?.currentWallpaperID = nil
                }
                if value.wallpaperIDs.count < 2 { result.playback?.enabled = false }
            } else {
                result.playback = nil
            }
        }
        return result
    }
    private func excludeWallpaper(_ id: UUID) {
        excluded.insert(id)
        available.removeValue(forKey: id)
        cleanLibraryReferences()
    }
    private func updateLibrary(_ items: [Wallpaper]) {
        refreshAvailable(items)
        let involved = [
            pendingActivationID, state.playback?.enabled == true ? state.playback?.playlistID : nil,
        ].compactMap { $0 }
        if involved.contains(where: { id in
            definition(id)?.wallpaperIDs.contains(where: { available[$0] == nil }) == true
        }) {
            invalidateWork()
            runtimeStopped = true
            error =
                "Rotation stopped because references are unresolved; membership has been preserved."
            self.errorPresentation = ProductText.playlistStoppedReferences.text
        }
        cleanLibraryReferences()
    }
    private func cleanLibraryReferences() {
        let previous = state
        let next = cleanedState(state)
        guard next != state else { return }
        do {
            try commit(next)
            reconcile(previous)
        } catch { stopForStorageError(error) }
    }
    private func reconcile(_ previous: PlaylistCollectionState) {
        if let bag = shuffleBag,
            previous.definitions.first(where: { $0.id == bag.playlistID })?.wallpaperIDs
                != definition(bag.playlistID)?.wallpaperIDs
        {
            shuffleBag = nil
        }
        if let pending = pendingActivationID {
            let involved = [pending, previous.playback?.playlistID].compactMap { $0 }
            if involved.contains(where: { id in
                previous.definitions.first { $0.id == id }?.wallpaperIDs
                    != definition(id)?.wallpaperIDs
            }) {
                halt(
                    "Rotation stopped because wallpapers involved in the activation were removed.",
                    presentation: ProductText.playlistStoppedRemoved.text)
            }
            return
        }
        guard previous.playback?.enabled == true else { return }
        guard let id = activePlaylistID, let value = definition(id) else {
            invalidateWork()
            return
        }
        let currentRemoved =
            previous.playback?.currentWallpaperID != nil
            && state.playback?.currentWallpaperID == nil
        let pendingRemoved = pendingWallpaperID.map { !value.wallpaperIDs.contains($0) } ?? false
        if currentRemoved || pendingRemoved {
            invalidateWork()
            beginApply(
                state.playback?.currentWallpaperID ?? nextCandidate(id, current: nil)
                    ?? value.wallpaperIDs[0], purpose: .rotation(id))
        }
    }
    private func freezeTimer() {
        if let deadline { remaining = max(0, deadline - scheduler.now) }
        timer?.cancel()
        timer = nil
        deadline = nil
    }
    private func invalidateWork() {
        shuffleBag = nil
        generation = UUID()
        freezeTimer()
        request?.cancel?()
        request = nil
        operation?.cancel()
        operation = nil
        pendingWallpaperID = nil
        pendingActivationID = nil
        recovering = false
    }
    private func beginApply(_ wallpaperID: UUID, purpose: Purpose) {
        guard !shuttingDown, let admission = try? maintenance.beginMutation(kind: .runtime) else {
            return
        }

        guard !shuttingDown, let wallpaper = available[wallpaperID] else {
            admission.finish()
            halt(
                "Rotation stopped because the wallpaper is no longer available.",
                presentation: ProductText.playlistStoppedMissing.text)
            return
        }
        freezeTimer()
        generation = UUID()
        let ticket = generation
        pendingWallpaperID = wallpaperID
        let reservedBag = shuffleBag
        let request = apply(wallpaper)
        self.request = request
        operation = Task { [weak self] in
            defer { admission.finish() }
            await MaintenanceOperation.$id.withValue(admission.id) {

                let outcome = await request.outcome
                guard let self, self.generation == ticket, !Task.isCancelled else { return }
                self.request = nil
                self.operation = nil
                self.pendingWallpaperID = nil
                switch outcome {
                case .accepted:
                    self.accept(wallpaperID, purpose: purpose, reservedBag: reservedBag)
                case .failed(let error):
                    let message = "\(wallpaper.title) — \(error.localizedDescription)"
                    if case .activation(_, let recovery?) = purpose,
                        self.canActivate(recovery.playback.playlistID),
                        let current = recovery.playback.currentWallpaperID,
                        self.available[current] != nil
                    {
                        self.shuffleBag = nil
                        self.recovering = true
                        self.beginApply(current, purpose: .recovery(recovery, message))
                    } else if case .recovery(_, let original) = purpose {
                        self.halt(
                            "Activation failed: \(original). Restoring the previous playlist also failed: \(message)",
                            presentation: ProductText.playlistRecoveryFailed.text
                        )
                    } else {
                        self.halt(
                            "Rotation stopped: \(message)",
                            presentation: ProductText.playlistActivationError.format(
                                wallpaper.title))
                    }
                case .superseded:
                    self.halt(
                        "Rotation stopped because playback was replaced or cancelled.",
                        presentation: ProductText.playlistStoppedReplaced.text)
                }

            }
        }
        if let operation { runtimeTasks.track(operation) }

    }
    private func accept(_ wallpaperID: UUID, purpose: Purpose, reservedBag: ShuffleBag?) {
        var next = state
        let seconds: TimeInterval
        switch purpose {
        case .rotation(let id), .activation(let id, _):
            guard let value = definition(id), canActivate(id),
                value.wallpaperIDs.contains(wallpaperID)
            else {
                halt(
                    "Rotation stopped because the playlist changed during playback preparation.",
                    presentation: ProductText.playlistStoppedChanged.text)
                return
            }
            next.playback = PlaylistPlaybackState(
                playlistID: id, enabled: true, currentWallpaperID: wallpaperID)
            seconds = TimeInterval(value.intervalSeconds)
        case .recovery(let recovery, let original):
            next.playback = recovery.playback
            seconds = recovery.remaining
            error =
                "Could not activate the requested playlist: \(original). Previous playlist restored."
            self.errorPresentation = ProductText.playlistRecoverySucceeded.text
        }
        do { try commit(next) } catch {
            stopForStorageError(error)
            return
        }
        if let reservedBag, shuffleBag == reservedBag,
            reservedBag.remainingIDs.first == wallpaperID
        {
            shuffleBag?.remainingIDs.removeFirst()
        }
        runtimeStopped = false
        pendingActivationID = nil
        recovering = false
        remaining = seconds
        armTimer()
    }
    private func stopForStorageError(_ error: Error) {
        runtimeStopped = true
        invalidateWork()
        self.error =
            "Rotation stopped because playlists could not be saved: \(error.localizedDescription)"
        self.errorPresentation = ProductText.playlistSaveError.text
    }
    private func halt(_ message: String, presentation: String) {
        disableAll()
        let previous = presentedError
        error = error.map { message + " " + $0 } ?? message
        errorPresentation =
            previous.map { ProductText.additionalIssue.format(presentation, $0) } ?? presentation
    }
    private func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        if value { freezeTimer() } else { armTimer() }
    }
    private func armTimer() {
        guard let id = activePlaylistID, !suspended, !shuttingDown, pendingWallpaperID == nil,
            pendingActivationID == nil, let value = definition(id), value.wallpaperIDs.count >= 2,
            timer == nil
        else { return }
        deadline = scheduler.now + remaining
        let ticket = generation
        timer = scheduler.schedule(after: remaining) { [weak self] in
            guard let self, self.generation == ticket, let deadline = self.deadline else { return }
            self.timer = nil
            self.remaining = max(0, deadline - self.scheduler.now)
            self.deadline = nil
            if self.remaining > 0 {
                self.armTimer()
                return
            }
            guard self.activePlaylistID == id else { return }
            guard
                let candidate = self.nextCandidate(
                    id, current: self.state.playback?.currentWallpaperID)
            else { return }
            self.beginApply(candidate, purpose: .rotation(id))
        }
    }
    func shutdownAndDrainForMaintenance() async {
        shutdown()
        subscriptions.removeAll()
        await runtimeTasks.cancelAndDrain()
    }
    func shutdown() {
        shuttingDown = true
        invalidateWork()
    }
}
