import XCTest

@testable import Wupsy

final class NativeImportBoundaryTests: XCTestCase {
    func testHistoricalLibraryCannotBeSilentlyRewrittenByNativeImport() async throws {
        let helper = ManagedLibraryTests()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let source = try helper.nativeSource()
        let old = try JSONSerialization.data(withJSONObject: [
            [
                "id": UUID().uuidString, "title": "Historical", "kind": "scene",
                "ownership": "managed",
                "managed": ["directory": "Loose/Old", "entry": "scene.json"],
                "scenePlaybackMode": "compatibility",
            ]
        ])
        _ = try helper.write("Support/library.json", old)
        let original = try helper.snapshot(source.deletingLastPathComponent())
        await helper.fails { _ = try await helper.store.importWallpaper(source, existing: []) }
        XCTAssertEqual(try Data(contentsOf: helper.store.storage), old)
        XCTAssertEqual(try helper.snapshot(source.deletingLastPathComponent()), original)
        let area = helper.store.wallpaperRoot.appendingPathComponent("WSS")
        if FileManager.default.fileExists(atPath: area.path) {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: area.path).isEmpty)
        }
    }

    func testManifestImportRejectsUnusedSymlinkInProject() async throws {
        let helper = ManagedLibraryTests()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let source = try helper.nativeSource()
        let outside = try helper.write("outside.txt", Data("preserved".utf8))
        try FileManager.default.createSymbolicLink(
            at: source.deletingLastPathComponent().appendingPathComponent("unused-link"),
            withDestinationURL: outside)
        await helper.fails { _ = try await helper.store.importWallpaper(source, existing: []) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: helper.store.storage.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("preserved".utf8))
    }

    func testPublicationFailurePreservesExistingNativeProjectAndSource() async throws {
        let helper = ManagedLibraryTests()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let source = try helper.nativeSource()
        let first = try await helper.store.importWallpaper(source, existing: [])
        let library = try Data(contentsOf: helper.store.storage)
        let project = try helper.snapshot(URL(fileURLWithPath: first.root))
        let original = try helper.snapshot(source.deletingLastPathComponent())
        let failing = ManagedWallpaperStore(storage: helper.store.storage) { stage in
            if stage == .sourcePublished { throw ImportFailure.message("synthetic failure") }
        }
        await helper.fails { _ = try await failing.importWallpaper(source, existing: [first]) }
        XCTAssertEqual(try Data(contentsOf: helper.store.storage), library)
        XCTAssertEqual(try helper.snapshot(URL(fileURLWithPath: first.root)), project)
        XCTAssertEqual(try helper.snapshot(source.deletingLastPathComponent()), original)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: helper.store.wallpaperRoot.appendingPathComponent("WSS").path),
            [URL(fileURLWithPath: first.root).lastPathComponent])
    }
}
