import AppKit
import Combine
import XCTest

@testable import Wupsy

@MainActor private final class GenerationClock: PlaylistScheduling {
    var now: TimeInterval = 0
    var schedules = 0
    var alarmID: UUID?
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void)
        -> AnyCancellable
    {
        schedules += 1
        let id = UUID()
        alarmID = id
        return AnyCancellable { [weak self] in if self?.alarmID == id { self?.alarmID = nil } }
    }
}

@MainActor final class WSSImageGenerationSaveTests: XCTestCase {
    func runSnapshotScenario(active: Bool) async throws {
        let helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
        defer { try? helper.helper.tearDownWithError() }
        let project = helper.project!
        let item = helper.item!
        let otherRoot = try helper.helper.fixtures.fixture(name: "Wallpapers/WSS/Other")
        let other = Wallpaper(
            title: "Other", path: otherRoot.appendingPathComponent("scene.wss.json").path,
            root: otherRoot.path, kind: .scene,
            managed: .init(directory: "WSS/Other", entry: "scene.wss.json"), sceneSource: .nativeWSS
        )
        let storage = helper.helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([item, other]).write(to: storage)
        let suite = "WSSGeneration-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "manuallyPaused")
        defaults.set(false, forKey: "conserve")
        defaults.set(false, forKey: "pauseOnBattery")
        let library = Library(
            storage: storage, defaults: defaults, restoreOnLaunch: false,
            rendererStart: { renderer, _ in renderer.setPaused(false) })
        defer { library.stop() }
        let clock = GenerationClock()
        var shuffles = 0
        let playlistURL = helper.helper.root.appendingPathComponent("playlists.json")
        let playlist = WallpaperPlaylist(
            library: library, storage: playlistURL, defaults: defaults,
            scheduler: clock, restoreOnLaunch: false,
            shuffle: { ids in
                shuffles += 1
                return ids
            })
        defer { playlist.shutdown() }
        let playlistID = try playlist.createPlaylist(name: "Generation test")
        try playlist.add((active ? item : other).id, to: playlistID)
        try playlist.add((active ? other : item).id, to: playlistID)
        try playlist.setPlaybackMode(playlistID: playlistID, mode: .shuffle)
        playlist.activatePlaylist(id: playlistID)
        for _ in 0..<10000 {
            if clock.alarmID != nil { break }
            await Task.yield()
        }
        XCTAssertEqual(library.active?.id, (active ? item : other).id)
        let renderers = library.renderers.map(ObjectIdentifier.init)
        let oldPlayer = library.renderers.first?.scene as? WSSStaticPlayer
        let playlistState = playlist.state
        let playlistBytes = try Data(contentsOf: playlistURL)
        let alarmID = clock.alarmID
        let scheduleCount = clock.schedules
        let shuffleCount = shuffles
        var gate: CheckedContinuation<Void, Never>?
        let doc = WSSEditorDocument(
            project: project,
            save: { snapshot in
                await withCheckedContinuation { gate = $0 }
                return try await library.saveWSSManifest(snapshot)
            })
        defer { doc.close() }
        let importer = WSSImageImporter()
        let a = try await importer.normalize(
            WSSImageImportTests().image(width: 10, height: 7), extension: "png")
        let b = try await importer.normalize(
            WSSImageImportTests().image(width: 7, height: 18), extension: "png")
        let id = doc.identity.layers[1].id
        try await doc.installImage(a, replacing: id)
        let modelA = doc.state.workingModel
        let saving = Task { await doc.save() }
        while gate == nil { await Task.yield() }
        try await doc.installImage(b, replacing: id)
        try doc.setImage(.centerX, value: 48, layer: id)
        let modelB = doc.state.workingModel
        gate?.resume()
        let success = await saving.value
        XCTAssertTrue(success)
        XCTAssertEqual(doc.state.savedModel, modelA)
        XCTAssertEqual(doc.state.workingModel, modelB)
        XCTAssertTrue(doc.isDirty)
        XCTAssertNotNil(doc.state.sessionAssets[b.path])
        XCTAssertEqual(try doc.state.sessionAssets[b.path]?.read(), try b.read())
        let loaded = try await WSSEditorProjectLoader().load(item)
        XCTAssertEqual(loaded.document, modelA)
        XCTAssertTrue(loaded.diskBasis.assets.keys.contains(a.path))
        XCTAssertFalse(loaded.diskBasis.assets.keys.contains(b.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: project.handle.root.appendingPathComponent(b.path).path))
        let cached = await ImageLoader.shared.thumbnail(item)
        let expected = try WSSLibraryThumbnail.render(loaded.resources, maxPixel: 480)
        let pixels = WSSLibraryPreviewTests()
        XCTAssertEqual(try pixels.pixels(XCTUnwrap(cached)), try pixels.pixels(expected))
        let cold = await ImageLoader().thumbnail(item)
        XCTAssertEqual(try pixels.pixels(XCTUnwrap(cold)), try pixels.pixels(expected))
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        XCTAssertNotNil(doc.previewResources.images[.init(value: b.path)])
        if active {
            let player = try XCTUnwrap(library.renderers.first?.scene as? WSSStaticPlayer)
            XCTAssertNotNil(player.resources.images[.init(value: a.path)])
            XCTAssertNil(player.resources.images[.init(value: b.path)])
        } else {
            XCTAssertEqual(library.renderers.map(ObjectIdentifier.init), renderers)
            XCTAssertTrue((library.renderers.first?.scene as? WSSStaticPlayer) === oldPlayer)
        }
        XCTAssertEqual(playlist.state, playlistState)
        XCTAssertEqual(try Data(contentsOf: playlistURL), playlistBytes)
        XCTAssertEqual(clock.schedules, scheduleCount)
        XCTAssertEqual(clock.alarmID, alarmID)
        XCTAssertEqual(shuffles, shuffleCount)
        gate = nil
        let next = Task { await doc.save() }
        while gate == nil { await Task.yield() }
        gate?.resume()
        let nextSuccess = await next.value
        XCTAssertTrue(nextSuccess)
        XCTAssertFalse(doc.isDirty)
        let newest = try await WSSEditorProjectLoader().load(item)
        XCTAssertEqual(newest.document, modelB)
    }
    func testSaveNWorkingNPlusOneActiveDesktopLibraryAndPlaylistUseN() async throws {
        try await runSnapshotScenario(active: true)
    }
    func testSaveNWorkingNPlusOneInactiveDesktopRemainsUnchanged() async throws {
        try await runSnapshotScenario(active: false)
    }
}
