import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WallpaperRenameTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var library: Library!
    private var entries: [Wallpaper] = []
    private var storage: URL { root.appendingPathComponent("library.json") }

    override func setUpWithError() throws {
        suite = "WupsyRenameTests-" + UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "conserve")
        defaults.set(false, forKey: "pauseOnBattery")
        entries = [
            Wallpaper(
                title: "Original", path: root.appendingPathComponent("image.png").path,
                root: root.path, kind: .image),
            Wallpaper(title: "Second", path: "/missing/video.mp4", root: "/missing", kind: .video),
        ]
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: entries[0].url)
        try JSONEncoder().encode(entries).write(to: storage)
        library = Library(storage: storage, defaults: defaults)
    }
    override func tearDownWithError() throws {
        library.stop()
        library = nil
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    func testRenamePreservesIdentitySelectionFavoritesAndSourceAndReloads() async throws {
        let original = entries[0]
        let source = try Data(contentsOf: original.url)
        library.selected = original.id
        library.toggleFavorite(original)
        let favoriteDefaults = defaults.stringArray(forKey: "favorites")
        try await library.rename(wallpaperID: original.id, newTitle: "  Wasserfall 🌊  ")
        var expected = original
        expected.title = "Wasserfall 🌊"
        XCTAssertEqual(library.items[0], expected)
        XCTAssertEqual(library.selected, original.id)
        XCTAssertTrue(library.favorites.contains(original.id))
        XCTAssertEqual(defaults.stringArray(forKey: "favorites"), favoriteDefaults)
        XCTAssertEqual(try ManagedWallpaperStore(storage: storage).load()[0], expected)
        XCTAssertEqual(try Data(contentsOf: original.url), source)
    }

    func testDisplayNameValidationAndCharacterBoundary() throws {
        for value in [
            "", "   ", "\nName", "Name\r", "a\u{2028}b", "a\u{2029}b", "a\0b", "a\tb",
            String(repeating: "a", count: 257),
        ] {
            XCTAssertThrowsError(try WallpaperTitle.normalized(value), value)
        }
        XCTAssertEqual(try WallpaperTitle.normalized("  /: \\ .. Café 👩‍👩‍👧‍👦 🌊  "), "/: \\ .. Café 👩‍👩‍👧‍👦 🌊")
        let boundary = String(repeating: "👩‍👩‍👧‍👦", count: 256)
        XCTAssertEqual(try WallpaperTitle.normalized(boundary), boundary)
    }

    func testInvalidNameAndMissingIdentityDoNotMutate() async throws {
        let before = try Data(contentsOf: storage)
        for (id, title) in [(entries[0].id, " "), (UUID(), "Name")] {
            do {
                try await library.rename(wallpaperID: id, newTitle: title)
                XCTFail("Expected rejection")
            } catch {}
        }
        XCTAssertEqual(library.items, entries)
        XCTAssertEqual(try Data(contentsOf: storage), before)
    }

    func testIdenticalNormalizedTitleDoesNotWriteAndDuplicateTitlesAreAllowed() async throws {
        let before = try Data(contentsOf: storage)
        let modified = try storage.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        try await library.rename(wallpaperID: entries[0].id, newTitle: " Original ")
        XCTAssertEqual(try Data(contentsOf: storage), before)
        XCTAssertEqual(
            try storage.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, modified)
        try await library.rename(wallpaperID: entries[1].id, newTitle: "Original")
        XCTAssertEqual(library.items.map(\.title), ["Original", "Original"])
        XCTAssertEqual(library.items.map(\.id), entries.map(\.id))
    }

    func testPersistFailureKeepsRuntimeAndStoredOldTitle() async throws {
        let before = try Data(contentsOf: storage)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: root.path)
        }
        do {
            try await library.rename(wallpaperID: entries[0].id, newTitle: "New")
            XCTFail("Expected persistence failure")
        } catch {}
        XCTAssertEqual(library.items, entries)
        XCTAssertEqual(try Data(contentsOf: storage), before)
    }

    func testManagedAndExternalTypesKeepEveryOtherFieldAndNativeProjectBytes() async throws {
        let store = ManagedWallpaperStore(storage: storage)
        var fixtures: [Wallpaper] = []
        for kind in [WallpaperKind.image, .video, .web, .scene] {
            for managed in [false, true] {
                for native in (kind == .scene ? [true] : [false]) {
                    var item = Wallpaper(
                        title: "Old", path: "/missing/source", root: "/missing",
                        kind: kind, sceneSource: native ? .nativeWSS : nil)
                    if managed {
                        item.managed = ManagedWallpaperLocation(
                            directory: (kind == .scene ? "WSS/" : kind == .web ? "Web/" : "Media/")
                                + "Original-\(item.id)", entry: "missing.file")
                        item = try store.resolve(item)
                    }
                    fixtures.append(item)
                }
            }
        }
        try JSONEncoder().encode(fixtures).write(to: storage)
        library = Library(storage: storage, defaults: defaults)
        let nativeFolder = URL(
            fileURLWithPath: fixtures.first { $0.kind == .scene && $0.managed != nil }!.root)
        try FileManager.default.createDirectory(at: nativeFolder, withIntermediateDirectories: true)
        let nativeFile = nativeFolder.appendingPathComponent("scene.wss.json")
        let corrupt = Data("user edit / invalid WSS must survive".utf8)
        try corrupt.write(to: nativeFile)
        for (index, item) in fixtures.enumerated() {
            try await library.rename(wallpaperID: item.id, newTitle: "New")
            var expected = item
            expected.title = "New"
            XCTAssertEqual(library.items[index], expected)
        }
        XCTAssertEqual(try Data(contentsOf: nativeFile), corrupt)
        XCTAssertEqual(try store.load(), library.items)
    }

    func testActiveRenameKeepsRendererInstancesAndPlaybackEvents() async throws {
        let request = library.apply(entries[0])
        guard case .accepted = await request.outcome else {
            return XCTFail("Playback not accepted")
        }
        let renderers = library.renderers.map(ObjectIdentifier.init)
        let events = library.playbackEvents
        let status = library.status
        var commands = 0
        library.onPlaybackCommand = { _ in commands += 1 }
        try await library.rename(wallpaperID: entries[0].id, newTitle: "Active 🌊")
        XCTAssertEqual(library.active?.id, entries[0].id)
        XCTAssertEqual(library.active?.title, "Active 🌊")
        XCTAssertEqual(library.renderers.map(ObjectIdentifier.init), renderers)
        XCTAssertEqual(library.playbackEvents, events)
        XCTAssertEqual(library.status, status)
        XCTAssertEqual(commands, 0)
        XCTAssertFalse(library.preparing)
    }

    func testRenameDuringPendingApplyDoesNotCancelOrRestartRequest() async throws {
        library.manuallyPaused = true
        let request = library.apply(entries[0])
        try await library.rename(wallpaperID: entries[0].id, newTitle: "Pending 🌊")
        XCTAssertEqual(library.active?.title, "Pending 🌊")
        library.manuallyPaused = false
        guard case .accepted = await request.outcome else {
            return XCTFail("Original request was cancelled")
        }
        XCTAssertEqual(library.active?.title, "Pending 🌊")
    }
    func testRenameDuringRunningPreparationKeepsOriginalApplyOutcome() async throws {
        var scene = entries[0]
        scene.kind = .scene
        try JSONEncoder().encode([scene]).write(to: storage)
        var continuation: CheckedContinuation<PreparedScenePlayback, Error>?
        var calls = 0
        library = Library(
            storage: storage, defaults: defaults,
            scenePreparation: { _ in
                calls += 1
                return try await withCheckedThrowingContinuation { continuation = $0 }
            })
        let request = library.apply(scene)
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try XCTUnwrap(continuation)
        try await library.rename(wallpaperID: scene.id, newTitle: "Preparing renamed")
        XCTAssertTrue(library.preparing)
        XCTAssertEqual(library.active?.title, "Preparing renamed")
        XCTAssertEqual(calls, 1)
        pending.resume(throwing: ImportFailure.message("Controlled preparation failure"))
        guard case .failed = await request.outcome else {
            return XCTFail("Rename replaced the original request")
        }
        XCTAssertEqual(calls, 1)
    }

}
