import XCTest

@testable import Wupsy

@MainActor final class WSSCloudsMaskContractTests: XCTestCase {
    func testRawCloudsDefinitionRetainsLegacyNilFullImageContract() throws {
        let fresh = try WSSAddableEffect.clouds.definition()
        let fullImage = WSSSceneDocumentV1.Effect(
            parameters: .clouds(WSSCloudsEffect()), mask: nil, field: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(fresh), try encoder.encode(fullImage))
        XCTAssertNil(fresh.maskPath)
        XCTAssertNil(
            try JSONDecoder().decode(WSSSceneDocumentV1.Effect.self, from: encoder.encode(fresh))
                .maskPath)
        let helper = WSSCloudsTests()
        let effect = WSSCloudsEffect(velocity: SIMD2(9, 3), scale: 32, intensity: 0.8, density: 0.6)
        let full = try helper.render(helper.resources(effect)).0
        var masked = effect
        masked.mask = WSSImageMask(asset: helper.mask)
        XCTAssertEqual(full, try helper.render(helper.resources(masked, maskValue: 255)).0)
        XCTAssertNotEqual(full, try helper.render(helper.resources(nil)).0)
        XCTAssertEqual(
            try helper.render(helper.resources(masked, maskValue: 0)).0,
            try helper.render(helper.resources(nil)).0)
    }
    func testCurrentCloudsSaveReloadPaintAndRemovePreserveExistingContracts() async throws {
        let helper = WSSMaskEditingTests()
        try await helper.setUp()
        addTeardownBlock { @MainActor in try await helper.tearDown() }
        let doc = try XCTUnwrap(helper.doc)
        doc.select(.layer(doc.identity.layers[0].id))
        try doc.setVisibility(false, layer: doc.identity.layers[1].id)
        await doc.waitForPreview()
        let base = doc.previewResources
        try doc.addEffect(.clouds)
        // Explicit removal is the supported authoring route to Full Image.
        try await doc.manageMask(.remove)
        let address = try XCTUnwrap(doc.effectAddress)
        try doc.setParameter(.cloudsScale, at: address, value: 32)
        try doc.setParameter(.cloudsDensity, at: address, value: 0.6)
        try doc.setParameter(.cloudsIntensity, at: address, value: 0.8)
        let selection = try XCTUnwrap(doc.selection)
        await doc.waitForPreview()
        let frame = WSSEditorLivePreviewTests()
        let fullFrame = try frame.frame(doc.previewResources, time: 0, width: 64)
        XCTAssertNil(doc.selectedMaskTarget)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let loaded = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        let reopened = WSSEditorDocument(project: loaded)
        defer { reopened.close() }
        XCTAssertFalse(reopened.isDirty)
        let stage = try XCTUnwrap(loaded.resources.effectPlans[0]?.stages.last)
        guard case .clouds(let persisted) = stage.declaredEffect else {
            return XCTFail("Missing Clouds stage")
        }
        XCTAssertNil(persisted.mask)
        XCTAssertNil(stage.binding.mask)
        XCTAssertEqual(fullFrame, try frame.frame(loaded.resources, time: 0, width: 64))
        let mask = doc.maskCanvas
        mask.setDiameter(12)
        XCTAssertTrue(mask.begin(SIMD2(16, 32), erase: false))
        mask.finish(SIMD2(48, 32))
        await mask.waitForFinish()
        await mask.waitForLoad()
        await doc.waitForPreview()
        XCTAssertNil(mask.error)
        let paintedFrame = try frame.frame(doc.previewResources, time: 0, width: 64)
        let baseFrame = try frame.frame(base, time: 0, width: 64)
        XCTAssertNotEqual(fullFrame, baseFrame)
        XCTAssertNotEqual(paintedFrame, fullFrame)
        XCTAssertEqual(paintedFrame.prefix(8 * 64 * 4), baseFrame.prefix(8 * 64 * 4))
        XCTAssertTrue(try XCTUnwrap(mask.pixels).contains { $0 > 0 })
        let paintedSave = await doc.save()
        XCTAssertTrue(paintedSave)
        let paintedReload = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(paintedFrame, try frame.frame(paintedReload.resources, time: 0, width: 64))
        doc.select(selection)
        try await doc.manageMask(.remove)
        await doc.waitForPreview()
        XCTAssertEqual(fullFrame, try frame.frame(doc.previewResources, time: 0, width: 64))
    }
}
