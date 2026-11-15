import XCTest

@testable import Wupsy

@MainActor final class WSSStarfieldAuthoringTests: XCTestCase {
    var helper: WSSMaskEditingTests!
    var doc: WSSEditorDocument { helper.doc }
    override func setUp() async throws {
        helper = WSSMaskEditingTests()
        try await helper.setUp()
        try doc.addStarfield()
    }
    override func tearDown() async throws { try await helper.tearDown() }
    func testParametersColorTransactionsAndSaveReopen() async throws {
        let id = try XCTUnwrap(doc.selection?.layer)
        await doc.waitForPreview()
        let original = doc.state.workingModel
        let resources = doc.previewResources
        doc.undoManager.removeAllActions()
        try doc.setStarfield(.brightness, value: 1.234567891, layer: id)
        await doc.waitForPreview()
        XCTAssertTrue(resources.starfield === doc.previewResources.starfield)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        doc.undoManager.redo()
        let before = doc.state.workingModel
        doc.beginStarfieldColorInteraction(id)
        try doc.setStarfieldColor(.init(r: 0, g: 1, b: 0.5), layer: id, undo: false)
        try doc.setStarfieldColor(.init(r: 0.2, g: 0.4, b: 0.8), layer: id, undo: false)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        doc.undoManager.redo()
        let snapshot = doc.state.workingModel
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, snapshot)
        XCTAssertNil(doc.starfieldColorDrag)
        XCTAssertTrue(
            WSSStaticComposition.model(snapshot).layers.allSatisfy { $0.imageTransform != nil })
    }
    func testCanvasTranslationIndependentScalingUndoAndNoRotation() async throws {
        let id = try XCTUnwrap(doc.selection?.layer)
        let original = try XCTUnwrap(doc.starfieldLayer(id)).starfield
        let transform = original.canvasTransform
        let native = try transform.native()
        XCTAssertEqual(
            WSSCanvasInteractionGeometry.handles(
                transform: native, origin: .zero, zoom: 1, height: 64, allowsRotation: false
            ).count, 4)
        XCTAssertFalse(doc.beginCanvasTransform(id, kind: .rotate))
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .move))
        var moved = transform
        moved.center[0] += 10
        moved.center[1] += 20
        try doc.updateCanvasTransform(moved)
        doc.endCanvasTransform()
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.x, original.x + 10)
        doc.undoManager.undo()
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield, original)
        doc.undoManager.redo()
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .scale(0, independent: true)))
        moved.scale = [0.5, 0.75]
        try doc.updateCanvasTransform(moved)
        doc.endCanvasTransform()
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.width, original.width * 0.5)
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.height, original.height * 0.75)
        var rotated = transform
        rotated.rotation = 1
        XCTAssertThrowsError(try original.applying(rotated))
        try doc.setVisibility(false, layer: id)
        XCTAssertFalse(doc.canTransform(id))
        doc.undoManager.undo()
        XCTAssertTrue(doc.canTransform(id))
    }
}
