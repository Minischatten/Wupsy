import Combine
import XCTest

@testable import Wupsy

@MainActor final class WallpaperSizeSaveTests: XCTestCase {
    func expected(_ item: Wallpaper) throws -> Int64 {
        let root = URL(fileURLWithPath: item.root)
        let document = try WSSSceneDocumentV1.load(entry: item.url, root: root)
        return try document.referencedPaths.union(["scene.wss.json"]).reduce(Int64(0)) {
            $0 + Int64(try Data(contentsOf: root.appendingPathComponent($1)).count)
        }
    }
    func testSavedSizeAndExistingSignalAfterReplaceImageAndMaskSaves() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        let item = project.handle.wallpaper
        let storage = helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([item]).write(to: storage)
        let suite = "wallpaper-size.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = Library(storage: storage, defaults: defaults, restoreOnLaunch: false)
        let document = WSSEditorEditingTests().editor(
            project, save: { try await library.saveWSSManifest($0) })
        defer { document.close() }
        var events: [UUID] = []
        let observer = NotificationCenter.default.publisher(for: .wssPreviewCommitted).sink {
            if let id = $0.object as? UUID { events.append(id) }
        }
        defer { observer.cancel() }
        let original = try WallpaperLogicalSize.measure(item)
        let generation = try await WSSImageImporter().normalize(
            WSSImageImportTests().image(width: 20, height: 20), extension: "png")
        try await document.installImage(generation, replacing: document.identity.layers[0].id)
        XCTAssertEqual(try WallpaperLogicalSize.measure(item), original)
        XCTAssertTrue(events.isEmpty)
        let savedImage = await document.save()
        XCTAssertTrue(savedImage)
        XCTAssertEqual(events, [item.id])
        XCTAssertEqual(try WallpaperLogicalSize.measure(item), try expected(item))
        XCTAssertNotEqual(try WallpaperLogicalSize.measure(item), original)
        let imageSize = try WallpaperLogicalSize.measure(item)
        document.selection = .effect(
            document.identity.layers[0].id, document.identity.layers[0].effects[0])
        try await document.manageMask(.create)
        XCTAssertEqual(try WallpaperLogicalSize.measure(item), imageSize)
        let savedMask = await document.save()
        XCTAssertTrue(savedMask)
        XCTAssertEqual(events, [item.id, item.id])
        let after = try WallpaperLogicalSize.measure(item)
        XCTAssertEqual(after, try expected(item))
        XCTAssertNotEqual(after, imageSize)
        let details = await MediaDetails.read(item)
        XCTAssertEqual(
            details.size, ByteCountFormatter.string(fromByteCount: after, countStyle: .file))
        await document.closeAndDrainForMaintenance()
    }
    func testFirstSaveAndSaveAsHaveOwnSavedSizesAndExistingCommitSignal() async throws {
        let helper = WSSDraftTests()
        try await helper.setUp()
        defer { try? helper.fixture.tearDownWithError() }
        let storage = helper.root.appendingPathComponent("Support/library.json")
        let suite = "wallpaper-size.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = Library(storage: storage, defaults: defaults, restoreOnLaunch: false)
        let project = try await helper.draft()
        let document = WSSEditorDocument(project: project)
        defer { document.close() }
        document.publishDraft = { try await library.publishWSSDraft($0) }
        document.chooseFirstSaveName = { _ in "First saved size" }
        var events: [UUID] = []
        let observer = NotificationCenter.default.publisher(for: .wssPreviewCommitted).sink {
            if let id = $0.object as? UUID { events.append(id) }
        }
        defer { observer.cancel() }
        XCTAssertTrue(library.items.isEmpty)
        let saved = await document.save()
        XCTAssertTrue(saved)
        let a = try XCTUnwrap(library.items.first)
        XCTAssertEqual(events, [a.id])
        XCTAssertEqual(try WallpaperLogicalSize.measure(a), try expected(a))
        let snapshot = try WSSSaveAsSnapshot(
            document: document.state.workingModel,
            state: document.state, source: document.project.handle,
            name: "Copy with its own saved title")
        let copy = try await library.saveWSSAs(snapshot)
        let b = copy.project.handle.wallpaper
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.path, b.path)
        XCTAssertEqual(events, [a.id, b.id])
        XCTAssertEqual(try WallpaperLogicalSize.measure(b), try expected(b))
        XCTAssertEqual(try WallpaperLogicalSize.measure(a), try expected(a))
        let details = await MediaDetails.read(b)
        XCTAssertEqual(
            details.size,
            ByteCountFormatter.string(fromByteCount: try expected(b), countStyle: .file))
        await document.closeAndDrainForMaintenance()
    }
}
