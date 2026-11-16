import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSShootingStarAuthoringTests: XCTestCase {
    var helper: WSSMaskEditingTests!
    var doc: WSSEditorDocument { helper.doc }
    var id: WSSLayerID!
    override func setUp() async throws {
        helper = WSSMaskEditingTests()
        try await helper.setUp()
        try doc.addStarfield()
        id = try XCTUnwrap(doc.selection?.layer)
        await doc.waitForPreview()
        doc.undoManager.removeAllActions()
    }
    override func tearDown() async throws {
        doc.finishInput = nil
        try await helper.tearDown()
    }
    func testParametersReusePopulationAndSaveReopenUndoRedo() async throws {
        let original = doc.state.workingModel
        let resources = doc.previewResources
        let index = try XCTUnwrap(doc.identity.layers.firstIndex { $0.id == id })
        let buffer = try XCTUnwrap(resources.starfield?.layers[index]?.buffer)
        try doc.setShootingStarsEnabled(true, layer: id)
        XCTAssertTrue(try XCTUnwrap(doc.starfieldLayer(id)).starfield.shootingStars.enabled)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        doc.undoManager.redo()
        for (parameter, value): (WSSShootingStarParameter, Double) in [
            (.frequency, 5.123456789), (.speed, 520.123456789), (.tailLength, 131.234567891),
            (.brightness, 1.632456789), (.direction, 240.75456789),
            (.directionVariation, 7.523456789),
        ] {
            let before = doc.state.workingModel
            try doc.setShootingStars(parameter, value: value, layer: id)
            XCTAssertEqual(
                parameter.value(try XCTUnwrap(doc.starfieldLayer(id)).starfield.shootingStars),
                value)
            doc.undoManager.undo()
            XCTAssertEqual(doc.state.workingModel, before)
            doc.undoManager.redo()
        }
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewResources.starfield === resources.starfield)
        XCTAssertTrue(doc.previewResources.starfield?.layers[index]?.buffer === buffer)
        let snapshot = doc.state.workingModel
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, snapshot)
        XCTAssertTrue(try reopened.document.scene().isAnimated)
        XCTAssertEqual(try reopened.document.encoded(), try snapshot.encoded())
        XCTAssertThrowsError(try doc.setShootingStars(.speed, value: .nan, layer: id))
        XCTAssertEqual(doc.state.workingModel, snapshot)
    }
    func testNumericReturnUsesCrashSafeCommitAndCompletesTransform() throws {
        let canvas = WSSCanvasScrollView(document: doc)
        defer { canvas.shutdown() }
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .scale(0, independent: true)))
        var t = try XCTUnwrap(doc.starfieldLayer(id)).starfield.canvasTransform
        t.scale = [1.5, 1.25]
        try doc.updateCanvasTransform(t)
        let input = WSSParameterTextField(
            value: 700, range: 50...3000, title: "Speed", maximumFractionDigits: 3,
            exactValue: 700, exactRange: 50...3000,
            commitExact: { [self] in try doc.setShootingStars(.speed, value: $0, layer: id) },
            commit: { [self] in try doc.setShootingStars(.speed, value: Double($0), layer: id) })
        let coordinator = input.makeCoordinator()
        let field = NSTextField(string: "900.125")
        doc.finishInput = {
            XCTFail("A parameter commit must not ask its own field to resign")
            return false
        }
        XCTAssertTrue(
            coordinator.control(
                field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))
            ))
        XCTAssertTrue(coordinator.control(field, textShouldEndEditing: NSTextView()))
        XCTAssertNil(doc.canvasTransform)
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.shootingStars.speed, 900.125)
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.width, 96)
        doc.finishInput = nil
        doc.undoManager.undo()
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.shootingStars.speed, 700)
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.width, 96)
        doc.undoManager.undo()
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.width, 64)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
}
