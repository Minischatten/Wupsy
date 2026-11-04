import XCTest

@testable import Wupsy

@MainActor final class ProductIdentityTests: XCTestCase {
    let files = FileManager.default
    var root: URL!
    var paths: ProductPaths!
    var domain: String!
    var oldDomain: String!
    var defaults: UserDefaults!
    var oldDefaults: UserDefaults!

    override func setUpWithError() throws {
        root = files.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("wupsy-namespace-tests-" + UUID().uuidString)
        paths = ProductPaths(
            applicationSupport: root.appendingPathComponent("Support"),
            caches: root.appendingPathComponent("Caches"), temporary: root)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        domain = "wupsy-tests." + UUID().uuidString
        oldDomain = "ambient-rejection-tests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        oldDefaults = try XCTUnwrap(UserDefaults(suiteName: oldDomain))
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: domain)
        oldDefaults.removePersistentDomain(forName: oldDomain)
        try files.removeItem(at: root)
    }
    func sentinel(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try files.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid old Ambient data: must never be loaded".utf8).write(to: url)
        return url
    }
    func testProductContractAndIndependentPaths() {
        XCTAssertEqual(ProductIdentity.bundleIdentifier, "com.wirdschonsoftware.wupsy")
        XCTAssertEqual(ProductIdentity.benchmarkDomain, "com.wirdschonsoftware.wupsy.benchmark")
        XCTAssertEqual(paths.library.path, root.path + "/Support/Wupsy/library.json")
        XCTAssertEqual(paths.playlists.path, root.path + "/Support/Wupsy/playlists.json")
        XCTAssertEqual(paths.videoCache.path, root.path + "/Caches/Wupsy/Video-v2")
        for url in [paths.benchmarkSupport, paths.benchmarkLibrary, paths.benchmarkPlaylists] {
            XCTAssertTrue(url.lastPathComponent.hasPrefix("Wupsy-benchmark-"))
        }
        XCTAssertEqual(ProductIdentity.backupFormat, "wupsy-library-backup")
        XCTAssertTrue(ProductIdentity.backupTemporaryTemplate.hasPrefix("Wupsy-"))
        XCTAssertTrue(ProductIdentity.backupPartialPrefix.hasPrefix(".Wupsy-"))
        XCTAssertTrue(ProductIdentity.draftPrefix.hasPrefix(".wupsy-"))
        XCTAssertTrue(ProductIdentity.editorTemporaryTemplate.hasPrefix("wupsy-"))
    }
    func testFreshRuntimeIgnoresOldLibraryPlaylistsPreferencesAndRecovery() throws {
        let sentinels = try [
            "Support/Ambient/library.json", "Support/Ambient/playlists.json",
            "Support/Ambient/.restore/journal.json",
            "Support/Ambient/.restore/metadata-recovery.json",
        ].map(sentinel)
        let before = try sentinels.map { try Data(contentsOf: $0) }
        oldDefaults.set(UUID().uuidString, forKey: "selectedWallpaper")
        oldDefaults.set(UUID().uuidString, forKey: "selectedPlaylistID")
        oldDefaults.set(true, forKey: "manuallyPaused")
        let preferences = oldDefaults.persistentDomain(forName: oldDomain)! as NSDictionary
        var constructed = false
        try WupsyStartup.run(
            context: .init(supportRoot: paths.supportRoot, preferenceDomain: domain)
        ) {
            constructed = true
            let library = Library(
                storage: paths.library, defaults: defaults, restoreOnLaunch: false)
            defer { library.stop() }
            XCTAssertTrue(library.items.isEmpty)
            XCTAssertNil(library.selected)
            XCTAssertNil(library.active)
            XCTAssertFalse(library.manuallyPaused)
            let playlist = WallpaperPlaylist(
                library: library, storage: paths.playlists, defaults: defaults,
                restoreOnLaunch: false)
            defer { playlist.shutdown() }
            XCTAssertTrue(playlist.state.definitions.isEmpty)
            XCTAssertNil(playlist.selectedPlaylistID)
        }
        XCTAssertTrue(constructed)
        XCTAssertEqual(try sentinels.map { try Data(contentsOf: $0) }, before)
        XCTAssertEqual(
            oldDefaults.persistentDomain(forName: oldDomain)! as NSDictionary, preferences)
        XCTAssertFalse(files.fileExists(atPath: paths.supportRoot.path))
    }

    func testFirstSaveAndSaveAsStayInsideWupsy() async throws {
        let input = root.appendingPathComponent("draft.png")
        try WSSImageImportTests().image().write(to: input)
        let draft = try await WSSDraftPreparation().create(image: input)
        defer { try? draft.handle.draftOwner?.discard() }
        XCTAssertTrue(draft.handle.root.lastPathComponent.hasPrefix(".wupsy-draft-"))
        let store = ManagedWallpaperStore(storage: paths.library)
        func snapshot(_ project: WSSLoadedEditorProject, id: UUID) throws -> WSSSaveAsSnapshot {
            try WSSSaveAsSnapshot(
                document: project.document,
                state: WSSEditorDocumentState(
                    model: project.document, diskBasis: project.diskBasis),
                source: project.handle, name: "Fresh", destinationID: id)
        }
        let first = try await store.publishWSSDraft(snapshot(draft, id: draft.handle.id))
        let copy = try await store.saveWSSAs(snapshot(first.project, id: UUID()))
        for project in [first.project, copy.project] {
            XCTAssertTrue(
                project.handle.root.path.hasPrefix(paths.supportRoot.path + "/Wallpapers/WSS/"))
            _ = try await WSSEditorProjectLoader().load(project.handle.wallpaper)
        }
        XCTAssertEqual(try store.load().count, 2)
    }
    func testImportAndPlaylistRestartUseOnlyWupsyRoot() async throws {
        let old = try sentinel("Support/Ambient/library.json")
        let before = try Data(contentsOf: old)
        let input = root.appendingPathComponent("source.png")
        try WSSImageImportTests().image().write(to: input)
        let store = ManagedWallpaperStore(storage: paths.library)
        let item = try await store.importWallpaper(input, existing: [])
        XCTAssertTrue(item.path.hasPrefix(paths.supportRoot.path + "/Wallpapers/"))
        let playlistStore = WallpaperPlaylistStore(url: paths.playlists)
        let definition = PlaylistDefinition(name: "Fresh playlist", wallpaperIDs: [item.id])
        let state = PlaylistCollectionState(definitions: [definition])
        try playlistStore.save(state)
        XCTAssertEqual(try playlistStore.load().definitions, state.definitions)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.map(\.id), [item.id])
        XCTAssertEqual(try Data(contentsOf: old), before)
    }
}
