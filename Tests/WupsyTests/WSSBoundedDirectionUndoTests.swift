import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSBoundedDirectionUndoTests: XCTestCase {
    var fixture: WSSVectorFieldEditingTests!
    var doc: WSSEditorDocument { fixture.doc }
    override func setUp() async throws {
        fixture = WSSVectorFieldEditingTests()
        try await fixture.setUp()
        _ = try fixture.select()
    }
    override func tearDown() async throws {
        try await fixture.tearDown()
        fixture = nil
    }
    func bytes(_ index: Int) throws -> Data {
        var data = try fixture.sourceField().vectors
        let value = UInt16(0x3000 + index)
        data[0] = UInt8(truncatingIfNeeded: value)
        data[1] = UInt8(truncatingIfNeeded: value >> 8)
        return data
    }
    func change(_ index: Int, checkpoint: WSSManifestWriter.Checkpoint? = nil) async throws {
        let edit = try await fixture.edit()
        let changed = try await doc.replaceVectorField(
            edit, vectors: bytes(index), generationCheckpoint: checkpoint)
        XCTAssertTrue(changed)
        await doc.waitForPreview()
        await doc.directionCanvas.waitForLoad()
    }
    func assertValue(_ index: Int) async throws {
        let edit = try await fixture.edit()
        XCTAssertEqual(edit.field.vectors, try bytes(index))
    }
    func test99Then100Then101Then250ChangesKeepLast100ExactStates() async throws {
        for index in 1...250 {
            try await change(index)
            if [99, 100, 101, 250].contains(index) {
                XCTAssertEqual(doc.directionUndoHistory.undoDepth, min(index, 100))
                XCTAssertTrue(doc.undoManager.canUndo)
                XCTAssertFalse(doc.undoManager.canRedo)
                XCTAssertLessThanOrEqual(doc.state.sessionAssets.count, 101)
                print(
                    "BOUNDED FLOW", index, "undo", doc.directionUndoHistory.undoDepth,
                    "bytes",
                    doc.state.sessionAssets.values.reduce(0) { $0 + $1.fingerprint.byteCount })
            }
        }
        for value in (150..<250).reversed() {
            doc.undoManager.undo()
            try await assertValue(value)
        }
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertTrue(doc.undoManager.canRedo)
        for value in 151...250 {
            doc.undoManager.redo()
            try await assertValue(value)
        }
        XCTAssertTrue(doc.undoManager.canUndo)
        XCTAssertFalse(doc.undoManager.canRedo)
        XCTAssertEqual(doc.directionUndoHistory.undoDepth, 100)
        // Only the current state and the 100 retained predecessor states remain.
        XCTAssertEqual(doc.state.sessionAssets.count, 101)
    }
    func testFailed101stAndRepeatedFailuresPreserveAll100StepsAndRedo() async throws {
        for index in 1...100 { try await change(index) }
        let model = doc.state.workingModel
        let paths = Set(doc.state.sessionAssets.keys)
        for _ in 0..<3 {
            do {
                try await change(
                    101,
                    checkpoint: { stage in
                        if stage == .assetFlush { throw WSSImageImportError.storage }
                    })
                XCTFail("Expected write failure")
            } catch { XCTAssertEqual(error as? WSSImageImportError, .storage) }
            XCTAssertEqual(doc.state.workingModel, model)
            XCTAssertEqual(doc.directionUndoHistory.undoDepth, 100)
            XCTAssertEqual(Set(doc.state.sessionAssets.keys), paths)
            XCTAssertFalse(doc.vectorFieldMutationInProgress)
        }
        doc.undoManager.undo()
        try await assertValue(99)
        XCTAssertTrue(doc.undoManager.canRedo)
        do {
            try await change(
                101,
                checkpoint: { stage in
                    if stage == .assetPartialWrite { throw WSSImageImportError.storage }
                })
            XCTFail("Expected write failure")
        } catch {}
        XCTAssertTrue(doc.undoManager.canRedo)
        doc.undoManager.redo()
        try await assertValue(100)
        try await change(101)
        XCTAssertEqual(doc.directionUndoHistory.undoDepth, 100)
        for value in (1..<101).reversed() {
            doc.undoManager.undo()
            try await assertValue(value)
        }
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testNewBranchReusesResourcesAndTrimmingPreservesChronologicalSuffix() async throws {
        // A parameter snapshot older than the cut must not resurrect skipped fields.
        try doc.setParameter(.flowSpeed, at: XCTUnwrap(doc.effectAddress), value: 41)
        for index in 1...105 { try await change(index) }
        // A recent parameter action remains in the retained suffix.
        try doc.setParameter(.flowSpeed, at: XCTUnwrap(doc.effectAddress), value: 42)
        doc.undoManager.undo()
        for _ in 0..<10 { doc.undoManager.undo() }
        try await assertValue(95)
        await doc.waitForPreview()
        await doc.directionCanvas.waitForLoad()
        try await change(96)  // Reuses a resource from the departing Redo branch.
        XCTAssertFalse(doc.undoManager.canRedo)
        try await assertValue(96)
        doc.undoManager.undo()
        try await assertValue(95)
        doc.undoManager.redo()
        try await assertValue(96)
        while doc.undoManager.canUndo { doc.undoManager.undo() }
        // The old parameter action is gone with the prefix, not left as a route
        // to the original field. The earliest retained field is state five.
        try await assertValue(5)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testOtherUndoManagerAndRecentParameterActionAreUnaffected() async throws {
        let other = UndoManager()
        let target = NSObject()
        var called = false
        other.registerUndo(withTarget: target) { _ in called = true }
        for index in 1...105 { try await change(index) }
        let address = try XCTUnwrap(doc.effectAddress)
        try doc.setParameter(.flowSpeed, at: address, value: 41)
        try await change(106)
        doc.undoManager.undo()
        try await assertValue(105)
        doc.undoManager.undo()  // Only the parameter changes; field stays exact.
        try await assertValue(105)
        XCTAssertTrue(other.canUndo)
        other.undo()
        XCTAssertTrue(called)
    }
    func test100AlternatingCanvasPaintEraseActionsShareResourcesAndSurviveCap() async throws {
        let canvas = WSSDirectionCanvasTests()
        try await canvas.setUp()
        var states: [Data] = []
        for index in 0..<110 {
            try await canvas.draw(neutralize: index % 2 == 1)
            XCTAssertNil(canvas.session.error)
            states.append(try await canvas.helper.edit().field.encodedNative())
        }
        XCTAssertEqual(canvas.doc.directionUndoHistory.undoDepth, 100)
        // Soft brush edges can produce several distinct intermediate states.
        // Compare content, not an assumed two-state paint/erase cycle.
        let required = Set(states.suffix(101))
        let retained = try Set(canvas.doc.state.sessionAssets.values.map { try $0.read() })
        XCTAssertEqual(retained, required)
        XCTAssertLessThan(retained.count, 101)
        let final = try await canvas.helper.edit()
        for _ in 0..<100 { canvas.doc.undoManager.undo() }
        XCTAssertFalse(canvas.doc.undoManager.canUndo)
        for _ in 0..<100 { canvas.doc.undoManager.redo() }
        XCTAssertFalse(canvas.doc.undoManager.canRedo)
        let redone = try await canvas.helper.edit()
        XCTAssertEqual(final.field.vectors, redone.field.vectors)
        XCTAssertEqual(final.region, redone.region)
        try await canvas.tearDown()
    }
    func testSaveAndReopenAfterTrimmingKeepsCurrentBytes() async throws {
        for index in 1...102 { try await change(index) }
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(doc.directionUndoHistory.undoDepth, 100)
        doc.close()
        fixture.helper.project = try await WSSEditorProjectLoader().load(fixture.helper.item)
        fixture.doc = fixture.makeDocument()
        _ = try fixture.select()
        try await assertValue(102)
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertFalse(doc.undoManager.canRedo)
        XCTAssertEqual(doc.directionUndoHistory.undoDepth, 0)
        try await change(103)
        doc.undoManager.undo()
        try await assertValue(102)
    }
}
