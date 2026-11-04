import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSEditorEffectManagementTests: XCTestCase {
    var helper: WSSEditorWorkspaceTests!
    override func setUp() async throws {
        helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
    }
    override func tearDown() async throws { try await helper.tearDown() }
    func image(_ doc: WSSEditorDocument, _ layer: Int = 1) throws -> WSSSceneDocumentV1.Image {
        guard case .image(let image) = doc.state.workingModel.layers[layer].content else {
            throw WSSDocumentError.invalid("expected image")
        }
        return image
    }
    func testFactoriesDefaultsRoundtripAndNoResources() throws {
        for kind: WSSAddableEffect in [.ripple, .clouds] {
            let effect = try kind.definition()
            let bytes = try JSONEncoder().encode(effect)
            XCTAssertEqual(
                try JSONDecoder().decode(WSSSceneDocumentV1.Effect.self, from: bytes), effect)
            XCTAssertNil(effect.maskPath)
            XCTAssertNil(effect.maskDefinition)
            XCTAssertNil(effect.fieldDefinition)
            if kind == .ripple {
                XCTAssertEqual(
                    effect.native,
                    .ripple(
                        WSSRippleEffect(
                            amplitude: 6, wavelength: 120, stretch: 1, direction: 180,
                            travelSpeed: 20, evolutionRate: 0.2, mask: nil, seed: 1,
                            structureRotation: 0, lateralDetail: 1)))
            } else {
                XCTAssertEqual(
                    effect.native,
                    .clouds(
                        WSSCloudsEffect(
                            velocity: SIMD2(12, 0), scale: 256, intensity: 0.3, density: 0.5,
                            seed: 1, mask: nil, secondaryField: nil, secondaryInfluence: 0.35,
                            softness: 0, brightness: 1, shadingAmount: 0, shadingDirection: 0)))
            }
        }
    }
    func testAddAppendSelectionInspectorOneUndoRedoAndPreview() async throws {
        for kind: WSSAddableEffect in [.ripple, .clouds] {
            let doc = helper.document()
            defer { doc.close() }
            let before = doc.state.workingModel
            let ids = doc.identity
            // The workspace creates this session before the user can press Add.
            _ = doc.maskCanvas
            doc.select(.layer(ids.layers[1].id))
            let canvas = doc.canvasModel
            let paths = before.referencedPaths
            try doc.addEffect(kind)
            let added = doc.identity
            let selection = doc.selection
            let effect = try XCTUnwrap(try image(doc).effects.last)
            let expected = try kind.definition()
            if kind == .clouds {
                XCTAssertNotNil(effect.maskDefinition)
                XCTAssertEqual(try effect.settingMask(slot: .clouds, definition: nil), expected)
            } else {
                XCTAssertEqual(effect, expected)
            }
            XCTAssertEqual(doc.effectAddress, .init(layerIndex: 1, effectIndex: 0))
            XCTAssertEqual(doc.selection, .effect(ids.layers[1].id, added.layers[1].effects[0]))
            XCTAssertFalse(doc.selectedInspection.isEmpty)
            XCTAssertEqual(doc.canvasModel, canvas)
            XCTAssertEqual(
                doc.state.workingModel.referencedPaths,
                paths.union(effect.maskPath.map { [$0] } ?? []))
            XCTAssertTrue(doc.isDirty)
            await doc.waitForPreview()
            XCTAssertTrue(doc.previewIsCurrent)
            XCTAssertEqual(
                doc.previewResources.scene.imageLayers[1].effects, [effect.native])
            let encoded = try doc.state.workingModel.encoded()
            XCTAssertEqual(try WSSSceneDocumentV1.decode(data: encoded), doc.state.workingModel)
            XCTAssertFalse(
                String(decoding: encoded, as: UTF8.self).contains(
                    added.layers[1].effects[0].rawValue.uuidString))
            doc.undoManager.undo()
            XCTAssertEqual(doc.state.workingModel, before)
            XCTAssertEqual(doc.identity, ids)
            XCTAssertEqual(doc.selection, .layer(ids.layers[1].id))
            XCTAssertFalse(doc.isDirty)
            XCTAssertFalse(doc.undoManager.canUndo)
            doc.undoManager.redo()
            XCTAssertEqual(doc.identity, added)
            XCTAssertEqual(doc.selection, selection)
            XCTAssertFalse(doc.undoManager.canRedo)
        }
    }
    func testIdenticalRipplesDeleteExactIDAndNextSelection() throws {
        let doc = helper.document()
        defer { doc.close() }
        let layer = doc.identity.layers[1].id
        doc.select(.layer(layer))
        try doc.addEffect(.ripple)
        let first = doc.selection
        try doc.addEffect(.ripple)
        let second = doc.selection
        let ids = doc.identity
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try image(doc).effects[0], try image(doc).effects[1])
        XCTAssertTrue(doc.canAddEffect(.ripple))
        try doc.deleteSelection()
        XCTAssertEqual(doc.selection, first)
        XCTAssertEqual(doc.identity.layers[1].effects, [ids.layers[1].effects[0]])
        doc.undoManager.undo()
        XCTAssertEqual(doc.identity, ids)
        XCTAssertEqual(doc.selection, second)
        doc.undoManager.redo()
        XCTAssertEqual(doc.selection, first)
        doc.select(first)
        try doc.deleteSelection()
        XCTAssertEqual(doc.selection, .layer(layer))
        XCTAssertEqual(doc.identity.layers.count, 2)
        doc.undoManager.undo()
        try doc.addEffect(.ripple)
        let next = doc.selection
        doc.select(first)
        try doc.deleteSelection()
        XCTAssertEqual(doc.selection, next)
    }
    func testInvalidTargetsArePureNoOpsAndRevertRepairsEffectSelection() async throws {
        let doc = helper.document()
        defer { doc.close() }
        let before = doc.state.workingModel
        let ids = doc.identity
        for selection: WSSEditorSelection? in [
            nil, .layer(WSSLayerID()), .effect(ids.layers[1].id, WSSEffectID()),
        ] {
            doc.selection = selection
            for kind in WSSAddableEffect.allCases {
                XCTAssertFalse(doc.canAddEffect(kind))
                try doc.addEffect(kind)
            }
            try doc.deleteSelection()
            XCTAssertEqual(doc.state.workingModel, before)
            XCTAssertEqual(doc.identity, ids)
            XCTAssertEqual(doc.state.workingRevision, 0)
            XCTAssertFalse(doc.undoManager.canUndo)
        }
        doc.select(.layer(ids.layers[1].id))
        try doc.addEffect(.ripple)
        let added = doc.selection
        doc.revert()
        XCTAssertEqual(doc.selection, .layer(ids.layers[1].id))
        XCTAssertFalse(doc.isDirty)
        doc.undoManager.undo()
        XCTAssertEqual(doc.selection, added)
        XCTAssertNotNil(doc.effectAddress)
        await doc.waitForPreview()
    }
    func testAvailabilityAndDeleteEveryNativeTypeWithRealPreparation() async throws {
        let fixtures = WSSEditorLivePreviewTests()
        try await fixtures.setUp()
        defer { try? fixtures.helper.tearDownWithError() }
        for name in [
            "WSS-Ripple-v1", "WSS-Flow-v1", "WSS-Clouds-v1",
            "WSS-Ripple-Chain-v1",
        ] {
            let project = try await fixtures.project(name)
            let doc = WSSEditorDocument(project: project)
            defer { doc.close() }
            let ids = doc.identity
            let before = doc.state.workingModel
            doc.select(.effect(ids.layers[0].id, ids.layers[0].effects[0]))
            XCTAssertTrue(doc.canAddEffect(.ripple), name)
            XCTAssertTrue(doc.canAddEffect(.clouds), name)
            try doc.deleteSelection()
            XCTAssertEqual(doc.identity.layers.count, ids.layers.count)
            XCTAssertEqual(doc.identity.layers[0].effects.count, ids.layers[0].effects.count - 1)
            XCTAssertTrue(doc.isDirty)
            await doc.waitForPreview()
            XCTAssertTrue(doc.previewIsCurrent, name)
            doc.undoManager.undo()
            XCTAssertEqual(doc.state.workingModel, before)
            XCTAssertEqual(doc.identity, ids)
            XCTAssertFalse(doc.isDirty)
        }
    }
    func testAppendRippleToExistingRippleAndFlowUsesSupportedChain() async throws {
        let fixtures = WSSEditorLivePreviewTests()
        try await fixtures.setUp()
        defer { try? fixtures.helper.tearDownWithError() }
        for name in ["WSS-Ripple-v1", "WSS-Flow-v1"] {
            let project = try await fixtures.project(name)
            let doc = WSSEditorDocument(project: project)
            defer { doc.close() }
            _ = doc.maskCanvas
            let original = doc.state.workingModel
            let ids = doc.identity.layers[0]
            doc.select(.effect(ids.id, ids.effects[0]))
            try doc.addEffect(.ripple)
            XCTAssertEqual(doc.identity.layers[0].effects.count, 2)
            XCTAssertEqual(doc.identity.layers[0].effects[0], ids.effects[0])
            XCTAssertEqual(doc.effectAddress, .init(layerIndex: 0, effectIndex: 1))
            XCTAssertTrue(doc.canAddEffect(.ripple))
            XCTAssertTrue(doc.canAddEffect(.clouds))
            await doc.waitForPreview()
            XCTAssertTrue(doc.previewIsCurrent, name)
            XCTAssertEqual(doc.previewResources.scene.imageLayers[0].effects.count, 2)
            doc.undoManager.undo()
            XCTAssertEqual(doc.state.workingModel, original)
            XCTAssertEqual(doc.identity.layers[0], ids)
        }
    }
    func testSaveDeleteSaveUndoSavePreservesResources() async throws {
        let storage = helper.helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([helper.item!]).write(to: storage)
        let store = ManagedWallpaperStore(storage: storage)
        let project = helper.project!
        let doc = WSSEditorDocument(
            project: project,
            save: { snapshot in
                let candidate = try await WSSManifestSaveValidator().prepare(
                    snapshot, handle: project.handle)
                return try await store.commitWSSManifest(candidate)
            })
        defer { doc.close() }
        let before = doc.state.workingModel
        let paths = before.referencedPaths
        doc.select(.effect(doc.identity.layers[0].id, doc.identity.layers[0].effects[0]))
        try doc.deleteSelection()
        let deleted = doc.state.workingModel
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(
            try WSSSceneDocumentV1.load(entry: helper.item.url, root: project.handle.root), deleted)
        for path in paths {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: project.handle.root.appendingPathComponent(path).path))
        }
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        let restored = await doc.save()
        XCTAssertTrue(restored)
        XCTAssertEqual(
            try WSSSceneDocumentV1.load(entry: helper.item.url, root: project.handle.root), before)
        doc.select(.layer(doc.identity.layers[1].id))
        try doc.addEffect(.clouds)
        let added = await doc.save()
        XCTAssertTrue(added)
        XCTAssertFalse(doc.isDirty)
    }
}

