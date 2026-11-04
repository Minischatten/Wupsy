import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSFlowAuthoringTests: XCTestCase {
    var fixture: WSSDirectionCanvasTests!
    var doc: WSSEditorDocument { fixture.doc }
    override func setUp() async throws {
        fixture = WSSDirectionCanvasTests()
        try await fixture.setUp()
    }
    override func tearDown() async throws {
        try await fixture.tearDown()
        fixture = nil
    }
    func installFlow() async throws -> Data {
        doc.close()
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixture.helper.helper.project.document.encoded())
                as? [String: Any])
        var layers = json["layers"] as! [[String: Any]]
        layers[0]["effects"] = [
            [
                "type": "flow", "speed": 30, "strength": 18, "edgeProtectionPixels": 72,
                "flowMap": [
                    "format": WSSVectorFieldAsset.fileFormat, "version": 1,
                    "asset": "assets/a.wssvf",
                ],
            ]
        ]
        json["layers"] = layers
        let bytes = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
        try bytes.write(to: fixture.helper.helper.item.url)
        fixture.helper.helper.project = try await WSSEditorProjectLoader().load(
            fixture.helper.helper.item)
        fixture.helper.doc = fixture.helper.makeDocument()
        _ = try fixture.helper.select(0)
        return bytes
    }
    func testFlowCleanOpenNoOpThenSaveReopenAndRevert() async throws {
        let original = try await installFlow()
        let file = doc.project.handle.entry
        let model = doc.state.workingModel
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
        let session = doc.directionCanvas
        session.setEnabled(true)
        await session.waitForLoad()
        let point = try XCTUnwrap(session.geometry).scene(SIMD2(0.5, 0.5))
        XCTAssertTrue(session.begin(point, erase: false))
        session.finish(point)
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertFalse(doc.isDirty)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original)
        let fieldBytes = try Data(
            contentsOf: doc.project.handle.root.appendingPathComponent("assets/a.wssvf"))
        try doc.setParameter(.flowSpeed, at: XCTUnwrap(doc.effectAddress), value: 31)
        XCTAssertTrue(doc.isDirty)
        doc.revert()
        await session.waitForLoad()
        await doc.waitForPreview()
        XCTAssertEqual(doc.state.workingModel, model)
        try doc.setParameter(.flowEdgeProtection, at: XCTUnwrap(doc.effectAddress), value: 72.125)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let json = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertTrue(json.contains("edgeProtectionPixels"))
        XCTAssertFalse(json.contains("surfaceAdvection"))
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, doc.state.workingModel)
        XCTAssertEqual(
            try Data(contentsOf: doc.project.handle.root.appendingPathComponent("assets/a.wssvf")),
            fieldBytes)
        let copy = try await fixture.helper.store.saveWSSAs(
            .init(
                document: doc.state.workingModel, state: doc.state, source: doc.project.handle,
                name: "Canonical Flow"))
        var expectedCopy = doc.state.workingModel
        expectedCopy.title = "Canonical Flow"
        XCTAssertEqual(copy.project.document, expectedCopy)
    }
    func testParameterIndependenceSliderPresentationAndUndoWithoutFieldGenerations() async throws {
        _ = try await installFlow()
        let address = try XCTUnwrap(doc.effectAddress)
        let before = doc.state.workingModel
        let range = WSSEditorParameter.flowEdgeProtection.sliderRange(in: before, at: address)
        XCTAssertEqual(range.upperBound, 63.5)
        XCTAssertEqual(WSSEditorParameter.flowEdgeProtection.value(in: before, at: address), 72)
        XCTAssertEqual(doc.state.workingRevision, 0)
        try doc.setParameter(.flowStrength, at: address, value: 22)
        XCTAssertEqual(
            WSSEditorParameter.flowEdgeProtection.value(in: doc.state.workingModel, at: address), 72
        )
        try doc.setParameter(.flowEdgeProtection, at: address, value: 4096)
        XCTAssertEqual(
            WSSEditorParameter.flowStrength.value(in: doc.state.workingModel, at: address), 22)
        try doc.setParameter(.flowSpeed, at: address, value: 128)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        let after = doc.state.workingModel
        for _ in 0..<3 { doc.undoManager.undo() }
        XCTAssertEqual(doc.state.workingModel, before)
        for _ in 0..<3 { doc.undoManager.redo() }
        XCTAssertEqual(doc.state.workingModel, after)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
    }
    func bytes(_ area: WSSDirectionArea?) throws -> Data {
        try XCTUnwrap(try XCTUnwrap(area).image.dataProvider?.data) as Data
    }
    func testAutomaticBrushAddAndStrokeCancelKeepSelectionEditable() async throws {
        let before = doc.state.workingModel
        try doc.addEffect(.flow)
        let session = doc.directionCanvas
        XCTAssertTrue(session.brushEnabled)
        await session.waitForLoad()
        let added = doc.state.workingModel
        XCTAssertNotEqual(before, added)
        let initial = try bytes(session.area)
        XCTAssertTrue(initial.allSatisfy { $0 == 0 })
        let geometry = try XCTUnwrap(session.geometry)
        session.setDiameter(40)
        session.setOperation(.neutralize)
        let a = geometry.scene(SIMD2(0.2, 0.5))
        let b = geometry.scene(SIMD2(0.8, 0.5))
        XCTAssertTrue(session.begin(a, erase: false))
        session.append(b)
        await session.waitForFeedback()
        XCTAssertNotEqual(try bytes(session.area), initial)
        XCTAssertEqual(doc.state.workingModel, added)
        XCTAssertEqual(doc.state.sessionAssets.count, 2)
        XCTAssertTrue(session.escape())
        XCTAssertEqual(try bytes(session.area), initial)
        XCTAssertFalse(session.escape())
        XCTAssertTrue(session.brushEnabled)
        XCTAssertEqual(doc.state.workingModel, added)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, added)
        session.setEnabled(true)
        await session.waitForLoad()
        session.setOperation(.direction)
        XCTAssertTrue(session.begin(a, erase: false))
        session.finish(b)
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertNotEqual(try bytes(session.area), initial)
        let painted = doc.state.workingModel
        session.setOperation(.neutralize)
        XCTAssertTrue(session.begin(a, erase: false))
        session.append(b)
        await session.waitForFeedback()
        XCTAssertNotEqual(try bytes(session.area), initial)
        session.finish(b)
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertNotEqual(doc.state.workingModel, painted)
        doc.undoManager.undo()
        await session.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, painted)
    }
    func testMagnitudeAreaIgnoresCoverageAndCapsLongVectors() throws {
        let zero = try WSSVectorFieldPaintTests().field(width: 2, height: 2)
        let strong = try WSSVectorFieldPaintTests().field(
            width: 2, height: 2, vector: SIMD2(1, 1), coverage: true)
        let area = try WSSDirectionArea.make(strong)
        let data = try bytes(area)
        // Coverage at this texel is zero; magnitude is still present.
        XCTAssertGreaterThan(data[3], 0)
        XCTAssertLessThanOrEqual(data[3], 90)
        XCTAssertTrue(try bytes(WSSDirectionArea.make(zero)).allSatisfy { $0 == 0 })
        let touched = try WSSDirectionArea.make(zero, touches: [255, 0, 0, 0])
        XCTAssertGreaterThan(try bytes(touched)[3], 0)
        XCTAssertEqual(try bytes(touched)[7], 0)
    }
    func testAreaOverlayRendersAtLocalTopAndFollowsRotationAndZoom() async throws {
        var model = doc.state.workingModel
        guard case .image(var image) = model.layers[0].content else { return XCTFail() }
        image.effects = []
        image.transform.center = [128, 128]
        image.transform.size = [128, 128]
        model.layers[0].content = .image(image)
        try await fixture.reload(model)
        doc.select(.layer(doc.identity.layers[0].id))
        try doc.addEffect(.flow)
        let session = doc.directionCanvas
        await session.waitForLoad()
        session.setDiameter(12)
        let geometry = try XCTUnwrap(session.geometry)
        XCTAssertTrue(session.begin(geometry.scene(SIMD2(0.25, 0.25)), erase: false))
        session.finish(geometry.scene(SIMD2(0.75, 0.25)))
        await session.waitForFinish()
        await session.waitForLoad()
        for rotation: Float in [0, .pi / 2, 0.7] {
            var updated = doc.state.workingModel
            guard case .image(var layer) = updated.layers[0].content else { return XCTFail() }
            layer.transform.rotation = rotation
            layer.transform.scale = [0.8, 1.2]
            updated.layers[0].content = .image(layer)
            try doc.mutate(updated, name: "Transform overlay test")
            await session.waitForLoad()
            let current = try XCTUnwrap(session.geometry)
            for zoom: CGFloat in [1, 2] {
                let overlay = WSSDirectionCanvasOverlay(
                    frame: NSRect(x: 0, y: 0, width: 512, height: 512))
                overlay.session = session
                overlay.sceneSize = CGSize(width: 256, height: 256)
                overlay.zoom = zoom
                let bitmap = try XCTUnwrap(
                    overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
                overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
                func alpha(_ uv: SIMD2<Double>) throws -> CGFloat {
                    let point = WSSCanvasGeometry.viewportPoint(
                        current.scene(uv), origin: .zero, zoom: zoom, height: 256)
                    return try XCTUnwrap(
                        bitmap.colorAt(
                            x: Int(point.x * CGFloat(bitmap.pixelsWide) / 512),
                            y: Int(point.y * CGFloat(bitmap.pixelsHigh) / 512))
                    ).alphaComponent
                }
                XCTAssertGreaterThan(
                    try alpha(SIMD2(0.5, 0.25)), 0.1, "rotation \(rotation), zoom \(zoom)")
                XCTAssertLessThan(try alpha(SIMD2(0.5, 0.75)), 0.01)
            }
        }
    }
    func testNativeFlowFloatRoundtripAndEdgeProtectionValidation() throws {
        for strength: Float in [0, .leastNonzeroMagnitude, 0.000000001, 0.1, 12, 16, 18, 128] {
            let flow = WSSFlowEffect(
                flowMap: WSSAssetID(value: "assets/a.wssvf"),
                speed: 30, strength: strength, edgeProtectionPixels: 4 * strength)
            let field = try JSONDecoder().decode(
                WSSSceneDocumentV1.Effect.FlowMap.self,
                from: JSONSerialization.data(withJSONObject: [
                    "format": WSSVectorFieldAsset.fileFormat,
                    "version": 1, "asset": "assets/a.wssvf",
                ]))
            let original = WSSSceneDocumentV1.Effect(
                parameters: .flow(flow), mask: nil, field: field)
            let decoded = try JSONDecoder().decode(
                WSSSceneDocumentV1.Effect.self,
                from: JSONEncoder().encode(original))
            XCTAssertEqual(decoded, original)
            guard case .flow(let actual) = decoded.native else { return XCTFail() }
            XCTAssertEqual(actual.strength.bitPattern, strength.bitPattern)
            XCTAssertEqual(actual.edgeProtectionPixels.bitPattern, (4 * strength).bitPattern)
        }
        for invalid: Float in [-1, .nan, .infinity, 4097] {
            var flow = WSSFlowEffect(flowMap: WSSAssetID(value: "a"))
            flow.edgeProtectionPixels = invalid
            XCTAssertThrowsError(try flow.validate())
        }
    }

}
