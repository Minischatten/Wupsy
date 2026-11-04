import Combine
import XCTest

@testable import Wupsy

@MainActor final class WSSEditorSnapshotConsistencyTests: XCTestCase {
    var helper: WSSEditorWorkspaceTests!
    override func setUp() async throws {
        helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
    }
    override func tearDown() async throws { try await helper.tearDown() }

    func assertConsistent(_ snapshot: WSSEditorDocument.Snapshot) {
        XCTAssertEqual(snapshot.state.workingModel.layers.count, snapshot.identity.layers.count)
        for (index, layer) in snapshot.state.workingModel.layers.enumerated() {
            if case .image(let image) = layer.content {
                XCTAssertEqual(image.effects.count, snapshot.identity.layers[index].effects.count)
            }
        }
        if case .effect(let layer, let effect) = snapshot.selection {
            XCTAssertNotNil(
                snapshot.identity.checkedAddress(
                    in: snapshot.state.workingModel, layer: layer, effect: effect))
        }
    }
    func testEmptyLayerAddWithLiveSelectionObserverRippleAndClouds() async throws {
        for kind in WSSAddableEffect.allCases {
            let doc = helper.document()
            defer { doc.close() }
            let session = doc.maskCanvas
            let layer = doc.identity.layers[1].id
            doc.select(.layer(layer))
            var refreshes = 0
            session.onChange = {
                refreshes += 1
                self.assertConsistent(doc.snapshot)
                if kind == .clouds, doc.effectAddress != nil {
                    XCTAssertEqual(doc.selectedMaskTarget?.slot, .clouds)
                    if let target = doc.selectedMaskTarget {
                        do {
                            _ = try doc.resolveMaskTarget(target)
                        } catch {
                            XCTFail("Published Clouds mask must resolve: \(error)")
                        }
                    }
                } else {
                    XCTAssertNil(doc.selectedMaskTarget)
                }
                _ = doc.selectedInspection
                _ = doc.structureRows
            }
            let observation = doc.objectWillChange.sink { self.assertConsistent(doc.snapshot) }
            let publications = doc.$snapshot.sink { self.assertConsistent($0) }
            defer {
                observation.cancel()
                publications.cancel()
                session.onChange = nil
            }
            try doc.addEffect(kind)
            XCTAssertGreaterThan(refreshes, 0)
            XCTAssertEqual(doc.selection, .effect(layer, doc.identity.layers[1].effects[0]))
            if kind == .clouds {
                XCTAssertEqual(doc.selectedMaskTarget?.slot, .clouds)
            } else {
                XCTAssertNil(doc.selectedMaskTarget)
            }
            XCTAssertNil(session.loaded)
            doc.undoManager.undo()
            XCTAssertEqual(doc.selection, .layer(layer))
            doc.undoManager.redo()
            XCTAssertNotNil(doc.effectAddress)
            try doc.deleteSelection()
            doc.undoManager.undo()
            doc.undoManager.redo()
            doc.undoManager.undo()
            doc.revert()
            XCTAssertEqual(doc.selection, .layer(layer))
            doc.undoManager.undo()
            await doc.waitForPreview()
            assertConsistent(doc.snapshot)
        }
    }
    func testMaskedRippleThenUnmaskedSecondRippleNeverInheritsMask() async throws {
        let masks = WSSMaskEditingTests()
        try await masks.setUp()
        defer {
            masks.doc.close()
            try? masks.helper.helper.tearDownWithError()
        }
        let doc = masks.doc!
        let session = doc.maskCanvas
        let target = try masks.target()
        await session.waitForLoad()
        XCTAssertEqual(session.loaded?.resolved.target, target)
        // Keep A with M0 and remove B before appending a fresh unmasked B.
        let layer = doc.identity.layers[0]
        doc.select(.effect(layer.id, layer.effects[1]))
        try doc.deleteSelection()
        doc.select(.effect(layer.id, layer.effects[0]))
        await session.waitForLoad()
        XCTAssertNotNil(doc.selectedMaskTarget)
        try doc.addEffect(.ripple)
        let newSelection = doc.selection
        XCTAssertNil(doc.selectedMaskTarget)
        XCTAssertNil(session.loaded)
        try doc.deleteSelection()
        XCTAssertEqual(doc.selectedMaskTarget, target)
        doc.undoManager.undo()
        XCTAssertEqual(doc.selection, newSelection)
        XCTAssertNil(doc.selectedMaskTarget)
        XCTAssertNil(session.loaded)
        doc.undoManager.redo()
        await session.waitForLoad()
        XCTAssertEqual(session.loaded?.resolved.target, target)
        try await masks.paint()
        doc.undoManager.undo()
        doc.undoManager.redo()
        XCTAssertNotNil(doc.selectedMaskTarget)
    }
    func testMaskResolutionFailsClosedForMalformedIdentityShapes() throws {
        let doc = helper.document()
        defer { doc.close() }
        let layer = doc.identity.layers[0]
        let selection = WSSEditorSelection.effect(layer.id, layer.effects[0])
        XCTAssertNotNil(
            WSSEditorDocument.Snapshot(
                state: doc.state, identity: doc.identity,
                selection: selection
            ).selectedMaskTarget)
        var shorter = doc.identity
        shorter.layers[0].effects.removeAll()
        var longer = doc.identity
        let outOfBounds = WSSEffectID()
        longer.layers[0].effects.append(outOfBounds)
        var missingLayer = doc.identity
        missingLayer.layers.removeFirst()
        for (identity, selection) in [
            (doc.identity, WSSEditorSelection.effect(layer.id, WSSEffectID())),
            (shorter, selection), (longer, selection),
            (longer, .effect(layer.id, outOfBounds)), (missingLayer, selection),
            (doc.identity, .effect(WSSLayerID(), layer.effects[0])),
        ] {
            let snapshot = WSSEditorDocument.Snapshot(
                state: doc.state, identity: identity,
                selection: selection)
            XCTAssertNil(snapshot.selectedMaskTarget)
        }
    }
}
