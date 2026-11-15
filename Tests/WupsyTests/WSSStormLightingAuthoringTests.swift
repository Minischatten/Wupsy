import XCTest

@testable import Wupsy

@MainActor final class WSSStormLightingAuthoringTests: XCTestCase {
    var helper: WSSMaskEditingTests!
    var doc: WSSEditorDocument { helper.doc }
    override func setUp() async throws {
        helper = WSSMaskEditingTests()
        try await helper.setUp()
        try doc.addStorm()
    }
    override func tearDown() async throws { try await helper.tearDown() }
    func testModesParametersPreviewReuseAndAtomicUndoRedo() async throws {
        let id = try XCTUnwrap(doc.selection?.layer)
        await doc.waitForPreview()
        let original = doc.state.workingModel
        let resources = doc.previewResources
        doc.undoManager.removeAllActions()
        try doc.setStormIlluminationEnabled(true, layer: id)
        await doc.waitForPreview()
        XCTAssertTrue(resources.sharesPreparedResources(with: doc.previewResources))
        XCTAssertNotNil(doc.previewResources.stormLighting)
        try doc.setStormBoltEnabled(false, layer: id)
        XCTAssertFalse(try XCTUnwrap(doc.stormLayer(id)).storm.boltEnabled)
        doc.undoManager.undo()
        XCTAssertTrue(try XCTUnwrap(doc.stormLayer(id)).storm.boltEnabled)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        doc.undoManager.redo()
        doc.undoManager.redo()
        for (parameter, value): (WSSStormIlluminationParameter, Double) in [
            (.intensity, 2.123456789), (.shadowLift, 0.03123456789),
        ] {
            let before = doc.state.workingModel
            try doc.setStormIllumination(parameter, value: value, layer: id)
            XCTAssertEqual(
                parameter.value(try XCTUnwrap(doc.stormLayer(id)).storm.illumination), value)
            doc.undoManager.undo()
            XCTAssertEqual(doc.state.workingModel, before)
            doc.undoManager.redo()
        }
        let before = doc.state.workingModel
        XCTAssertThrowsError(try doc.setStormIllumination(.intensity, value: 5, layer: id))
        XCTAssertThrowsError(try doc.setStormIllumination(.shadowLift, value: .nan, layer: id))
        XCTAssertEqual(doc.state.workingModel, before)
    }
    func testSeparateColorTransactionsAndSaveReopen() async throws {
        let id = try XCTUnwrap(doc.selection?.layer)
        let original = try XCTUnwrap(doc.stormLayer(id)).storm
        try doc.setStormIlluminationEnabled(true, layer: id)
        doc.undoManager.removeAllActions()
        let before = doc.state.workingModel
        doc.beginStormColorInteraction(id, role: .illumination)
        try doc.setStormColor(
            .init(r: 0.2, g: 0.4, b: 0.8), layer: id, role: .illumination, undo: false)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        doc.undoManager.redo()
        let light = try XCTUnwrap(doc.stormLayer(id)).storm
        XCTAssertEqual(light.red, original.red)
        XCTAssertEqual(light.green, original.green)
        XCTAssertEqual(light.blue, original.blue)
        XCTAssertEqual(light.illumination.red, Double(Float(0.2)))
        doc.beginStormColorInteraction(id)  // Switching picker commits the prior role first.
        try doc.setStormColor(.init(r: 1, g: 0.1, b: 0.2), layer: id, undo: false)
        let snapshot = doc.state.workingModel
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertNil(doc.stormColorDrag)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, snapshot)
        doc.undoManager.undo()
        XCTAssertEqual(try XCTUnwrap(doc.stormLayer(id)).storm, light)
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, snapshot)
    }
}
