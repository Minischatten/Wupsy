import XCTest

@testable import Wupsy

@MainActor final class WSSStormAuthoringTests: XCTestCase {
    var helper: WSSMaskEditingTests!
    var doc: WSSEditorDocument { helper.doc }
    override func setUp() async throws {
        helper = WSSMaskEditingTests()
        try await helper.setUp()
    }
    override func tearDown() async throws { try await helper.tearDown() }
    func testAddParametersRenameVisibilityReorderDeleteUndoRedo() async throws {
        let before = doc.state.workingModel
        let ids = doc.identity
        try doc.addStorm()
        let id = try XCTUnwrap(doc.selection?.layer)
        let added = doc.state.workingModel
        XCTAssertNotNil(doc.stormLayer(id))
        XCTAssertEqual(before.referencedPaths, added.referencedPaths)
        XCTAssertEqual(doc.identity.layers.last?.effects, [])
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        XCTAssertNotNil(doc.previewResources.storm)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertEqual(doc.identity, ids)
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, added)
        for (parameter, value): (WSSStormParameter, Double) in [
            (.x, 12.123456789), (.direction, 37), (.seed, Double(UInt32.max)), (.branchDepth, 3),
            (.glow, 0), (.red, 0.2), (.flashes, 3),
        ] {
            let previous = doc.state.workingModel
            try doc.setStorm(parameter, value: value, layer: id)
            XCTAssertEqual(parameter.value(try XCTUnwrap(doc.stormLayer(id)).storm), value)
            doc.undoManager.undo()
            XCTAssertEqual(doc.state.workingModel, previous)
            doc.undoManager.redo()
        }
        try doc.renameStorm(id, name: "Sky lightning")
        XCTAssertTrue(doc.structureRows.contains { $0.title.contains("Sky lightning") })
        let renamed = doc.state.workingModel
        try doc.toggleVisibility(id)
        XCTAssertFalse(try XCTUnwrap(doc.stormLayer(id)).visible)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, renamed)
        try doc.moveLayer(id, to: 0)
        XCTAssertEqual(doc.identity.layers.first?.id, id)
        doc.select(.layer(id))
        try doc.deleteSelection()
        XCTAssertNil(doc.stormLayer(id))
        doc.undoManager.undo()
        XCTAssertNotNil(doc.stormLayer(id))
        XCTAssertEqual(doc.identity.layers.first?.id, id)
        doc.undoManager.redo()
        XCTAssertNil(doc.stormLayer(id))
    }
    func testSaveReopenAndInvalidEditsAreAtomic() async throws {
        try doc.addStorm()
        let id = try XCTUnwrap(doc.selection?.layer)
        try doc.setStorm(.seed, value: Double(UInt32.max), layer: id)
        try doc.renameStorm(id, name: "Saved lightning")
        for (parameter, value): (WSSStormParameter, Double) in [
            (.branchDepth, 4), (.seed, 1.5), (.duration, .infinity), (.interval, 0.49),
        ] {
            let previous = doc.state.workingModel
            XCTAssertThrowsError(try doc.setStorm(parameter, value: value, layer: id))
            XCTAssertEqual(doc.state.workingModel, previous)
        }
        XCTAssertThrowsError(try doc.renameStorm(id, name: "\n"))
        let snapshot = doc.state.workingModel
        let paths = snapshot.referencedPaths
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(doc.isDirty)
        let reloaded = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reloaded.document, snapshot)
        XCTAssertEqual(reloaded.document.referencedPaths, paths)
        XCTAssertNotNil(reloaded.resources.storm)
        doc.undoManager.undo()
        XCTAssertTrue(doc.isDirty)
        doc.undoManager.redo()
        XCTAssertFalse(doc.isDirty)
    }
    func testInsertionOnMinimumCanvas() throws {
        var json =
            try JSONSerialization.jsonObject(with: doc.state.workingModel.encoded())
            as! [String: Any]
        json["canvas"] = ["width": 1, "height": 1]
        let tiny = try WSSSceneDocumentV1.decode(data: JSONSerialization.data(withJSONObject: json))
        try doc.mutate(tiny, name: "Synthetic minimum canvas")
        try doc.addStorm()
        let id = try XCTUnwrap(doc.selection?.layer)
        XCTAssertEqual(doc.stormLayer(id)?.storm.length, 1)
        _ = try doc.state.workingModel.encoded()
    }

    func testHiddenLayerBudgetAndStaleIdentityCannotEditOtherLayer() throws {
        for _ in 0..<8 { try doc.addStorm() }
        let last = try XCTUnwrap(doc.selection?.layer)
        try doc.setVisibility(false, layer: last)
        let before = doc.state.workingModel
        XCTAssertThrowsError(try doc.addStorm())
        XCTAssertEqual(doc.state.workingModel, before)
        try doc.setStorm(.x, value: 7, layer: WSSLayerID())
        XCTAssertEqual(doc.state.workingModel, before)
    }
}
