import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSCloudsAuthoringTests: XCTestCase {
    var helper: WSSMaskEditingTests!
    var doc: WSSEditorDocument { helper.doc }
    override func setUp() async throws {
        helper = WSSMaskEditingTests()
        try await helper.setUp()
        doc.select(.layer(doc.identity.layers[0].id))
        try doc.setVisibility(false, layer: doc.identity.layers[1].id)
        await doc.waitForPreview()
        let saved = await doc.save()
        XCTAssertTrue(saved)
        doc.undoManager.removeAllActions()
    }
    override func tearDown() async throws { try await helper.tearDown() }
    func bitmap(_ document: WSSEditorDocument) throws -> WSSMaskAsset {
        let target = try XCTUnwrap(document.selectedMaskTarget)
        let resolved = try document.resolveMaskTarget(target)
        var source = try document.state.workingModel.assetSource(root: document.project.handle.root)
        source.sessionAssets = document.state.sessionAssets
        return try source.mask(for: WSSAssetID(value: resolved.path))
    }
    func frame(_ resources: WSSStaticResources) throws -> Data {
        try WSSEditorLivePreviewTests().frame(resources, time: 0, width: 64)
    }
    func testAddCreatesOneBlackCanonicalMaskWithImmediatePaintAndStableUnpaintedRoundtrip()
        async throws
    {
        let base = try frame(doc.previewResources)
        let assets = Set(doc.state.sessionAssets.keys)
        try doc.addEffect(.clouds)
        let target = try XCTUnwrap(doc.selectedMaskTarget)
        let resolved = try doc.resolveMaskTarget(target)
        try WSSNativeAssets.validatePath(resolved.path)
        XCTAssertEqual(target.slot, .clouds)
        XCTAssertEqual(Set(doc.state.sessionAssets.keys).subtracting(assets), [resolved.path])
        let definition = try XCTUnwrap(resolved.definition)
        let dimensions = try WSSMaskPreparation.blackMaskDimensions(size: [64, 64])
        XCTAssertEqual(definition.width, dimensions.width)
        XCTAssertEqual(definition.height, dimensions.height)
        XCTAssertEqual(definition.uvScale, [1, 1])
        XCTAssertFalse(definition.mipmapped)
        XCTAssertTrue(try bitmap(doc).pixels.allSatisfy { $0 == 0 })
        XCTAssertTrue(doc.maskCanvas.brushEnabled)
        await doc.maskCanvas.waitForLoad()
        XCTAssertEqual(doc.maskCanvas.brushFootprint(at: SIMD2(32, 32)).count, 64)
        await doc.waitForPreview()
        XCTAssertEqual(try frame(doc.previewResources), base)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let project = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        let reopened = helper.makeDocument(project)
        defer { reopened.close() }
        XCTAssertFalse(reopened.isDirty)
        reopened.select(
            .effect(reopened.identity.layers[0].id, reopened.identity.layers[0].effects.last!))
        XCTAssertEqual(
            try reopened.resolveMaskTarget(XCTUnwrap(reopened.selectedMaskTarget)).path,
            resolved.path)
        XCTAssertTrue(try bitmap(reopened).pixels.allSatisfy { $0 == 0 })
        XCTAssertTrue(reopened.maskCanvas.brushEnabled)
        await reopened.maskCanvas.waitForLoad()
        XCTAssertEqual(reopened.maskCanvas.brushFootprint(at: SIMD2(32, 32)).count, 64)
        XCTAssertEqual(try frame(project.resources), base)
        XCTAssertFalse(reopened.isDirty)
    }
    func testFirstAndSecondStrokeUseExistingMaskWithoutCreateUndoAndPaintRoundtrip() async throws {
        let base = try frame(doc.previewResources)
        try doc.addEffect(.clouds)
        let address = try XCTUnwrap(doc.effectAddress)
        try doc.setParameter(.cloudsScale, at: address, value: 32)
        try doc.setParameter(.cloudsDensity, at: address, value: 0.6)
        try doc.setParameter(.cloudsIntensity, at: address, value: 0.8)
        await doc.maskCanvas.waitForLoad()
        let added = doc.state.workingModel
        let original = try doc.resolveMaskTarget(XCTUnwrap(doc.selectedMaskTarget))
        let originalBytes = try XCTUnwrap(doc.state.sessionAssets[original.path]).read()
        let assets = Set(doc.state.sessionAssets.keys)
        let mask = doc.maskCanvas
        mask.setDiameter(12)
        let contour = mask.brushFootprint(at: SIMD2(32, 32))
        XCTAssertTrue(mask.begin(SIMD2(16, 32), erase: false))
        XCTAssertEqual(mask.loaded?.resolved.path, original.path)
        XCTAssertEqual(Set(doc.state.sessionAssets.keys), assets)
        mask.finish(SIMD2(48, 32))
        await mask.waitForFinish()
        await mask.waitForLoad()
        await doc.waitForPreview()
        XCTAssertNil(mask.error)
        // One normal immutable Paint generation; no intermediate Mask Create generation.
        XCTAssertEqual(Set(doc.state.sessionAssets.keys).subtracting(assets).count, 1)
        XCTAssertEqual(try doc.state.sessionAssets[original.path]?.read(), originalBytes)
        XCTAssertEqual(mask.brushFootprint(at: SIMD2(32, 32)), contour)
        let painted = doc.state.workingModel
        let paintedFrame = try frame(doc.previewResources)
        XCTAssertNotEqual(paintedFrame, base)
        XCTAssertEqual(paintedFrame.prefix(8 * 64 * 4), base.prefix(8 * 64 * 4))
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, added)
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, painted)
        await mask.waitForLoad()
        XCTAssertTrue(mask.begin(SIMD2(16, 44), erase: false))
        mask.finish(SIMD2(48, 44))
        await mask.waitForFinish()
        await mask.waitForLoad()
        XCTAssertNil(mask.error)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, painted)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reloaded = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(try frame(reloaded.resources), paintedFrame)
        let reopened = helper.makeDocument(reloaded)
        defer { reopened.close() }
        reopened.select(
            .effect(reopened.identity.layers[0].id, reopened.identity.layers[0].effects.last!))
        XCTAssertTrue(reopened.maskCanvas.brushEnabled)
        XCTAssertTrue(try bitmap(reopened).pixels.contains { $0 > 0 })
        XCTAssertFalse(reopened.isDirty)
    }
    func testAddUndoRedoRetainsOwnedGenerationButFiltersUnreferencedSave() async throws {
        let before = doc.state.workingModel
        let ids = doc.identity
        try doc.addEffect(.clouds)
        let added = doc.state.workingModel
        let resolved = try doc.resolveMaskTarget(XCTUnwrap(doc.selectedMaskTarget))
        let bytes = try XCTUnwrap(doc.state.sessionAssets[resolved.path]).read()
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertEqual(doc.identity, ids)
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.state.workingModel.referencedPaths.contains(resolved.path))
        // History owns staged bytes for Redo; Save must not publish them while unreferenced.
        XCTAssertEqual(try doc.state.sessionAssets[resolved.path]?.read(), bytes)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: doc.project.handle.root.appendingPathComponent(resolved.path).path))
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, added)
        XCTAssertEqual(try bitmap(doc).pixels, Data(repeating: 0, count: 64 * 64))
        XCTAssertFalse(doc.undoManager.canRedo)
    }
    func testFailedAddDoesNotRetainEffectResourceOrUndo() throws {
        let before = doc.state.workingModel
        let ids = doc.identity
        let assets = Set(doc.state.sessionAssets.keys)
        let catalog = doc.state.resourceCatalog
        let revision = doc.state.workingRevision
        // Simulate an external manifest change after opening, on the isolated fixture only.
        var bytes = try Data(contentsOf: doc.project.handle.entry)
        bytes.append(10)
        try bytes.write(to: doc.project.handle.entry)
        XCTAssertThrowsError(try doc.addEffect(.clouds))
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertEqual(doc.identity, ids)
        XCTAssertEqual(doc.state.workingRevision, revision)
        XCTAssertEqual(Set(doc.state.sessionAssets.keys), assets)
        XCTAssertEqual(doc.state.resourceCatalog, catalog)
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertFalse(doc.isDirty)
    }
    func testCanonicalPreparationAndGenerationBudgetFailClosed() throws {
        let bitmap = try WSSMaskPreparation.blackMaskBitmap(size: [3840, 1920])
        XCTAssertEqual(bitmap.width, 3840)
        XCTAssertEqual(bitmap.height, 1920)
        XCTAssertTrue(bitmap.pixels.allSatisfy { $0 == 0 })
        XCTAssertThrowsError(try WSSMaskPreparation.prepareGeneration(bitmap, remainingBudget: 0))
        XCTAssertThrowsError(try WSSMaskPreparation.blackMaskBitmap(size: [.nan, 1920]))
        let large = try WSSMaskPreparation.blackMaskDimensions(size: [12000, 12000])
        XCTAssertLessThanOrEqual(large.width, 8192)
        XCTAssertLessThanOrEqual(large.height, 8192)
        XCTAssertLessThanOrEqual(large.width * large.height, 32 * 1024 * 1024)
    }
}
