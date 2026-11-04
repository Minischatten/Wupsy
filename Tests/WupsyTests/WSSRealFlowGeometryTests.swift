import AppKit
import MetalKit
import XCTest

@testable import Wupsy

@MainActor final class WSSRealFlowGeometryTests: XCTestCase {
    func prepare(wallpaper7Geometry: Bool) async throws -> WSSNewFlowCanvasInputTests {
        let input = WSSNewFlowCanvasInputTests()
        try await input.setUp()
        addTeardownBlock { @MainActor in try await input.tearDown() }
        input.canvas.shutdown()
        input.controller.close()
        let width = wallpaper7Geometry ? 3840 : 4096
        let height = wallpaper7Geometry ? 1920 : 4096
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: input.doc.state.workingModel.encoded())
                as? [String: Any])
        json["canvas"] = ["width": width, "height": height]
        var layers = try XCTUnwrap(json["layers"] as? [[String: Any]])
        layers = [layers[0]]
        layers[0]["transform"] = [
            "size": [width, height], "center": [width / 2, height / 2], "scale": [1, 1],
            "rotation": 0,
        ]
        let root = input.doc.project.handle.root
        try WSSNativeSceneTests().png(
            [UInt8](repeating: 255, count: width * height * 4), width: width, height: height
        ).write(to: root.appendingPathComponent("assets/base.png"))
        if wallpaper7Geometry {
            // Independent synthetic pixels; only sizes/padding mirror the read-only metadata.
            var foreground = layers[0]
            foreground["image"] = [
                "asset": "assets/padded.rgba8", "encoding": "rgba8", "width": 4096, "height": 4096,
                "filter": "linear", "edge": "clamp", "mipmapped": false,
                "uvScale": [0.9375, 0.52734375],
            ]
            foreground["transform"] = [
                "size": [3840, 2160], "center": [1846.158, 738.332], "scale": [1.15, 0.85],
                "rotation": 0.17,
            ]
            foreground["composition"] = "sourceOver"
            layers.append(foreground)
            try Data(repeating: 255, count: 4096 * 4096 * 4).write(
                to: root.appendingPathComponent("assets/padded.rgba8"))
        }
        json["layers"] = layers
        let model = try JSONDecoder().decode(
            WSSSceneDocumentV1.self, from: JSONSerialization.data(withJSONObject: json))
        try await input.fixture.fixture.reload(model)
        input.doc.select(.layer(input.doc.identity.layers[wallpaper7Geometry ? 1 : 0].id))
        try input.mountEditor()
        try input.doc.addEffect(.flow)
        await input.doc.directionCanvas.waitForLoad()
        await input.doc.waitForPreview()
        if wallpaper7Geometry {
            XCTAssertTrue(input.canvas.performZoom(.actualSize))
            for _ in 0..<3 { XCTAssertTrue(input.canvas.performZoom(.zoomOut)) }
            let clip = input.canvas.contentView
            clip.scroll(
                to: clip.constrainBoundsRect(
                    CGRect(origin: CGPoint(x: 240, y: 80), size: clip.bounds.size)
                ).origin)
        }
        input.controller.window?.contentView?.layoutSubtreeIfNeeded()
        return input
    }
    func metal(_ input: WSSNewFlowCanvasInputTests) throws -> MTKView {
        try XCTUnwrap(input.canvas.surface.subviews.compactMap { $0 as? MTKView }.first)
    }
    func point(_ input: WSSNewFlowCanvasInputTests, x: CGFloat, y: CGFloat) throws -> CGPoint {
        let rect = try metal(input).frame.intersection(input.canvas.surface.visibleRect)
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThan(rect.height, 0)
        return CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }
    func event(
        _ input: WSSNewFlowCanvasInputTests, _ type: NSEvent.EventType, _ point: CGPoint,
        option: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: input.canvas.surface.convert(point, to: nil),
                modifierFlags: option ? .option : [], timestamp: 0,
                windowNumber: input.controller.window!.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1))
    }
    func down(_ input: WSSNewFlowCanvasInputTests, _ point: CGPoint, option: Bool = false) throws {
        let e = try event(input, .leftMouseDown, point, option: option)
        let root = try XCTUnwrap(input.controller.window?.contentView)
        let parent = try XCTUnwrap(root.superview)
        let hit = try XCTUnwrap(root.hitTest(parent.convert(e.locationInWindow, from: nil)))
        XCTAssertTrue(hit === input.canvas.surface)
        hit.mouseDown(with: e)
        XCTAssertTrue(input.doc.directionCanvas.isDrawing)
    }
    // Independent Double inverse, starting at an actual laid-out view point.
    // No geometry.scene()/viewPoint() inverse roundtrip is used to generate input.
    func expectedUV(_ input: WSSNewFlowCanvasInputTests, _ point: CGPoint) throws -> SIMD2<Double> {
        let rect = try metal(input).frame
        let model = input.doc.state.workingModel
        let scene = SIMD2(
            Double((point.x - rect.minX) / rect.width) * Double(model.canvas.width),
            (1 - Double((point.y - rect.minY) / rect.height)) * Double(model.canvas.height))
        let transform = try XCTUnwrap(model.layers[input.doc.selectedLayer].imageTransform)
        let delta = scene - SIMD2(Double(transform.center[0]), Double(transform.center[1]))
        let angle = Double(transform.rotation)
        let x =
            (cos(angle) * delta.x + sin(angle) * delta.y)
            / (Double(transform.size[0]) * Double(transform.scale[0]))
        let y =
            (-sin(angle) * delta.x + cos(angle) * delta.y)
            / (Double(transform.size[1]) * Double(transform.scale[1]))
        return SIMD2(x + 0.5, 0.5 - y)
    }
    func pixel(_ region: WSSFlowRegion, _ uv: SIMD2<Double>) -> UInt8 {
        region.pixels[
            Int(uv.y * Double(region.height)) * region.width + Int(uv.x * Double(region.width))]
    }
    func exercise(_ input: WSSNewFlowCanvasInputTests) async throws {
        let doc = input.doc
        let session = doc.directionCanvas
        let view = try metal(input)
        let backing = input.controller.window!.backingScaleFactor
        let rasterLimit = min(
            1, 2560 / max(view.bounds.width * backing, view.bounds.height * backing))
        XCTAssertEqual(
            view.drawableSize.width, max(1, view.bounds.width * backing) * rasterLimit,
            accuracy: 0.01)
        let a = try point(input, x: 0.35, y: 0.5)
        let b = try point(input, x: 0.65, y: 0.5)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: a.y)
        let uv = try expectedUV(input, mid)
        XCTAssertTrue((0...1).contains(uv.x) && (0...1).contains(uv.y))
        let added = doc.state.workingModel
        let identity = doc.identity
        let original = try XCTUnwrap(session.loaded)
        print(
            "REAL FLOW GEOMETRY", session.geometry!.imageSize, "field", original.field.width,
            original.field.height, "region", original.region!.width, original.region!.height,
            "textures", doc.previewResources.textureBytes, "backing", backing, "view", a, b, "uv",
            uv)
        var authoringPublishedBeforeGPU = false
        let previousChange = session.onChange
        session.onChange = {
            if session.transientState != nil, session.livePreviewAttemptCount == 0,
                session.liveResources == nil
            {
                authoringPublishedBeforeGPU = true
            }
            previousChange?()
        }
        try down(input, a)
        for p in [mid, b] {
            input.canvas.surface.mouseDragged(with: try event(input, .leftMouseDragged, p))
            XCTAssertTrue(session.isDrawing)
        }
        await session.waitForFeedback()
        XCTAssertNil(session.error, String(describing: session.feedbackFailure))
        XCTAssertNil(session.feedbackFailure)
        XCTAssertTrue(session.isDrawing)
        XCTAssertTrue(session.livePreviewBudgetLimited)
        XCTAssertTrue(authoringPublishedBeforeGPU)
        XCTAssertEqual(session.livePreviewAttemptCount, 1)
        XCTAssertNil(session.liveResources)
        let transient = try XCTUnwrap(session.transientState)
        XCTAssertEqual(pixel(try XCTUnwrap(transient.region), uv), 255)
        let sample = try XCTUnwrap(WSSDirectionSampling.samples(transient.field, at: [uv]).first)
        let t = try XCTUnwrap(added.layers[doc.selectedLayer].imageTransform)
        let local = SIMD2(
            cos(Double(t.rotation)) / Double(t.scale[0]),
            sin(Double(t.rotation)) / Double(t.scale[1]))
        let length = hypot(local.x, local.y)
        XCTAssertEqual(Double(sample.vector.x), local.x / length, accuracy: 0.01)
        XCTAssertEqual(Double(sample.vector.y), local.y / length, accuracy: 0.01)
        XCTAssertEqual(transient.field.coverage, original.field.coverage)
        // The GPU cap must still reject the optional allocation. Only editing degrades.
        XCTAssertThrowsError(
            try doc.previewResources.previewDirection(
                at: XCTUnwrap(doc.effectAddress), state: transient)
        ) { error in
            guard case WSSVectorFieldEditError.budget = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let firstFeedback = transient
        let paintPasses = session.feedbackPaintPassCount
        session.updateQueries([uv])
        await session.waitForFeedback()
        XCTAssertEqual(
            session.livePreviewAttemptCount, 1, "Known budget rejection must not retry per feedback"
        )
        XCTAssertEqual(
            session.feedbackPaintPassCount, paintPasses,
            "Viewport queries must not replay the stroke")
        XCTAssertEqual(session.transientState?.field.vectors, firstFeedback.field.vectors)
        XCTAssertEqual(session.transientState?.region, firstFeedback.region)
        session.onChange = previousChange
        input.canvas.surface.mouseUp(with: try event(input, .leftMouseUp, b))
        await session.waitForFinish()
        await session.waitForLoad()
        await doc.waitForPreview()
        XCTAssertNil(session.error)
        XCTAssertTrue(doc.previewIsCurrent)
        XCTAssertFalse(session.isDrawing)
        XCTAssertFalse(session.finalizing)
        XCTAssertEqual(doc.identity, identity)
        let first = doc.state.workingModel
        XCTAssertNotEqual(first, added)
        doc.undoManager.undo()
        await session.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, added)
        doc.undoManager.redo()
        await session.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, first)
        // A second actual view-space stroke must work too.
        let c = try point(input, x: 0.35, y: 0.7)
        let d = try point(input, x: 0.65, y: 0.7)
        try down(input, c)
        input.canvas.surface.mouseDragged(with: try event(input, .leftMouseDragged, d))
        input.canvas.surface.mouseUp(with: try event(input, .leftMouseUp, d))
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertNil(session.error)
        let second = doc.state.workingModel
        XCTAssertNotEqual(second, first)
        try down(input, a, option: true)
        input.canvas.surface.mouseDragged(
            with: try event(input, .leftMouseDragged, b, option: true))
        input.canvas.surface.mouseUp(with: try event(input, .leftMouseUp, b, option: true))
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertNil(session.error)
        XCTAssertEqual(pixel(try XCTUnwrap(session.loaded?.region), uv), 0)
        XCTAssertEqual(
            WSSDirectionSampling.samples(try XCTUnwrap(session.loaded?.field), at: [uv]).first?
                .vector, .zero)
        doc.undoManager.undo()
        await session.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, second)
        doc.undoManager.redo()
        await session.waitForLoad()
        XCTAssertEqual(pixel(try XCTUnwrap(session.loaded?.region), uv), 0)
        // Truly invalid native input still cancels safely, without publishing anything.
        let beforeInvalid = doc.state.workingModel
        let assets = doc.state.sessionAssets.count
        try down(input, a)
        input.canvas.surface.mouseDragged(
            with: try event(input, .leftMouseDragged, CGPoint(x: CGFloat.nan, y: CGFloat.nan)))
        XCTAssertFalse(session.isDrawing)
        XCTAssertNotNil(session.error)
        await session.waitForFeedback()
        XCTAssertEqual(doc.state.workingModel, beforeInvalid)
        XCTAssertEqual(doc.state.sessionAssets.count, assets)
    }
    func testLargeIdentityImageUsesOverlayWhenOptionalGPUPreviewIsOverBudget() async throws {
        try await exercise(prepare(wallpaper7Geometry: false))
    }
    func testWallpaper7SizedAssetsWithOffsetScaleRotationZoomPanAndNativeBacking() async throws {
        try await exercise(prepare(wallpaper7Geometry: true))
    }
}
