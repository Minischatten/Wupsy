import AppKit
import XCTest

@testable import Wupsy

@MainActor private final class MovePublicationPause {
    var onReach: () -> Void = {}
    var reached = false
    var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        reached = true
        onReach()
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor final class LibraryMoveTests: XCTestCase {
    var root: URL!
    var storage: URL { root.appendingPathComponent("library.json") }
    var defaults: UserDefaults!
    var suite: String!
    var items: [Wallpaper]!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "LibraryMove-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        items = (0..<5).map {
            Wallpaper(
                title: "Item \($0)", path: root.appendingPathComponent("\($0).png").path,
                root: root.path, kind: .image)
        }
        try save(items)
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }
    func save(_ value: [Wallpaper]) throws {
        try JSONEncoder().encode(value).write(to: storage, options: .atomic)
    }
    func testEverySourceTargetAndPlacementPreservesMetadataAndReloads() async throws {
        let store = ManagedWallpaperStore(storage: storage)
        for source in items.indices {
            for target in items.indices where source != target {
                for placement in [LibraryMovePlacement.before, .after] {
                    try save(items)
                    var visible = Array(items.reversed())
                    let moving = visible.remove(at: visible.firstIndex(of: items[source])!)
                    let destination = visible.firstIndex(of: items[target])!
                    visible.insert(moving, at: destination + (placement == .after ? 1 : 0))
                    let result = try await store.move(
                        wallpaperID: moving.id,
                        relativeTo: items[target].id, placement: placement)
                    XCTAssertEqual(result, Array(visible.reversed()))
                    XCTAssertEqual(try store.load(), result)
                    XCTAssertEqual(Set(result), Set(items))
                }
            }
        }
    }
    func testInvalidIDsAndNoOpDoNotWrite() async throws {
        let store = ManagedWallpaperStore(storage: storage)
        // Noncanonical bytes make an accidental JSON re-encode observable.
        var bytes = try Data(contentsOf: storage)
        bytes.append(contentsOf: [10, 32, 10])
        try bytes.write(to: storage)
        _ = try await store.move(
            wallpaperID: items[1].id, relativeTo: items[0].id,
            placement: .before)
        XCTAssertEqual(try Data(contentsOf: storage), bytes)
        for (source, target) in [
            (items[0].id, items[0].id), (UUID(), items[0].id),
            (items[0].id, UUID()),
        ] {
            do {
                _ = try await store.move(
                    wallpaperID: source, relativeTo: target, placement: .before)
                XCTFail("Invalid move accepted")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: storage), bytes)
        }
        try save(items + [items[3]])
        let duplicateBytes = try Data(contentsOf: storage)
        do {
            _ = try await store.move(
                wallpaperID: items[0].id, relativeTo: items[1].id,
                placement: .before)
            XCTFail("Duplicate identity accepted")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: storage), duplicateBytes)
    }
    func testPublicationFailureAndMaintenance() async throws {
        let maintenance = MaintenanceCoordinator()
        let library = Library(
            maintenance: maintenance, storage: storage, defaults: defaults,
            restoreOnLaunch: false)
        let before = library.items
        let original = try Data(contentsOf: storage)
        // A symlink destination is refused before atomic replacement.
        let other = root.appendingPathComponent("other.json")
        try original.write(to: other)
        try FileManager.default.removeItem(at: storage)
        try FileManager.default.createSymbolicLink(at: storage, withDestinationURL: other)
        do {
            try await library.move(
                wallpaperID: items[0].id, relativeTo: items[4].id,
                placement: .before)
            XCTFail("Unsafe persistence accepted")
        } catch {}
        XCTAssertEqual(library.items, before)
        XCTAssertEqual(try Data(contentsOf: other), original)
        try FileManager.default.removeItem(at: storage)
        try save(items)
        let snapshot = try XCTUnwrap(LibraryMutationBarrier.shared.trySnapshot())
        do {
            try await library.move(
                wallpaperID: items[0].id, relativeTo: items[4].id,
                placement: .before)
            XCTFail("Snapshot mutation accepted")
        } catch {}
        withExtendedLifetime(snapshot) {}
        let job = try maintenance.reserve(.restore)
        defer { job.finish() }
        try maintenance.freeze()
        do {
            try await library.move(
                wallpaperID: items[0].id, relativeTo: items[4].id,
                placement: .before)
            XCTFail("Frozen mutation accepted")
        } catch {}
        XCTAssertEqual(library.items, before)
    }
    func testImportCommitPublicationGapAndQueuedMoves() async throws {
        let pause = MovePublicationPause()
        let library = Library(
            maintenance: MaintenanceCoordinator(),
            beforeLibraryPublication: { if $0 == "import" { await pause.pause() } },
            storage: storage, defaults: defaults, restoreOnLaunch: false)
        let image = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = root.appendingPathComponent("import.png")
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
        library.importURLs([url, url])
        for _ in 0..<10000 where !pause.reached { await Task.yield() }
        XCTAssertTrue(pause.reached)
        let store = ManagedWallpaperStore(storage: storage)
        XCTAssertEqual(try store.load().count, items.count + 1)
        XCTAssertEqual(library.items.count, items.count)
        var completed = false
        let move = Task {
            try await library.move(
                wallpaperID: items[0].id, relativeTo: items[4].id,
                placement: .before)
            completed = true
        }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(completed)
        // Only the first import pauses. Subsequent batch entries proceed normally.
        pause.resume()
        for _ in 0..<10000 where library.importing {
            if pause.continuation != nil { pause.resume() }
            await Task.yield()
        }
        try await move.value
        XCTAssertFalse(library.importing)
        XCTAssertEqual(library.items.count, items.count + 2)
        XCTAssertEqual(Set(library.items.map(\.id)).count, library.items.count)
        XCTAssertEqual(library.items, try store.load())
        async let first: Void = library.move(
            wallpaperID: items[1].id,
            relativeTo: items[3].id, placement: .before)
        async let second: Void = library.move(
            wallpaperID: items[2].id,
            relativeTo: items[4].id, placement: .after)
        _ = try await (first, second)
        XCTAssertEqual(library.items, try store.load())
    }
    func testPersistenceFaultDoesNotPublishAndRetryWorks() async throws {
        var fail = true
        var writes = 0
        let library = Library(
            maintenance: MaintenanceCoordinator(),
            beforeMovePersistence: {
                writes += 1
                if fail { throw CocoaError(.fileWriteOutOfSpace) }
            }, storage: storage, defaults: defaults, restoreOnLaunch: false)
        let before = try Data(contentsOf: storage)
        do {
            try await library.move(
                wallpaperID: items[0].id, relativeTo: items[4].id,
                placement: .before)
            XCTFail("Write fault ignored")
        } catch {}
        XCTAssertEqual(library.items, items)
        XCTAssertEqual(try Data(contentsOf: storage), before)
        fail = false
        try await library.move(
            wallpaperID: items[0].id, relativeTo: items[4].id,
            placement: .before)
        try await library.move(
            wallpaperID: items[0].id, relativeTo: items[4].id,
            placement: .before)
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(library.items, try ManagedWallpaperStore(storage: storage).load())
    }

    func testSaveAsCommitPublicationGapPreservesPlaylist() async throws {
        let helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
        defer { try? helper.helper.tearDownWithError() }
        let a = helper.item!
        let storage = helper.helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([a] + items).write(to: storage)
        let pause = MovePublicationPause()
        let reached = expectation(description: "Save As persisted before publication")
        pause.onReach = { reached.fulfill() }
        let library = Library(
            maintenance: MaintenanceCoordinator(),
            beforeLibraryPublication: { if $0 == "saveWSSAs" { await pause.pause() } },
            storage: storage, defaults: defaults, restoreOnLaunch: false)
        let playlistURL = root.appendingPathComponent("playlists.json")
        let playlist = WallpaperPlaylist(
            library: library, storage: playlistURL,
            defaults: defaults, restoreOnLaunch: false)
        let id = try playlist.createPlaylist(name: "Unchanged")
        try playlist.add(a.id, to: id)
        try playlist.add(items[0].id, to: id)
        let playlistBytes = try Data(contentsOf: playlistURL)
        let doc = helper.document()
        defer { doc.close() }
        let snapshot = try WSSSaveAsSnapshot(
            document: doc.state.workingModel,
            state: doc.state, source: doc.project.handle, name: "Copy")
        let copy = Task { try await library.saveWSSAs(snapshot, preview: { _ in true }) }
        await fulfillment(of: [reached], timeout: 15)
        XCTAssertTrue(pause.reached)
        let store = ManagedWallpaperStore(storage: storage)
        XCTAssertEqual(try store.load().count, library.items.count + 1)
        var moved = false
        let move = Task {
            try await library.move(
                wallpaperID: a.id, relativeTo: items[4].id,
                placement: .before)
            moved = true
        }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(moved)
        pause.resume()
        _ = try await copy.value
        try await move.value
        XCTAssertEqual(library.items, try store.load())
        XCTAssertEqual(Set(library.items.map(\.id)).count, library.items.count)
        XCTAssertEqual(try Data(contentsOf: playlistURL), playlistBytes)
        playlist.shutdown()
    }

    func testFirstSaveCommitPublicationGap() async throws {
        let fixture = WSSDraftTests()
        try await fixture.setUp()
        defer { try? fixture.fixture.tearDownWithError() }
        let project = try await fixture.draft()
        defer { try? project.handle.draftOwner?.discard() }
        let snapshot = try fixture.snapshot(project)
        let pause = MovePublicationPause()
        let reached = expectation(description: "First Save committed")
        pause.onReach = { reached.fulfill() }
        let library = Library(
            maintenance: MaintenanceCoordinator(),
            beforeLibraryPublication: { if $0 == "publishWSSDraft" { await pause.pause() } },
            storage: storage, defaults: defaults, restoreOnLaunch: false)
        let publish = Task { try await library.publishWSSDraft(snapshot) }
        await fulfillment(of: [reached], timeout: 15)
        let move = Task {
            try await library.move(
                wallpaperID: items[0].id, relativeTo: items[4].id,
                placement: .before)
        }
        for _ in 0..<50 { await Task.yield() }
        pause.resume()
        _ = try await publish.value
        try await move.value
        let store = ManagedWallpaperStore(storage: storage)
        XCTAssertEqual(library.items, try store.load())
        XCTAssertEqual(library.items.filter { $0.id == project.handle.id }.count, 1)
    }

    func testRenameAndRemoveAfterMovePublication() async throws {
        let pause = MovePublicationPause()
        let reached = expectation(description: "Move committed")
        pause.onReach = { reached.fulfill() }
        let library = Library(
            maintenance: MaintenanceCoordinator(),
            beforeLibraryPublication: { if $0 == "move" { await pause.pause() } },
            storage: storage, defaults: defaults, restoreOnLaunch: false)
        let move = Task {
            try await library.move(
                wallpaperID: items[0].id, relativeTo: items[4].id,
                placement: .before)
        }
        await fulfillment(of: [reached], timeout: 15)
        let rename = Task {
            try await library.rename(wallpaperID: items[1].id, newTitle: "Renamed")
        }
        for _ in 0..<50 { await Task.yield() }
        // Cancellation after persistence must not suppress the confirmed publication.
        move.cancel()
        pause.resume()
        try await move.value
        try await rename.value
        XCTAssertEqual(library.items.first { $0.id == items[1].id }?.title, "Renamed")
        library.remove(items[2])
        for _ in 0..<10000 where library.importing { await Task.yield() }
        XCTAssertFalse(library.importing)
        XCTAssertFalse(library.items.contains { $0.id == items[2].id })
        XCTAssertEqual(library.items, try ManagedWallpaperStore(storage: storage).load())
    }

    func testQueueCancellationDoesNotBlockSuccessor() async throws {
        let queue = LibraryEditQueue()
        try await queue.acquire()
        let cancelled = Task { try await queue.withEdit { XCTFail("Cancelled work ran") } }
        for _ in 0..<30 { await Task.yield() }
        cancelled.cancel()
        queue.release()
        do {
            try await cancelled.value
            XCTFail("Cancellation ignored")
        } catch is CancellationError {}
        try await queue.withEdit {}
    }
}
