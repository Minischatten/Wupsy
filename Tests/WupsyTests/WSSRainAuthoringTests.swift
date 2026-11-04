import AppKit
import MetalKit
import XCTest

@testable import Wupsy

@MainActor final class WSSRainAuthoringTests: XCTestCase {
    var helper: WSSMaskEditingTests!
    var doc: WSSEditorDocument { helper.doc }
    override func setUp() async throws {
        helper = WSSMaskEditingTests()
        try await helper.setUp()
    }
    override func tearDown() async throws { try await helper.tearDown() }
    func add() throws -> WSSLayerID {
        try doc.addRain()
        return try XCTUnwrap(doc.selection?.layer)
    }
    func bitmap() async throws -> WSSMaskBitmap {
        let target = try XCTUnwrap(doc.selectedMaskTarget)
        return try await WSSMaskPreparation().read(
            doc.resolveMaskTarget(target),
            model: doc.state.workingModel, handle: doc.project.handle,
            generations: doc.state.sessionAssets, basis: doc.state.diskBasis)
    }
    func testAddDefaultsIdentitySelectionSingleUndoAndPreview() async throws {
        let before = doc.state.workingModel
        let ids = doc.identity
        let id = try add()
        let added = doc.state.workingModel
        let rain = try XCTUnwrap(doc.rainLayer(id))
        XCTAssertEqual(doc.identity.layers.last?.id, id)
        XCTAssertEqual(doc.selection, .layer(id))
        XCTAssertTrue(doc.identity.layers.last!.effects.isEmpty)
        XCTAssertTrue(rain.visible)
        XCTAssertNil(rain.mask)
        XCTAssertEqual(rain.region.x, 0)
        XCTAssertEqual(rain.region.y, 0)
        XCTAssertEqual(rain.region.width, Float(added.canvas.width))
        XCTAssertEqual(rain.region.height, Float(added.canvas.height))
        XCTAssertEqual(rain.rain.effect.profiles, WSSRainEffect.authoredProfiles)
        var expected = WSSRainEffect()
        expected.density = 150
        expected.profiles = [
            .init(length: 24, width: 1.2), .init(length: 40, width: 1.6),
            .init(length: 56, width: 2.0),
        ]
        XCTAssertEqual(rain.rain.effect, expected)
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(added.referencedPaths, before.referencedPaths)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        XCTAssertNotNil(doc.previewResources.rain?.layers[added.layers.count - 1])
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertEqual(doc.identity, ids)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, added)
        XCTAssertEqual(doc.identity.layers.last?.id, id)
    }
    func testNewDefaultsKeepSmallCanvasProtectionAndFailClosed() throws {
        for dimension in [32, 16] {
            var json =
                try JSONSerialization.jsonObject(with: doc.state.workingModel.encoded())
                as! [String: Any]
            json["canvas"] = ["width": dimension, "height": dimension]
            let model = try WSSSceneDocumentV1.decode(
                data: JSONSerialization.data(withJSONObject: json))
            try doc.mutate(model, name: "Small canvas")
            if dimension == 32 {
                let id = try add()
                XCTAssertEqual(doc.rainLayer(id)?.rain.effect.density, 976.5625)
                try doc.state.workingModel.scene().validate()
                doc.undoManager.undo()
            } else {
                let before = doc.state.workingModel
                XCTAssertThrowsError(try doc.addRain())
                XCTAssertEqual(doc.state.workingModel, before)
            }
        }
    }
    func testParametersSlantProfilesAndGroupedUndo() throws {
        let id = try add()
        let before = doc.state.workingModel
        doc.undoManager.removeAllActions()
        doc.beginRainSlider(.density, layer: id)
        for value: Float in [110, 120, 130] {
            try doc.setRain(.density, value: value, layer: id, undo: false)
        }
        doc.endRainSlider()
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        for (parameter, value): (WSSRainParameter, Float) in [
            (.density, 500), (.speed, 5500), (.slant, -30),
            (.length(0), 25), (.width(0), 2), (.length(1), 45), (.width(1), 3),
            (.length(2), 90), (.width(2), 4),
        ] {
            let original = doc.state.workingModel
            try doc.setRain(parameter, value: value, layer: id)
            XCTAssertEqual(parameter.value(try XCTUnwrap(doc.rainLayer(id)).rain.effect), value)
            doc.undoManager.undo()
            XCTAssertEqual(doc.state.workingModel, original)
            doc.undoManager.redo()
        }
        XCTAssertEqual(doc.rainLayer(id)?.rain.effect.direction, 330)
        try doc.setRain(.slant, value: 30, layer: id)
        XCTAssertEqual(doc.rainLayer(id)?.rain.effect.direction, 30)
        for (p, v): (WSSRainParameter, Float) in [
            (.density, 2001), (.speed, .nan), (.slant, 181), (.width(1), 9), (.length(0), 385),
        ] {
            let original = doc.state.workingModel
            XCTAssertThrowsError(try doc.setRain(p, value: v, layer: id))
            XCTAssertEqual(doc.state.workingModel, original)
        }
    }
    func testSelectionAndLazyBrushNeverMaterializeOrDirty() throws {
        let id = try add()
        let before = doc.state.workingModel
        let revision = doc.state.workingRevision
        let count = doc.state.sessionAssets.count
        doc.select(.layer(doc.identity.layers[0].id))
        doc.select(.layer(id))
        doc.maskCanvas.setBrush(false)
        doc.maskCanvas.setBrush(true)
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertEqual(doc.state.workingRevision, revision)
        XCTAssertEqual(doc.state.sessionAssets.count, count)
        XCTAssertNil(doc.selectedMaskTarget)
        XCTAssertNil(doc.maskManagementTarget?.effectID)
        XCTAssertFalse(doc.maskCanvas.begin(SIMD2(32, 32), erase: true))
        XCTAssertEqual(doc.state.workingModel, before)
    }
    func testLazyPaintFillEraseClearFullAreaCOWUndoAndCancel() async throws {
        _ = try add()
        let before = doc.state.workingModel
        let session = doc.maskCanvas
        session.setDiameter(8)
        let point = SIMD2<Float>(32, 32)
        XCTAssertTrue(session.begin(point, erase: false))
        session.finish(point)
        await session.waitForFinish()
        XCTAssertNotNil(doc.selectedMaskTarget)
        var scalar = try await bitmap()
        XCTAssertTrue(scalar.pixels.contains(where: { $0 > 0 }))
        XCTAssertTrue(scalar.pixels.contains(0))
        let painted = doc.state.workingModel
        doc.undoManager.undo()  // stroke
        scalar = try await bitmap()
        XCTAssertTrue(scalar.pixels.allSatisfy { $0 == 0 })
        doc.undoManager.undo()  // lazy create
        XCTAssertEqual(doc.state.workingModel, before)
        doc.undoManager.redo()
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, painted)
        await session.waitForLoad()
        XCTAssertTrue(session.begin(point, erase: false))
        XCTAssertTrue(session.escape())
        XCTAssertEqual(doc.state.workingModel, painted)
        let old = try doc.resolveMaskTarget(XCTUnwrap(doc.selectedMaskTarget))
        try await doc.manageMask(.fill)
        scalar = try await bitmap()
        XCTAssertTrue(scalar.pixels.allSatisfy { $0 == 255 })
        XCTAssertNotEqual(
            try doc.resolveMaskTarget(XCTUnwrap(doc.selectedMaskTarget)).path, old.path)
        await session.waitForLoad()
        XCTAssertTrue(session.begin(point, erase: true))
        session.finish(point)
        await session.waitForFinish()
        scalar = try await bitmap()
        XCTAssertTrue(scalar.pixels.contains(where: { $0 < 255 }))
        try await doc.manageMask(.clear)
        scalar = try await bitmap()
        XCTAssertTrue(scalar.pixels.allSatisfy { $0 == 0 })
        try await doc.manageMask(.remove)
        XCTAssertNil(doc.selectedMaskTarget)
        XCTAssertEqual(doc.state.workingModel, before)
        doc.undoManager.undo()
        XCTAssertNotNil(doc.selectedMaskTarget)
    }
    func testMaskSaveReloadSaveAsRevertAndSharedResources() async throws {
        let id = try add()
        try await doc.manageMask(.create)
        try await doc.manageMask(.fill)
        let model = doc.state.workingModel
        let resolved = try doc.resolveMaskTarget(XCTUnwrap(doc.selectedMaskTarget))
        XCTAssertTrue(model.referencedPaths.contains(resolved.path))
        XCTAssertTrue(
            try model.assetSource(root: doc.project.handle.root).imageDefinitions.keys.contains(
                WSSAssetID(value: resolved.path)))
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(doc.isDirty)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, model)
        XCTAssertNotNil(reopened.resources.rain)
        let snapshot = try WSSSaveAsSnapshot(
            document: model, state: doc.state, source: doc.project.handle, name: "Rain copy")
        let copy = try await helper.store.saveWSSAs(snapshot)
        XCTAssertEqual(copy.project.document, snapshot.model)
        XCTAssertEqual(Set(copy.project.diskBasis.assets.keys), model.referencedPaths)
        try doc.setRain(.speed, value: 1200, layer: id)
        doc.revert()
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertFalse(doc.isDirty)
    }
    func testStaleTargetAndLayerReorderVisibilityDeleteUndo() async throws {
        let id = try add()
        try await doc.manageMask(.create)
        var stroke = try await doc.beginMaskStroke(
            target: XCTUnwrap(doc.selectedMaskTarget),
            settings: .init(diameter: 3, opacity: 1, mode: .paint), start: .zero)
        let candidate = try XCTUnwrap(stroke.finish())
        try doc.moveLayer(id, to: 0)
        XCTAssertEqual(doc.identity.layers.first?.id, id)
        do {
            try await doc.applyMaskStroke(candidate)
            XCTFail("stale stroke accepted")
        } catch {}
        doc.undoManager.undo()
        XCTAssertEqual(doc.identity.layers.last?.id, id)
        try doc.setVisibility(false, layer: id)
        XCTAssertEqual(doc.rainLayer(id)?.visible, false)
        doc.undoManager.undo()
        XCTAssertEqual(doc.rainLayer(id)?.visible, true)
        try doc.deleteLayer(id)
        XCTAssertNil(doc.rainLayer(id))
        doc.undoManager.undo()
        XCTAssertNotNil(doc.rainLayer(id))
        _ = try add()
        XCTAssertEqual(
            try doc.state.workingModel.scene().layers.filter {
                if case .rain = $0 { return true }
                return false
            }.count, 2)
    }
    func testRainRegionGeometryMatchesTopLeftScalarUV() throws {
        _ = try add()
        let target = try XCTUnwrap(doc.maskManagementTarget)
        var model = doc.state.workingModel
        guard case .rain(var rain) = model.layers.last!.content else { return XCTFail() }
        rain.region = .init(x: 10, y: 20, width: 200, height: 100)
        model.layers[model.layers.count - 1].content = .rain(rain)
        try doc.mutate(model, name: "Region")
        let context = try doc.snapshot.maskContext(target)
        let geometry = WSSMaskCanvasGeometry(transform: context.transform, width: 200, height: 100)
        XCTAssertEqual(geometry.texel(SIMD2(10, 120)), SIMD2(-0.5, -0.5))
        XCTAssertEqual(geometry.texel(SIMD2(210, 20)), SIMD2(199.5, 99.5))
        XCTAssertNil(geometry.texel(SIMD2(9, 50)))
        for p: SIMD2<Double> in [.zero, SIMD2(100, 50), SIMD2(199, 99)] {
            let roundtrip = try XCTUnwrap(geometry.texel(geometry.scene(p)))
            XCTAssertEqual(roundtrip.x, p.x, accuracy: 0.0001)
            XCTAssertEqual(roundtrip.y, p.y, accuracy: 0.0001)
        }
    }
    func testRealPopulationBudgetRejectsBeforeModelOrIdentityChanges() throws {
        var json =
            try JSONSerialization.jsonObject(with: doc.state.workingModel.encoded())
            as! [String: Any]
        json["canvas"] = ["width": 8192, "height": 4096]
        let model = try WSSSceneDocumentV1.decode(
            data: JSONSerialization.data(withJSONObject: json))
        try doc.mutate(model, name: "Canvas")
        let first = try add()
        XCTAssertEqual(doc.rainLayer(first)?.rain.effect.density, 150)
        // At the new default, one maximum-canvas layer fits; a second exceeds the total budget.
        let before = doc.state.workingModel
        let ids = doc.identity
        let revision = doc.state.workingRevision
        XCTAssertThrowsError(try doc.setRain(.density, value: 2000, layer: first))
        XCTAssertThrowsError(try doc.setRain(.slant, value: 45, layer: first))
        XCTAssertThrowsError(try doc.addRain())
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertEqual(doc.identity, ids)
        XCTAssertEqual(doc.state.workingRevision, revision)
    }
    func testLegacyOpenSaveAndDisplayNeverConvertProfilesOrAngles() async throws {
        let id = try add()
        var model = doc.state.workingModel
        guard case .rain(var rain) = model.layers.last!.content else { return XCTFail() }
        var effect = rain.rain.effect
        effect.profiles = nil
        effect.direction = 233.33333
        effect.speed = 5500
        effect.density = 450
        rain.rain = .init(effect: effect)
        model.layers[model.layers.count - 1].content = .rain(rain)
        try doc.mutate(model, name: "Legacy")
        let saved = await doc.save()
        XCTAssertTrue(saved)
        doc.undoManager.removeAllActions()
        let bytes = try Data(contentsOf: doc.project.handle.entry)
        doc.select(.layer(doc.identity.layers[0].id))
        doc.select(.layer(id))
        for parameter in WSSRainParameter.allCases { _ = parameter.value(effect) }
        try doc.setRain(.slant, value: WSSRainParameter.slant.value(effect), layer: id)
        XCTAssertFalse(doc.isDirty)
        XCTAssertNil(doc.rainLayer(id)?.rain.effect.profiles)
        let unchanged = await doc.save()
        XCTAssertTrue(unchanged)
        XCTAssertEqual(try Data(contentsOf: doc.project.handle.entry), bytes)
        try doc.setRain(.speed, value: 5600, layer: id)
        XCTAssertNil(doc.rainLayer(id)?.rain.effect.profiles)
        doc.undoManager.undo()
        XCTAssertFalse(doc.isDirty)
        try doc.setRain(.length(0), value: 20, layer: id)
        XCTAssertNotNil(doc.rainLayer(id)?.rain.effect.profiles)
        doc.undoManager.undo()
        XCTAssertFalse(doc.isDirty)
        XCTAssertNil(doc.rainLayer(id)?.rain.effect.profiles)
    }

}
