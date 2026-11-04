import AppKit
import Darwin
import XCTest

@testable import Wupsy

@MainActor final class WSSMaskEditingTests: XCTestCase {
    var helper: WSSEditorEffectSelectionTests!
    var doc: WSSEditorDocument!
    var store: ManagedWallpaperStore!
    var storage: URL!
    override func setUp() async throws {
        helper = WSSEditorEffectSelectionTests()
        try await helper.setUp()
        storage = helper.helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([helper.item!]).write(to: storage)
        store = ManagedWallpaperStore(storage: storage)
        doc = makeDocument(helper.project)
    }
    override func tearDown() async throws {
        doc.close()
        doc = nil
        store = nil
        try await helper.tearDown()
        helper = nil
    }
    func makeDocument(_ project: WSSLoadedEditorProject) -> WSSEditorDocument {
        let store = store!
        return WSSEditorDocument(
            project: project,
            save: { snapshot in
                let candidate = try await WSSManifestSaveValidator().prepare(
                    snapshot, handle: project.handle)
                return try await store.commitWSSManifest(candidate)
            })
    }
    func target(layer: Int = 0, effect: Int = 0) throws -> WSSMaskTarget {
        let ids = doc.identity.layers[layer]
        doc.select(.effect(ids.id, ids.effects[effect]))
        return try XCTUnwrap(doc.selectedMaskTarget)
    }
    func paint(opacity: Double = 0.5) async throws {
        var stroke = try await doc.beginMaskStroke(
            target: target(), settings: .init(diameter: 2, opacity: opacity, mode: .paint),
            start: .zero)
        try await doc.applyMaskStroke(XCTUnwrap(stroke.finish()))
    }
    func mask(_ model: WSSSceneDocumentV1, layer: Int = 0, effect: Int = 0) -> String? {
        guard case .image(let image) = model.layers[layer].content else { return nil }
        return image.effects[effect].maskPath
    }
    func scalar(_ model: WSSSceneDocumentV1, assets: [String: WSSImageGeneration] = [:]) throws
        -> Data
    {
        var source = try model.assetSource(root: doc.project.handle.root)
        source.sessionAssets = assets
        return try source.mask(for: WSSAssetID(value: XCTUnwrap(mask(model)))).pixels
    }
    func testResolutionUsesSessionLayerEffectAndTypedSlot() throws {
        let ripple = try target()
        XCTAssertEqual(ripple.slot, .ripple)
        let resolved = try doc.resolveMaskTarget(ripple)
        XCTAssertEqual(resolved.path, "assets/mask.png")
        XCTAssertEqual(try target(layer: 1).slot, .clouds)
        for bad in [
            WSSMaskTarget(
                sessionID: UUID(), layerID: ripple.layerID, effectID: ripple.effectID, slot: .ripple
            ),
            WSSMaskTarget(
                sessionID: ripple.sessionID, layerID: WSSLayerID(), effectID: ripple.effectID,
                slot: .ripple),
            WSSMaskTarget(
                sessionID: ripple.sessionID, layerID: ripple.layerID, effectID: WSSEffectID(),
                slot: .ripple),
            WSSMaskTarget(
                sessionID: ripple.sessionID, layerID: ripple.layerID, effectID: ripple.effectID,
                slot: .clouds),
        ] { XCTAssertThrowsError(try doc.resolveMaskTarget(bad)) }
        doc.select(nil)
        XCTAssertNil(doc.selectedMaskTarget)
        doc.select(.layer(ripple.layerID))
        XCTAssertNil(doc.selectedMaskTarget)
    }
    func testSharedMaskCopyOnWriteOneUndoRedoAndOriginalUntouched() async throws {
        let original = doc.state.workingModel
        let originalFiles = try helper.helper.snapshot()
        try await paint()
        let painted = doc.state.workingModel
        XCTAssertNotEqual(mask(painted), mask(original))
        XCTAssertEqual(mask(painted, effect: 1), mask(original, effect: 1))
        XCTAssertEqual(try scalar(painted, assets: doc.state.sessionAssets), Data([128, 255]))
        XCTAssertEqual(try helper.helper.snapshot(), originalFiles)
        XCTAssertEqual(doc.state.sessionAssets.count, 1)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, painted)
        XCTAssertFalse(doc.undoManager.canRedo)
    }
    func testCloudMaskEditDoesNotChangeRippleMasks() async throws {
        let before = doc.state.workingModel
        var stroke = try await doc.beginMaskStroke(
            target: target(layer: 1), settings: .init(diameter: 2, opacity: 1, mode: .paint),
            start: .zero)
        try await doc.applyMaskStroke(XCTUnwrap(stroke.finish()))
        XCTAssertNotEqual(mask(doc.state.workingModel, layer: 1), mask(before, layer: 1))
        XCTAssertEqual(doc.state.workingModel.layers[0], before.layers[0])
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
    }
    func testResourceReplacementRejectsTraversalAndParameterAPIStillProtectsResources() throws {
        let resolved = try doc.resolveMaskTarget(target())
        guard case .image(let image) = doc.state.workingModel.layers[0].content else {
            return XCTFail()
        }
        let effect = image.effects[0]
        let bitmap = try WSSMaskBitmap(
            width: 2, height: 1, uvScale: SIMD2(1, 1), pixels: Data([0, 128]))
        for path in ["../mask.png", "/mask.png", "assets/../../mask.png"] {
            XCTAssertThrowsError(
                try effect.replacingMask(
                    slot: .ripple, expected: resolved, definition: bitmap.definition(path: path)))
        }
        var protected = effect
        XCTAssertThrowsError(
            try protected.updateParameters { value in
                guard case .ripple(var ripple) = value else { return }
                ripple.mask = WSSImageMask(asset: WSSAssetID(value: "assets/different.png"))
                value = .ripple(ripple)
            })
        XCTAssertEqual(protected, effect)
    }
    func testSaveAsCommittedMaskHasDifferentInode() async throws {
        try await paint()
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let snapshot = try WSSSaveAsSnapshot(
            document: doc.state.workingModel, state: doc.state, source: doc.project.handle,
            name: "Independent")
        let receipt = try await store.saveWSSAs(snapshot)
        let path = try XCTUnwrap(mask(snapshot.model))
        let a = try FileManager.default.attributesOfItem(
            atPath: doc.project.handle.root.appendingPathComponent(path).path)
        let b = try FileManager.default.attributesOfItem(
            atPath: receipt.project.handle.root.appendingPathComponent(path).path)
        XCTAssertNotEqual(a[.systemFileNumber] as? NSNumber, b[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(
            try Data(contentsOf: doc.project.handle.root.appendingPathComponent(path)),
            try Data(contentsOf: receipt.project.handle.root.appendingPathComponent(path)))
    }
    func testCancelAndNoOpDoNotTouchDocumentOrCatalog() async throws {
        let before = doc.state.workingModel
        var stroke = try await doc.beginMaskStroke(
            target: target(), settings: .init(diameter: 2, opacity: 1, mode: .paint), start: .zero)
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        stroke.cancel()
        XCTAssertThrowsError(try stroke.finish())
        var zero = try await doc.beginMaskStroke(
            target: target(), settings: .init(diameter: 2, opacity: 0, mode: .paint), start: .zero)
        XCTAssertNil(try zero.finish())
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertEqual(doc.state.workingModel, before)
    }
    func testStaleRevisionAndDuplicateFinishCandidateFailClosed() async throws {
        var stroke = try await doc.beginMaskStroke(
            target: target(), settings: .init(diameter: 2, opacity: 1, mode: .paint), start: .zero)
        let candidate = try XCTUnwrap(stroke.finish())
        try doc.setVisibility(false, layer: doc.identity.layers[0].id)
        let before = doc.state.workingModel
        do {
            try await doc.applyMaskStroke(candidate)
            XCTFail("stale revision accepted")
        } catch {}
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        doc.undoManager.undo()
        try await paint()
        do {
            try await doc.applyMaskStroke(candidate)
            XCTFail("old candidate reused")
        } catch {}
        XCTAssertEqual(doc.state.sessionAssets.count, 1)
    }
    func testAbsolutePaintNoOpAndChangingTargetsKeepExactUndoHistory() async throws {
        let original = doc.state.workingModel
        try await paint(opacity: 0.5)
        let half = doc.state.workingModel
        var same = try await doc.beginMaskStroke(
            target: target(), settings: .init(diameter: 2, opacity: 0.5, mode: .paint), start: .zero
        )
        XCTAssertNil(try same.finish())
        XCTAssertEqual(doc.state.sessionAssets.count, 1)
        XCTAssertEqual(doc.state.workingModel, half)
        try await paint(opacity: 0.7)
        XCTAssertEqual(
            try scalar(doc.state.workingModel, assets: doc.state.sessionAssets), Data([179, 255]))
        try await paint(opacity: 0.3)
        XCTAssertEqual(
            try scalar(doc.state.workingModel, assets: doc.state.sessionAssets), Data([77, 255]))
        doc.undoManager.undo()
        XCTAssertEqual(
            try scalar(doc.state.workingModel, assets: doc.state.sessionAssets), Data([179, 255]))
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, half)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, half)
    }
    func testSaveReopenAndUndoBeforeSaveRetainOnlyReferencedGeneration() async throws {
        let originalBytes = try Data(
            contentsOf: helper.project.handle.root.appendingPathComponent("assets/mask.png"))
        try await paint()
        let m1 = doc.state.workingModel
        try await paint(opacity: 0.7)
        let m2 = doc.state.workingModel
        XCTAssertNotEqual(mask(m1), mask(m2))
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, m1)
        let copy = try WSSSaveAsSnapshot(
            document: m1, state: doc.state, source: doc.project.handle, name: "Mask copy")
        XCTAssertEqual(copy.generations.count, 1)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let loaded = try await WSSEditorProjectLoader().load(helper.item)
        XCTAssertEqual(loaded.document, m1)
        XCTAssertEqual(try scalar(loaded.document), Data([128, 255]))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: loaded.handle.root.appendingPathComponent(try XCTUnwrap(mask(m2))).path))
        XCTAssertEqual(
            try Data(contentsOf: loaded.handle.root.appendingPathComponent("assets/mask.png")),
            originalBytes)
        XCTAssertEqual(loaded.diskBasis.assets, doc.state.diskBasis.assets)
        doc.undoManager.redo()
        let savedAgain = await doc.save()
        XCTAssertTrue(savedAgain)
        let reopenedAgain = try await WSSEditorProjectLoader().load(helper.item)
        XCTAssertEqual(reopenedAgain.document, m2)
    }
    func testSaveAsHasIndependentPhysicalMaskAndSurvivesSourceRemoval() async throws {
        try await paint()
        let snapshot = try WSSSaveAsSnapshot(
            document: doc.state.workingModel, state: doc.state, source: doc.project.handle,
            name: "Copy")
        let receipt = try await store.saveWSSAs(snapshot)
        let path = try XCTUnwrap(mask(snapshot.model))
        XCTAssertEqual(receipt.project.diskBasis.assets[path], snapshot.catalog[path])
        XCTAssertEqual(
            try Data(contentsOf: receipt.project.handle.root.appendingPathComponent(path)),
            try snapshot.generations[path]?.read())
        let originalPath = doc.project.handle.root
        doc.close()
        try FileManager.default.removeItem(at: originalPath)
        let loaded = try await WSSEditorProjectLoader().load(receipt.project.handle.wallpaper)
        XCTAssertEqual(loaded.document, snapshot.model)
        let assets = try loaded.document.assetSource(root: loaded.handle.root)
        XCTAssertEqual(try assets.mask(for: WSSAssetID(value: path)).pixels, Data([128, 255]))
    }
    func testChangedMalformedSymlinkAndNonRegularMaskFailClosed() async throws {
        let path = helper.project.handle.root.appendingPathComponent("assets/mask.png")
        let bytes = try Data(contentsOf: path)
        let target = try target()
        let original = doc.state.workingModel
        try Data("malformed".utf8).write(to: path)
        do {
            _ = try await doc.beginMaskStroke(
                target: target, settings: .init(diameter: 2, opacity: 1, mode: .paint), start: .zero
            )
            XCTFail("mutation accepted")
        } catch {}
        try FileManager.default.removeItem(at: path)
        let outside = helper.helper.root.appendingPathComponent("external.png")
        try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
        do {
            _ = try await doc.beginMaskStroke(
                target: target, settings: .init(diameter: 2, opacity: 1, mode: .paint), start: .zero
            )
            XCTFail("symlink accepted")
        } catch {}
        try FileManager.default.removeItem(at: path)
        XCTAssertEqual(mkfifo(path.path, 0o600), 0)
        do {
            _ = try await doc.beginMaskStroke(
                target: target, settings: .init(diameter: 2, opacity: 1, mode: .paint), start: .zero
            )
            XCTFail("FIFO accepted")
        } catch {}
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
    }
    func testCopyOnWriteAggregateMaskBudgetRejectsWithoutAnyDocumentMutation() async throws {
        let bitmap = try WSSMaskBitmap(
            width: 4096, height: 4097, uvScale: SIMD2(1, 1),
            pixels: Data(repeating: 0, count: 4096 * 4097))
        try bitmap.encoded().write(
            to: helper.project.handle.root.appendingPathComponent("assets/mask.png"))
        doc.close()
        doc = makeDocument(try await WSSEditorProjectLoader().load(helper.item))
        let before = doc.state.workingModel
        let catalog = doc.state.resourceCatalog
        let files = try helper.helper.snapshot()
        do {
            try await paint()
            XCTFail("two separate masks exceeded aggregate budget")
        } catch {}
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertEqual(doc.state.resourceCatalog, catalog)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertFalse(doc.interactionLocked)
        XCTAssertEqual(try helper.helper.snapshot(), files)
    }
    func testExplicitDescriptorUVAndScalarContractSurviveStrokeSave() async throws {
        let bitmap = try WSSMaskBitmap(
            width: 2, height: 1, uvScale: SIMD2(0.5, 0.75), pixels: Data([0, 255]))
        let definition = bitmap.definition(path: "assets/mask.png")
        var model = doc.state.workingModel
        if case .image(var image) = model.layers[0].content {
            image.effects = image.effects.map {
                .init(parameters: $0.native, mask: definition, field: $0.fieldDefinition)
            }
            model.layers[0].content = .image(image)
        }
        try model.encoded().write(to: helper.item.url)
        doc.close()
        doc = makeDocument(try await WSSEditorProjectLoader().load(helper.item))
        try await paint()
        guard case .image(let image) = doc.state.workingModel.layers[0].content else {
            return XCTFail()
        }
        XCTAssertEqual(image.effects[0].maskDefinition?.uvScale, [0.5, 0.75])
        XCTAssertEqual(image.effects[0].maskDefinition?.filter, "linear")
        XCTAssertEqual(image.effects[0].maskDefinition?.edge, "clamp")
        XCTAssertEqual(image.effects[0].maskDefinition?.mipmapped, false)
        XCTAssertEqual(image.effects[1].maskDefinition, definition)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(helper.item)
        XCTAssertEqual(reopened.document, doc.state.workingModel)
    }
    func testSourceChangedAfterStrokeBeginRejectsFinalization() async throws {
        var value = try await doc.beginMaskStroke(
            target: target(), settings: .init(diameter: 2, opacity: 1, mode: .paint), start: .zero)
        let candidate = try XCTUnwrap(value.finish())
        let before = doc.state.workingModel
        try Data("changed".utf8).write(
            to: helper.project.handle.root.appendingPathComponent("assets/mask.png"))
        do {
            try await doc.applyMaskStroke(candidate)
            XCTFail("changed committed source accepted")
        } catch {}
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertFalse(doc.interactionLocked)
    }
    func testGenerationBudgetAndMalformedCodecFailBeforeStaging() async throws {
        let bitmap = try WSSMaskBitmap(
            width: 2, height: 1, uvScale: SIMD2(1, 1), pixels: Data([0, 128]))
        do {
            _ = try await WSSMaskPreparation().generation(bitmap, remainingBudget: 0)
            XCTFail("budget ignored")
        } catch {}
        XCTAssertThrowsError(
            try WSSMaskAsset.decode(Data("bad".utf8), width: 2, height: 1, uvScale: SIMD2(1, 1)))
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testFlowFieldsAndAbsentRippleMaskRejectScalarEditing() async throws {
        let fixture = WSSEditorLivePreviewTests()
        try await fixture.setUp()
        defer { try? fixture.helper.tearDownWithError() }
        for name in ["WSS-Flow-v1"] {
            let loaded = try await fixture.project(name)
            let value = WSSEditorDocument(project: loaded)
            defer { value.close() }
            let ids = value.identity.layers[0]
            value.select(.effect(ids.id, ids.effects[0]))
            XCTAssertNil(value.selectedMaskTarget)
            XCTAssertThrowsError(
                try value.resolveMaskTarget(
                    .init(
                        sessionID: value.state.sessionID, layerID: ids.id,
                        effectID: ids.effects[0], slot: .ripple)))
        }
        var model = doc.state.workingModel
        if case .image(var image) = model.layers[0].content {
            image.effects = [.init(parameters: .ripple(WSSRippleEffect()), mask: nil, field: nil)]
            model.layers[0].content = .image(image)
        }
        try model.encoded().write(to: helper.item.url)
        let value = WSSEditorDocument(project: try await WSSEditorProjectLoader().load(helper.item))
        defer { value.close() }
        value.select(.effect(value.identity.layers[0].id, value.identity.layers[0].effects[0]))
        XCTAssertNil(value.selectedMaskTarget)
    }

}
