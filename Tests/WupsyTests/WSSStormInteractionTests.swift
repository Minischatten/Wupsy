import AppKit
import XCTest
import simd

@testable import Wupsy

@MainActor final class WSSStormInteractionTests: XCTestCase {
    var helper: WSSMaskEditingTests!
    var doc: WSSEditorDocument { helper.doc }
    var id: WSSLayerID!
    override func setUp() async throws {
        helper = WSSMaskEditingTests()
        try await helper.setUp()
        try doc.addStorm()
        id = try XCTUnwrap(doc.selection?.layer)
        doc.undoManager.removeAllActions()
    }
    override func tearDown() async throws { try await helper.tearDown() }
    func configuration() throws -> WSSStormConfiguration { try XCTUnwrap(doc.stormLayer(id)).storm }
    func proxy() throws -> WSSSceneDocumentV1.Transform {
        WSSStormCanvas.transform(try configuration())
    }
    func point(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, accuracy: Float = 0.002,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }
    func testStableRegionAndCoordinateConversionsAcrossZoomAndAngles() throws {
        var c = try configuration()
        for direction in [0.0, 90, 180, 270, 359.9] {
            c.direction = direction
            let t = WSSStormCanvas.transform(c)
            let native = try t.native()
            // The proxy center lies along the downward bolt; top is +0.5.
            point(native.point(SIMD2(0, 0.5)), SIMD2(Float(c.x), Float(c.y)))
            for zoom: CGFloat in [0.1, 1, 4] {
                let origin = CGPoint(x: -100, y: 50)
                let view = WSSCanvasGeometry.viewportPoint(
                    native.center, origin: origin, zoom: zoom, height: 1080)
                point(
                    WSSCanvasGeometry.scenePoint(view, origin: origin, zoom: zoom, height: 1080),
                    native.center)
            }
            var other = c
            other.seed = .max
            other.red = 0.1
            other.interval = 100
            XCTAssertEqual(WSSStormCanvas.transform(other), t)
        }
    }
    func testSelectedStormFrameHitThroughForegroundAndSurfaceOutline() throws {
        XCTAssertEqual(doc.transformModeLayer, id)
        try doc.moveLayer(id, to: 0)  // Opaque images may visually cover the bolt.
        doc.select(.layer(id))
        let native = try proxy().native()
        let view = WSSCanvasGeometry.viewportPoint(
            native.center, origin: .zero, zoom: 2, height: 64)
        XCTAssertEqual(
            WSSCanvasInteractionGeometry.hit(
                point: view, scene: doc.workingScene, identity: doc.identity, selected: id,
                origin: .zero, zoom: 2), .image(id))
        let handles = WSSCanvasInteractionGeometry.handles(
            transform: native, origin: .zero, zoom: 2, height: 64)
        XCTAssertEqual(
            WSSCanvasInteractionGeometry.hit(
                point: handles[4], scene: doc.workingScene, identity: doc.identity, selected: id,
                origin: .zero, zoom: 2), .rotation(id))
        let canvas = WSSCanvasScrollView(document: doc)
        defer { canvas.shutdown() }
        canvas.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        canvas.update(doc, zoom: 1)
        XCTAssertTrue(canvas.surface.showsTransformHandles)
        try doc.setVisibility(false, layer: id)
        canvas.update(doc, zoom: 1)
        XCTAssertFalse(canvas.surface.showsTransformHandles)
    }
    func testMoveSingleUndoCancellationAndUnchangedPrecision() throws {
        let original = try configuration()
        let before = doc.state.workingModel
        let t = try proxy()
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .move))
        var g = WSSCanvasGesture(kind: .move, transform: t, start: .zero)
        for delta: Float in [5, 10, 15] {
            try doc.updateCanvasTransform(g.transform(at: SIMD2(delta, 7)))
        }
        doc.endCanvasTransform()
        let moved = try configuration()
        XCTAssertEqual(moved.x, original.x + 15, accuracy: 0.0001)
        XCTAssertEqual(moved.y, original.y + 7, accuracy: 0.0001)
        XCTAssertEqual(moved.length, original.length)
        XCTAssertEqual(moved.spread, original.spread)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        XCTAssertEqual(try configuration(), moved)
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .move))
        var cancel = try proxy()
        cancel.center[0] += 30
        try doc.updateCanvasTransform(cancel)
        doc.endCanvasTransform(cancel: true)
        XCTAssertEqual(try configuration(), moved)
    }
    func testRotationAndIndependentScaleReuseImageGesturesAndAnchor() throws {
        let before = try configuration()
        let t = try proxy()
        let n = try t.native()
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .rotate))
        var rotation = t
        rotation.rotation += .pi / 2
        try doc.updateCanvasTransform(rotation)
        doc.endCanvasTransform()
        let rotated = try configuration()
        XCTAssertEqual(rotated.direction, 90, accuracy: 0.001)
        point(try proxy().native().center, n.center)
        XCTAssertEqual(rotated.length, before.length)
        doc.undoManager.undo()
        let corner = WSSCanvasInteractionGeometry.corners[2]
        let anchor = n.point(-corner)
        let start = n.point(corner)
        var scale = WSSCanvasGesture(kind: .scale(2, independent: true), transform: t, start: start)
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .scale(2, independent: true)))
        let target = anchor + n.axisX * 1.3 + n.axisY * 0.8
        try doc.updateCanvasTransform(scale.transform(at: target))
        doc.endCanvasTransform()
        XCTAssertEqual(try configuration().length, before.length * 0.8, accuracy: 0.001)
        point(try proxy().native().point(-corner), anchor)
        XCTAssertEqual(try configuration().width, before.width)
        XCTAssertEqual(try configuration().glow, before.glow)
        doc.undoManager.undo()
        XCTAssertEqual(try configuration(), before)
    }
    func testProportionalScaleAndNumericEditsKeepSharedCanvasInSync() throws {
        let before = try configuration()
        let t = try proxy()
        let n = try t.native()
        let corner = WSSCanvasInteractionGeometry.corners[0]
        let start = n.point(corner)
        let anchor = n.point(-corner)
        let kind = WSSCanvasGesture.Kind.scale(0, independent: false)
        var gesture = WSSCanvasGesture(kind: kind, transform: t, start: start)
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: kind))
        try doc.updateCanvasTransform(gesture.transform(at: anchor + (start - anchor) * 1.5))
        doc.endCanvasTransform()
        XCTAssertEqual(try configuration().length, before.length * 1.5, accuracy: 0.001)
        XCTAssertEqual(try configuration().spread, (before.spread + 1) * 1.5 - 1, accuracy: 0.001)
        point(try proxy().native().point(-corner), anchor)
        try doc.setStorm(.direction, value: 271.123456789, layer: id)
        try doc.setStorm(.spread, value: 12.987654321, layer: id)
        let stored = try configuration()
        let frame = try proxy()
        XCTAssertEqual(frame.rotation, Float(stored.direction * .pi / 180))
        XCTAssertEqual(
            Double(frame.size[0] * frame.scale[0]), WSSStormCanvas.width(stored), accuracy: 0.001)
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .move))
        var moved = frame
        moved.center[0] += 10
        try doc.updateCanvasTransform(moved)
        doc.endCanvasTransform()
        XCTAssertEqual(try configuration().direction, stored.direction)
        XCTAssertEqual(try configuration().spread, stored.spread)
        XCTAssertEqual(try configuration().y, stored.y)
    }

    func testColorPickerAdapterGroupedUndoAndSaveReopen() async throws {
        let original = doc.state.workingModel
        let color = try XCTUnwrap(
            WSSTrailColorAdapter.linear(NSColor(srgbRed: 0.5, green: 0.25, blue: 0.75, alpha: 1)))
        XCTAssertEqual(color.r, 0.214041, accuracy: 0.0001)
        XCTAssertEqual(color.g, 0.050876, accuracy: 0.0001)
        doc.beginStormColorInteraction(id)
        try doc.setStormColor(.init(r: 1, g: 0, b: 0), layer: id, undo: false)
        try doc.setStormColor(color, layer: id, undo: false)
        doc.undoManager.undo()  // Native Undo must finish the active color transaction.
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        let edited = try configuration()
        XCTAssertEqual(edited.red, Double(color.r))
        XCTAssertEqual(edited.green, Double(color.g))
        XCTAssertEqual(edited.blue, Double(color.b))
        let native = try XCTUnwrap(WSSTrailColorAdapter.linear(WSSTrailColorAdapter.system(color)))
        XCTAssertEqual(native.r, color.r, accuracy: 0.00001)
        let t = try proxy()
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .move))
        var move = t
        move.center[0] += 19
        try doc.updateCanvasTransform(move)
        doc.endCanvasTransform()
        let snapshot = doc.state.workingModel
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, snapshot)
        _ = WSSStormCanvas.transform(try configuration())
        // Presenting the proxy/color never rewrites RGB.
        XCTAssertEqual(doc.state.workingModel, snapshot)
    }
}
