import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSDirectionCanvasTests: XCTestCase {
    var helper: WSSVectorFieldEditingTests!
    var doc: WSSEditorDocument { helper.doc }
    var session: WSSDirectionCanvasSession { doc.directionCanvas }
    override func setUp() async throws {
        helper = WSSVectorFieldEditingTests()
        try await helper.setUp()
        _ = try helper.select()
    }
    override func tearDown() async throws {
        try await helper.tearDown()
        helper = nil
    }
    func enable() async throws {
        session.setEnabled(true)
        await session.waitForLoad()
        XCTAssertNotNil(session.loaded)
        XCTAssertTrue(session.brushEnabled)
        session.updateQueries([SIMD2(0.125, 0.5), SIMD2(0.375, 0.5), SIMD2(0.625, 0.5)])
    }
    func scene(_ uv: SIMD2<Double>) throws -> SIMD2<Float> {
        try XCTUnwrap(session.geometry).scene(uv)
    }
    func draw(neutralize: Bool = false) async throws {
        try await enable()
        let start = try scene(SIMD2(0.05, 0.5))
        let end = try scene(SIMD2(0.4, 0.5))
        XCTAssertTrue(session.begin(start, erase: neutralize))
        session.append(end)
        session.finish(end)
        await session.waitForFinish()
        await session.waitForLoad()
        await doc.waitForPreview()
    }
    func generationField() throws -> WSSVectorFieldAsset {
        let path = try helper.fields(doc.state.workingModel)[2]
        return try WSSVectorFieldAsset.decodeNative(XCTUnwrap(doc.state.sessionAssets[path]).read())
    }
    func testBoundedCaptureAndOverlayQueriesRejectOverflowWithoutMutation() async throws {
        try await enable()
        let initial = doc.state.workingModel
        session.updateQueries(
            [SIMD2(.nan, 0.5), SIMD2(-1, 0.5)]
                + Array(
                    repeating: SIMD2(0.5, 0.5), count: WSSDirectionSampling.maximumSamples + 10))
        XCTAssertEqual(session.samples.count, WSSDirectionSampling.maximumSamples - 2)
        XCTAssertTrue(session.begin(try scene(SIMD2(0.1, 0.5)), erase: false))
        // No suspension: exercise bounded native capture without launching thousands of jobs.
        for index in 1...WSSVectorFieldPaint.maximumPoints {
            session.append(try scene(SIMD2(index.isMultiple(of: 2) ? 0.2 : 0.3, 0.5)))
        }
        XCTAssertFalse(session.isDrawing)
        XCTAssertEqual(session.pointCount, 0)
        XCTAssertNotNil(session.error)
        await session.waitForFeedback()
        XCTAssertEqual(doc.state.workingModel, initial)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertFalse(doc.isDirty)
    }
    func reload(_ model: WSSSceneDocumentV1) async throws {
        doc.close()
        try model.encoded().write(to: helper.helper.item.url)
        helper.helper.project = try await WSSEditorProjectLoader().load(helper.helper.item)
        helper.doc = helper.makeDocument()
    }
    func testActionEligibilityAllEffectsNativeAndLegacyWithoutPublication() async throws {
        XCTAssertEqual(doc.directionAvailability, .native)
        XCTAssertTrue(session.brushEnabled)
        XCTAssertFalse(session.requiresExplicitActivation)
        let initial = doc.state.workingModel
        let files = try helper.helper.helper.snapshot()
        try await enable()
        XCTAssertEqual(doc.state.workingModel, initial)
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(try helper.helper.helper.snapshot(), files)
        for type in ["flow"] {
            var model = helper.helper.project.document
            guard case .image(var image) = model.layers[0].content else { return XCTFail() }
            image.effects = [try helper.effect(type, "a")]
            model.layers[0].content = .image(image)
            try await reload(model)
            _ = try helper.select(0)
            XCTAssertEqual(doc.directionAvailability, .native)
            try await enable()
            let start = try scene(SIMD2(0.05, 0.5))
            let end = try scene(SIMD2(0.4, 0.5))
            XCTAssertTrue(session.begin(start, erase: false))
            session.finish(end)
            await session.waitForFinish()
            await session.waitForLoad()
            guard case .image(let after) = doc.state.workingModel.layers[0].content else {
                return XCTFail()
            }
            XCTAssertNotEqual(after.effects[0].fieldDefinition, image.effects[0].fieldDefinition)
        }
        session.setEnabled(false)
        for kind: WSSAddableEffect in [.ripple, .clouds] {
            try doc.addEffect(kind)
            XCTAssertEqual(doc.directionAvailability, .unavailable)
            session.setEnabled(true)
            XCTAssertFalse(session.brushEnabled)
        }
        let fixture = WSSEditorLivePreviewTests()
        try await fixture.setUp()
        defer { try? fixture.helper.tearDownWithError() }
        let png = WSSEditorDocument(project: try await fixture.project("WSS-Flow-v1"))
        defer { png.close() }
        let ids = png.identity.layers[0]
        png.select(.effect(ids.id, ids.effects[0]))
        XCTAssertEqual(png.directionAvailability, .legacy)
        png.directionCanvas.setEnabled(true)
        await png.directionCanvas.waitForLoad()
        XCTAssertTrue(png.directionCanvas.brushEnabled)
        XCTAssertNotNil(png.directionCanvas.loaded)
        XCTAssertTrue(png.state.sessionAssets.isEmpty)
        XCTAssertFalse(png.isDirty)
    }
    func testLiveSparseFeedbackWithoutWorkingMutationOrPreviewUntilMouseUp() async throws {
        try await enable()
        let original = doc.state.workingModel
        let resources = doc.previewResources
        let samples = session.samples
        let start = try scene(SIMD2(0.05, 0.5))
        let end = try scene(SIMD2(0.4, 0.5))
        XCTAssertTrue(session.begin(start, erase: false))
        session.append(end)
        await session.waitForFeedback()
        XCTAssertNotEqual(session.samples, samples)
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertFalse(doc.isDirty)
        XCTAssertTrue(doc.previewResources === resources)
        XCTAssertFalse(doc.canSave)
        XCTAssertFalse(doc.canSaveAs)
        session.finish(end)
        XCTAssertTrue(session.finalizing)
        XCTAssertTrue(doc.interactionLocked)
        XCTAssertFalse(doc.permitsStructureEditing)
        let selection = doc.selection
        doc.select(.layer(doc.identity.layers[0].id))
        XCTAssertEqual(doc.selection, selection)
        await session.waitForFinish()
        await session.waitForLoad()
        await doc.waitForPreview()
        XCTAssertNil(session.error)
        XCTAssertFalse(doc.interactionLocked)
        XCTAssertTrue(doc.isDirty)
        XCTAssertTrue(doc.previewIsCurrent)
        XCTAssertFalse(doc.previewResources === resources)
        XCTAssertEqual(try generationField().coverage, try helper.sourceField().coverage)
        let after = doc.state.workingModel
        let paintedSamples = session.samples
        let path = try helper.fields(after)[2]
        let generation = doc.state.sessionAssets[path]
        doc.undoManager.undo()
        await session.waitForLoad()
        await doc.waitForPreview()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertEqual(session.samples, samples)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        await session.waitForLoad()
        await doc.waitForPreview()
        XCTAssertEqual(doc.state.workingModel, after)
        XCTAssertEqual(session.samples, paintedSamples)
        XCTAssertTrue(doc.state.sessionAssets[path] === generation)
    }
    func testSettingsClickNoOpCancelEscapeAndSelectionDoNotDirty() async throws {
        try await enable()
        session.setDiameter(40)
        session.setMagnitude(0.35)
        session.setOperation(.direction)
        let resources = doc.previewResources
        let point = try scene(SIMD2(0.25, 0.5))
        XCTAssertTrue(session.begin(point, erase: false))
        session.finish(point)
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertTrue(doc.previewResources === resources)
        XCTAssertTrue(session.begin(point, erase: false))
        session.append(try scene(SIMD2(0.5, 0.5)))
        XCTAssertTrue(doc.cancelPaintInteraction())
        await session.waitForFeedback()
        XCTAssertTrue(session.brushEnabled)
        XCTAssertFalse(session.isDrawing)
        XCTAssertFalse(doc.cancelPaintInteraction())
        XCTAssertTrue(session.brushEnabled)
        try await enable()
        XCTAssertTrue(session.begin(point, erase: false))
        doc.select(.layer(doc.identity.layers[0].id))
        await session.waitForFeedback()
        XCTAssertFalse(session.brushEnabled)
        XCTAssertFalse(session.isDrawing)
        XCTAssertFalse(doc.isDirty)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
    }
    func testNeutralizeSingleStampAndModeExclusionWithScalarMask() async throws {
        try await draw()
        let painted = try generationField()
        session.setOperation(.neutralize)
        let point = try scene(SIMD2(0.125, 0.5))
        XCTAssertTrue(session.begin(point, erase: false))
        session.finish(point)
        await session.waitForFinish()
        await session.waitForLoad()
        let neutral = try generationField()
        XCTAssertNotEqual(neutral.vectors, painted.vectors)
        XCTAssertEqual(neutral.coverage, painted.coverage)
        var model = helper.helper.project.document
        guard case .image(var image) = model.layers[0].content else { return XCTFail() }
        image.effects = [
            try helper.effect("flow", "a"),
            try JSONDecoder().decode(
                WSSSceneDocumentV1.Effect.self,
                from: JSONSerialization.data(
                    withJSONObject: WSSSceneCodecTests().ripple(mask: "assets/mask.png"))),
        ]
        model.layers[0].content = .image(image)
        try await reload(model)
        doc.select(.effect(doc.identity.layers[0].id, doc.identity.layers[0].effects[1]))
        await doc.maskCanvas.waitForLoad()
        doc.maskCanvas.setBrush(true)
        XCTAssertTrue(doc.maskCanvas.brushEnabled)
        _ = try helper.select(0)
        try await enable()
        XCTAssertFalse(doc.maskCanvas.brushEnabled)
        doc.select(.effect(doc.identity.layers[0].id, doc.identity.layers[0].effects[1]))
        await doc.maskCanvas.waitForLoad()
        doc.maskCanvas.setBrush(true)
        XCTAssertFalse(session.brushEnabled)
        XCTAssertTrue(doc.maskCanvas.brushEnabled)
    }
    func testStaleTargetAndFinalizationFailureLeaveModelUnchanged() async throws {
        try await enable()
        let before = doc.state.workingModel
        let point = try scene(SIMD2(0.1, 0.5))
        let end = try scene(SIMD2(0.4, 0.5))
        XCTAssertTrue(session.begin(point, erase: false))
        session.append(end)
        let file = doc.project.handle.root.appendingPathComponent("assets/a.wssvf")
        try Data("external mutation".utf8).write(to: file)
        session.finish(end)
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.interactionLocked)
        XCTAssertNotNil(session.error)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testRawSelectionChangeDuringFinalizationAndCloseCannotAdoptCandidate() async throws {
        try await enable()
        let before = doc.state.workingModel
        XCTAssertTrue(session.begin(try scene(SIMD2(0.1, 0.5)), erase: false))
        session.finish(try scene(SIMD2(0.4, 0.5)))
        doc.selection = .layer(doc.identity.layers[0].id)
        await session.waitForFinish()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        _ = try helper.select()
        try await enable()
        XCTAssertTrue(session.begin(try scene(SIMD2(0.1, 0.5)), erase: false))
        session.finish(try scene(SIMD2(0.4, 0.5)))
        doc.close()
        await session.waitForFinish()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
    }
    func testSaveReopenSaveAsIndependenceAndRevertOverlay() async throws {
        try await draw()
        let painted = doc.state.workingModel
        let paintedSamples = session.samples
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(helper.helper.item)
        XCTAssertEqual(reopened.document, painted)
        session.setMagnitude(0.35)
        let start = try scene(SIMD2(0.4, 0.5))
        let end = try scene(SIMD2(0.05, 0.5))
        XCTAssertTrue(session.begin(start, erase: false))
        session.finish(end)
        await session.waitForFinish()
        await session.waitForLoad()
        let copy = try await helper.store.saveWSSAs(
            .init(
                document: doc.state.workingModel,
                state: doc.state, source: doc.project.handle, name: "Direction Painted Copy"))
        let copied = copy.project.document
        doc.revert()
        await session.waitForLoad()
        await doc.waitForPreview()
        XCTAssertEqual(doc.state.workingModel, painted)
        XCTAssertEqual(session.samples, paintedSamples)
        XCTAssertFalse(doc.isDirty)
        doc.close()
        try FileManager.default.removeItem(at: helper.helper.project.handle.root)
        let independent = try await WSSEditorProjectLoader().load(copy.project.handle.wallpaper)
        XCTAssertEqual(independent.document, copied)
        _ = try WSSEditorLivePreviewTests().frame(independent.resources, time: 0.2, width: 128)
    }
    func event(
        _ type: NSEvent.EventType, canvas: WSSCanvasScrollView, point: SIMD2<Float>,
        flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: canvas.surface.convert(canvas.viewPoint(for: point), to: nil),
                modifierFlags: flags, timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    func testNativePointerRoutingZoomPanEscapeAndFocusCancellation() async throws {
        _ = NSApplication.shared
        let controller = WSSEditorWindowController(document: doc, onClose: {})
        let canvas = WSSCanvasScrollView(document: doc)
        controller.window?.contentView = canvas
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        canvas.update(doc, zoom: 1)
        canvas.layoutSubtreeIfNeeded()
        defer {
            canvas.shutdown()
            controller.close()
        }
        try await enable()
        let selection = doc.selection
        let start = try scene(SIMD2(0.05, 0.5))
        let end = try scene(SIMD2(0.4, 0.5))
        canvas.beginInteraction(try event(.leftMouseDown, canvas: canvas, point: start))
        canvas.dragInteraction(try event(.leftMouseDragged, canvas: canvas, point: end))
        XCTAssertEqual(canvas.interactionPhase, .painting)
        XCTAssertNil(doc.canvasTransform)
        XCTAssertEqual(doc.selection, selection)
        canvas.endInteraction(try event(.leftMouseUp, canvas: canvas, point: end))
        await session.waitForFinish()
        await session.waitForLoad()
        let first = try generationField().vectors
        doc.undoManager.undo()
        await session.waitForLoad()
        canvas.update(doc, zoom: 2)
        canvas.layoutSubtreeIfNeeded()
        canvas.beginInteraction(try event(.leftMouseDown, canvas: canvas, point: start))
        canvas.endInteraction(try event(.leftMouseUp, canvas: canvas, point: end))
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertEqual(try generationField().vectors, first)
        let model = doc.state.workingModel
        doc.canvasSpaceDown = true
        canvas.beginInteraction(try event(.leftMouseDown, canvas: canvas, point: start))
        XCTAssertEqual(canvas.interactionPhase, .panning)
        XCTAssertFalse(session.isDrawing)
        canvas.endInteraction()
        _ = canvas.resignFirstResponder()
        doc.canvasSpaceDown = false
        XCTAssertTrue(canvas.performZoom(.zoomOut))
        XCTAssertEqual(doc.state.workingModel, model)
        canvas.beginInteraction(try event(.leftMouseDown, canvas: canvas, point: start))
        XCTAssertTrue(session.isDrawing)
        _ = canvas.resignFirstResponder()
        XCTAssertFalse(session.isDrawing)
        XCTAssertEqual(doc.state.workingModel, model)
    }
    func testGeometryTransformUVScaleOverlayDensityMagnitudeAndCoverage() throws {
        let imageSize = SIMD2<Float>(160, 90)
        for rotation: Float in [0, .pi / 2, 0.7] {
            let transform = WSSImageTransform(
                center: SIMD2(300, 200), size: imageSize,
                scale: SIMD2(2, 0.5), rotation: rotation)
            let geometry = WSSDirectionCanvasGeometry(transform: transform)
            let uv = SIMD2<Double>(0.25, 0.75)
            let scene = geometry.scene(uv)
            let recovered = try XCTUnwrap(geometry.uv(scene))
            XCTAssertEqual(recovered.x, uv.x, accuracy: 0.00001)
            XCTAssertEqual(recovered.y, uv.y, accuracy: 0.00001)
            let footprint = geometry.footprint(uv, diameter: 20)
            XCTAssertEqual(
                hypot(footprint[0].x - footprint[32].x, footprint[0].y - footprint[32].y), 40,
                accuracy: 0.001)
            XCTAssertEqual(
                hypot(footprint[16].x - footprint[48].x, footprint[16].y - footprint[48].y), 10,
                accuracy: 0.001)
            let arrow = WSSDirectionOverlayGeometry.arrow(
                .init(uv: uv, vector: SIMD2(1, 0), coverage: 1),
                geometry: geometry, origin: .zero, zoom: 1, height: 600)
            XCTAssertEqual(
                arrow.tip.x - arrow.center.x, 18 * CGFloat(cos(rotation)), accuracy: 0.001)
            XCTAssertEqual(
                arrow.tip.y - arrow.center.y, -18 * CGFloat(sin(rotation)), accuracy: 0.001)
            let large = WSSDirectionOverlayGeometry.arrow(
                .init(uv: uv, vector: SIMD2(1, 1), coverage: 0),
                geometry: geometry, origin: .zero, zoom: 2, height: 600)
            XCTAssertGreaterThan(large.magnitude, arrow.magnitude)
            XCTAssertGreaterThan(large.opacity, 0)
            XCTAssertLessThan(large.opacity, arrow.opacity)
            let queries = WSSDirectionOverlayGeometry.queries(
                visible: CGRect(x: 0, y: 0, width: 1000, height: 800),
                origin: .zero, zoom: 1, height: 600, geometry: geometry)
            XCTAssertLessThan(queries.count, 400)
        }
    }
    func testImageSamplingUVScaleIsNotAppliedToFieldCoordinates() async throws {
        var model = doc.state.workingModel
        guard case .image(var image) = model.layers[0].content else { return XCTFail() }
        image.definition = .init(
            asset: image.asset, encoding: "image", width: 128, height: 128,
            uvScale: [0.5, 0.75], filter: "linear", edge: "clamp", mipmapped: false)
        model.layers[0].content = .image(image)
        try await reload(model)
        _ = try helper.select()
        try await enable()
        let expected = SIMD2<Double>(0.8, 0.6)
        XCTAssertEqual(
            try XCTUnwrap(session.geometry?.uv(scene(expected))).x, expected.x, accuracy: 0.00001)
        let edit = try XCTUnwrap(session.loaded)
        let points: [SIMD2<Double>] = [SIMD2(0.05, 0.5), SIMD2(0.4, 0.5)]
        let geometry = try XCTUnwrap(session.geometry)
        let expectedPaint = try WSSVectorFieldPaint.paint(
            edit.field, imageSize: geometry.imageSize,
            uvPoints: points,
            brush: WSSVectorBrush(
                diameter: session.diameter, magnitude: session.magnitude, operation: .direction))
        XCTAssertTrue(session.begin(geometry.scene(points[0]), erase: false))
        session.finish(geometry.scene(points[1]))
        await session.waitForFinish()
        await session.waitForLoad()
        guard case .changed(let field) = expectedPaint else { return XCTFail() }
        XCTAssertEqual(try generationField().vectors, field.vectors)
    }
    func prepareBoundsField(rotation: Float = 0, scale: [Float] = [1, 1]) async throws {
        var model = doc.state.workingModel
        guard case .image(var image) = model.layers[0].content else { return XCTFail() }
        image.transform.rotation = rotation
        image.transform.scale = scale
        image.transform.center = [64, 64]
        model.layers[0].content = .image(image)
        let root = doc.project.handle.root
        doc.close()
        let field = try WSSVectorFieldPaintTests().field(coverage: true)
        try field.encodedNative().write(to: root.appendingPathComponent("assets/a.wssvf"))
        try await reload(model)
        _ = try helper.select()
        try await enable()
        session.setDiameter(8)
        session.updateQueries([SIMD2(0.04, 0.25), SIMD2(0.04, 0.75), SIMD2(0.0078125, 0.5)])
    }
    func testClippingUsesLocalSegmentIntersectionsRatherThanClampedPointers() throws {
        typealias G = WSSDirectionCanvasGeometry
        let diagonal = try XCTUnwrap(G.clip(SIMD2(0.5, 0.5), SIMD2(-0.5, 0)))
        XCTAssertEqual(diagonal.1, SIMD2(0, 0.25))
        let entry = try XCTUnwrap(G.clip(SIMD2(-0.5, 0), SIMD2(0.5, 0.5)))
        XCTAssertEqual(entry.0, SIMD2(0, 0.25))
        XCTAssertNil(G.clip(SIMD2(-1, 0.25), SIMD2(-1, 0.75)))
        XCTAssertNil(G.clip(SIMD2(-1, 2), SIMD2(2, 2)))
        let crossing = try XCTUnwrap(G.clip(SIMD2(-1, 0.25), SIMD2(2, 0.75)))
        XCTAssertEqual(crossing.0.x, 0)
        XCTAssertEqual(crossing.0.y, 5.0 / 12, accuracy: 1e-12)
        XCTAssertEqual(crossing.1.x, 1)
        XCTAssertEqual(crossing.1.y, 7.0 / 12, accuracy: 1e-12)
        for rotation: Float in [0, .pi / 2, 0.7] {
            let geometry = WSSDirectionCanvasGeometry(
                transform: WSSImageTransform(
                    center: SIMD2(320, 240), size: SIMD2(128, 128),
                    scale: SIMD2(2, 0.5), rotation: rotation))
            let outside = geometry.scene(SIMD2(-0.2, 0.5))
            // Includes points inside the rotated canvas bounding box.
            XCTAssertNil(geometry.uv(outside))
            let local = try XCTUnwrap(geometry.unboundedUV(outside))
            let hit = try XCTUnwrap(G.clip(SIMD2(0.5, 0.5), local))
            XCTAssertEqual(hit.1.x, 0, accuracy: 1e-7)
            XCTAssertEqual(hit.1.y, 0.5, accuracy: 1e-6)
        }
    }
    func testOutsideMouseUpFinalizesValidPartAndOneUndo() async throws {
        try await prepareBoundsField()
        let original = doc.state.workingModel
        let preview = doc.previewResources
        XCTAssertTrue(session.begin(try scene(SIMD2(0.5, 0.25)), erase: false))
        session.append(try scene(SIMD2(-0.5, 0.25)))
        await session.waitForFeedback()
        XCTAssertTrue(session.isDrawing)
        XCTAssertLessThan(session.samples[0].vector.x, -0.9)
        let feedback = session.samples
        session.append(try scene(SIMD2(-0.5, 0.75)))
        await session.waitForFeedback()
        XCTAssertEqual(session.samples, feedback)
        XCTAssertTrue(doc.previewResources === preview)
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertNil(session.error)
        session.finish(try scene(SIMD2(-0.5, 0.9)))
        await session.waitForFinish()
        await session.waitForLoad()
        await doc.waitForPreview()
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.state.sessionAssets.count, 1)
        XCTAssertFalse(doc.previewResources === preview)
        XCTAssertLessThan(session.samples[0].vector.x, -0.9)
        XCTAssertEqual(session.samples[2].vector, .zero)  // No vertical edge-clamped stroke.
        doc.undoManager.undo()
        await session.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testReentryPreservesFragmentsDirectionsAndEscapeStillDiscardsEverything() async throws {
        try await prepareBoundsField()
        let original = doc.state.workingModel
        let path: [SIMD2<Double>] = [
            SIMD2(0.5, 0.25), SIMD2(-0.5, 0.25), SIMD2(-0.5, 0.75), SIMD2(0.5, 0.75),
        ]
        XCTAssertTrue(session.begin(try scene(path[0]), erase: false))
        for uv in path.dropFirst() { session.append(try scene(uv)) }
        await session.waitForFeedback()
        XCTAssertLessThan(session.samples[0].vector.x, -0.9)
        XCTAssertGreaterThan(session.samples[1].vector.x, 0.9)
        XCTAssertEqual(session.samples[2].vector, .zero)
        XCTAssertTrue(session.escape())
        await session.waitForFeedback()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertFalse(doc.isDirty)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertTrue(session.begin(try scene(path[0]), erase: false))
        for uv in path.dropFirst() { session.append(try scene(uv)) }
        session.finish(try scene(path.last!))
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertEqual(doc.state.sessionAssets.count, 1)
        XCTAssertLessThan(session.samples[0].vector.x, -0.9)
        XCTAssertGreaterThan(session.samples[1].vector.x, 0.9)
        XCTAssertEqual(session.samples[2].vector, .zero)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testOutsideStartEntryCrossingAndMiss() async throws {
        try await prepareBoundsField()
        let original = doc.state.workingModel
        XCTAssertTrue(session.begin(try scene(SIMD2(-0.5, 0.25)), erase: false))
        session.finish(try scene(SIMD2(-0.5, 0.75)))
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertFalse(doc.isDirty)
        XCTAssertTrue(session.begin(try scene(SIMD2(-0.5, 0.25)), erase: false))
        session.finish(try scene(SIMD2(0.5, 0.25)))
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertGreaterThan(session.samples[0].vector.x, 0.9)
        doc.undoManager.undo()
        await session.waitForLoad()
        XCTAssertTrue(session.begin(try scene(SIMD2(-0.5, 0.25)), erase: false))
        session.finish(try scene(SIMD2(1.5, 0.25)))
        await session.waitForFinish()
        await session.waitForLoad()
        let field = try generationField()
        let values = WSSDirectionSampling.samples(
            field, at: [SIMD2(0.04, 0.25), SIMD2(0.96, 0.25)])
        XCTAssertTrue(values.allSatisfy { $0.vector.x > 0.9 && abs($0.vector.y) < 0.001 })
    }
    func testDiagonalExitAndReentryRetainNaturalLocalDirection() async throws {
        try await prepareBoundsField()
        let path: [SIMD2<Double>] = [
            SIMD2(0.5, 0.5), SIMD2(-0.5, 0), SIMD2(-0.5, 1), SIMD2(0.5, 0.5),
        ]
        XCTAssertTrue(session.begin(try scene(path[0]), erase: false))
        for uv in path.dropFirst() { session.append(try scene(uv)) }
        session.finish(try scene(path.last!))
        await session.waitForFinish()
        await session.waitForLoad()
        let values = WSSDirectionSampling.samples(
            try generationField(), at: [SIMD2(0.04, 0.27), SIMD2(0.04, 0.73)])
        XCTAssertEqual(values[0].vector.x, -Float(2 / sqrt(5.0)), accuracy: 0.005)
        XCTAssertEqual(values[0].vector.y, -Float(1 / sqrt(5.0)), accuracy: 0.005)
        XCTAssertEqual(values[1].vector.x, Float(2 / sqrt(5.0)), accuracy: 0.005)
        XCTAssertEqual(values[1].vector.y, -Float(1 / sqrt(5.0)), accuracy: 0.005)
    }
    func testNativeClippedStrokeWithRotationNonuniformScaleAndZoomIsIdentical() async throws {
        try await prepareBoundsField(rotation: .pi / 2, scale: [2, 0.5])
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
            backing: .buffered, defer: false)
        let canvas = WSSCanvasScrollView(document: doc)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer {
            canvas.shutdown()
            window.close()
        }
        var first: Data?
        let path: [SIMD2<Double>] = [
            SIMD2(0.5, 0.25), SIMD2(-0.5, 0.25), SIMD2(-0.5, 0.75), SIMD2(0.5, 0.75),
            SIMD2(1.5, 0.75),
        ]
        for zoom: CGFloat in [1, 2] {
            canvas.update(doc, zoom: zoom)
            canvas.layoutSubtreeIfNeeded()
            canvas.beginInteraction(
                try event(.leftMouseDown, canvas: canvas, point: scene(path[0])))
            for uv in path.dropFirst().dropLast() {
                canvas.dragInteraction(
                    try event(.leftMouseDragged, canvas: canvas, point: scene(uv)))
            }
            canvas.endInteraction(try event(.leftMouseUp, canvas: canvas, point: scene(path.last!)))
            await session.waitForFinish()
            await session.waitForLoad()
            let vectors = try generationField().vectors
            if let first { XCTAssertEqual(vectors, first) } else { first = vectors }
            let values = WSSDirectionSampling.samples(
                try generationField(),
                at: [SIMD2(0.04, 0.25), SIMD2(0.04, 0.75), SIMD2(0.0078125, 0.5)])
            XCTAssertLessThan(values[0].vector.x, -0.9)
            XCTAssertGreaterThan(values[1].vector.x, 0.9)
            XCTAssertEqual(values[2].vector, .zero)
            doc.undoManager.undo()
            await session.waitForLoad()
        }
    }

}
