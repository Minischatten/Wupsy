import AppKit
import Combine
import XCTest

@testable import Wupsy

@MainActor private final class TestPlaylistScheduler: PlaylistScheduling {
    var now: TimeInterval = 0
    private var alarms: [UUID: (TimeInterval, @MainActor () -> Void)] = [:]
    var count: Int { alarms.count }
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void)
        -> AnyCancellable
    {
        let id = UUID()
        alarms[id] = (now + seconds, action)
        return AnyCancellable { [weak self] in self?.alarms.removeValue(forKey: id) }
    }
    func advance(_ seconds: TimeInterval) {
        now += seconds
        let due = alarms.filter { $0.value.0 <= now }.sorted { $0.value.0 < $1.value.0 }
        for (id, _) in due {
            guard let alarm = alarms.removeValue(forKey: id) else { continue }
            alarm.1()
        }
    }
}

@MainActor final class WallpaperPlaylistTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var library: Library!
    private var playlist: WallpaperPlaylist!
    private var clock: TestPlaylistScheduler!
    private var entries: [Wallpaper] = []
    private var applied: [Wallpaper] = []
    private var requests: [WallpaperApplyRequest] = []
    private var store: WallpaperPlaylistStore {
        WallpaperPlaylistStore(url: root.appendingPathComponent("playlists.json"))
    }

    override func setUpWithError() throws {
        suite = "WupsyMultiPlaylistTests-" + UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "conserve")
        defaults.set(false, forKey: "pauseOnBattery")
        entries = try (0..<3).map { index in
            let url = root.appendingPathComponent("\(index).png")
            let bitmap = try XCTUnwrap(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            return Wallpaper(
                title: "Wallpaper \(index)", path: url.path, root: root.path, kind: .image)
        }
        try JSONEncoder().encode(entries).write(to: root.appendingPathComponent("library.json"))
        library = Library(storage: root.appendingPathComponent("library.json"), defaults: defaults)
        clock = TestPlaylistScheduler()
        playlist = controller()
    }
    override func tearDownWithError() throws {
        playlist.shutdown()
        library.stop()
        playlist = nil
        library = nil
        for request in requests { request.finish(.superseded) }
        requests.removeAll()
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }
    private func controller(
        restore: Bool = false, realApply: Bool = false,
        shuffle: @escaping ([UUID]) -> [UUID] = { $0 }
    ) -> WallpaperPlaylist {
        let apply: (@MainActor (Wallpaper) -> WallpaperApplyRequest)?
        if realApply {
            apply = nil
        } else {
            apply = { [weak self] item in
                let request = WallpaperApplyRequest()
                self?.applied.append(item)
                self?.requests.append(request)
                return request
            }
        }
        return WallpaperPlaylist(
            library: library, storage: store.url, defaults: defaults,
            scheduler: clock, restoreOnLaunch: restore, apply: apply, shuffle: shuffle)
    }
    private func create(_ name: String = "A", order: [Int] = [0, 1, 2], interval: Int = 5) throws
        -> UUID
    {
        let id = try playlist.createPlaylist(name: name)
        for index in order { try playlist.add(entries[index].id, to: id) }
        try playlist.setInterval(interval, for: id)
        return id
    }
    func testPausedRequestDoesNotBlockEarlyMutationDrainAndStopsWithoutWriteback() async throws {
        playlist.shutdown()
        let maintenance = MaintenanceCoordinator()
        library = Library(
            maintenance: maintenance,
            storage: root.appendingPathComponent("library.json"), defaults: defaults)
        library.manuallyPaused = true
        playlist = controller(realApply: true)
        let id = try create("Paused maintenance")
        playlist.activatePlaylist(id: id)
        XCTAssertFalse(library.preparing)
        XCTAssertGreaterThan(maintenance.activeOperationCount, 0)
        let bytes = try Data(contentsOf: store.url)
        let before = defaults.persistentDomain(forName: suite)! as NSDictionary
        let job = try maintenance.reserve(.restore)
        defer { job.finish() }
        try maintenance.freeze()
        let editors = WSSEditorCoordinator(
            maintenance: maintenance,
            lookup: { _ in throw WSSEditorOpenError.unavailable })
        try await editors.cancelPendingForMaintenance()
        await maintenance.drainMutations()
        XCTAssertGreaterThan(maintenance.activeOperationCount, 0)
        let result = await editors.resolveAndCloseAllForMaintenance()
        XCTAssertEqual(result, .approved)
        await playlist.shutdownAndDrainForMaintenance()
        await library.stopAndDrainForMaintenance()
        await maintenance.drain()
        XCTAssertEqual(maintenance.activeOperationCount, 0)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        XCTAssertEqual(defaults.persistentDomain(forName: suite)! as NSDictionary, before)
        try maintenance.requireRestart()
    }
    func testMaintenanceStopsTimerAndPendingRequestWithoutPersistingRotation() async throws {
        for pending in [false, true] {
            playlist.shutdown()
            let maintenance = MaintenanceCoordinator()
            library = Library(
                maintenance: maintenance, storage: root.appendingPathComponent("library.json"),
                defaults: defaults)
            playlist = controller()
            let id = try create("Maintenance")
            playlist.activatePlaylist(id: id)
            if !pending { await accept() }
            let bytes = try Data(contentsOf: store.url)
            let preferences = defaults.persistentDomain(forName: suite)! as NSDictionary
            let count = applied.count
            let job = try maintenance.reserve(.restore)
            try maintenance.freeze()
            // Our injected request behaves like Library's request cancellation contract.
            for request in requests { request.cancel = { request.finish(.superseded) } }
            await playlist.shutdownAndDrainForMaintenance()
            await maintenance.drain()
            clock.advance(1000)
            XCTAssertEqual(clock.count, 0)
            XCTAssertEqual(applied.count, count)
            XCTAssertEqual(try Data(contentsOf: store.url), bytes)
            XCTAssertEqual(defaults.persistentDomain(forName: suite)! as NSDictionary, preferences)
            XCTAssertEqual(maintenance.activeOperationCount, 0)
            job.finish()
        }
    }
    private func drain() async { for _ in 0..<30 { await Task.yield() } }
    private func accept() async {
        requests.last?.finish(.accepted)
        await drain()
    }
    private func fail(_ message: String = "broken") async {
        requests.last?.finish(.failed(ImportFailure.message(message)))
        await drain()
    }
    private func start(_ id: UUID) async {
        playlist.activatePlaylist(id: id)
        await accept()
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for real playback")
    }

    func testCreateIndependentDefinitionsNamesAndIntervalsPersist() throws {
        let a = try create("Same", order: [0, 1], interval: 5)
        let b = try create("Same", order: [2, 0], interval: 10)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(playlist.definition(a)?.wallpaperIDs, [entries[0].id, entries[1].id])
        XCTAssertEqual(playlist.definition(b)?.wallpaperIDs, [entries[2].id, entries[0].id])
        XCTAssertEqual(playlist.definition(a)?.intervalSeconds, 5)
        XCTAssertEqual(playlist.definition(b)?.intervalSeconds, 10)
        XCTAssertEqual(try store.load(), playlist.state)
        XCTAssertNil(playlist.activePlaylistID)
        XCTAssertEqual(playlist.selectedPlaylistID, b)
    }
    func testEmptyAndSingleEntryRemainEditableButCannotActivate() throws {
        let a = try create(order: [])
        playlist.activatePlaylist(id: a)
        XCTAssertTrue(applied.isEmpty)
        try playlist.add(entries[0].id, to: a)
        playlist.activatePlaylist(id: a)
        XCTAssertFalse(playlist.canActivate(a))
        XCTAssertEqual(playlist.state.definitions.count, 1)
        XCTAssertEqual(try store.load().definitions[0].wallpaperIDs.count, 1)
    }
    func testInvalidNamesAndMissingIDsDoNotMutate() throws {
        let a = try create()
        let previous = playlist.state
        for name in ["", "  ", "a\n", "a\u{2028}b", "a\0b", String(repeating: "x", count: 257)] {
            XCTAssertThrowsError(try playlist.createPlaylist(name: name))
            XCTAssertThrowsError(try playlist.renamePlaylist(id: a, newName: name))
        }
        XCTAssertThrowsError(try playlist.renamePlaylist(id: UUID(), newName: "Missing"))
        XCTAssertThrowsError(try playlist.add(UUID(), to: a))
        XCTAssertEqual(playlist.state, previous)
    }
    func testPlaylistRenameKeepsIdentityCursorTimerAndAllowsUnicode() async throws {
        let a = try create()
        await start(a)
        clock.advance(4)
        let before = playlist.state
        try playlist.renamePlaylist(id: a, newName: "  Ruhe 🌊 /: \\ ..  ")
        XCTAssertEqual(playlist.definition(a)?.name, "Ruhe 🌊 /: \\ ..")
        XCTAssertEqual(playlist.definition(a)?.wallpaperIDs, before.definitions[0].wallpaperIDs)
        XCTAssertEqual(playlist.state.playback, before.playback)
        XCTAssertEqual(applied.count, 1)
        clock.advance(1)
        XCTAssertEqual(applied.last?.id, entries[1].id)
    }
    func testIdenticalNormalizedNameDoesNotWrite() throws {
        let a = try create()
        let modified = try store.url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        try playlist.renamePlaylist(id: a, newName: " A ")
        XCTAssertEqual(
            try store.url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, modified)
    }
    func testSelectionIsSeparateFromActiveAndDoesNotSaveOrResetTimer() async throws {
        let a = try create()
        let b = try create("B", order: [2, 1])
        await start(b)
        clock.advance(4)
        let before = try Data(contentsOf: store.url)
        let modified = try store.url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        playlist.select(a)
        XCTAssertEqual(playlist.selectedPlaylistID, a)
        XCTAssertEqual(playlist.activePlaylistID, b)
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        XCTAssertEqual(
            try store.url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, modified)
        XCTAssertEqual(applied.count, 1)
        clock.advance(1)
        XCTAssertEqual(applied.last?.id, entries[1].id)
    }
    func testPlaybackModeDefaultsIndependentPersistenceAndAdditiveDecode() throws {
        let a = try create()
        let b = try create("B")
        XCTAssertEqual(playlist.definition(a)?.playbackMode, .inOrder)
        try playlist.setPlaybackMode(playlistID: b, mode: .shuffle)
        XCTAssertEqual(try store.load().definitions.map(\.playbackMode), [.inOrder, .shuffle])
        let data = try JSONEncoder().encode(playlist.definition(b)!)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object.removeValue(forKey: "playbackMode") as? String, "shuffle")
        let old = try JSONDecoder().decode(
            PlaylistDefinition.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.playbackMode, .inOrder)
        for invalid: Any in ["unknown", 7, NSNull()] {
            object["playbackMode"] = invalid
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    PlaylistDefinition.self, from: JSONSerialization.data(withJSONObject: object)))
        }
    }
    func testShuffleRoundsReserveUntilAcceptedAndAvoidBoundaryRepeat() async throws {
        var mixes = 0
        playlist.shutdown()
        playlist = controller(shuffle: { ids in
            mixes += 1
            return mixes == 1 ? Array(ids.reversed()) : ids
        })
        let a = try create()
        try playlist.setPlaybackMode(playlistID: a, mode: .shuffle)
        playlist.activatePlaylist(id: a)
        XCTAssertEqual(applied.last?.id, entries[2].id)
        XCTAssertNil(playlist.state.playback)
        XCTAssertEqual(mixes, 1)
        clock.advance(100)
        XCTAssertEqual(applied.count, 1)
        await accept()
        for index in [1, 0] {
            clock.advance(5)
            XCTAssertEqual(applied.last?.id, entries[index].id)
            XCTAssertEqual(mixes, 1)
            await accept()
        }
        clock.advance(5)
        XCTAssertEqual(mixes, 2)
        XCTAssertEqual(applied.last?.id, entries[1].id)
        await accept()
        for _ in 0..<8 {
            let previous = playlist.state.playback?.currentWallpaperID
            clock.advance(5)
            XCTAssertNotEqual(applied.last?.id, previous)
            await accept()
        }
    }
    func testModeSwitchesPreserveRemainingTimeAndCurrent() async throws {
        let a = try create()
        await start(a)
        clock.advance(4)
        try playlist.setPlaybackMode(playlistID: a, mode: .shuffle)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(playlist.state.playback?.currentWallpaperID, entries[0].id)
        clock.advance(1)
        XCTAssertEqual(applied.last?.id, entries[1].id)
        XCTAssertFalse(playlist.canSetPlaybackMode(a))
        XCTAssertThrowsError(try playlist.setPlaybackMode(playlistID: a, mode: .inOrder))
        await accept()
        clock.advance(4)
        try playlist.setPlaybackMode(playlistID: a, mode: .inOrder)
        XCTAssertEqual(applied.count, 2)
        clock.advance(1)
        XCTAssertEqual(applied.last?.id, entries[2].id)
    }
    func testShufflePauseRenameAndIntervalKeepBag() async throws {
        var mixes = 0
        playlist.shutdown()
        playlist = controller(shuffle: { ids in
            mixes += 1
            return ids.reversed()
        })
        let a = try create()
        try playlist.setPlaybackMode(playlistID: a, mode: .shuffle)
        await start(a)
        clock.advance(4)
        library.manuallyPaused = true
        await drain()
        try playlist.renamePlaylist(id: a, newName: "Renamed")
        try playlist.setInterval(10, for: a)
        clock.advance(100)
        XCTAssertEqual(applied.count, 1)
        library.manuallyPaused = false
        await drain()
        clock.advance(9)
        XCTAssertEqual(applied.count, 1)
        clock.advance(1)
        XCTAssertEqual(applied.last?.id, entries[1].id)
        XCTAssertEqual(mixes, 1)
        XCTAssertEqual(playlist.definition(a)?.playbackMode, .shuffle)
    }
    func testShuffleRestartRestoresCurrentThenStartsPartialRound() async throws {
        let a = try create()
        try playlist.setPlaybackMode(playlistID: a, mode: .shuffle)
        await start(a)
        playlist.shutdown()
        playlist = controller(restore: true)
        XCTAssertEqual(applied.last?.id, entries[0].id)
        await accept()
        clock.advance(5)
        XCTAssertEqual(applied.last?.id, entries[1].id)
    }
    func testShuffleActivationFailureRecoverySupersededAndNewTarget() async throws {
        let a = try create()
        let b = try create("B", order: [2, 1])
        for id in [a, b] { try playlist.setPlaybackMode(playlistID: id, mode: .shuffle) }
        await start(a)
        clock.advance(4)
        playlist.activatePlaylist(id: b)
        await fail()
        XCTAssertTrue(playlist.recovering)
        await accept()
        XCTAssertEqual(playlist.activePlaylistID, a)
        clock.advance(1)
        XCTAssertEqual(applied.last?.id, entries[1].id)
        await accept()
        playlist.activatePlaylist(id: b)
        let obsolete = requests.last!
        playlist.activatePlaylist(id: a)
        obsolete.finish(.accepted)
        await drain()
        await accept()
        XCTAssertEqual(playlist.activePlaylistID, a)
        playlist.activatePlaylist(id: b)
        requests.last?.finish(.superseded)
        await drain()
        XCTAssertNil(playlist.activePlaylistID)
        let count = applied.count
        clock.advance(100)
        XCTAssertEqual(applied.count, count)
    }
    func testShuffleStructureChangesResetBagWithoutChangingTimerOrCurrent() async throws {
        var mixes = 0
        playlist.shutdown()
        playlist = controller(shuffle: { ids in
            mixes += 1
            return ids
        })
        let a = try create()
        let b = try create("B")
        try playlist.setPlaybackMode(playlistID: a, mode: .shuffle)
        await start(a)
        clock.advance(4)
        try playlist.setPlaybackMode(playlistID: b, mode: .shuffle)
        try playlist.remove(entries[1].id, from: b)
        try playlist.move(entries[2].id, by: -1, in: a)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(playlist.state.playback?.currentWallpaperID, entries[0].id)
        clock.advance(1)
        XCTAssertEqual(applied.last?.id, entries[2].id)
        XCTAssertEqual(mixes, 2)
        await accept()
        try playlist.remove(entries[1].id, from: a)
        try playlist.add(entries[1].id, to: a)
        clock.advance(5)
        XCTAssertNotEqual(applied.last?.id, entries[2].id)
        XCTAssertEqual(mixes, 3)
        await accept()
        let current = try XCTUnwrap(playlist.state.playback?.currentWallpaperID)
        try playlist.remove(current, from: a)
        XCTAssertNotEqual(applied.last?.id, current)
        await accept()
        let other = try XCTUnwrap(playlist.definition(a)?.wallpaperIDs.first)
        library.onPlaybackCommand?(.remove(other))
        XCTAssertNil(playlist.activePlaylistID)
    }
    func testShuffleAcceptedSaveFailureDoesNotPublishCandidateOrRetry() async throws {
        let a = try create()
        try playlist.setPlaybackMode(playlistID: a, mode: .shuffle)
        await start(a)
        clock.advance(5)
        let previous = playlist.state.playback
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
        await accept()
        XCTAssertEqual(playlist.state.playback, previous)
        XCTAssertNil(playlist.activePlaylistID)
        let count = applied.count
        clock.advance(100)
        XCTAssertEqual(applied.count, count)
    }
    func testShuffleTwoEntriesNeverRepeatAcrossRounds() async throws {
        let a = try create(order: [0, 1])
        try playlist.setPlaybackMode(playlistID: a, mode: .shuffle)
        await start(a)
        for index in 1...8 {
            clock.advance(5)
            XCTAssertEqual(applied.last?.id, entries[index % 2].id)
            await accept()
        }
    }
    func testLocalizedPlaylistStatesPreserveNameAndPlaybackIdentity() async throws {
        let name = "海 🌈 %@"
        let id = try create(name)
        await start(id)
        let playback = playlist.state.playback
        XCTAssertEqual(playlist.localizedStatus(language: "en"), name + " · Playing in order")
        XCTAssertEqual(
            playlist.localizedStatus(language: "de"), name + " · Wiedergabe der Reihe nach")
        try playlist.setPlaybackMode(playlistID: id, mode: .shuffle)
        XCTAssertEqual(playlist.localizedStatus(language: "de"), name + " · Zufällige Wiedergabe")
        XCTAssertEqual(playlist.state.playback, playback)
        XCTAssertEqual(playlist.definition(id)?.name, name)
        XCTAssertEqual(playlist.activePlaylistID, id)
    }

    func testShuffleBActivationAcceptedContinuesItsOwnBag() async throws {
        let a = try create()
        let b = try create("B", order: [2, 1], interval: 10)
        try playlist.setPlaybackMode(playlistID: b, mode: .shuffle)
        await start(a)
        playlist.activatePlaylist(id: b)
        XCTAssertEqual(playlist.activePlaylistID, a)
        XCTAssertEqual(applied.last?.id, entries[2].id)
        XCTAssertFalse(playlist.canSetPlaybackMode(a))
        XCTAssertFalse(playlist.canSetPlaybackMode(b))
        await accept()
        XCTAssertEqual(playlist.activePlaylistID, b)
        XCTAssertTrue(playlist.localizedStatus(language: "en").contains("Shuffling"))
        clock.advance(9)
        XCTAssertEqual(applied.count, 2)
        clock.advance(1)
        XCTAssertEqual(applied.last?.id, entries[1].id)
    }
    func testShufflePendingStructureChangeCannotRestoreOldBag() async throws {
        var inputs: [[UUID]] = []
        playlist.shutdown()
        playlist = controller(shuffle: { ids in
            inputs.append(ids)
            return ids
        })
        let a = try create()
        try playlist.setPlaybackMode(playlistID: a, mode: .shuffle)
        await start(a)
        clock.advance(5)
        XCTAssertEqual(applied.last?.id, entries[1].id)
        try playlist.move(entries[2].id, by: -1, in: a)
        await accept()
        clock.advance(5)
        XCTAssertEqual(inputs.count, 2)
        XCTAssertEqual(inputs.last, [entries[0].id, entries[2].id])
        XCTAssertEqual(applied.last?.id, entries[0].id)
    }
    func testInactiveShuffleEditsDoNotBuildBagAndModeSaveFailureIsAtomic() async throws {
        var mixes = 0
        playlist.shutdown()
        playlist = controller(shuffle: { ids in
            mixes += 1
            return ids
        })
        let a = try create()
        let b = try create("B")
        await start(a)
        clock.advance(4)
        playlist.select(b)
        try playlist.setPlaybackMode(playlistID: b, mode: .shuffle)
        try playlist.move(entries[2].id, by: -1, in: b)
        try playlist.remove(entries[0].id, from: b)
        XCTAssertEqual(mixes, 0)
        XCTAssertEqual(playlist.activePlaylistID, a)
        XCTAssertTrue(playlist.status.contains("A"))
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try playlist.setPlaybackMode(playlistID: a, mode: .shuffle))
        XCTAssertEqual(playlist.definition(a)?.playbackMode, .inOrder)
        clock.advance(1)
        XCTAssertEqual(applied.last?.id, entries[1].id)
        XCTAssertEqual(mixes, 0)
    }
    func testSequenceAndWraparoundAdvanceOnlyAfterAccepted() async throws {
        let a = try create()
        playlist.activatePlaylist(id: a)
        XCTAssertNil(playlist.activePlaylistID)
        XCTAssertNil(playlist.state.playback)
        XCTAssertEqual(clock.count, 0)
        clock.advance(100)
        XCTAssertEqual(applied.count, 1)
        await accept()
        for index in [1, 2, 0] {
            clock.advance(4)
            XCTAssertNil(playlist.pendingWallpaperID)
            clock.advance(1)
            XCTAssertEqual(applied.last?.id, entries[index].id)
            clock.advance(100)
            XCTAssertEqual(clock.count, 0)
            await accept()
            XCTAssertEqual(playlist.state.playback?.currentWallpaperID, entries[index].id)
            XCTAssertEqual(clock.count, 1)
        }
    }
    func testAlreadyActiveAndAlreadyPendingActivationAreIdempotent() async throws {
        let a = try create()
        playlist.activatePlaylist(id: a)
        playlist.activatePlaylist(id: a)
        XCTAssertEqual(applied.count, 1)
        await accept()
        clock.advance(4)
        let bytes = try Data(contentsOf: store.url)
        playlist.activatePlaylist(id: a)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        clock.advance(1)
        XCTAssertEqual(applied.count, 2)
        // Doppelklick while a normal sequential apply is pending is also a no-op.
        playlist.activatePlaylist(id: a)
        XCTAssertEqual(applied.count, 2)
    }
    func testInvalidActivationLeavesRunningPlaylistUntouched() async throws {
        let a = try create()
        let b = try create("B", order: [0])
        await start(a)
        clock.advance(4)
        let before = playlist.state
        playlist.activatePlaylist(id: b)
        playlist.activatePlaylist(id: UUID())
        XCTAssertEqual(playlist.state, before)
        XCTAssertEqual(applied.count, 1)
        clock.advance(1)
        XCTAssertEqual(applied.count, 2)
    }
    func testActivationBCommitsOnlyAfterAcceptedAndGetsOwnInterval() async throws {
        let a = try create()
        let b = try create("B", order: [2, 1], interval: 10)
        await start(a)
        clock.advance(4)
        playlist.activatePlaylist(id: b)
        XCTAssertEqual(playlist.activePlaylistID, a)
        XCTAssertEqual(try store.load().playback?.playlistID, a)
        XCTAssertEqual(playlist.pendingActivationID, b)
        XCTAssertEqual(clock.count, 0)
        clock.advance(100)
        XCTAssertEqual(applied.count, 2)
        await accept()
        XCTAssertEqual(playlist.activePlaylistID, b)
        clock.advance(9)
        XCTAssertEqual(applied.count, 2)
        clock.advance(1)
        XCTAssertEqual(applied.last?.id, entries[1].id)
    }
    func testFailedBRecoversAOnceAndResumesRemainingSecond() async throws {
        let a = try create()
        let b = try create("B", order: [2, 1])
        await start(a)
        clock.advance(4)
        playlist.activatePlaylist(id: b)
        await fail("B failed")
        XCTAssertTrue(playlist.recovering)
        XCTAssertEqual(applied.map(\.id), [entries[0].id, entries[2].id, entries[0].id])
        XCTAssertEqual(clock.count, 0)
        await accept()
        XCTAssertEqual(playlist.activePlaylistID, a)
        XCTAssertEqual(playlist.state.playback?.currentWallpaperID, entries[0].id)
        XCTAssertTrue(playlist.error?.contains("restored") == true)
        clock.advance(1)
        XCTAssertEqual(applied.last?.id, entries[1].id)
    }
    func testFailedRecoveryStopsWithoutRetryLoopAndReportsBothFailures() async throws {
        let a = try create()
        let b = try create("B", order: [2, 1])
        await start(a)
        playlist.activatePlaylist(id: b)
        await fail("B failed")
        await fail("A failed")
        XCTAssertNil(playlist.activePlaylistID)
        XCTAssertTrue(playlist.error?.contains("B failed") == true)
        XCTAssertTrue(playlist.error?.contains("A failed") == true)
        clock.advance(10000)
        XCTAssertEqual(applied.count, 3)
        XCTAssertEqual(clock.count, 0)
        XCTAssertFalse(try XCTUnwrap(store.load().playback).enabled)
    }
    func testFirstActivationFailureDoesNotRecoverAnything() async throws {
        let a = try create()
        playlist.activatePlaylist(id: a)
        await fail()
        XCTAssertNil(playlist.activePlaylistID)
        XCTAssertEqual(applied.count, 1)
        clock.advance(100)
        XCTAssertEqual(applied.count, 1)
    }
    func testSupersededActivationDoesNotAdvanceOrRecover() async throws {
        let a = try create()
        let b = try create("B")
        await start(a)
        playlist.activatePlaylist(id: b)
        requests.last?.finish(.superseded)
        await drain()
        XCTAssertNil(playlist.activePlaylistID)
        XCTAssertEqual(playlist.state.playback?.currentWallpaperID, entries[0].id)
        XCTAssertEqual(applied.count, 2)
        XCTAssertEqual(clock.count, 0)
    }
    func testNewTargetInvalidatesLateActivationAndRecovery() async throws {
        let a = try create()
        let b = try create("B", order: [1, 2])
        let c = try create("C", order: [2, 0])
        await start(a)
        playlist.activatePlaylist(id: b)
        let obsoleteB = try XCTUnwrap(requests.last)
        playlist.activatePlaylist(id: c)
        obsoleteB.finish(.failed(ImportFailure.message("late B")))
        await drain()
        XCTAssertEqual(applied.count, 3)
        await accept()
        XCTAssertEqual(playlist.activePlaylistID, c)
        playlist.activatePlaylist(id: b)
        await fail()
        let obsoleteRecovery = try XCTUnwrap(requests.last)
        playlist.activatePlaylist(id: a)
        obsoleteRecovery.finish(.accepted)
        await drain()
        XCTAssertEqual(playlist.pendingActivationID, a)
        await accept()
        XCTAssertEqual(playlist.activePlaylistID, a)
        XCTAssertEqual(clock.count, 1)
    }
    func testManualApplyDuringPendingInvalidatesRecoveryAndKeepsDefinitionsAndSelection()
        async throws
    {
        let a = try create()
        let b = try create("B")
        await start(a)
        playlist.activatePlaylist(id: b)
        let obsolete = try XCTUnwrap(requests.last)
        library.manuallyPaused = true
        let manual = library.apply(entries[2])
        obsolete.finish(.failed(ImportFailure.message("late")))
        await drain()
        XCTAssertNil(playlist.activePlaylistID)
        XCTAssertNil(playlist.pendingActivationID)
        XCTAssertEqual(playlist.selectedPlaylistID, b)
        XCTAssertEqual(playlist.state.definitions.count, 2)
        XCTAssertEqual(applied.count, 2)
        XCTAssertEqual(library.active?.id, entries[2].id)
        library.stop()
        guard case .superseded = await manual.outcome else {
            return XCTFail("Manual apply should stop")
        }
    }
    func testStopDuringRecoveryAndShutdownIgnoreLateResults() async throws {
        let a = try create()
        let b = try create("B")
        await start(a)
        playlist.activatePlaylist(id: b)
        await fail()
        let obsolete = try XCTUnwrap(requests.last)
        library.stop()
        obsolete.finish(.accepted)
        await drain()
        XCTAssertNil(playlist.activePlaylistID)
        XCTAssertEqual(clock.count, 0)
        XCTAssertEqual(playlist.state.definitions.count, 2)
        await start(a)
        playlist.activatePlaylist(id: b)
        let pending = try XCTUnwrap(requests.last)
        playlist.shutdown()
        let saved = try Data(contentsOf: store.url)
        pending.finish(.accepted)
        await drain()
        XCTAssertEqual(try Data(contentsOf: store.url), saved)
        XCTAssertEqual(try store.load().playback?.playlistID, a)
        XCTAssertEqual(clock.count, 0)
    }
    func testNormalFailureAndSupersededStopWithoutCursorProgress() async throws {
        let a = try create()
        for outcome in [WallpaperApplyOutcome.failed(ImportFailure.message("broken")), .superseded]
        {
            await start(a)
            clock.advance(5)
            requests.last?.finish(outcome)
            await drain()
            XCTAssertNil(playlist.activePlaylistID)
            XCTAssertEqual(playlist.state.playback?.currentWallpaperID, entries[0].id)
            let count = applied.count
            clock.advance(10000)
            XCTAssertEqual(applied.count, count)
            XCTAssertEqual(clock.count, 0)
        }
    }
    func testPauseFreezesRemainingTimeAndResumeContinuesIt() async throws {
        let a = try create()
        await start(a)
        clock.advance(2)
        library.manuallyPaused = true
        XCTAssertTrue(playlist.suspended)
        XCTAssertEqual(clock.count, 0)
        clock.advance(100)
        library.manuallyPaused = false
        clock.advance(2)
        XCTAssertEqual(applied.count, 1)
        clock.advance(1)
        XCTAssertEqual(applied.last?.id, entries[1].id)
    }
    func testActiveIntervalChangeDuringPauseStartsNewInterval() async throws {
        let a = try create()
        await start(a)
        clock.advance(4)
        library.manuallyPaused = true
        try playlist.setInterval(10, for: a)
        clock.advance(100)
        library.manuallyPaused = false
        clock.advance(9)
        XCTAssertEqual(applied.count, 1)
        clock.advance(1)
        XCTAssertEqual(applied.count, 2)
    }
    func testInactiveEditingDoesNotAffectActiveRuntime() async throws {
        let a = try create()
        let b = try create("B", order: [2, 1])
        await start(a)
        clock.advance(4)
        let playback = playlist.state.playback
        try playlist.add(entries[0].id, to: b)
        try playlist.move(entries[0].id, by: -1, in: b)
        try playlist.remove(entries[2].id, from: b)
        try playlist.setInterval(10, for: b)
        try playlist.renamePlaylist(id: b, newName: "B renamed")
        XCTAssertEqual(playlist.state.playback, playback)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(clock.count, 1)
        clock.advance(1)
        XCTAssertEqual(applied.last?.id, entries[1].id)
    }
    func testActiveReorderingKeepsCursorIntervalAndChangesSuccessor() async throws {
        let a = try create()
        await start(a)
        clock.advance(4)
        try playlist.move(fromOffsets: IndexSet(integer: 2), toOffset: 1, in: a)
        XCTAssertEqual(playlist.state.playback?.currentWallpaperID, entries[0].id)
        XCTAssertEqual(applied.count, 1)
        clock.advance(1)
        XCTAssertEqual(applied.last?.id, entries[2].id)
        XCTAssertEqual(
            try store.load().definitions[0].wallpaperIDs, [0, 2, 1].map { entries[$0].id })
    }
    func testLongJumpsEndpointsMultiOffsetsAndInvalidOffsetsPreserveIdentity() throws {
        let a = try create(order: [])
        let extended = (0..<15).map {
            Wallpaper(title: "Entry \($0)", path: entries[0].path, root: root.path, kind: .image)
        }
        library.items = extended
        for item in extended { try playlist.add(item.id, to: a) }
        let ids = extended.map(\.id)
        try playlist.move(fromOffsets: IndexSet(integer: 14), toOffset: 1, in: a)
        XCTAssertEqual(
            playlist.definition(a)?.wallpaperIDs, [ids[0], ids[14]] + Array(ids[1..<14]))
        try playlist.move(fromOffsets: IndexSet(integer: 1), toOffset: 15, in: a)
        XCTAssertEqual(playlist.definition(a)?.wallpaperIDs, ids)
        try playlist.move(fromOffsets: IndexSet(integer: 0), toOffset: 15, in: a)
        XCTAssertEqual(playlist.definition(a)?.wallpaperIDs, Array(ids.dropFirst()) + [ids[0]])
        try playlist.move(fromOffsets: IndexSet(integer: 14), toOffset: 0, in: a)
        XCTAssertEqual(playlist.definition(a)?.wallpaperIDs, ids)
        try playlist.move(fromOffsets: IndexSet([1, 3]), toOffset: 15, in: a)
        let moved = try XCTUnwrap(playlist.definition(a)?.wallpaperIDs)
        XCTAssertEqual(
            moved,
            ids.enumerated().filter { ![1, 3].contains($0.offset) }.map(\.element) + [
                ids[1], ids[3],
            ])
        XCTAssertEqual(Set(moved), Set(ids))
        XCTAssertEqual(moved.count, ids.count)
        let before = playlist.state
        for source in [IndexSet(), IndexSet(integer: 15)] {
            try playlist.move(fromOffsets: source, toOffset: 0, in: a)
        }
        try playlist.move(fromOffsets: IndexSet(integer: 0), toOffset: -1, in: a)
        XCTAssertEqual(playlist.state, before)
        XCTAssertEqual(try store.load(), before)
    }
    func testDragPayloadRejectsOtherPlaylistAndAcceptsSamePlaylist() throws {
        let a = try create()
        let b = try create("B")
        let before = playlist.state
        let payload = PlaylistReorderItem(sourcePlaylistID: a, wallpaperID: entries[0].id)
        XCTAssertFalse(playlist.acceptDrop(payload, before: nil, in: b))
        XCTAssertEqual(playlist.state, before)
        XCTAssertTrue(playlist.acceptDrop(payload, before: nil, in: a))
        XCTAssertEqual(playlist.definition(a)?.wallpaperIDs, [1, 2, 0].map { entries[$0].id })
        XCTAssertEqual(playlist.definition(b)?.wallpaperIDs, entries.map(\.id))
    }
    func testRemoveCurrentAndPendingPreservesReplacementSemantics() async throws {
        let a = try create()
        await start(a)
        clock.advance(5)
        let obsolete = try XCTUnwrap(requests.last)
        try playlist.remove(entries[1].id, from: a)
        XCTAssertEqual(applied.last?.id, entries[0].id)
        obsolete.finish(.accepted)
        await drain()
        await accept()
        try playlist.remove(entries[0].id, from: a)
        XCTAssertNil(playlist.activePlaylistID)
        XCTAssertEqual(playlist.definition(a)?.wallpaperIDs, [entries[2].id])
    }
    func testRemoveCurrentWithTwoRemainingAppliesFirstRemaining() async throws {
        let a = try create()
        await start(a)
        try playlist.remove(entries[0].id, from: a)
        XCTAssertNil(playlist.state.playback?.currentWallpaperID)
        XCTAssertEqual(applied.last?.id, entries[1].id)
        await accept()
        XCTAssertEqual(playlist.state.playback?.currentWallpaperID, entries[1].id)
    }
    func testLibraryDeletionPrunesAllAffectedDefinitionsOnlyAndStopsTooShortActive() async throws {
        let a = try create(order: [0, 1])
        let b = try create("B", order: [0, 2])
        let c = try create("C", order: [1, 2])
        let untouched = playlist.definition(c)
        await start(a)
        library.remove(entries[0])
        try await waitUntil { !self.library.importing }
        XCTAssertEqual(playlist.definition(a)?.wallpaperIDs, [entries[1].id])
        XCTAssertEqual(playlist.definition(b)?.wallpaperIDs, [entries[2].id])
        XCTAssertEqual(playlist.definition(c), untouched)
        XCTAssertNil(playlist.activePlaylistID)
        try await waitUntil { !self.library.importing }
        XCTAssertTrue(FileManager.default.fileExists(atPath: entries[0].path))
        var replacement = entries[0]
        replacement.id = UUID()
        library.items.append(replacement)
        XCTAssertFalse(playlist.definition(a)!.wallpaperIDs.contains(replacement.id))
    }
    func testDuplicateLibraryIdentityIsNotUniquelyResolvable() throws {
        let a = try create()
        library.items.append(entries[0])
        XCTAssertTrue(playlist.definition(a)!.wallpaperIDs.contains(entries[0].id))
        XCTAssertThrowsError(try playlist.add(entries[0].id, to: a))
    }
    func testDeleteInactiveActiveAndLastNeverDeletesLibraryOrSources() async throws {
        let a = try create()
        let b = try create("B")
        let libraryBytes = try Data(contentsOf: root.appendingPathComponent("library.json"))
        await start(a)
        clock.advance(4)
        try playlist.deletePlaylist(id: b)
        XCTAssertEqual(playlist.activePlaylistID, a)
        XCTAssertEqual(playlist.selectedPlaylistID, a)
        clock.advance(1)
        await accept()
        try playlist.deletePlaylist(id: a)
        XCTAssertTrue(playlist.state.definitions.isEmpty)
        XCTAssertNil(playlist.selectedPlaylistID)
        XCTAssertNil(playlist.activePlaylistID)
        XCTAssertEqual(clock.count, 0)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("library.json")), libraryBytes)
        for item in entries { XCTAssertTrue(FileManager.default.fileExists(atPath: item.path)) }
    }
    func testDeleteTransitionParticipantsIsBlockedButUnrelatedDeleteWorks() async throws {
        let a = try create()
        let b = try create("B")
        let c = try create("C")
        await start(a)
        playlist.activatePlaylist(id: b)
        XCTAssertFalse(playlist.canDelete(a))
        XCTAssertFalse(playlist.canDelete(b))
        XCTAssertThrowsError(try playlist.deletePlaylist(id: a))
        XCTAssertThrowsError(try playlist.deletePlaylist(id: b))
        try playlist.deletePlaylist(id: c)
        await fail()
        XCTAssertFalse(playlist.canDelete(a))
        await accept()
        XCTAssertTrue(playlist.canDelete(a))
    }
    func testDeleteActiveKeepsAcceptedRealWallpaperPlaying() async throws {
        playlist.shutdown()
        playlist = controller(realApply: true)
        let a = try create()
        playlist.activatePlaylist(id: a)
        try await waitUntil { self.playlist.activePlaylistID == a }
        let rendererIDs = library.renderers.map(ObjectIdentifier.init)
        try playlist.deletePlaylist(id: a)
        XCTAssertEqual(library.active?.id, entries[0].id)
        XCTAssertEqual(library.renderers.map(ObjectIdentifier.init), rendererIDs)
        XCTAssertNil(playlist.activePlaylistID)
    }
    func testRestartRestoresOnlyConfirmedActiveAndIndependentSelection() async throws {
        let a = try create()
        let b = try create("B", order: [2, 1])
        await start(a)
        clock.advance(5)
        await accept()
        playlist.select(b)
        playlist.shutdown()
        playlist = controller(restore: true)
        XCTAssertEqual(playlist.selectedPlaylistID, b)
        XCTAssertEqual(playlist.pendingActivationID, a)
        XCTAssertEqual(applied.last?.id, entries[1].id)
        await accept()
        clock.advance(4)
        XCTAssertNil(playlist.pendingWallpaperID)
        clock.advance(1)
        XCTAssertEqual(applied.last?.id, entries[2].id)
        XCTAssertEqual(playlist.state.definitions.count, 2)
    }
    func testStartupPreservesMissingReferencesAndDoesNotActivateAnotherPlaylist() async throws {
        let a = try create(order: [0, 1])
        let b = try create("B", order: [1, 2])
        await start(a)
        playlist.shutdown()
        library.items = [entries[1], entries[2]]
        playlist = controller(restore: true)
        XCTAssertNil(playlist.activePlaylistID)
        XCTAssertNil(playlist.pendingActivationID)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(playlist.definition(a)?.wallpaperIDs, [entries[0].id, entries[1].id])
        XCTAssertEqual(playlist.definition(b)?.wallpaperIDs, [entries[1].id, entries[2].id])
    }
    func testSelectionFallsBackToActiveThenFirstThenEmpty() async throws {
        let a = try create()
        let b = try create("B")
        await start(b)
        defaults.set(UUID().uuidString, forKey: "selectedPlaylistID")
        playlist.shutdown()
        playlist = controller()
        XCTAssertEqual(playlist.selectedPlaylistID, b)
        playlist.deactivatePlaylist(id: b)
        defaults.set(UUID().uuidString, forKey: "selectedPlaylistID")
        playlist.shutdown()
        playlist = controller()
        XCTAssertEqual(playlist.selectedPlaylistID, a)
    }
    func testWallpaperRenameUpdatesResolutionWithoutPlaylistWriteOrIntervalReset() async throws {
        let a = try create()
        let b = try create("B")
        await start(a)
        clock.advance(4)
        let state = playlist.state
        let bytes = try Data(contentsOf: store.url)
        let modified = try store.url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        try await library.rename(wallpaperID: entries[0].id, newTitle: "Current 🌊")
        try await library.rename(wallpaperID: entries[1].id, newTitle: "Next 🌈")
        XCTAssertEqual(playlist.state, state)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        XCTAssertEqual(
            try store.url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, modified)
        XCTAssertEqual(
            library.items.first { $0.id == playlist.definition(b)?.wallpaperIDs[0] }?.title,
            "Current 🌊")
        clock.advance(1)
        XCTAssertEqual(applied.last?.title, "Next 🌈")
        XCTAssertEqual(applied.count, 2)
    }
    func testCorruptUnknownVersionAndOldShapeAreNeverOverwritten() throws {
        for bytes in [
            Data("corrupt".utf8), Data(#"{"version":99,"definitions":[]}"#.utf8),
            Data(#"{"version":1,"wallpaperIDs":[],"enabled":false,"intervalSeconds":900}"#.utf8),
        ] {
            try bytes.write(to: store.url)
            playlist.shutdown()
            playlist = controller()
            XCTAssertFalse(playlist.canEdit)
            XCTAssertThrowsError(try playlist.createPlaylist(name: "New"))
            XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        }
    }
    func testLegacyFileIsIgnoredAndNotChanged() throws {
        let legacy = root.appendingPathComponent("playlist.json")
        let bytes = Data(#"{"version":1,"wallpaperIDs":["bad-id"],"enabled":true}"#.utf8)
        try bytes.write(to: legacy)
        playlist.shutdown()
        playlist = controller(restore: true)
        XCTAssertTrue(playlist.state.definitions.isEmpty)
        XCTAssertTrue(playlist.canEdit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        _ = try create()
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        XCTAssertEqual(WallpaperPlaylistStore.defaultURL.lastPathComponent, "playlists.json")
    }
    func testNewFormatRejectsDuplicateIDsInvalidNamesIntervalsAndPlayback() throws {
        let a = PlaylistDefinition(name: "A")
        for state in [
            PlaylistCollectionState(definitions: [a, a]),
            PlaylistCollectionState(definitions: [PlaylistDefinition(name: " ")]),
            PlaylistCollectionState(definitions: [
                PlaylistDefinition(name: "A", wallpaperIDs: [entries[0].id, entries[0].id])
            ]),
            PlaylistCollectionState(definitions: [PlaylistDefinition(name: "A", intervalSeconds: 7)]
            ),
            PlaylistCollectionState(
                definitions: [a],
                playback: PlaylistPlaybackState(playlistID: UUID(), enabled: false)),
            PlaylistCollectionState(
                definitions: [a], playback: PlaylistPlaybackState(playlistID: a.id, enabled: true)),
        ] { XCTAssertThrowsError(try store.save(state)) }
    }
    func testSymlinkStoreFailsClosed() throws {
        let target = root.appendingPathComponent("private.json")
        let bytes = Data("untouched".utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: target)
        playlist.shutdown()
        playlist = controller()
        XCTAssertFalse(playlist.canEdit)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }
    func testDefinitionSaveFailureDoesNotPublishOrAffectActiveRuntime() async throws {
        let a = try create()
        let b = try create("B")
        await start(a)
        clock.advance(4)
        let old = playlist.state
        let bytes = try Data(contentsOf: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: root.path)
        }
        XCTAssertThrowsError(try playlist.renamePlaylist(id: b, newName: "New"))
        XCTAssertThrowsError(try playlist.deletePlaylist(id: a))
        XCTAssertEqual(playlist.state, old)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        clock.advance(1)
        XCTAssertEqual(applied.count, 2)
    }
    func testAcceptedActivationSaveFailureStopsRuntimeWithoutPublishingCandidate() async throws {
        let a = try create()
        let b = try create("B", order: [2, 1])
        await start(a)
        playlist.activatePlaylist(id: b)
        let old = playlist.state
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: root.path)
        }
        await accept()
        XCTAssertEqual(playlist.state, old)
        XCTAssertNil(playlist.activePlaylistID)
        XCTAssertNil(playlist.pendingActivationID)
        XCTAssertEqual(clock.count, 0)
        XCTAssertNotNil(playlist.error)
        XCTAssertEqual(try store.load(), old)
    }
    func testRealApplyWaitsForResumeAndRotatesThenStops() async throws {
        playlist.shutdown()
        playlist = controller(realApply: true)
        let a = try create(order: [0, 1])
        library.manuallyPaused = true
        playlist.activatePlaylist(id: a)
        XCTAssertNil(playlist.activePlaylistID)
        XCTAssertEqual(playlist.pendingActivationID, a)
        clock.advance(100)
        XCTAssertEqual(clock.count, 0)
        library.manuallyPaused = false
        try await waitUntil { self.playlist.activePlaylistID == a }
        clock.advance(5)
        try await waitUntil {
            self.playlist.state.playback?.currentWallpaperID == self.entries[1].id
        }
        library.stop()
        XCTAssertNil(library.active)
        XCTAssertNil(playlist.activePlaylistID)
        XCTAssertEqual(playlist.state.definitions.count, 1)
    }
    func testRealInternalReapplyFreezesRemainingInterval() async throws {
        playlist.shutdown()
        playlist = controller(realApply: true)
        let a = try create(order: [0, 1])
        playlist.activatePlaylist(id: a)
        try await waitUntil { self.playlist.activePlaylistID == a }
        clock.advance(2)
        library.profile = .eco
        XCTAssertTrue(playlist.suspended)
        try await waitUntil { !self.playlist.suspended }
        clock.advance(2)
        XCTAssertNil(playlist.pendingWallpaperID)
        clock.advance(1)
        try await waitUntil {
            self.playlist.state.playback?.currentWallpaperID == self.entries[1].id
        }
    }
    func testOnlyExistingUniqueReferencesAreAdded() throws {
        let a = try create(order: [])
        try playlist.add(entries[0].id, to: a)
        try playlist.add(entries[0].id, to: a)
        XCTAssertThrowsError(try playlist.add(UUID(), to: a))
        XCTAssertEqual(playlist.definition(a)?.wallpaperIDs, [entries[0].id])
    }
    func testDeactivateOnlyAppliesToTheRequestedPlaylist() async throws {
        let a = try create()
        let b = try create("B")
        await start(a)
        clock.advance(4)
        playlist.deactivatePlaylist(id: b)
        XCTAssertEqual(playlist.activePlaylistID, a)
        clock.advance(1)
        await accept()
        playlist.deactivatePlaylist(id: a)
        XCTAssertNil(playlist.activePlaylistID)
        XCTAssertEqual(clock.count, 0)
        XCTAssertEqual(playlist.state.definitions.count, 2)
    }
    func testStopDuringPendingActivationCannotBeUndoneByLateFailure() async throws {
        let a = try create()
        let b = try create("B")
        await start(a)
        playlist.activatePlaylist(id: b)
        let obsolete = try XCTUnwrap(requests.last)
        library.stop()
        obsolete.finish(.failed(ImportFailure.message("obsolete failure")))
        await drain()
        XCTAssertNil(playlist.activePlaylistID)
        XCTAssertEqual(applied.count, 2)
        XCTAssertEqual(clock.count, 0)
    }
    func testManualApplyDuringRecoveryCannotBeUndoneByLateAcceptance() async throws {
        let a = try create()
        let b = try create("B")
        await start(a)
        playlist.activatePlaylist(id: b)
        await fail()
        let obsolete = try XCTUnwrap(requests.last)
        library.manuallyPaused = true
        let manual = library.apply(entries[2])
        obsolete.finish(.accepted)
        await drain()
        XCTAssertNil(playlist.activePlaylistID)
        XCTAssertEqual(applied.count, 3)
        XCTAssertEqual(library.active?.id, entries[2].id)
        library.stop()
        guard case .superseded = await manual.outcome else { return XCTFail("Expected stop") }
    }
    func testRemovingTransitionWallpaperStopsAndRejectsLateAcceptance() async throws {
        let a = try create(order: [0, 1])
        let b = try create("B", order: [2, 1])
        await start(a)
        playlist.activatePlaylist(id: b)
        let obsolete = try XCTUnwrap(requests.last)
        library.items = [entries[0], entries[1]]
        obsolete.finish(.accepted)
        await drain()
        XCTAssertNil(playlist.activePlaylistID)
        XCTAssertNil(playlist.pendingActivationID)
        XCTAssertEqual(clock.count, 0)
        XCTAssertEqual(playlist.definition(b)?.wallpaperIDs, [entries[2].id, entries[1].id])
    }
    func testDeletePreservesNativeProjectAndEveryLibraryByte() async throws {
        let a = try create()
        let nativeFile = root.appendingPathComponent(
            "Wallpapers/NativeProjects/\(entries[0].id)/scene.wss.json")
        try FileManager.default.createDirectory(
            at: nativeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let nativeBytes = Data("native user edits remain even if invalid".utf8)
        try nativeBytes.write(to: nativeFile)
        let libraryBytes = try Data(contentsOf: root.appendingPathComponent("library.json"))
        let sources = try entries.map { try Data(contentsOf: $0.url) }
        try playlist.deletePlaylist(id: a)
        XCTAssertEqual(try Data(contentsOf: nativeFile), nativeBytes)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("library.json")), libraryBytes)
        XCTAssertEqual(try entries.map { try Data(contentsOf: $0.url) }, sources)
    }
    func testCollectionByteAndCountLimitsAreEnforcedBeforeWriting() throws {
        let tooMany = PlaylistCollectionState(
            definitions: (0..<1001).map { _ in PlaylistDefinition(name: "Name") })
        XCTAssertThrowsError(try store.save(tooMany))
        let longName = String(repeating: "👩‍👩‍👧‍👦", count: 256)
        let oversized = PlaylistCollectionState(
            definitions: (0..<200).map { _ in PlaylistDefinition(name: longName) })
        XCTAssertThrowsError(try store.save(oversized))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        let bytes = Data(repeating: 0, count: WallpaperPlaylistStore.byteLimit + 1)
        try bytes.write(to: store.url)
        playlist.shutdown()
        playlist = controller()
        XCTAssertFalse(playlist.canEdit)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
    }
    func testRealFailedCandidateRecoversUsingSharedApplyContract() async throws {
        playlist.shutdown()
        playlist = controller(realApply: true)
        let a = try create(order: [0, 1])
        let b = try create("B", order: [2, 1])
        playlist.activatePlaylist(id: a)
        try await waitUntil { self.playlist.activePlaylistID == a }
        clock.advance(4)
        try FileManager.default.removeItem(at: entries[2].url)
        playlist.activatePlaylist(id: b)
        try await waitUntil { self.playlist.pendingActivationID == nil }
        XCTAssertEqual(playlist.activePlaylistID, a)
        XCTAssertEqual(library.active?.id, entries[0].id)
        XCTAssertTrue(playlist.error?.contains("restored") == true)
        clock.advance(1)
        try await waitUntil {
            self.playlist.state.playback?.currentWallpaperID == self.entries[1].id
        }
    }

    func testMissingItemsAndReadableEmptyIndexNeverPrunePersistedMembership() throws {
        let id = try create()
        let bytes = try Data(contentsOf: store.url)
        library.items = []
        XCTAssertEqual(playlist.definition(id)?.wallpaperIDs, entries.map(\.id))
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        playlist.shutdown()
        try Data("[]".utf8).write(to: root.appendingPathComponent("library.json"))
        library = Library(
            storage: root.appendingPathComponent("library.json"), defaults: defaults,
            restoreOnLaunch: false)
        XCTAssertTrue(library.isLibraryReadable)
        playlist = controller(restore: true)
        XCTAssertEqual(playlist.definition(id)?.wallpaperIDs, entries.map(\.id))
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        XCTAssertTrue(applied.isEmpty)
    }
    func testLoadFailureNeverPrunesPlaylistBytes() throws {
        let id = try create()
        let bytes = try Data(contentsOf: store.url)
        playlist.shutdown()
        try Data("invalid".utf8).write(to: root.appendingPathComponent("library.json"))
        library = Library(
            storage: root.appendingPathComponent("library.json"), defaults: defaults,
            restoreOnLaunch: false)
        XCTAssertFalse(library.isLibraryReadable)
        playlist = controller()
        XCTAssertFalse(playlist.canEdit)
        XCTAssertEqual(
            try store.load().definitions.first(where: { $0.id == id })?.wallpaperIDs,
            entries.map(\.id))
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
    }
    func testFailedLibraryRemovalDoesNotRemovePlaylistMembership() async throws {
        let id = try create()
        let bytes = try Data(contentsOf: store.url)
        // Force persistence to fail without a user deletion ever being confirmed.
        let storage = root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: storage)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)
        library.remove(entries[0])
        try await waitUntil { !self.library.importing }
        XCTAssertEqual(playlist.definition(id)?.wallpaperIDs, entries.map(\.id))
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
    }

}
