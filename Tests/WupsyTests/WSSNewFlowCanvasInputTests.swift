import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSNewFlowCanvasInputTests: XCTestCase {
    var fixture: WSSNewVectorEffectTests!
    var doc: WSSEditorDocument { fixture.doc }
    var controller: WSSEditorWindowController!
    var canvas: WSSCanvasScrollView!
    override func setUp() async throws {
        _ = NSApplication.shared
        fixture = WSSNewVectorEffectTests()
        try await fixture.setUp()
        try mountEditor()
    }
    func mountEditor() throws {
        controller = WSSEditorWindowController(document: doc, onClose: {})
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> WSSCanvasScrollView? {
            if let canvas = view as? WSSCanvasScrollView { return canvas }
            return view.subviews.lazy.compactMap(find).first
        }
        canvas = try XCTUnwrap(find(try XCTUnwrap(window.contentView)))
        canvas.layoutSubtreeIfNeeded()
    }
    override func tearDown() async throws {
        canvas.shutdown()
        controller.close()
        controller = nil
        canvas = nil
        try await fixture.tearDown()
        fixture = nil
    }
    func event(_ type: NSEvent.EventType, uv: SIMD2<Double>, option: Bool = false) throws -> NSEvent
    {
        let geometry = try XCTUnwrap(doc.directionCanvas.geometry)
        return try fixture.fixture.event(
            type, canvas: canvas, point: geometry.scene(uv), flags: option ? .option : [])
    }
    func downAndDrag() throws {
        let down = try event(.leftMouseDown, uv: SIMD2(0.3, 0.6))
        let root = try XCTUnwrap(controller.window?.contentView)
        let parent = try XCTUnwrap(root.superview)
        let hit = try XCTUnwrap(root.hitTest(parent.convert(down.locationInWindow, from: nil)))
        XCTAssertTrue(hit === canvas.surface, "Canvas pointer intercepted by \(hit)")
        hit.mouseDown(with: down)
        XCTAssertTrue(
            doc.directionCanvas.isDrawing,
            doc.directionCanvas.error ?? "Down did not begin a stroke")
        for uv in [SIMD2<Double>(0.35, 0.6), SIMD2(0.4, 0.6), SIMD2(0.45, 0.6)] {
            canvas.surface.mouseDragged(with: try event(.leftMouseDragged, uv: uv))
            XCTAssertTrue(doc.directionCanvas.isDrawing)
            XCTAssertEqual(
                canvas.surface.maskCursor, try XCTUnwrap(doc.directionCanvas.geometry).scene(uv))
        }
        XCTAssertGreaterThan(doc.directionCanvas.pointCount, 1)
    }
    func testNewFlowNativeDragAfterLoad() async throws {
        try doc.addEffect(.flow)
        let session = doc.directionCanvas
        await session.waitForLoad()
        await doc.waitForPreview()
        XCTAssertNotNil(session.loaded)
        XCTAssertNil(session.error)
        try downAndDrag()
        await session.waitForFeedback()
        XCTAssertTrue(session.isDrawing, session.error ?? "Stroke cancelled")
        XCTAssertNotNil(session.transientState)
        canvas.surface.mouseUp(with: try event(.leftMouseUp, uv: SIMD2(0.45, 0.6)))
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertNil(session.error)
        XCTAssertTrue(try XCTUnwrap(session.loaded?.region).pixels.contains(255))
        XCTAssertFalse(try XCTUnwrap(session.loaded?.field).isNeutral)
    }
    func testNewFlowNativeFirstPressWithoutWaitingForResourceLoad() async throws {
        try doc.addEffect(.flow)
        let session = doc.directionCanvas
        XCTAssertTrue(session.brushEnabled)
        XCTAssertNil(session.loaded)
        let added = doc.state.workingModel
        let identity = doc.identity
        try downAndDrag()
        canvas.surface.mouseUp(with: try event(.leftMouseUp, uv: SIMD2(0.45, 0.6)))
        XCTAssertFalse(session.isDrawing)
        await session.waitForFinish()
        await session.waitForLoad()
        await doc.waitForPreview()
        XCTAssertNil(session.error)
        XCTAssertFalse(session.finalizing)
        XCTAssertFalse(doc.interactionLocked)
        XCTAssertTrue(try XCTUnwrap(session.loaded?.region).pixels.contains(255))
        XCTAssertFalse(try XCTUnwrap(session.loaded?.field).isNeutral)
        XCTAssertNil(session.loaded?.field.coverage)
        XCTAssertEqual(doc.identity, identity)
        let firstPaint = doc.state.workingModel
        doc.undoManager.undo()
        await session.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, added)
        XCTAssertEqual(
            doc.undoManager.undoActionName,
            EditorText.addEffectUndo.format(WSSAddableEffect.flow.title))
        doc.undoManager.redo()
        await session.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, firstPaint)
        XCTAssertEqual(doc.identity, identity)
        // A second held stroke publishes a provisional state before mouse-up.
        canvas.surface.mouseDown(with: try event(.leftMouseDown, uv: SIMD2(0.3, 0.7)))
        XCTAssertTrue(session.isDrawing)
        canvas.surface.mouseDragged(with: try event(.leftMouseDragged, uv: SIMD2(0.4, 0.7)))
        await session.waitForFeedback()
        XCTAssertTrue(session.isDrawing, session.error ?? "Second stroke cancelled")
        XCTAssertNotNil(session.transientState)
        XCTAssertNotNil(session.liveResources)
        XCTAssertTrue(try XCTUnwrap(session.transientState?.region).pixels.contains(255))
        canvas.surface.mouseUp(with: try event(.leftMouseUp, uv: SIMD2(0.45, 0.7)))
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertNil(session.error)
        XCTAssertNotEqual(doc.state.workingModel, firstPaint)
        let secondPaint = doc.state.workingModel
        let paintedRegion = try XCTUnwrap(session.loaded?.region)
        // Option/Erase removes region and zeros movement in the same native input path.
        canvas.surface.mouseDown(with: try event(.leftMouseDown, uv: SIMD2(0.3, 0.6), option: true))
        canvas.surface.mouseDragged(
            with: try event(.leftMouseDragged, uv: SIMD2(0.45, 0.6), option: true))
        canvas.surface.mouseUp(with: try event(.leftMouseUp, uv: SIMD2(0.45, 0.6), option: true))
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertNil(session.error)
        let erasedRegion = try XCTUnwrap(session.loaded?.region)
        XCTAssertLessThan(
            erasedRegion.pixels.filter { $0 == 255 }.count,
            paintedRegion.pixels.filter { $0 == 255 }.count)
        let center = try XCTUnwrap(session.loaded).field
        XCTAssertEqual(
            WSSDirectionSampling.samples(center, at: [SIMD2(0.375, 0.6)]).first?.vector, .zero)
        doc.undoManager.undo()
        await session.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, secondPaint)
        doc.undoManager.redo()
        await session.waitForLoad()
        XCTAssertEqual(session.loaded?.region, erasedRegion)
        XCTAssertFalse(session.requiresExplicitActivation)
        XCTAssertFalse(session.isDrawing)
        XCTAssertFalse(doc.hasActivePaintInteraction)
    }
    func testExistingLegacyFlowNativeDragPreservesCoverageAndDimensions() async throws {
        canvas.shutdown()
        controller.close()
        var model = doc.state.workingModel
        guard case .image(var image) = model.layers[0].content else { return XCTFail() }
        image.effects = [try fixture.fixture.helper.effect("flow", "a")]
        model.layers[0].content = .image(image)
        try await fixture.fixture.reload(model)
        _ = try fixture.fixture.helper.select(0)
        try mountEditor()
        let session = doc.directionCanvas
        await session.waitForLoad()
        let before = try XCTUnwrap(session.loaded)
        XCTAssertNil(before.region)
        let originalBytes = try Data(
            contentsOf: doc.project.handle.root.appendingPathComponent(before.resolved.path))
        try downAndDrag()
        canvas.surface.mouseUp(with: try event(.leftMouseUp, uv: SIMD2(0.45, 0.6)))
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertNil(session.error)
        let after = try XCTUnwrap(session.loaded)
        XCTAssertNil(after.region)
        XCTAssertEqual(after.field.width, before.field.width)
        XCTAssertEqual(after.field.height, before.field.height)
        XCTAssertEqual(after.field.coverage, before.field.coverage)
        XCTAssertNotEqual(after.field.vectors, before.field.vectors)
        XCTAssertEqual(
            try Data(
                contentsOf: doc.project.handle.root.appendingPathComponent(before.resolved.path)),
            originalBytes)
    }

    func testEscapeDuringPendingLoadCancelsCaptureWithoutPublishingAssets() async throws {
        try doc.addEffect(.flow)
        let session = doc.directionCanvas
        let added = doc.state.workingModel
        let assets = doc.state.sessionAssets.count
        try downAndDrag()
        // Only the capture-owned loader may read under this active input lock.
        do {
            _ = try await doc.loadVectorField(
                XCTUnwrap(doc.selectedVectorFieldTarget), finishControls: false)
            XCTFail("An unrelated read must not bypass active paint capture")
        } catch {
            guard case WSSVectorFieldEditError.stale = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(session.escape())
        await session.waitForLoad()
        await session.waitForFeedback()
        XCTAssertFalse(session.isDrawing)
        XCTAssertFalse(doc.hasActivePaintInteraction)
        XCTAssertEqual(doc.state.workingModel, added)
        XCTAssertEqual(doc.state.sessionAssets.count, assets)
        try downAndDrag()
        canvas.surface.mouseUp(with: try event(.leftMouseUp, uv: SIMD2(0.45, 0.6)))
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertNil(session.error)
        XCTAssertNotEqual(doc.state.workingModel, added)
    }

}
