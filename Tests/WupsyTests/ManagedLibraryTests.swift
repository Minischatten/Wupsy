import MetalKit
import XCTest

@testable import Wupsy

final class ManagedLibraryTests: XCTestCase {
    var root: URL!
    var store: ManagedWallpaperStore!
    let files = FileManager.default
    override func setUpWithError() throws {
        root = files.temporaryDirectory.appendingPathComponent(
            "WupsyManaged-" + UUID().uuidString
        ).resolvingSymlinksInPath()
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        store = ManagedWallpaperStore(storage: root.appendingPathComponent("Support/library.json"))
    }
    override func tearDownWithError() throws { try files.removeItem(at: root) }
    func write(_ path: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(path)
        try files.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func nativeSource(_ name: String = "Source") throws -> URL {
        let helper = WSSNativeSceneTests()
        helper.root = root
        var document = helper.document()
        document["title"] = name == "Project" ? "Water / Project" : "Ocean"
        return try helper.fixture(document, name: name).appendingPathComponent("scene.wss.json")
    }
    func nativeFolder() throws -> URL { try nativeSource("Project").deletingLastPathComponent() }
    func snapshot(_ url: URL) throws -> [String: Data] {
        let enumerator = try XCTUnwrap(files.enumerator(atPath: url.path))
        var result: [String: Data] = [:]
        for case let key as String in enumerator {
            let child = url.appendingPathComponent(key)
            result[key] =
                try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                ? Data() : Data(contentsOf: child)
        }
        return result
    }
    func fails(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line)
        async
    {
        do {
            try await body()
            XCTFail("Expected controlled failure", file: file, line: line)
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line) }
    }
    func render(_ item: Wallpaper) async throws -> Data {
        let resources = try await WSSStaticPreparation.shared.prepare(item)
        return try WSSRippleChainTests().render(resources, time: 0.7, width: 32, height: 16).0
    }
    func testNativeCopyCanonicalNamePersistenceAndSourceIndependence() async throws {
        let source = try nativeSource()
        let before = try Data(contentsOf: source)
        let item = try await store.importWallpaper(source, existing: [])
        XCTAssertEqual(item.managed?.directory, "WSS/Ocean")
        XCTAssertEqual(item.managed?.entry, "scene.wss.json")
        XCTAssertEqual(item.ownership, .managed)
        XCTAssertEqual(try Data(contentsOf: item.url), before)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(item.root, store.wallpaperRoot.appendingPathComponent("WSS/Ocean").path)
        let json = try String(contentsOf: store.storage)
        XCTAssertFalse(json.contains(source.path))
        XCTAssertFalse(json.contains(root.path))
        let record = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        ).first!
        XCTAssertNil(record["path"])
        XCTAssertNil(record["root"])
        let loaded = try XCTUnwrap(store.load().first)
        XCTAssertEqual(loaded, item)
        try files.moveItem(
            at: source.deletingLastPathComponent(),
            to: root.appendingPathComponent("Source unavailable"))
        let a = try await render(item)
        let b = try await render(loaded)
        XCTAssertEqual(a, b)
        let relocated = root.appendingPathComponent("RelocatedSupport")
        try files.copyItem(at: store.supportRoot, to: relocated)
        let movedStore = ManagedWallpaperStore(
            storage: relocated.appendingPathComponent("library.json"))
        let moved = try XCTUnwrap(movedStore.load().first)
        XCTAssertNotEqual(moved.path, item.path)
        let rendered = try await render(moved)
        XCTAssertEqual(a, rendered)
    }
    func testNativeCompleteTreeAndSourceIndependence() async throws {
        let source = try nativeFolder()
        let before = try snapshot(source)
        let item = try await store.importWallpaper(
            source.appendingPathComponent("scene.wss.json"), existing: [])
        XCTAssertEqual(item.managed?.directory, "WSS/Water - Project")
        XCTAssertEqual(item.managed?.entry, "scene.wss.json")
        XCTAssertEqual(try snapshot(URL(fileURLWithPath: item.root)), before)
        XCTAssertEqual(try snapshot(source), before)
        try files.moveItem(at: source, to: root.appendingPathComponent("Source unavailable"))
        _ = try await render(try XCTUnwrap(store.load().first))
    }
    func testNativeCollisionNamesRepeatedImport() async throws {
        let source = try nativeSource()
        let first = try await store.importWallpaper(source, existing: [])
        let second = try await store.importWallpaper(source, existing: [first])
        let third = try await store.importWallpaper(source, existing: [first, second])
        XCTAssertEqual(second.managed?.directory, "WSS/Ocean 2")
        XCTAssertEqual(third.managed?.directory, "WSS/Ocean 3")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(try Data(contentsOf: first.url), try Data(contentsOf: source))
        let loose = try await store.importWallpaper(
            self.nativeFolder(), existing: [first, second, third])
        XCTAssertTrue(loose.managed!.directory.hasPrefix("WSS/"))
        XCTAssertEqual(try store.load().count, 4)
        XCTAssertEqual(ManagedWallpaperStore.readableName("../a:b\\c/"), "-a-b-c-")
        XCTAssertFalse(ManagedWallpaperStore.readableName("../a:b\\c/").contains("/"))
        XCTAssertLessThanOrEqual(
            ManagedWallpaperStore.readableName(String(repeating: "水", count: 200)).utf8.count, 120)
    }
    func testConcurrentImportsClaimDistinctNamesWithoutLosingRecords() async throws {
        let source = try nativeSource()
        async let first = store.importWallpaper(source, existing: [])
        async let second = store.importWallpaper(source, existing: [])
        let (a, b) = try await (first, second)
        XCTAssertNotEqual(a.managed?.directory, b.managed?.directory)
        XCTAssertEqual(try store.load().count, 2)
    }
    func testRemoveNativeProjectsPreservesOriginalsAndOtherImports() async throws {
        let source = try nativeSource()
        let project = try nativeFolder()
        let original = try snapshot(root.appendingPathComponent("Source"))
        let originalProject = try snapshot(project)
        let a = try await store.importWallpaper(source, existing: [])
        let b = try await store.importWallpaper(project, existing: [a])
        _ = try await store.remove(a, existing: [a, b])
        XCTAssertFalse(files.fileExists(atPath: a.root))
        XCTAssertTrue(files.fileExists(atPath: b.root))
        _ = try await store.remove(b, existing: [b])
        XCTAssertFalse(files.fileExists(atPath: b.root))
        XCTAssertEqual(try snapshot(root.appendingPathComponent("Source")), original)
        XCTAssertEqual(try snapshot(project), originalProject)
        XCTAssertTrue(try store.load().isEmpty)
    }
    func testExternalNativeJSONStillLoadsAndNeverDeletesSource() async throws {
        let source = try nativeSource()
        let id = UUID()
        let old: [[String: Any]] = [
            [
                "id": id.uuidString, "title": "Old", "path": source.path,
                "root": source.deletingLastPathComponent().path, "kind": "scene",
                "sceneSource": "nativeWSS",
            ]
        ]
        _ = try write("Support/library.json", JSONSerialization.data(withJSONObject: old))
        let item = try XCTUnwrap(store.load().first)
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.ownership, .external)
        let managed = try await store.importWallpaper(source, existing: [item])
        XCTAssertEqual(try store.load().count, 2)
        _ = try await store.remove(item, existing: [item, managed])
        XCTAssertTrue(files.fileExists(atPath: source.path))
        XCTAssertTrue(files.fileExists(atPath: managed.path))
        _ = try await store.remove(managed, existing: [managed])
        XCTAssertTrue(files.fileExists(atPath: source.path))
        XCTAssertTrue(try store.load().isEmpty)
    }
    func testProjectContainingManagedRootCannotRecursivelyImportItself() async throws {
        _ = try write("index.html", Data("<p>project</p>".utf8))
        await fails { _ = try await self.store.importWallpaper(self.root, existing: []) }
        XCTAssertFalse(files.fileExists(atPath: store.storage.path))
        XCTAssertFalse(files.fileExists(atPath: store.wallpaperRoot.path))
    }

    func testInvalidSourcesAndFailedPersistenceRollBackWithoutHalfEntry() async throws {
        let broken = try write("broken.pkg", Data("broken".utf8))
        await fails { _ = try await self.store.importWallpaper(broken, existing: []) }
        XCTAssertFalse(files.fileExists(atPath: store.storage.path))
        let source = try nativeSource()
        try files.createDirectory(at: store.storage, withIntermediateDirectories: true)
        await fails { _ = try await self.store.importWallpaper(source, existing: []) }
        let names = try files.contentsOfDirectory(atPath: store.wallpaperRoot.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".import-") })
        XCTAssertTrue(
            try files.contentsOfDirectory(
                atPath: store.wallpaperRoot.appendingPathComponent("WSS").path
            ).isEmpty)
        XCTAssertTrue(files.fileExists(atPath: source.path))
    }
    func testFailedRemovalPersistenceRestoresManagedFolder() async throws {
        let source = try nativeSource()
        let item = try await store.importWallpaper(source, existing: [])
        try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.supportRoot.path)
        defer {
            try? files.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: store.supportRoot.path)
        }
        await fails { _ = try await self.store.remove(item, existing: [item]) }
        XCTAssertTrue(files.fileExists(atPath: item.path))
        XCTAssertEqual(try store.load(), [item])
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: item.url))
        XCTAssertFalse(
            try files.contentsOfDirectory(atPath: store.wallpaperRoot.path).contains {
                $0.hasPrefix(".remove-")
            })
    }
    func testSourceSymlinksInternalAndExternalAreRejected() async throws {
        let source = try nativeFolder()
        let outside = try write("outside.txt", Data("untouched".utf8))
        for destination in [outside, source.appendingPathComponent("scene.json")] {
            let link = source.appendingPathComponent("link")
            try files.createSymbolicLink(at: link, withDestinationURL: destination)
            await fails { _ = try await self.store.importWallpaper(source, existing: []) }
            try files.removeItem(at: link)
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
        XCTAssertFalse(files.fileExists(atPath: store.storage.path))
    }
    func testDeletionRejectsTraversalRootsAndForgedRuntimePaths() async throws {
        let source = try nativeSource()
        for directory in [
            "", "WSS", "Loose", "Wallpapers", "../Source", "/Packages/Ocean",
            "Packages/../Source", "WSS/Ocean/nested",
        ] {
            let item = Wallpaper(
                title: "Unsafe", path: source.path, root: source.deletingLastPathComponent().path,
                kind: .scene,
                managed: ManagedWallpaperLocation(directory: directory, entry: "scene.wss.json"))
            await fails { _ = try await self.store.remove(item, existing: [item]) }
        }
        let item = try await store.importWallpaper(source, existing: [])
        var forged = item
        forged.path = source.path
        await fails { _ = try await self.store.remove(forged, existing: [forged]) }
        XCTAssertTrue(files.fileExists(atPath: item.path))
        XCTAssertTrue(files.fileExists(atPath: source.path))
    }
    func testManagedDirectoryAndNestedSymlinkEscapesAreNeverDeleted() async throws {
        let source = try nativeSource()
        let item = try await store.importWallpaper(source, existing: [])
        let outside = try write("outside/keep.txt", Data("keep".utf8))
        let child = URL(fileURLWithPath: item.root).appendingPathComponent("escape")
        try files.createSymbolicLink(
            at: child, withDestinationURL: outside.deletingLastPathComponent())
        await fails { _ = try await self.store.remove(item, existing: [item]) }
        try files.removeItem(at: child)
        try files.removeItem(at: URL(fileURLWithPath: item.root))
        try files.createSymbolicLink(
            at: URL(fileURLWithPath: item.root),
            withDestinationURL: outside.deletingLastPathComponent())
        await fails { _ = try await self.store.remove(item, existing: [item]) }
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }
    func testDestinationAndJSONSymlinksAreRejected() async throws {
        let source = try nativeSource()
        let outside = try write("outside/keep.txt", Data("keep".utf8))
        try files.createDirectory(at: store.wallpaperRoot, withIntermediateDirectories: true)
        let category = store.wallpaperRoot.appendingPathComponent("WSS")
        try files.createSymbolicLink(
            at: category, withDestinationURL: outside.deletingLastPathComponent())
        await fails { _ = try await self.store.importWallpaper(source, existing: []) }
        try files.removeItem(at: category)
        try files.createSymbolicLink(at: store.storage, withDestinationURL: outside)
        await fails { _ = try await self.store.importWallpaper(source, existing: []) }
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }
    func testSymlinkLibraryRootIsRejectedEvenBeforeStoreInitialization() async throws {
        let source = try nativeSource()
        let outside = try write("outside/keep.txt", Data("keep".utf8))
        try files.createSymbolicLink(
            at: root.appendingPathComponent("Support"),
            withDestinationURL: outside.deletingLastPathComponent())
        let unsafe = ManagedWallpaperStore(
            storage: root.appendingPathComponent("Support/library.json"))
        await fails { _ = try await unsafe.importWallpaper(source, existing: []) }
        XCTAssertFalse(
            files.fileExists(
                atPath: outside.deletingLastPathComponent().appendingPathComponent("Wallpapers")
                    .path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }

    @MainActor func wait(_ library: Library) async throws {
        for _ in 0..<1000 {
            if !library.importing { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Library operation timed out")
    }
    @MainActor func testLibraryUIImportRestartAndActiveRemoval() async throws {
        let source = try nativeSource()
        let suite = "WupsyManagedTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "manuallyPaused")
        let library = Library(storage: store.storage, defaults: defaults)
        library.importURLs([source])
        try await wait(library)
        XCTAssertNil(library.message)
        let item = try XCTUnwrap(library.items.first)
        library.apply(item)
        XCTAssertEqual(library.active?.id, item.id)
        let restarted = Library(storage: store.storage, defaults: defaults)
        XCTAssertEqual(restarted.items.first?.path, item.path)
        library.remove(item)
        XCTAssertNil(library.active)
        try await wait(library)
        XCTAssertTrue(library.items.isEmpty)
        XCTAssertFalse(files.fileExists(atPath: item.root))
        XCTAssertTrue(files.fileExists(atPath: source.path))
        library.stop()
        restarted.stop()
    }
    @MainActor func testUnreadableLibraryIsNotSilentlyOverwritten() async throws {
        _ = try write("Support/library.json", Data("not JSON".utf8))
        let source = try nativeSource()
        let suite = "WupsyManagedTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = Library(storage: store.storage, defaults: defaults)
        XCTAssertNotNil(library.message)
        library.importURLs([source])
        try await wait(library)
        XCTAssertEqual(try Data(contentsOf: store.storage), Data("not JSON".utf8))
    }
    func testNonSceneFilesAndWebProjectsAreAlsoManaged() async throws {
        let html = try write("Web/index.html", Data("<img src='assets/picture.png'>".utf8))
        _ = try write("Web/assets/picture.png", Data("asset".utf8))
        let item = try await store.importWallpaper(html.deletingLastPathComponent(), existing: [])
        XCTAssertTrue(item.managed!.directory.hasPrefix("Web/"))
        XCTAssertTrue(
            files.fileExists(
                atPath: URL(fileURLWithPath: item.root).appendingPathComponent("assets/picture.png")
                    .path))
        let gif = try write(
            "Media/demo.gif",
            Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!)
        let media = try await store.importWallpaper(gif, existing: [item])
        XCTAssertEqual(media.managed?.directory, "Media/demo")
    }
}
