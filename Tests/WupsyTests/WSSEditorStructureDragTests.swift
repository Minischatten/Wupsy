import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSEditorStructureDragTests: XCTestCase {
    var reorder: WSSEditorEffectReorderTests!
    override func setUp() async throws {
        reorder = WSSEditorEffectReorderTests()
        try await reorder.setUp()
    }
    override func tearDown() async throws { try await reorder.tearDown() }
    func nativeMove(
        _ doc: WSSEditorDocument, source: WSSEditorSelection, before target: WSSEditorSelection
    ) throws -> Bool {
        let rows = doc.structureRows
        return try doc.moveStructureRows(
            IndexSet(integer: XCTUnwrap(rows.firstIndex { $0.id == source })),
            to: XCTUnwrap(rows.firstIndex { $0.id == target }), rows: rows,
            session: doc.state.sessionID)
    }
    func definitions() -> [WSSSceneDocumentV1.Effect] {
        (0..<4).map { i in
            WSSSceneDocumentV1.Effect(
                parameters: .ripple(WSSRippleEffect(amplitude: Float(i + 2))), mask: nil, field: nil
            )
        }
    }
    func testEffectInsertionBoundariesIDsSelectionAndOneUndo() throws {
        let effects = definitions()
        for (from, target, after, order) in [
            (0, 2, false, [1, 0, 2, 3]), (0, 3, true, [1, 2, 3, 0]),
            (3, 0, false, [3, 0, 1, 2]), (2, 1, false, [0, 2, 1, 3]),
            (1, 1, false, [0, 1, 2, 3]), (1, 1, true, [0, 1, 2, 3]),
            (1, 2, false, [0, 1, 2, 3]), (1, 0, true, [0, 1, 2, 3]),
        ] {
            let doc = try reorder.document(effects)
            defer { doc.close() }
            let before = doc.state.workingModel
            let ids = doc.identity
            let layer = ids.layers[1]
            doc.select(.layer(layer.id))
            let source = WSSEditorSelection.effect(layer.id, layer.effects[from])
            let payload = try XCTUnwrap(doc.beginStructureDrag(source))
            XCTAssertEqual(doc.selection, source)
            let revision = doc.state.workingRevision
            let drop = WSSStructureDropTarget(
                row: .effect(layer.id, layer.effects[target]), after: after)
            XCTAssertTrue(try doc.performStructureDrop(payload, target: drop))
            XCTAssertEqual(try reorder.effects(doc), order.map { effects[$0] })
            XCTAssertEqual(doc.identity.layers[1].effects, order.map { layer.effects[$0] })
            XCTAssertEqual(doc.selection, source)
            if order == [0, 1, 2, 3] {
                XCTAssertEqual(doc.state.workingRevision, revision)
                XCTAssertFalse(doc.undoManager.canUndo)
            } else {
                doc.undoManager.undo()
                XCTAssertEqual(doc.state.workingModel, before)
                XCTAssertEqual(doc.identity, ids)
                XCTAssertEqual(doc.selection, source)
                XCTAssertFalse(doc.undoManager.canUndo)
                doc.undoManager.redo()
                XCTAssertEqual(doc.identity.layers[1].effects, order.map { layer.effects[$0] })
                XCTAssertEqual(doc.selection, source)
            }
        }
    }
    func testEqualEffectsRetainIdentityAndParameterEditor() throws {
        let doc = try reorder.document(
            Array(repeating: WSSAddableEffect.ripple.definition(), count: 3))
        defer { doc.close() }
        let ids = doc.identity.layers[1]
        let source = WSSEditorSelection.effect(ids.id, ids.effects[2])
        let payload = try XCTUnwrap(doc.beginStructureDrag(source))
        XCTAssertTrue(
            try doc.performStructureDrop(
                payload, target: .init(row: .effect(ids.id, ids.effects[0]), after: false)))
        XCTAssertEqual(
            doc.identity.layers[1].effects, [ids.effects[2], ids.effects[0], ids.effects[1]])
        XCTAssertEqual(doc.selection, source)
        let address = try XCTUnwrap(doc.effectAddress)
        try doc.setParameter(.rippleAmplitude, at: address, value: 22)
        XCTAssertEqual(
            try reorder.effects(doc).map { $0.native.samplingRipple?.amplitude }, [22, 6, 6])
        doc.undoManager.undo()
        doc.undoManager.undo()
        XCTAssertEqual(doc.identity.layers[1], ids)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        doc.undoManager.redo()
        XCTAssertEqual(doc.effectAddress?.effectIndex, 0)
    }
    func layersDocument() throws -> WSSEditorDocument {
        let doc = try reorder.document(definitions())
        var model = doc.state.workingModel
        model.layers += model.layers
        model.layers[2].content = .trail(WSSTrailTests().configuration(), visible: true)
        try doc.mutate(model, name: "Setup", ids: WSSEditorIdentity(model))
        doc.undoManager.removeAllActions()
        return doc
    }
    func testLayerInsertionBoundariesMixedTypes() throws {
        for (from, target, after, order) in [
            (0, 3, true, [1, 2, 3, 0]), (3, 0, false, [3, 0, 1, 2]),
            (2, 1, false, [0, 2, 1, 3]), (0, 2, false, [1, 0, 2, 3]),
            (1, 1, true, [0, 1, 2, 3]),
        ] {
            let doc = try layersDocument()
            defer { doc.close() }
            let model = doc.state.workingModel
            let ids = doc.identity
            let source = WSSEditorSelection.layer(ids.layers[from].id)
            let payload = try XCTUnwrap(doc.beginStructureDrag(source))
            let revision = doc.state.workingRevision
            let drop = WSSStructureDropTarget(row: .layer(ids.layers[target].id), after: after)
            XCTAssertTrue(try doc.performStructureDrop(payload, target: drop))
            XCTAssertEqual(doc.state.workingModel.layers, order.map { model.layers[$0] })
            XCTAssertEqual(doc.identity.layers, order.map { ids.layers[$0] })
            XCTAssertEqual(doc.selection, source)
            if order == [0, 1, 2, 3] {
                XCTAssertEqual(doc.state.workingRevision, revision)
                XCTAssertFalse(doc.undoManager.canUndo)
            } else {
                doc.undoManager.undo()
                XCTAssertEqual(doc.state.workingModel, model)
                XCTAssertEqual(doc.identity, ids)
                XCTAssertEqual(doc.selection, source)
                XCTAssertFalse(doc.undoManager.canUndo)
                doc.undoManager.redo()
                XCTAssertEqual(doc.identity.layers, order.map { ids.layers[$0] })
            }
            XCTAssertEqual(
                try WSSSceneDocumentV1.decode(data: doc.state.workingModel.encoded()),
                doc.state.workingModel)

        }
    }
    func testRejectWrongKindCrossLayerSessionStaleAndInvalidNativeOffsets() throws {
        let doc = try layersDocument()
        defer { doc.close() }
        let ids = doc.identity
        let a = ids.layers[1]
        let b = ids.layers[3]
        let effect = try XCTUnwrap(doc.beginStructureDrag(.effect(a.id, a.effects[0])))
        let layer = WSSStructureDragPayload(session: doc.state.sessionID, source: .layer(a.id))
        let foreign = WSSStructureDragPayload(session: UUID(), source: .effect(a.id, a.effects[0]))
        let stale = WSSStructureDragPayload(
            session: doc.state.sessionID, source: .effect(a.id, WSSEffectID()))
        let target = WSSStructureDropTarget(row: .effect(a.id, a.effects[2]), after: true)
        let model = doc.state.workingModel
        let revision = doc.state.workingRevision
        for (payload, drop) in [
            (effect, WSSStructureDropTarget(row: .layer(a.id), after: false)),
            (layer, target), (effect, .init(row: .effect(b.id, b.effects[0]), after: false)),
            (foreign, target), (stale, target),
        ] {
            XCTAssertNil(doc.structureDropDestination(payload, target: drop))
            XCTAssertFalse(try doc.performStructureDrop(payload, target: drop))
        }
        let rows = doc.structureRows
        for (sources, boundary, session) in [
            (IndexSet(), 0, doc.state.sessionID),
            (IndexSet([0, 1]), 0, doc.state.sessionID),
            (IndexSet(integer: rows.count), 0, doc.state.sessionID),
            (IndexSet(integer: 0), -1, doc.state.sessionID),
            (IndexSet(integer: 0), rows.count + 1, doc.state.sessionID),
            (IndexSet(integer: 0), 0, UUID()),
        ] {
            XCTAssertFalse(
                try doc.moveStructureRows(sources, to: boundary, rows: rows, session: session))
        }
        doc.interactionLocked = true
        XCTAssertFalse(try doc.performStructureDrop(effect, target: target))
        doc.interactionLocked = false
        // A cancelled drag only selected its source, with no reorder or preview revision.
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertEqual(doc.state.workingRevision, revision)
        XCTAssertEqual(doc.identity, ids)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testNativeListMoveCallbackAndResourceBindings() async throws {
        let synthetic = WSSArbitraryEffectChainTests()
        let a = synthetic.effects()
        let b = synthetic.effects(1)
        let c = WSSImageEffect.flow(
            WSSFlowEffect(flowMap: .init(value: "assets/field-C.wssvf"), speed: 9, strength: 4))
        let model = try synthetic.document([a[2], b[2], c, a[0], b[1]])
        guard case .image(let image) = model.layers[0].content else { return XCTFail("fixture") }
        let doc = try reorder.document(image.effects)
        defer { doc.close() }
        let before = doc.state.workingModel
        let ids = doc.identity.layers[1]
        let source = WSSEditorSelection.effect(ids.id, ids.effects[3])
        let payload = try XCTUnwrap(doc.beginStructureDrag(source))
        let rows = doc.structureRows
        let from = try XCTUnwrap(rows.firstIndex { $0.id == source })
        let to = try XCTUnwrap(rows.firstIndex { $0.id == .effect(ids.id, ids.effects[0]) })
        XCTAssertTrue(
            try doc.moveStructureRows(
                IndexSet(integer: from), to: to, rows: rows, session: payload.session))
        XCTAssertEqual(
            try reorder.effects(doc),
            [
                image.effects[3], image.effects[0], image.effects[1], image.effects[2],
                image.effects[4],
            ])
        XCTAssertEqual(doc.state.workingModel.referencedPaths, before.referencedPaths)
        XCTAssertEqual(doc.selection, source)
        XCTAssertEqual(doc.editTarget?.effect, ids.effects[3])
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertEqual(doc.identity.layers[1], ids)
        doc.undoManager.redo()
        XCTAssertEqual(doc.effectAddress?.effectIndex, 0)
    }
    // Exercises the exact callback now attached to ForEach.onMove. The previous
    // provider/model tests bypassed List's native event routing entirely.
    func testNativeListCallbackMapsFlatRowsAndRejectsCrossOwnerBoundaries() throws {
        for (from, boundary, order) in [
            (0, 2, [1, 0, 2, 3]), (0, 4, [1, 2, 3, 0]),
            (3, 0, [3, 0, 1, 2]), (2, 1, [0, 2, 1, 3]),
        ] {
            let doc = try layersDocument()
            defer { doc.close() }
            let rows = doc.structureRows
            let model = doc.state.workingModel
            let ids = doc.identity
            let source = try XCTUnwrap(rows.firstIndex { $0.id == .layer(ids.layers[from].id) })
            let destination =
                boundary == ids.layers.count
                ? rows.count
                : try XCTUnwrap(rows.firstIndex { $0.id == .layer(ids.layers[boundary].id) })
            XCTAssertTrue(
                try doc.moveStructureRows(
                    IndexSet(integer: source), to: destination, rows: rows,
                    session: doc.state.sessionID))
            XCTAssertEqual(doc.identity.layers, order.map { ids.layers[$0] })
            XCTAssertEqual(doc.state.workingModel.layers, order.map { model.layers[$0] })
            XCTAssertEqual(doc.selection, .layer(ids.layers[from].id))
            doc.undoManager.undo()
            XCTAssertEqual(doc.identity, ids)
            XCTAssertFalse(doc.undoManager.canUndo)
            let effect = try XCTUnwrap(
                rows.firstIndex { $0.id == .effect(ids.layers[1].id, ids.layers[1].effects[0]) })
            let otherLayer = try XCTUnwrap(rows.firstIndex { $0.id == .layer(ids.layers[3].id) })
            XCTAssertFalse(
                try doc.moveStructureRows(
                    IndexSet(integer: effect), to: otherLayer, rows: rows,
                    session: doc.state.sessionID))
            XCTAssertFalse(
                try doc.moveStructureRows(
                    IndexSet(integer: source), to: effect, rows: rows, session: doc.state.sessionID)
            )
            XCTAssertFalse(doc.undoManager.canUndo)
        }
    }
    func testNativeListEffectEndBoundaryAndStableSnapshotIDs() throws {
        let doc = try layersDocument()
        defer { doc.close() }
        let rows = doc.structureRows
        let ids = doc.identity
        let layer = ids.layers[1]
        let source = try XCTUnwrap(rows.firstIndex { $0.id == .effect(layer.id, layer.effects[0]) })
        let end = try XCTUnwrap(rows.firstIndex { $0.id == .layer(ids.layers[2].id) })
        // Another action changes current layer indices after this rendered snapshot.
        try doc.moveLayer(layer.id, to: 0)
        doc.undoManager.removeAllActions()
        XCTAssertTrue(
            try doc.moveStructureRows(
                IndexSet(integer: source), to: end, rows: rows, session: doc.state.sessionID))
        XCTAssertEqual(
            doc.identity.layers[0].effects, Array(layer.effects.dropFirst()) + [layer.effects[0]])
        XCTAssertEqual(doc.selection, .effect(layer.id, layer.effects[0]))
        doc.undoManager.undo()
        XCTAssertEqual(doc.identity.layers[0], layer)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testNativeListInstallsPasteboardMoveWriter() throws {
        let doc = try layersDocument()
        defer { doc.close() }
        let controller = WSSEditorWindowController(document: doc, onClose: {})
        defer { controller.close() }
        controller.showWindow(nil)
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { findTable($0) }.first
        }
        let table = try XCTUnwrap(findTable(content))
        let writer: NSPasteboardWriting?
        if let outline = table as? NSOutlineView, let item = outline.item(atRow: 0) {
            writer = outline.dataSource?.outlineView?(outline, pasteboardWriterForItem: item)
        } else {
            writer = table.dataSource?.tableView?(table, pasteboardWriterForRow: 0)
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertFalse(try XCTUnwrap(writer).writableTypes(for: pasteboard).isEmpty)
        // This checks native List registration, not an end-to-end pointer drag.
    }
    func testDragPreviewPixelsSaveReopenSaveAsAndArrowEquivalence() async throws {
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
                try await store.commitWSSManifest(
                    WSSManifestSaveValidator().prepare(snapshot, handle: loaded.handle))
            })
        defer { doc.close() }
        let layer = doc.identity.layers[0]
        doc.select(.layer(layer.id))
        try doc.addEffect(.clouds)
        // Two overlapping image layers make scene order pixel-relevant too.
        var model = doc.state.workingModel
        var second = model.layers[0]
        guard case .image(var image) = second.content else { return XCTFail("image") }
        image.effects = [try WSSAddableEffect.clouds.definition()]
        image.opacity = 0.6
        image.composition = "sourceOver"
        second.content = .image(image)
        model.layers.append(second)
        try doc.mutate(model, name: "Setup", ids: WSSEditorIdentity(model))
        let saved = await doc.save()
        XCTAssertTrue(saved)
        await doc.waitForPreview()
        doc.undoManager.removeAllActions()
        let original = doc.state.workingModel
        let ids = doc.identity
        let first = ids.layers[0]
        let before = try fixture.frame(doc.previewResources, time: 0.37, width: 128)
        let unchangedRevision = doc.state.workingRevision
        let unchangedPreview = doc.previewResources
        let noOpSource = WSSEditorSelection.effect(first.id, first.effects[0])
        let noOp = try XCTUnwrap(doc.beginStructureDrag(noOpSource))
        XCTAssertTrue(
            try doc.performStructureDrop(noOp, target: .init(row: noOpSource, after: true)))
        // Starting then cancelling a layer drag also only changes selection.
        _ = try XCTUnwrap(doc.beginStructureDrag(.layer(ids.layers[1].id)))
        XCTAssertEqual(doc.state.workingRevision, unchangedRevision)
        XCTAssertTrue(doc.previewResources === unchangedPreview)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
        let source = WSSEditorSelection.effect(first.id, first.effects[1])
        let payload = try XCTUnwrap(doc.beginStructureDrag(source))
        XCTAssertTrue(
            try nativeMove(doc, source: source, before: .effect(first.id, first.effects[0])))
        let effectOrder = doc.state.workingModel
        XCTAssertTrue(doc.isDirty)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        let effectFrame = try fixture.frame(doc.previewResources, time: 0.37, width: 128)
        XCTAssertNotEqual(effectFrame, before)
        doc.undoManager.undo()
        XCTAssertFalse(doc.isDirty)
        try doc.moveSelection(by: -1)
        XCTAssertEqual(doc.state.workingModel, effectOrder)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertTrue(
            try nativeMove(doc, source: source, before: .effect(first.id, first.effects[0])))
        let layerSource = WSSEditorSelection.layer(ids.layers[1].id)
        _ = try XCTUnwrap(doc.beginStructureDrag(layerSource))
        XCTAssertTrue(
            try nativeMove(doc, source: layerSource, before: .layer(first.id)))
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        let final = doc.state.workingModel
        let reference = try await WSSEditorPreviewPreparation().prepare(
            final, basis: doc.state.diskBasis, handle: loaded.handle)
        let finalFrame = try fixture.frame(doc.previewResources, time: 0.37, width: 128)
        XCTAssertNotEqual(finalFrame, effectFrame)
        XCTAssertEqual(finalFrame, try fixture.frame(reference, time: 0.37, width: 128))
        XCTAssertEqual(doc.selection, layerSource)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, effectOrder)
        try doc.moveSelection(by: -1)
        XCTAssertEqual(doc.state.workingModel, final)
        let copy = try await store.saveWSSAs(
            WSSSaveAsSnapshot(
                document: final, state: doc.state, source: loaded.handle, name: "Dragged copy"))
        XCTAssertEqual(copy.project.document.layers, final.layers)
        XCTAssertEqual(
            try WSSSceneDocumentV1.load(entry: loaded.handle.entry, root: loaded.handle.root),
            original)
        let didSave = await doc.save()
        XCTAssertTrue(didSave)
        let reopened = try await WSSEditorProjectLoader().load(loaded.handle.wallpaper)
        XCTAssertEqual(reopened.document, final)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(
            String(decoding: try final.encoded(), as: UTF8.self).contains(
                payload.session.uuidString))
    }
}
