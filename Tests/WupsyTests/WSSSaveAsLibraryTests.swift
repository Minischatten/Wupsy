import AppKit
import Combine
import XCTest

@testable import Wupsy

@MainActor private final class CopyClock: PlaylistScheduling {
    var now: TimeInterval = 0
    var count = 0
    var alarm: UUID?
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void)
        -> AnyCancellable
    {
        count += 1
        let id = UUID()
        alarm = id
        return AnyCancellable { [weak self] in if self?.alarm == id { self?.alarm = nil } }
    }
}
@MainActor final class WSSSaveAsLibraryTests: XCTestCase {
    func scenario(activeA: Bool, previewFailure: Bool = false) async throws {
        let helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
        defer { try? helper.helper.tearDownWithError() }
        let a = helper.item!
        let root = try helper.helper.fixtures.fixture(name: "Wallpapers/WSS/Other")
        let other = Wallpaper(
            title: "Other", path: root.appendingPathComponent("scene.wss.json").path,
            root: root.path, kind: .scene,
            managed: .init(directory: "WSS/Other", entry: "scene.wss.json"), sceneSource: .nativeWSS
        )
        let storage = helper.helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([a, other]).write(to: storage)
        let suite = "WSSSaveAs-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "manuallyPaused")
        defaults.set(false, forKey: "conserve")
        defaults.set(false, forKey: "pauseOnBattery")
        let library = Library(
            storage: storage, defaults: defaults, restoreOnLaunch: false,
            rendererStart: { renderer, _ in renderer.setPaused(false) })
        defer { library.stop() }
        let clock = CopyClock()
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
        let id = try playlist.createPlaylist(name: "Keep A")
        try playlist.add((activeA ? a : other).id, to: id)
        try playlist.add((activeA ? other : a).id, to: id)
        try playlist.setPlaybackMode(playlistID: id, mode: .shuffle)
        playlist.activatePlaylist(id: id)
        for _ in 0..<10000 where clock.alarm == nil { await Task.yield() }
        XCTAssertNotNil(clock.alarm)
        let active = library.active?.id
        let renderers = library.renderers.map(ObjectIdentifier.init)
        let player = library.renderers.first?.scene as? WSSStaticPlayer
        let state = playlist.state
        let bytes = try Data(contentsOf: playlistURL)
        let timer = clock.alarm
        let timers = clock.count
        let bags = shuffles
        let oldPlayback = library.onPlaybackCommand
        var events = 0
        library.onPlaybackCommand = { command in
            events += 1
            oldPlayback?(command)
        }
        let original = try Data(contentsOf: helper.project.handle.entry)
        let doc = helper.document()
        defer { doc.close() }
        let generation = try await WSSImageImporter().normalize(
            WSSImageImportTests().image(), extension: "png")
        try await doc.installImage(generation)
        try doc.setImage(.centerX, value: 19, layer: doc.identity.layers[0].id)
        let snapshot = try WSSSaveAsSnapshot(
            document: doc.state.workingModel, state: doc.state,
            source: doc.project.handle, name: "Library Copy")
        let receipt: WSSSaveAsReceipt
        if previewFailure {
            receipt = try await library.saveWSSAs(snapshot, preview: { _ in false })
        } else {
            receipt = try await library.saveWSSAs(snapshot)
        }
        let b = receipt.project.handle.wallpaper
        XCTAssertTrue(library.items.contains { $0.id == b.id })
        XCTAssertTrue(library.items.contains { $0.id == a.id })
        XCTAssertEqual(library.selected, b.id)
        XCTAssertEqual(try Data(contentsOf: helper.project.handle.entry), original)
        XCTAssertEqual(library.active?.id, active)
        XCTAssertEqual(library.renderers.map(ObjectIdentifier.init), renderers)
        XCTAssertTrue((library.renderers.first?.scene as? WSSStaticPlayer) === player)
        XCTAssertEqual(events, 0)
        XCTAssertEqual(playlist.state, state)
        XCTAssertEqual(try Data(contentsOf: playlistURL), bytes)
        XCTAssertFalse(playlist.state.definitions.flatMap(\.wallpaperIDs).contains(b.id))
        XCTAssertEqual(clock.alarm, timer)
        XCTAssertEqual(clock.count, timers)
        XCTAssertEqual(shuffles, bags)
        if previewFailure { XCTAssertFalse(receipt.warnings.isEmpty) }
        let image = await ImageLoader().thumbnail(b)
        let expected = try WSSLibraryThumbnail.render(receipt.project.resources, maxPixel: 480)
        let pixels = WSSLibraryPreviewTests()
        XCTAssertEqual(try pixels.pixels(XCTUnwrap(image)), try pixels.pixels(expected))
        let bdoc = WSSEditorDocument(
            project: receipt.project, save: { try await library.saveWSSManifest($0) })
        defer { bdoc.close() }
        try bdoc.setImage(.opacity, value: 0.5, layer: bdoc.identity.layers[0].id)
        let success = await bdoc.save()
        XCTAssertTrue(success)
        XCTAssertEqual(library.active?.id, active)
        XCTAssertEqual(library.renderers.map(ObjectIdentifier.init), renderers)
        XCTAssertEqual(events, 0)
        XCTAssertEqual(playlist.state, state)
        XCTAssertEqual(clock.alarm, timer)
        XCTAssertEqual(clock.count, timers)
        XCTAssertEqual(shuffles, bags)
    }
    func testActiveARemainsDesktopAndPlaylistMemberAfterCopyAndNormalBSave() async throws {
        try await scenario(activeA: true)
    }
    func testOtherDesktopRemainsUnchangedAfterCopyAndNormalBSave() async throws {
        try await scenario(activeA: false)
    }
    func testPreviewFailureAfterCommitRetainsBAndCanReloadPreview() async throws {
        try await scenario(activeA: true, previewFailure: true)
    }
}