extension WSSEditorEffectManagementTests {
    func testSharedAndUnsavedPaintedMaskSurviveDeleteUndoAndSaveFiltering() async throws {
        let masks = WSSMaskEditingTests()
        try await masks.setUp()
        defer {
            masks.doc.close()
            try? masks.helper.helper.tearDownWithError()
        }
        let doc = masks.doc!
        let original = doc.state.workingModel
        _ = try masks.target()
        try doc.deleteSelection()
        XCTAssertTrue(doc.state.workingModel.referencedPaths.contains("assets/mask.png"))
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        try await masks.paint()
        let painted = doc.state.workingModel
        let path = try XCTUnwrap(masks.mask(painted))
        let bytes = try XCTUnwrap(doc.state.sessionAssets[path]).read()
        let selected = doc.selection
        try doc.deleteSelection()
        XCTAssertNotNil(doc.state.sessionAssets[path])
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: doc.project.handle.root.appendingPathComponent(path).path))
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, painted)
        XCTAssertEqual(doc.selection, selected)
        XCTAssertEqual(try doc.state.sessionAssets[path]?.read(), bytes)
        let restored = await doc.save()
        XCTAssertTrue(restored)
        XCTAssertEqual(
            try Data(contentsOf: doc.project.handle.root.appendingPathComponent(path)), bytes)
    }
    func testSaveAsAfterAddAndDeleteFiltersReferencesWithoutChangingSource() async throws {
        let storage = helper.helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([helper.item!]).write(to: storage)
        let store = ManagedWallpaperStore(storage: storage)
        let original = try helper.helper.snapshot()
        let doc = helper.document()
        defer { doc.close() }
        doc.select(.layer(doc.identity.layers[1].id))
        try doc.addEffect(.ripple)
        for delete in [false, true] {
            if delete {
                doc.select(.effect(doc.identity.layers[0].id, doc.identity.layers[0].effects[0]))
                try doc.deleteSelection()
            }
            let snapshot = try WSSSaveAsSnapshot(
                document: doc.state.workingModel, state: doc.state,
                source: doc.project.handle, name: "Effect copy")
            let receipt = try await store.saveWSSAs(snapshot)
            XCTAssertEqual(receipt.project.document, snapshot.model)
            XCTAssertEqual(
                Set(receipt.project.diskBasis.assets.keys), snapshot.model.referencedPaths)
            XCTAssertNotEqual(receipt.project.handle.id, helper.item.id)
        }
        let current = try helper.helper.snapshot()
        for (path, bytes) in original where path.hasPrefix("Wallpapers/WSS/Native/") {
            XCTAssertEqual(current[path], bytes)
        }
    }
    func testSaveSnapshotNAndCloseChoicesWithStructuralEdits() async throws {
        var pending: CheckedContinuation<WSSSaveReceipt, Error>?
        var captured: WSSSaveSnapshot?
        let project = helper.project!
        let doc = WSSEditorDocument(
            project: project,
            save: { snapshot in
                captured = snapshot
                return try await withCheckedThrowingContinuation { pending = $0 }
            })
        defer { doc.close() }
        doc.select(.layer(doc.identity.layers[1].id))
        try doc.addEffect(.ripple)
        let n = doc.state.workingModel
        let save = Task { await doc.save() }
        while pending == nil { await Task.yield() }
        try doc.addEffect(.ripple)
        let newer = doc.state.workingModel
        let snapshot = try XCTUnwrap(captured)
        pending?.resume(
            returning: WSSSaveReceipt(
                snapshot: snapshot,
                diskBasis: snapshot.diskBasis, outcome: .committed(warnings: [])))
        let saved = await save.value
        XCTAssertTrue(saved)
        XCTAssertEqual(doc.state.savedModel, n)
        XCTAssertEqual(doc.state.workingModel, newer)
        XCTAssertTrue(doc.isDirty)
        for choice in [WSSEditorDocument.CloseChoice.cancel, .discard] {
            doc.chooseClose = { choice }
            let resolved = await doc.resolveChanges()
            XCTAssertEqual(resolved, choice == .discard)
        }
        let closing = WSSEditorDocument(
            project: project,
            save: { snapshot in
                WSSSaveReceipt(
                    snapshot: snapshot, diskBasis: snapshot.diskBasis,
                    outcome: .committed(warnings: []))
            })
        defer { closing.close() }
        closing.select(.layer(closing.identity.layers[1].id))
        try closing.addEffect(.clouds)
        closing.chooseClose = { .save }
        let resolved = await closing.resolveChanges()
        XCTAssertTrue(resolved)
        XCTAssertFalse(closing.isDirty)
    }
    func testSharedVectorFieldAndLastLayerProtection() async throws {
        let fixtures = WSSEditorLivePreviewTests()
        try await fixtures.setUp()
        defer { try? fixtures.helper.tearDownWithError() }
        let project = try await fixtures.project("WSS-Flow-v1")
        var model = project.document
        model.layers.append(model.layers[0])
        try model.encoded().write(to: project.handle.entry)
        let loaded = try await WSSEditorProjectLoader().load(project.handle.wallpaper)
        let doc = WSSEditorDocument(project: loaded)
        defer { doc.close() }
        let paths = model.referencedPaths
        doc.select(.effect(doc.identity.layers[0].id, doc.identity.layers[0].effects[0]))
        try doc.deleteSelection()
        XCTAssertEqual(doc.state.workingModel.referencedPaths, paths)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, model)
        doc.select(.layer(doc.identity.layers[1].id))
        try doc.deleteSelection()
        doc.select(.effect(doc.identity.layers[0].id, doc.identity.layers[0].effects[0]))
        try doc.deleteSelection()
        XCTAssertEqual(doc.identity.layers.count, 1)
        XCTAssertNil(doc.currentDeletableSelection)
        doc.undoManager.undo()
        XCTAssertNotNil(doc.effectAddress)
    }
    func testAppendRepeatedMixedStackUndoRedoAndPreview() async throws {
        let fixtures = WSSEditorLivePreviewTests()
        try await fixtures.setUp()
        defer { try? fixtures.helper.tearDownWithError() }
        let doc = WSSEditorDocument(project: try await fixtures.project("WSS-Flow-v1"))
        defer { doc.close() }
        let original = doc.state.workingModel
        let layer = doc.identity.layers[0]
        doc.select(.layer(layer.id))
        for kind: WSSAddableEffect in [.ripple, .clouds, .ripple] {
            XCTAssertTrue(doc.canAddEffect(kind))
            try doc.addEffect(kind)
        }
        let working = doc.state.workingModel
        let ids = doc.identity
        XCTAssertEqual(ids.layers[0].effects.count, 4)
        XCTAssertEqual(Set(ids.layers[0].effects).count, 4)
        let encoded = try working.encoded()
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: encoded), working)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        XCTAssertEqual(doc.previewResources.effectPlans[0]?.activeStages.count, 4)
        for _ in 0..<3 { doc.undoManager.undo() }
        XCTAssertEqual(doc.state.workingModel, original)
        for _ in 0..<3 { doc.undoManager.redo() }
        XCTAssertEqual(doc.state.workingModel, working)
        XCTAssertEqual(doc.identity, ids)
    }

}
