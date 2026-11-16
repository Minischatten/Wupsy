import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSMilkyWayAuthoringTests: XCTestCase {
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
    func testLazyEnableNumericEditsReuseStarsUndoAndSave() async throws {
        let original = doc.state.workingModel
        let resources = doc.previewResources
        XCTAssertNil(resources.milkyWay)
        try doc.changeStarfield(id, name: "Milky Way") { $0.starfield.milkyWay.enabled = true }
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewResources.starfield === resources.starfield)
        XCTAssertNotNil(doc.previewResources.milkyWay)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        doc.undoManager.redo()
        for (p, value): (WSSMilkyWayParameter, Double) in [
            (.positionX, 0.6123456789), (.positionY, 0.4123456789), (.angle, 125.123456789),
            (.width, 0.32123456789), (.intensity, 0.6123456789), (.structure, 0.8123456789),
            (.dust, 0.5123456789), (.seed, Double(UInt32.max)),
        ] {
            let before = doc.state.workingModel
            try doc.setMilkyWay(p, value: value, layer: id)
            XCTAssertEqual(p.value(try XCTUnwrap(doc.starfieldLayer(id)).starfield.milkyWay), value)
            doc.undoManager.undo()
            XCTAssertEqual(doc.state.workingModel, before)
            doc.undoManager.redo()
        }
        let snapshot = doc.state.workingModel
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, snapshot)
        let resourcesAfter = doc.previewResources
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewResources.starfield === resourcesAfter.starfield)
    }
    func testIndependentColorPickerRolesCoalescingAndSave() async throws {
        let original = try XCTUnwrap(doc.starfieldLayer(id)).starfield
        doc.beginStarfieldColorInteraction(id, role: .milkyWay)
        try doc.setStarfieldColor(
            .init(r: 0.2, g: 0.8, b: 0.4), layer: id, role: .milkyWay, undo: false)
        try doc.setStarfieldColor(
            .init(r: 0.8, g: 0.1, b: 0.5), layer: id, role: .milkyWay, undo: false)
        doc.undoManager.undo()
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield, original)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        let milky = try XCTUnwrap(doc.starfieldLayer(id)).starfield
        XCTAssertEqual(milky.red, original.red)
        XCTAssertEqual(milky.green, original.green)
        XCTAssertEqual(milky.blue, original.blue)
        doc.beginStarfieldColorInteraction(id)
        try doc.setStarfieldColor(.init(r: 0, g: 1, b: 1), layer: id, undo: false)
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.milkyWay, milky.milkyWay)
        let snapshot = doc.state.workingModel
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertNil(doc.starfieldColorDrag)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, snapshot)
        doc.undoManager.undo()
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield, milky)
    }
    func testNumericReturnNeverReentersFieldEditor() throws {
        let input = WSSParameterTextField(
            value: 0.5, range: 0...1, title: "Position", maximumFractionDigits: 3,
            exactValue: 0.5, exactRange: 0...1,
            commitExact: { [self] in try doc.setMilkyWay(.positionX, value: $0, layer: id) },
            commit: { [self] in try doc.setMilkyWay(.positionX, value: Double($0), layer: id) })
        let coordinator = input.makeCoordinator()
        let field = NSTextField(string: "0.625")
        doc.finishInput = {
            XCTFail("Recursive field resignation")
            return false
        }
        XCTAssertTrue(
            coordinator.control(
                field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))
            ))
        XCTAssertTrue(coordinator.control(field, textShouldEndEditing: NSTextView()))
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.milkyWay.positionX, 0.625)
        doc.finishInput = nil
        doc.undoManager.undo()
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.milkyWay.positionX, 0.5)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
}
