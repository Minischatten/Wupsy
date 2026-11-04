import AppKit
import MetalKit
import XCTest

@testable import Wupsy

@MainActor final class WSSEditorLivePreviewTests: XCTestCase {
    var helper: WSSEditorProjectTests!
    override func setUp() async throws {
        helper = WSSEditorProjectTests()
        try helper.setUpWithError()
    }
    override func tearDown() async throws { try helper.tearDownWithError() }
    func project(_ name: String) async throws -> WSSLoadedEditorProject {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let target = helper.root.appendingPathComponent("Wallpapers/WSS/" + name)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: repo.appendingPathComponent("Test-Wallpaper/" + name), to: target)
        let item = Wallpaper(
            title: name, path: target.appendingPathComponent("scene.wss.json").path,
            root: target.path, kind: .scene,
            managed: .init(directory: "WSS/" + name, entry: "scene.wss.json"),
            sceneSource: .nativeWSS)
        return try await WSSEditorProjectLoader().load(item)
    }
    func testNativeAndEditorPreparationPreserveEverySupportedLayerAndChain() async throws {
        for name in [
            "WSS-Flow-v1", "WSS-Flow-Ripple-v1",
            "WSS-Ripple-Chain-v1", "WSS-Ripple-v1",
            "WSS-Clouds-v2", "WSS-Rain-v1",
        ] {
            let loaded = try await project(name)
            let desktop = try await WSSStaticPreparation.shared.prepare(loaded.handle.wallpaper)
            let preview = try await WSSEditorPreviewPreparation().prepare(
                loaded.document, basis: loaded.diskBasis, handle: loaded.handle)
            XCTAssertEqual(preview.scene.layers.count, desktop.scene.layers.count, name)
            XCTAssertEqual(
                preview.scene.imageLayers.map(\.effects), desktop.scene.imageLayers.map(\.effects),
                name)
            XCTAssertEqual(
                preview.scene.imageLayers.map(\.effects), loaded.scene.imageLayers.map(\.effects),
                name)
            XCTAssertEqual(preview.scene.isAnimated, desktop.scene.isAnimated, name)
            XCTAssertEqual(preview.flow != nil, desktop.flow != nil, name)
            XCTAssertEqual(preview.ripple != nil, desktop.ripple != nil, name)
            XCTAssertEqual(preview.rain != nil, desktop.rain != nil, name)
            let doc = WSSEditorDocument(project: loaded)
            defer { doc.close() }
            for row in doc.structureRows {
                doc.select(row.id)
                XCTAssertTrue(doc.previewResources === loaded.resources, name)
                XCTAssertEqual(
                    doc.previewResources.scene.imageLayers.map(\.effects),
                    desktop.scene.imageLayers.map(\.effects), name)
                XCTAssertFalse(doc.isDirty)
            }
            let staticScene = try WSSStaticComposition.scene(doc.canvasModel)
            XCTAssertTrue(staticScene.imageLayers.allSatisfy { $0.effects.isEmpty }, name)
            XCTAssertEqual(staticScene.layers.count, loaded.scene.imageLayers.count, name)
        }
    }

    func frame(_ resources: WSSStaticResources, time: Double, width: Int) throws -> Data {
        let height = Int(
            Double(width) * Double(resources.scene.height) / Double(resources.scene.width))
        let texture = try WSSRippleChainTests().target(
            resources.device, width: width, height: height)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
        let context = WSSRippleRenderContext(device: resources.device)
        let trail = WSSTrailRenderContext()
        try resources.encode(
            command: command, descriptor: pass, size: CGSize(width: width, height: height),
            time: time, rippleContext: context, trailContext: trail, pointer: SIMD2(100, 100),
            projection: .fullCanvas)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0)
        }
        return bytes
    }
    func rms(_ a: Data, _ b: Data) -> Double {
        sqrt(
            zip(a, b).enumerated().filter { $0.offset % 4 != 3 }.reduce(0.0) {
                $0 + pow(Double($1.element.0) - Double($1.element.1), 2)
            } / Double(a.count / 4 * 3))
    }

    func testCursorTrailAndRainRemainInLivePreparationAndOutOfCanvas() async throws {
        let loaded = try await project("WSS-Rain-v1")
        var model = loaded.document
        var layer = model.layers[0]
        layer.content = .trail(WSSTrailTests().configuration(), visible: true)
        model.layers.append(layer)
        try model.encoded().write(to: loaded.handle.entry)
        let full = try await WSSEditorProjectLoader().load(loaded.handle.wallpaper)
        let preview = try await WSSEditorPreviewPreparation().prepare(
            full.document, basis: full.diskBasis, handle: full.handle)
        XCTAssertNotNil(preview.rain)
        XCTAssertNotNil(preview.trail)
        XCTAssertEqual(preview.scene.layers.count, full.scene.layers.count)
        let doc = WSSEditorDocument(project: full)
        defer { doc.close() }
        for row in doc.structureRows {
            doc.select(row.id)
            XCTAssertNotNil(doc.previewResources.rain)
            XCTAssertNotNil(doc.previewResources.trail)
            XCTAssertFalse(doc.isDirty)
        }
        XCTAssertEqual(doc.canvasModel.layers.count, full.scene.imageLayers.count)
        _ = try frame(preview, time: 0.5, width: 360)
    }
    func testVisibleWorkspaceStartsReadOnlyPreviewWithoutAnEditAndHonorsPause() async throws {
        for name in ["WSS-Flow-v1", "WSS-Ripple-v1"] {
            let loaded = try await project(name)
            let doc = WSSEditorDocument(project: loaded)
            let controller = WSSEditorWindowController(document: doc, onClose: {})
            defer {
                doc.close()
                controller.close()
            }
            let window = try XCTUnwrap(controller.window)
            controller.showWindow(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            func surface(_ view: NSView) -> WSSPreviewSurface? {
                if let result = view as? WSSPreviewSurface { return result }
                return view.subviews.lazy.compactMap { surface($0) }.first
            }
            for _ in 0..<10 { try await Task.sleep(nanoseconds: 20_000_000) }
            let preview = try XCTUnwrap(surface(try XCTUnwrap(window.contentView)))
            let player = try XCTUnwrap(preview.player)
            XCTAssertTrue(window.isVisible)
            XCTAssertTrue(player.resources.scene.isAnimated)
            let before = player.elapsed
            try await Task.sleep(nanoseconds: 40_000_000)
            XCTAssertGreaterThan(player.elapsed, before)
            XCTAssertFalse(player.view.isPaused)
            let original = doc.state.workingModel
            for row in doc.structureRows { doc.select(row.id) }
            XCTAssertEqual(doc.state.workingModel, original)
            XCTAssertFalse(doc.isDirty)
            doc.playing = false
            for _ in 0..<5 { await Task.yield() }
            let frozen = player.elapsed
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertEqual(player.elapsed, frozen)
            doc.playing = true
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertGreaterThan(player.elapsed, frozen)
            XCTAssertNil(doc.previewError)
        }
    }
    func testEditingRippleRetainsReadOnlyFlowAndNeverChangesStaticCanvas() async throws {
        let loaded = try await project("WSS-Flow-Ripple-v1")
        let doc = WSSEditorDocument(project: loaded)
        defer { doc.close() }
        let effects = doc.structureRows.filter { $0.depth == 1 }
        XCTAssertEqual(effects.count, 3)
        let layerIndex = try XCTUnwrap(
            loaded.scene.layers.firstIndex { node in
                if case .image(let image) = node { return image.effects.count == 2 }
                return false
            })
        let ids = doc.identity.layers[layerIndex]
        let original = loaded.scene.imageLayers[layerIndex].effects
        guard case .flow = original[0], case .ripple = original[1] else {
            return XCTFail("Flow -> Ripple fixture")
        }
        let canvas = doc.canvasModel
        for row in effects {
            doc.select(row.id)
            XCTAssertEqual(doc.previewResources.scene.imageLayers[layerIndex].effects, original)
            XCTAssertFalse(doc.isDirty)
        }
        doc.select(.effect(ids.id, ids.effects[1]))
        let address = try XCTUnwrap(doc.effectAddress)
        try doc.setParameter(.rippleAmplitude, at: address, value: 25)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        XCTAssertNotNil(doc.previewResources.flow)
        XCTAssertEqual(doc.previewResources.scene.imageLayers[layerIndex].effects[0], original[0])
        XCTAssertEqual(doc.previewResources.scene.imageLayers[layerIndex].effects.count, 2)
        XCTAssertNotEqual(
            doc.previewResources.scene.imageLayers[layerIndex].effects[1], original[1])
        XCTAssertEqual(doc.canvasModel, canvas)
        doc.select(.effect(ids.id, ids.effects[0]))
        XCTAssertEqual(doc.previewResources.scene.imageLayers[layerIndex].effects[0], original[0])
        doc.undoManager.undo()
        await doc.waitForPreview()
        XCTAssertEqual(doc.previewResources.scene.imageLayers[layerIndex].effects, original)
        XCTAssertFalse(doc.isDirty)
    }

    func testFlowRippleChainUsesFullWorkingStateAtPreviewSize() async throws {
        let loaded = try await project("WSS-Ripple-v1")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let flowSource = repo.appendingPathComponent("Test-Wallpaper/WSS-Flow-v1")
        let flowDocument = try WSSSceneDocumentV1.load(
            entry: flowSource.appendingPathComponent("scene.wss.json"), root: flowSource)
        guard case .image(let flowImage) = flowDocument.layers[0].content,
            case .image(var image) = loaded.document.layers[0].content
        else { return XCTFail("native fixtures") }
        try FileManager.default.copyItem(
            at: flowSource.appendingPathComponent("assets/flow.png"),
            to: loaded.handle.root.appendingPathComponent("assets/flow.png"))
        image.effects.insert(flowImage.effects[0], at: 0)
        var model = loaded.document
        model.layers[0].content = .image(image)
        try model.encoded().write(to: loaded.handle.entry)
        let full = try await WSSEditorProjectLoader().load(loaded.handle.wallpaper)
        let preview = try await WSSEditorPreviewPreparation().prepare(
            full.document, basis: full.diskBasis, handle: full.handle)
        let desktop = try await WSSStaticPreparation.shared.prepare(full.handle.wallpaper)
        XCTAssertEqual(preview.scene.imageLayers[0].effects, full.scene.imageLayers[0].effects)
        XCTAssertEqual(preview.stages(for: preview.scene.imageLayers[0]).count, 2)
        XCTAssertEqual(preview.scene.imageLayers[0].effects, desktop.scene.imageLayers[0].effects)
        let a = try frame(preview, time: 0.2, width: 360)
        let b = try frame(preview, time: 0.8, width: 360)
        XCTAssertGreaterThan(rms(a, b), 0)
        XCTAssertEqual(a, try frame(desktop, time: 0.2, width: 360))
        let doc = WSSEditorDocument(project: full)
        defer { doc.close() }
        for row in doc.structureRows {
            doc.select(row.id)
            XCTAssertEqual(
                doc.previewResources.scene.imageLayers[0].effects, image.effects.map(\.native))
            XCTAssertFalse(doc.isDirty)
        }
        XCTAssertTrue(
            doc.canvasModel.layers.allSatisfy {
                if case .image(let i) = $0.content { return i.effects.isEmpty }
                return false
            })
    }

}
