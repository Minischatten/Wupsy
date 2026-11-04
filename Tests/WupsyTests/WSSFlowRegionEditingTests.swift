import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSFlowRegionEditingTests: XCTestCase {
    var fixture: WSSNewVectorEffectTests!
    var doc: WSSEditorDocument { fixture.doc }
    override func setUp() async throws {
        fixture = WSSNewVectorEffectTests()
        try await fixture.setUp()
        try doc.addEffect(.flow)
        await doc.directionCanvas.waitForLoad()
    }
    override func tearDown() async throws {
        try await fixture.tearDown()
        fixture = nil
    }
    func edit() async throws -> WSSVectorFieldEdit {
        try await doc.loadVectorField(XCTUnwrap(doc.selectedVectorFieldTarget))
    }
    func stroke(magnitude: Float = 1, neutralize: Bool = false, erase: Bool = false) async throws {
        let session = doc.directionCanvas
        session.setEnabled(true)
        await session.waitForLoad()
        session.setMagnitude(magnitude)
        session.setDiameter(40)
        session.setOperation(neutralize ? .neutralize : .direction)
        let geometry = try XCTUnwrap(session.geometry)
        let a = geometry.scene(SIMD2(0.2, 0.5))
        let b = geometry.scene(SIMD2(0.8, 0.5))
        XCTAssertTrue(session.begin(a, erase: erase))
        session.append(b)
        await session.waitForFeedback()
        let transient = try XCTUnwrap(session.transientState)
        XCTAssertNotNil(transient.region)
        session.finish(b)
        await session.waitForFinish()
        await session.waitForLoad()
        await doc.waitForPreview()
        let persisted = try await edit()
        XCTAssertEqual(persisted.region, transient.region)
        XCTAssertEqual(persisted.field.vectors, transient.field.vectors)
    }
    func testRegionOnlyCombinedNeutralizeEraseAndSingleUndoRedo() async throws {
        let empty = try await edit()
        XCTAssertTrue(try XCTUnwrap(empty.region).pixels.allSatisfy { $0 == 0 })
        let added = doc.state.workingModel
        try await stroke(magnitude: 0)
        let regionOnly = try await edit()
        XCTAssertEqual(regionOnly.field.vectors, empty.field.vectors)
        XCTAssertEqual(regionOnly.resolved.path, empty.resolved.path)
        XCTAssertTrue(try XCTUnwrap(regionOnly.region).pixels.contains(255))
        let regionModel = doc.state.workingModel
        doc.undoManager.undo()
        await doc.directionCanvas.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, added)
        doc.undoManager.redo()
        await doc.directionCanvas.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, regionModel)
        try await stroke()
        let painted = try await edit()
        let paintModel = doc.state.workingModel
        XCTAssertNotEqual(painted.field.vectors, empty.field.vectors)
        XCTAssertEqual(painted.region, regionOnly.region)
        XCTAssertEqual(painted.resolved.regionID, regionOnly.resolved.regionID)
        try await stroke(neutralize: true)
        let neutral = try await edit()
        let neutralModel = doc.state.workingModel
        XCTAssertEqual(neutral.region, painted.region)
        XCTAssertEqual(neutral.field.coverage, painted.field.coverage)
        doc.undoManager.undo()
        await doc.directionCanvas.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, paintModel)
        doc.undoManager.redo()
        await doc.directionCanvas.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, neutralModel)
        try await stroke(erase: true)
        let erased = try await edit()
        let eraseModel = doc.state.workingModel
        XCTAssertEqual(erased.region, empty.region)
        XCTAssertEqual(erased.field.coverage, empty.field.coverage)
        XCTAssertTrue(erased.field.isNeutral)
        doc.undoManager.undo()
        await doc.directionCanvas.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, neutralModel)
        doc.undoManager.redo()
        await doc.directionCanvas.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, eraseModel)
    }
    func testAtomicValidationAndStaleRollbackNoGenerationLeaks() async throws {
        let source = try await edit()
        let model = doc.state.workingModel
        let count = doc.state.sessionAssets.count
        var invalid = try XCTUnwrap(source.region)
        invalid.pixels[0] = 128
        do {
            _ = try await doc.replaceVectorField(
                source, vectors: source.field.vectors, region: invalid)
            XCTFail()
        } catch {}
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertEqual(doc.state.sessionAssets.count, count)
        var valid = try XCTUnwrap(source.region)
        valid.pixels[0] = 255
        do {
            _ = try await doc.replaceVectorField(source, vectors: Data(), region: valid)
            XCTFail()
        } catch {}
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertEqual(doc.state.sessionAssets.count, count)
        let address = try XCTUnwrap(doc.effectAddress)
        try doc.setParameter(.flowSpeed, at: address, value: 41)
        let modified = doc.state.workingModel
        do {
            _ = try await doc.replaceVectorField(
                source, vectors: source.field.vectors, region: valid)
            XCTFail()
        } catch {}
        XCTAssertEqual(doc.state.workingModel, modified)
        XCTAssertEqual(doc.state.sessionAssets.count, count)
    }
    func testRegionPersistenceRevertRemoveUndoAndResourceIsolation() async throws {
        try await stroke()
        let painted = try await edit()
        let model = doc.state.workingModel
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, model)
        XCTAssertEqual(
            try reopened.document.assetSource(root: reopened.handle.root).flowRegion(
                for: XCTUnwrap(painted.resolved.regionID)), painted.region)
        try await stroke(erase: true)
        doc.revert()
        await doc.directionCanvas.waitForLoad()
        await doc.waitForPreview()
        XCTAssertEqual(doc.state.workingModel, model)
        let target = try XCTUnwrap(doc.currentDeletableSelection)
        try doc.deleteEffect(target)
        doc.undoManager.undo()
        await doc.directionCanvas.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, model)
        let firstID = try XCTUnwrap(painted.resolved.regionID)
        let originalLayer = doc.identity.layers[0].id
        try doc.moveLayer(originalLayer, to: 1)
        XCTAssertEqual(doc.effectAddress?.layerIndex, 1)
        let moved = try await edit()
        XCTAssertEqual(moved.resolved.regionID, firstID)
        XCTAssertEqual(moved.region, painted.region)
        doc.undoManager.undo()
        await doc.directionCanvas.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, model)
        try doc.addEffect(.flow)
        await doc.directionCanvas.waitForLoad()
        let second = try await edit()
        XCTAssertNotEqual(second.resolved.regionID, firstID)
        try await stroke()
        let secondPainted = try await edit()
        let secondPaintedID = try XCTUnwrap(secondPainted.resolved.regionID)
        var assets = try doc.state.workingModel.assetSource(root: doc.project.handle.root)
        assets.sessionAssets = doc.state.sessionAssets
        XCTAssertEqual(try assets.flowRegion(for: firstID), painted.region)
        let layer = doc.identity.layers[0].id
        let effect = doc.identity.layers[0].effects[1]
        try doc.moveEffect(layer, effect: effect, to: 0)
        guard case .image(let image) = doc.state.workingModel.layers[0].content else {
            return XCTFail()
        }
        XCTAssertEqual(image.effects[0].flowRegionID, secondPaintedID)
        XCTAssertEqual(image.effects[1].flowRegionID, firstID)
    }
    func testBatchRetentionFailureRollsBackCatalogAndSharedBudget() throws {
        let before = doc.state.resourceCatalog
        let existing = try XCTUnwrap(doc.state.sessionAssets.values.first)
        let region = try WSSFlowRegion.empty(size: SIMD2(4, 4))
        XCTAssertThrowsError(try WSSEditorAssetGeneration.flowRegion(region, remainingBudget: 0))
        let generation = try WSSEditorAssetGeneration.flowRegion(region, remainingBudget: 1000)
        XCTAssertThrowsError(try doc.retainImageGenerations([generation, existing]))
        XCTAssertEqual(doc.state.resourceCatalog, before)
        XCTAssertNil(doc.state.sessionAssets[generation.path])
    }
    func testRegionPublishFailuresPreserveOldManifestAndAllowRetry() async throws {
        try await stroke()
        var state = doc.state
        let snapshot = try XCTUnwrap(state.beginSave())
        let candidate = try await WSSManifestSaveValidator().prepare(
            snapshot, handle: doc.project.handle)
        let entry = doc.project.handle.entry
        let original = try Data(contentsOf: entry)
        for failure: WSSManifestWriter.Stage in [
            .assetPartialWrite, .assetPublish, .afterAssetPublish, .beforeCommit, .replace,
        ] {
            var reached = false
            XCTAssertThrowsError(
                try WSSManifestWriter.commit(
                    candidate, verifyTarget: {},
                    checkpoint: { stage in
                        if stage == failure {
                            reached = true
                            throw WSSImageImportError.storage
                        }
                    }))
            XCTAssertTrue(reached)
            XCTAssertEqual(try Data(contentsOf: entry), original)
            XCTAssertEqual(doc.state.workingModel, snapshot.model)
            XCTAssertTrue(doc.isDirty)
        }
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let loaded = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(loaded.document, snapshot.model)
    }
    func testMissingRegionRejectsCombinedEditWithoutChangingVectorOrModel() async throws {
        try await stroke()
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let source = try await edit()
        let id = try XCTUnwrap(source.resolved.regionID)
        let path = doc.project.handle.root.appendingPathComponent(id.value)
        // The saved region is still owned by its immutable session generation;
        // a conflicting on-disk source is detected by the disk-basis contract.
        try FileManager.default.removeItem(at: path)
        let before = doc.state.workingModel
        let count = doc.state.sessionAssets.count
        var region = try XCTUnwrap(source.region)
        region.pixels[0] = 255
        do {
            _ = try await doc.replaceVectorField(
                source, vectors: source.field.vectors, region: region)
            XCTFail()
        } catch {}
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertEqual(doc.state.sessionAssets.count, count)
    }

    func testTransformReusePreservesRegionMetricAndRebuildsOnLocalSizeChange() async throws {
        try await stroke()
        let original = doc.state.workingModel
        let resources = doc.previewResources
        var model = original
        guard case .image(var image) = model.layers[0].content else { return XCTFail() }
        image.transform.center = [20, 30]
        image.transform.scale = [2, 0.5]
        image.transform.rotation = 0.7
        model.layers[0].content = .image(image)
        let reused = try XCTUnwrap(resources.updatingTransforms(from: original, to: model))
        XCTAssertTrue(reused.flow === resources.flow)
        image.transform.size = [128, 64]
        model.layers[0].content = .image(image)
        XCTAssertNil(try resources.updatingTransforms(from: original, to: model))
        var assets = try model.assetSource(root: doc.project.handle.root)
        assets.sessionAssets = doc.state.sessionAssets
        let rebuilt = try WSSStaticResources(
            scene: model.scene(), assets: assets, device: resources.device)
        XCTAssertEqual(rebuilt.flow?.regions.first?.size, SIMD2(128, 64))
        XCTAssertNotNil(try WSSEditorLivePreviewTests().frame(rebuilt, time: 0.35, width: 128))
    }

}
