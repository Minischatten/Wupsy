import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSLibraryPreviewTests: XCTestCase {
    var helper: WSSEditorWorkspaceTests!
    var suites: [String] = []
    override func setUp() async throws {
        helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
    }
    override func tearDown() async throws {
        for suite in suites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        suites.removeAll()
        try await helper.tearDown()
    }
    func pixels(_ image: NSImage) throws -> Data {
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var result = Data(count: cg.width * cg.height * 4)
        try result.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(
                CGContext(
                    data: bytes.baseAddress, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return result
    }
    func library(_ items: [Wallpaper]) throws -> Library {
        let storage = helper.helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode(items).write(to: storage)
        let suite = "WSSPreview-" + UUID().uuidString
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        // This test never applies/starts desktop playback or writes preferences.
        return Library(storage: storage, defaults: defaults, restoreOnLaunch: false)
    }
    func thumbnail(_ loader: ImageLoader, _ item: Wallpaper) async throws -> NSImage {
        let image = await loader.thumbnail(item)
        return try XCTUnwrap(image)
    }
    func testNativePreviewUsesCommittedSceneInsteadOfOriginalPreviewJPG() async throws {
        let item = helper.item!
        let preview = URL(fileURLWithPath: item.root).appendingPathComponent("preview.jpg")
        try helper.helper.fixtures.png([0, 0, 255, 255, 0, 0, 255, 255]).write(to: preview)
        let before = try helper.helper.snapshot()
        let loader = ImageLoader()
        let actual = try await thumbnail(loader, item)
        let expected = try WSSLibraryThumbnail.render(helper.project.resources, maxPixel: 480)
        XCTAssertEqual(try pixels(actual), try pixels(expected))
        let oldImage = await loader.image(preview, maxPixel: 480)
        let old = try XCTUnwrap(oldImage)
        XCTAssertNotEqual(try pixels(actual), try pixels(old))
        XCTAssertEqual(try helper.helper.snapshot(), before)
    }
    func testSaveNWorkingNPlusOneRefreshesOnlyCommittedUUIDAndSurvivesColdLoader() async throws {
        let item = helper.item!
        let folder = try helper.helper.fixtures.fixture(name: "Wallpapers/WSS/Other")
        let other = Wallpaper(
            title: "Other", path: folder.appendingPathComponent("scene.wss.json").path,
            root: folder.path, kind: .scene,
            managed: .init(directory: "WSS/Other", entry: "scene.wss.json"), sceneSource: .nativeWSS
        )
        let library = try library([item, other])
        defer { library.stop() }
        let old = try await thumbnail(.shared, item)
        let untouched = try await thumbnail(.shared, other)
        var gate: CheckedContinuation<Void, Never>?
        let doc = WSSEditorDocument(
            project: helper.project,
            save: { snapshot in
                await withCheckedContinuation { gate = $0 }
                return try await library.saveWSSManifest(snapshot)
            })
        defer { doc.close() }
        var notifications: [UUID] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .wssPreviewCommitted, object: nil, queue: .main
        ) {
            notification in
            MainActor.assumeIsolated {
                if let id = notification.object as? UUID { notifications.append(id) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let layer = doc.identity.layers[1].id
        try doc.setImage(.centerX, value: 40, layer: layer)
        let n = doc.state.workingModel
        let saving = Task { await doc.save() }
        while gate == nil { await Task.yield() }
        try doc.setImage(.centerX, value: 96, layer: layer)
        gate?.resume()
        let success = await saving.value
        XCTAssertTrue(success)
        let disk = try await WSSEditorProjectLoader().load(item)
        XCTAssertEqual(disk.document, n)
        XCTAssertEqual(doc.state.savedModel, n)
        XCTAssertEqual(doc.state.workingModel.layers[1].imageTransform?.center[0], 96)
        XCTAssertTrue(doc.isDirty)
        let current = try await thumbnail(.shared, item)
        let expected = try WSSLibraryThumbnail.render(disk.resources, maxPixel: 480)
        XCTAssertEqual(try pixels(current), try pixels(expected))
        XCTAssertNotEqual(try pixels(current), try pixels(old))
        let cold = try await thumbnail(ImageLoader(), item)
        XCTAssertEqual(try pixels(current), try pixels(cold))
        let otherAfter = try await thumbnail(.shared, other)
        XCTAssertTrue(otherAfter === untouched)
        XCTAssertEqual(notifications, [item.id])
        XCTAssertNil(library.active)
        await doc.waitForPreview()
        let working = try WSSLibraryThumbnail.render(doc.previewResources, maxPixel: 480)
        XCTAssertNotEqual(try pixels(current), try pixels(working))
        gate = nil
        let nextSave = Task { await doc.save() }
        while gate == nil { await Task.yield() }
        gate?.resume()
        let next = await nextSave.value
        XCTAssertTrue(next)
        let nextImage = try await thumbnail(.shared, item)
        XCTAssertEqual(try pixels(nextImage), try pixels(working))
    }
    func testFailedSaveLeavesPreviewAndNotificationUntouched() async throws {
        let item = helper.item!
        let library = try library([item])
        defer { library.stop() }
        let old = try await thumbnail(.shared, item)
        let originalManifest = try Data(contentsOf: item.url)
        let doc = WSSEditorDocument(
            project: helper.project, save: { try await library.saveWSSManifest($0) })
        defer { doc.close() }
        var count = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .wssPreviewCommitted, object: nil, queue: .main
        ) { notification in
            MainActor.assumeIsolated { if notification.object as? UUID == item.id { count += 1 } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try doc.setImage(.centerX, value: 99, layer: doc.identity.layers[1].id)
        try JSONEncoder().encode([Wallpaper]()).write(
            to: helper.helper.root.appendingPathComponent("library.json"))
        let success = await doc.save()
        XCTAssertFalse(success)
        XCTAssertEqual(try Data(contentsOf: item.url), originalManifest)
        let after = try await thumbnail(.shared, item)
        XCTAssertTrue(after === old)
        XCTAssertEqual(count, 0)
    }

    func testInvalidExistingWSSNeverFallsBackToOldSourcePicture() async throws {
        let item = helper.item!
        try helper.helper.fixtures.png().write(
            to: URL(fileURLWithPath: item.root).appendingPathComponent("preview.jpg"))
        try Data("broken existing WSS".utf8).write(to: item.url)
        let before = try helper.helper.snapshot()
        let result = await ImageLoader().thumbnail(item)
        XCTAssertNil(result)
        XCTAssertEqual(try helper.helper.snapshot(), before)
    }

    func testThumbnailPreservesOpaqueNativeReplaceOutput() throws {
        var model = helper.project.document
        guard case .image(var image) = model.layers[0].content else { return XCTFail("fixture") }
        image.effects = []
        image.opacity = 0
        image.composition = "replace"
        model.layers[0].content = .image(image)
        model.layers.removeLast()
        let resources = try WSSStaticResources(
            scene: model.scene(), assets: model.assetSource(root: helper.project.handle.root),
            device: helper.project.resources.device)
        let thumbnail = try WSSLibraryThumbnail.render(resources, maxPixel: 480)
        let data = try pixels(thumbnail)
        XCTAssertTrue(stride(from: 3, to: data.count, by: 4).allSatisfy { data[$0] == 255 })
        XCTAssertTrue(data.enumerated().contains { $0.offset % 4 != 3 && $0.element > 0 })
    }

}
