import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSEditorEffectReorderTests: XCTestCase {
    var helper: WSSEditorWorkspaceTests!
    override func setUp() async throws {
        helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
    }
    override func tearDown() async throws { try await helper.tearDown() }
    func effects(_ doc: WSSEditorDocument) throws -> [WSSSceneDocumentV1.Effect] {
        guard case .image(let image) = doc.state.workingModel.layers[1].content else {
            throw WSSDocumentError.invalid("image")
        }
        return image.effects
    }
    func document(_ definitions: [WSSSceneDocumentV1.Effect]) throws -> WSSEditorDocument {
        // Resource identity tests use valid definitions without loading synthetic paths.
        let doc = WSSEditorDocument(
            project: helper.project, prepare: { _, _, _ in self.helper.project.resources })
        var model = doc.state.workingModel
        guard case .image(var image) = model.layers[1].content else { fatalError("fixture") }
        image.effects = definitions
        model.layers[1].content = .image(image)
        try doc.mutate(model, name: "Setup", ids: WSSEditorIdentity(model))
        doc.undoManager.removeAllActions()
        return doc
    }
    func testMovesPreserveDefinitionsIDsSelectionAndSingleUndo() throws {
        let definitions = (0..<3).map { i in
            WSSSceneDocumentV1.Effect(
                parameters: .ripple(WSSRippleEffect(amplitude: Float(i + 2))), mask: nil, field: nil
            )
        }
        for (from, to, order) in [
            (1, 0, [1, 0, 2]), (1, 2, [0, 2, 1]), (2, 0, [2, 0, 1]), (0, 2, [1, 2, 0]),
        ] {
            for selectedIndex in [from, (from + 1) % 3] {
                let doc = try document(definitions)
                defer { doc.close() }
                let before = doc.state.workingModel
                let ids = doc.identity
                let layer = ids.layers[1]
                let selected = WSSEditorSelection.effect(layer.id, layer.effects[selectedIndex])
                doc.select(selected)
                try doc.moveEffect(layer.id, effect: layer.effects[from], to: to)
                XCTAssertEqual(try effects(doc), order.map { definitions[$0] })
                XCTAssertEqual(doc.identity.layers[1].effects, order.map { layer.effects[$0] })
                XCTAssertEqual(doc.selection, selected)
                XCTAssertEqual(doc.effectAddress?.effectIndex, order.firstIndex(of: selectedIndex))
                doc.undoManager.undo()
                XCTAssertEqual(doc.state.workingModel, before)
                XCTAssertEqual(doc.identity, ids)
                XCTAssertEqual(doc.selection, selected)
                XCTAssertFalse(doc.undoManager.canUndo)
                doc.undoManager.redo()
                XCTAssertEqual(try effects(doc), order.map { definitions[$0] })
                XCTAssertEqual(doc.identity.layers[1].effects, order.map { layer.effects[$0] })
                XCTAssertEqual(doc.selection, selected)
                XCTAssertFalse(doc.undoManager.canRedo)
            }
        }
    }
    func testEqualValuesStillMoveIDsAndUndo() throws {
        let doc = try document(Array(repeating: WSSAddableEffect.ripple.definition(), count: 3))
        defer { doc.close() }
        let layer = doc.identity.layers[1]
        let model = doc.state.workingModel
        doc.select(.effect(layer.id, layer.effects[2]))
        try doc.moveSelection(by: -1)
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertEqual(
            doc.identity.layers[1].effects, [layer.effects[0], layer.effects[2], layer.effects[1]])
        XCTAssertEqual(doc.effectAddress?.effectIndex, 1)
        doc.undoManager.undo()
        XCTAssertEqual(doc.identity.layers[1], layer)
        doc.undoManager.redo()
        XCTAssertEqual(doc.effectAddress?.effectIndex, 1)
    }
    func testNoOpsBoundariesAndLocksDoNotPrepareOrRegisterUndo() async throws {
        for count in 0...1 {
            let doc = try document(
                Array(repeating: WSSAddableEffect.ripple.definition(), count: count))
            defer { doc.close() }
            await doc.waitForPreview()
            let layer = doc.identity.layers[1]
            doc.select(count == 0 ? .layer(layer.id) : .effect(layer.id, layer.effects[0]))
            if count == 1 {
                let before = doc.snapshot
                let preview = doc.previewResources
                for destination in [-1, 0, 1] {
                    try doc.moveEffect(layer.id, effect: layer.effects[0], to: destination)
                }
                XCTAssertEqual(doc.identity, before.identity)
                XCTAssertEqual(doc.state.workingRevision, before.state.workingRevision)
                XCTAssertTrue(doc.previewResources === preview)
                XCTAssertFalse(doc.canMoveSelection(by: -1))
                XCTAssertFalse(doc.canMoveSelection(by: 1))
            }
            doc.select(nil)
            XCTAssertFalse(doc.canMoveSelection(by: -1))
            XCTAssertFalse(doc.canMoveSelection(by: 1))
            try doc.moveSelection(by: 1)
            XCTAssertFalse(doc.undoManager.canUndo)
        }
        let doc = try document(Array(repeating: WSSAddableEffect.clouds.definition(), count: 3))
        defer { doc.close() }
        let layer = doc.identity.layers[1]
        doc.select(.effect(layer.id, layer.effects[0]))
        XCTAssertFalse(doc.canMoveSelection(by: -1))
        XCTAssertTrue(doc.canMoveSelection(by: 1))
        doc.interactionLocked = true
        try doc.moveSelection(by: 1)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.interactionLocked = false
        doc.select(.effect(layer.id, layer.effects[2]))
        XCTAssertTrue(doc.canMoveSelection(by: -1))
        XCTAssertFalse(doc.canMoveSelection(by: 1))
        try doc.moveEffect(layer.id, effect: WSSEffectID(), to: 0)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testResourceDefinitionsMoveAtomicallyWithIDs() throws {
        let synthetic = WSSArbitraryEffectChainTests()
        let a = synthetic.effects()
        let b = synthetic.effects(1)
        let c = WSSImageEffect.flow(
            WSSFlowEffect(
                flowMap: WSSAssetID(value: "assets/field-C.wssvf"), speed: 15, strength: 6))
        let model = try synthetic.document([a[2], b[2], c, a[0], b[1]])
        guard case .image(let image) = model.layers[0].content else { return XCTFail("fixture") }
        let doc = try document(image.effects)
        defer { doc.close() }
        let original = doc.state.workingModel
        let paths = original.referencedPaths
        let ids = doc.identity.layers[1]
        doc.select(.effect(ids.id, ids.effects[3]))
        for (from, to) in [(3, 0), (4, 1), (2, 4)] {
            let id = doc.identity.layers[1].effects[from]
            let before = doc.state.workingModel
            let oldIDs = doc.identity
            try doc.moveEffect(ids.id, effect: id, to: to)
            XCTAssertEqual(doc.state.workingModel.referencedPaths, paths)
            for index in image.effects.indices {
                let newIndex = try XCTUnwrap(
                    doc.identity.layers[1].effects.firstIndex(of: ids.effects[index]))
                XCTAssertEqual(try effects(doc)[newIndex], image.effects[index])
            }
            doc.undoManager.undo()
            XCTAssertEqual(doc.state.workingModel, before)
            XCTAssertEqual(doc.identity, oldIDs)
            doc.undoManager.redo()
        }
    }
    func testPreviewPixelsDirtySaveReopenAndSaveAs() async throws {
        let fixture = WSSEditorLivePreviewTests()
        try await fixture.setUp()
        defer { try? fixture.helper.tearDownWithError() }
        let loaded = try await fixture.project("WSS-Ripple-v1")
        let storage = fixture.helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([loaded.handle.wallpaper]).write(to: storage)
        let store = ManagedWallpaperStore(storage: storage)
        let doc = WSSEditorDocument(
            project: loaded,
            save: { snapshot in
                let prepared = try await WSSManifestSaveValidator().prepare(
                    snapshot, handle: loaded.handle)
                return try await store.commitWSSManifest(prepared)
            })
        defer { doc.close() }
        let layer = doc.identity.layers[0]
        doc.select(.layer(layer.id))
        try doc.addEffect(.clouds)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        await doc.waitForPreview()
        doc.undoManager.removeAllActions()
        let original = doc.state.workingModel
        let originalIDs = doc.identity
        let before = try fixture.frame(doc.previewResources, time: 0.37, width: 128)
        let clouds = doc.identity.layers[0].effects[1]
        doc.select(.effect(layer.id, clouds))
        try doc.moveSelection(by: -1)
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.selection, .effect(layer.id, clouds))
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        let reordered = doc.state.workingModel
        let reference = try await WSSEditorPreviewPreparation().prepare(
            reordered, basis: doc.state.diskBasis, handle: loaded.handle)
        let actual = try fixture.frame(doc.previewResources, time: 0.37, width: 128)
        XCTAssertEqual(actual, try fixture.frame(reference, time: 0.37, width: 128))
        XCTAssertNotEqual(actual, before)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertEqual(doc.identity, originalIDs)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, reordered)
        let address = try XCTUnwrap(doc.effectAddress)
        XCTAssertEqual(address.effectIndex, 0)
        try doc.setParameter(.cloudsIntensity, at: address, value: 0.8)
        XCTAssertEqual(
            WSSEditorParameter.cloudsIntensity.value(in: doc.state.workingModel, at: address), 0.8)
        doc.undoManager.undo()
        let snapshot = try WSSSaveAsSnapshot(
            document: doc.state.workingModel, state: doc.state, source: loaded.handle,
            name: "Reordered copy")
        let copy = try await store.saveWSSAs(snapshot)
        XCTAssertEqual(copy.project.document, snapshot.model)
        XCTAssertEqual(
            try WSSSceneDocumentV1.load(entry: loaded.handle.entry, root: loaded.handle.root),
            original)
        let didSave = await doc.save()
        XCTAssertTrue(didSave)
        let reopened = try await WSSEditorProjectLoader().load(loaded.handle.wallpaper)
        XCTAssertEqual(reopened.document, reordered)
        let bytes = String(decoding: try reordered.encoded(), as: UTF8.self)
        XCTAssertFalse(bytes.contains(clouds.rawValue.uuidString))
        XCTAssertFalse(doc.isDirty)
    }
}
