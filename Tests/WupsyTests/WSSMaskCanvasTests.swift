import AppKit
import MetalKit
import XCTest

@testable import Wupsy

@MainActor final class WSSMaskCanvasTests: XCTestCase {
    var helper: WSSMaskEditingTests!
    var doc: WSSEditorDocument { helper.doc }
    var session: WSSMaskCanvasSession { doc.maskCanvas }
    override func setUp() async throws {
        helper = WSSMaskEditingTests()
        try await helper.setUp()
        _ = try helper.target()
        await session.waitForLoad()
    }
    override func tearDown() async throws {
        try await helper.tearDown()
        helper = nil
    }
    func scene(_ x: Double = 0, _ y: Double = 0) throws -> SIMD2<Float> {
        try XCTUnwrap(session.geometry).scene(SIMD2(x, y))
    }
    func brush() {
        session.setBrush(true)
        session.setDiameter(2)
        session.setOpacity(1)
    }
    func testSelectedOnlyOverlayTracksEffectsAndInvalidSelections() async throws {
        XCTAssertEqual(session.loaded?.resolved.target.slot, .ripple)
        let first = session.loaded?.resolved.target
        _ = try helper.target(layer: 1)
        await session.waitForLoad()
        XCTAssertEqual(session.loaded?.resolved.target.slot, .clouds)
        XCTAssertNotEqual(session.loaded?.resolved.target, first)
        doc.selection = .effect(doc.identity.layers[0].id, WSSEffectID())
        XCTAssertNil(session.loaded)
        XCTAssertFalse(session.brushEnabled)
        doc.select(nil)
        XCTAssertNil(session.loaded)
        doc.select(.layer(doc.identity.layers[0].id))
        XCTAssertNil(session.loaded)
        XCTAssertFalse(doc.isDirty)
    }
    func testSessionSettingsDoNotDirtyAndClampAfterTargetChanges() async throws {
        let version = session.displayVersion
        session.setDiameter(99999)
        session.setOpacity(0.35)
        session.setBrush(true)
        XCTAssertEqual(session.diameter, 4)
        XCTAssertEqual(session.opacity, 0.35)
        XCTAssertEqual(session.displayVersion, version)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
        _ = try helper.target(layer: 1)
        await session.waitForLoad()
        XCTAssertTrue(session.brushEnabled)
        XCTAssertEqual(session.opacity, 0.35)
        XCTAssertEqual(session.diameter, 4)
    }
    func testCanvasStrokeTransientThenOneUndoAndPreviewUpdate() async throws {
        brush()
        let point = try scene()
        let original = doc.state.workingModel
        XCTAssertTrue(session.begin(point, erase: false))
        XCTAssertEqual(session.pixels, Data([255, 255]))
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        session.finish(point)
        XCTAssertTrue(session.finalizing)
        XCTAssertTrue(doc.interactionLocked)
        await session.waitForFinish()
        await session.waitForLoad()
        await doc.waitForPreview()
        XCTAssertTrue(doc.isDirty)
        XCTAssertFalse(doc.interactionLocked)
        XCTAssertTrue(doc.previewIsCurrent)
        let painted = doc.state.workingModel
        doc.undoManager.undo()
        XCTAssertEqual(session.pixels, Data([0, 255]))
        await session.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertEqual(session.pixels, Data([0, 255]))
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        await session.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, painted)
        XCTAssertEqual(session.pixels, Data([255, 255]))
        XCTAssertTrue(session.brushEnabled)
    }
    func testEscapeCancelsExactBufferThenExitsIdleBrush() throws {
        brush()
        let original = session.pixels
        XCTAssertTrue(session.begin(try scene(), erase: false))
        XCTAssertTrue(doc.cancelMaskInteraction())
        XCTAssertEqual(session.pixels, original)
        XCTAssertTrue(session.brushEnabled)
        XCTAssertFalse(doc.isDirty)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertTrue(doc.cancelMaskInteraction())
        XCTAssertFalse(session.brushEnabled)
        XCTAssertFalse(doc.cancelMaskInteraction())
    }
    func testSelectionChangeCancelsStrokeWithoutApplyingToAnotherEffect() async throws {
        brush()
        let original = doc.state.workingModel
        XCTAssertTrue(session.begin(try scene(), erase: false))
        _ = try helper.target(layer: 1)
        await session.waitForLoad()
        XCTAssertFalse(session.isDrawing)
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertEqual(session.loaded?.resolved.target.slot, .clouds)
    }
    func testDocumentActionsAbortDuringStrokeAndFinalization() async throws {
        brush()
        doc.requestSaveAs = {
            XCTFail("Save As should not be enabled")
            return true
        }
        let point = try scene()
        XCTAssertTrue(session.begin(point, erase: false))
        XCTAssertFalse(doc.finishEditing())
        XCTAssertFalse(doc.canSave)
        XCTAssertFalse(doc.canSaveAs)
        let before = doc.state.workingModel
        XCTAssertNil(doc.currentDeletableSelection)
        XCTAssertFalse(doc.structureCommands.canPerform(.delete))
        try doc.deleteSelection()
        try doc.addEffect(.ripple)
        XCTAssertEqual(doc.state.workingModel, before)
        let saved = await doc.save()
        let closed = await doc.resolveChanges()
        XCTAssertFalse(saved)
        XCTAssertFalse(closed)
        doc.revert()
        XCTAssertTrue(session.isDrawing)
        XCTAssertFalse(doc.isDirty)
        session.finish(point)
        XCTAssertNil(doc.currentDeletableSelection)
        try doc.deleteSelection()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertFalse(doc.finishEditing())
        XCTAssertFalse(doc.canSaveAs)
        for _ in 0..<50 where session.finalizing {
            XCTAssertTrue(doc.interactionLocked)
            await Task.yield()
        }
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertTrue(doc.canSave)
        let after = await doc.save()
        XCTAssertTrue(after)
    }
    func testNativePointerRouteFreezesEraseAndPreventsRetargetAndDoubleClick() async throws {
        _ = NSApplication.shared
        let controller = WSSEditorWindowController(document: doc, onClose: {})
        defer {
            doc.close()
            controller.close()
        }
        let canvas = WSSCanvasScrollView(document: doc)
        controller.window?.contentView = canvas
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        canvas.update(doc, zoom: 1)
        canvas.layoutSubtreeIfNeeded()
        brush()
        let selection = doc.selection
        let point = try scene(1, 0)
        canvas.beginInteraction(
            try event(.leftMouseDown, canvas: canvas, scene: point, flags: .option, clicks: 2))
        XCTAssertTrue(session.isDrawing)
        XCTAssertEqual(doc.selection, selection)
        XCTAssertNil(doc.transformModeLayer)
        // Releasing Option during drag does not change the frozen erase mode.
        canvas.dragInteraction(try event(.leftMouseDragged, canvas: canvas, scene: point))
        canvas.endInteraction(try event(.leftMouseUp, canvas: canvas, scene: point))
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertEqual(session.pixels, Data([0, 0]))
    }
    func testSpacePanAndFocusLossDoNotCommitPaint() async throws {
        _ = NSApplication.shared
        let canvas = WSSCanvasScrollView(document: doc)
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        canvas.update(doc, zoom: 1)
        canvas.layoutSubtreeIfNeeded()
        defer { canvas.shutdown() }
        brush()
        let space = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: false, keyCode: 49))
        canvas.keyDown(with: space)
        let point = try scene()
        canvas.beginInteraction(try event(.leftMouseDown, canvas: canvas, scene: point))
        XCTAssertFalse(session.isDrawing)
        canvas.endInteraction()
        _ = canvas.resignFirstResponder()
        XCTAssertTrue(session.begin(point, erase: false))
        _ = canvas.resignFirstResponder()
        XCTAssertFalse(session.isDrawing)
        XCTAssertFalse(doc.isDirty)
    }
    func event(
        _ type: NSEvent.EventType, canvas: WSSCanvasScrollView, scene: SIMD2<Float>,
        flags: NSEvent.ModifierFlags = [], clicks: Int = 1
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: canvas.surface.convert(canvas.viewPoint(for: scene), to: nil),
                modifierFlags: flags, timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0,
                context: nil, eventNumber: 1, clickCount: clicks, pressure: 1))
    }
    func testGeometryRoundtripAndFootprintAcrossTransformsUVZoomPanAndHiDPI() throws {
        let bitmap = try WSSMaskBitmap(
            width: 100, height: 50, uvScale: SIMD2(0.5, 0.75),
            pixels: Data(repeating: 0, count: 5000))
        for rotation: Float in [0, 0.7, 1.57] {
            let transform = WSSImageTransform(
                center: SIMD2(300, 200), size: SIMD2(200, 100), scale: SIMD2(2, 0.5),
                rotation: rotation)
            let geometry = WSSMaskCanvasGeometry(transform: transform, bitmap: bitmap)
            let texel = SIMD2<Double>(20, 15)
            let scene = geometry.scene(texel)
            let result = try XCTUnwrap(geometry.texel(scene))
            XCTAssertEqual(result.x, texel.x, accuracy: 0.0001)
            XCTAssertEqual(result.y, texel.y, accuracy: 0.0001)
            let footprint = geometry.footprint(center: scene, diameter: 10)
            XCTAssertEqual(footprint.count, 64)
            // X diameter: 400 scene units across 50 sampled mask texels.
            XCTAssertEqual(
                hypot(footprint[0].x - footprint[32].x, footprint[0].y - footprint[32].y), 80,
                accuracy: 0.001)
            // Y diameter: 50 scene units across 37.5 sampled mask texels.
            XCTAssertEqual(
                hypot(footprint[16].x - footprint[48].x, footprint[16].y - footprint[48].y),
                50 * 10 / 37.5, accuracy: 0.001)
            for zoom: CGFloat in [0.25, 1, 4] {
                let origin = CGPoint(x: 81, y: -37)
                let view = WSSCanvasGeometry.viewportPoint(
                    scene, origin: origin, zoom: zoom, height: 600)
                let back = WSSCanvasGeometry.scenePoint(
                    view, origin: origin, zoom: zoom, height: 600)
                XCTAssertEqual(back.x, scene.x, accuracy: 0.001)
                XCTAssertEqual(back.y, scene.y, accuracy: 0.001)
                // No backing scale enters this route; raster density is independent.
                XCTAssertNotNil(geometry.texel(back))
            }
        }
    }
    func testMetalOverlayPassShowsCoverageTransientPaintingAndCancel() throws {
        let resources = doc.project.resources
        let renderer = try WSSMaskCanvasOverlay(device: resources.device)
        var version = session.displayVersion
        session.onChange = { [weak session = session] in
            guard let session, version != session.displayVersion else { return }
            version = session.displayVersion
            renderer.invalidate(region: session.dirtyRegion)
        }
        defer { session.onChange = nil }
        func frame() throws -> Data {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
            d.storageMode = .shared
            d.usage = [.renderTarget, .shaderRead]
            let texture = try XCTUnwrap(resources.device.makeTexture(descriptor: d))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
            let clear = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            clear.endEncoding()
            try renderer.encode(
                session: session, scene: CGSize(width: 64, height: 64), command: command,
                descriptor: pass)
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            var bytes = Data(count: 64 * 64 * 4)
            bytes.withUnsafeMutableBytes {
                texture.getBytes(
                    $0.baseAddress!, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 64),
                    mipmapLevel: 0)
            }
            return bytes
        }
        let before = try frame()
        let left = (32 * 64) * 4
        let right = (32 * 64 + 63) * 4
        XCTAssertEqual(before[left..<left + 3].reduce(0) { $0 + Int($1) }, 0)
        XCTAssertGreaterThan(before[right..<right + 3].reduce(0) { $0 + Int($1) }, 0)
        brush()
        XCTAssertTrue(session.begin(try scene(), erase: false))
        let painted = try frame()
        XCTAssertGreaterThan(painted[left..<left + 3].reduce(0) { $0 + Int($1) }, 0)
        session.cancelStroke()
        XCTAssertEqual(try frame(), before)
    }
    func testNativeCloseAndQuitAbortDuringActiveStroke() async throws {
        let project = helper.helper.project!
        var controller: WSSEditorWindowController!
        let coordinator = WSSEditorCoordinator(
            lookup: { _ in project.handle.wallpaper },
            saveAs: { _ in
                XCTFail("Save As should be blocked")
                throw WSSMaskError.stale
            },
            load: { _ in project },
            makeWindow: { value, callback in
                controller = WSSEditorWindowController(document: value, onClose: callback)
                return controller
            })
        defer { coordinator.shutdown() }
        try await coordinator.open(wallpaperID: project.handle.id)
        let value = controller.editorDocument
        value.select(.effect(value.identity.layers[0].id, value.identity.layers[0].effects[0]))
        let mask = value.maskCanvas
        await mask.waitForLoad()
        mask.setBrush(true)
        mask.setDiameter(2)
        let point = try XCTUnwrap(mask.geometry).scene(.zero)
        XCTAssertTrue(mask.begin(point, erase: false))
        XCTAssertFalse(controller.windowShouldClose(try XCTUnwrap(controller.window)))
        let quit = await coordinator.approveTermination()
        XCTAssertFalse(quit)
        let copied = await value.requestSaveAs?()
        XCTAssertEqual(copied, false)
        XCTAssertTrue(mask.isDrawing)
        XCTAssertFalse(value.closed)
        XCTAssertFalse(value.isDirty)
        _ = value.cancelMaskInteraction()
        XCTAssertTrue(controller.windowShouldClose(try XCTUnwrap(controller.window)))
    }
    func testEscapeDuringTargetLoadDoesNotReactivateBrush() async throws {
        brush()
        _ = try helper.target(layer: 1)
        XCTAssertTrue(session.escape())
        await session.waitForLoad()
        XCTAssertFalse(session.brushEnabled)
        XCTAssertEqual(session.loaded?.resolved.target.slot, .clouds)
    }
    func testSpaceHeldBeforeCanvasFocusCannotPaint() throws {
        let canvas = WSSCanvasScrollView(document: doc)
        defer { canvas.shutdown() }
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        canvas.update(doc, zoom: 1)
        canvas.layoutSubtreeIfNeeded()
        brush()
        // The native editor window records this even when a text field owns focus.
        doc.canvasSpaceDown = true
        canvas.beginInteraction(try event(.leftMouseDown, canvas: canvas, scene: scene()))
        XCTAssertFalse(session.isDrawing)
        XCTAssertFalse(doc.isDirty)
        doc.canvasSpaceDown = false
    }
    func testTreeDoubleClickWhileBrushingDoesNotActivateTransform() {
        brush()
        let result = doc.activateStructureRow(.layer(doc.identity.layers[0].id))
        XCTAssertFalse(result)
        XCTAssertNil(doc.transformModeLayer)
        XCTAssertFalse(session.brushEnabled)
    }
    func testOverlayFailureDisablesPaintingWithoutMutatingDocument() throws {
        brush()
        XCTAssertTrue(session.begin(try scene(), erase: false))
        session.overlayFailed()
        XCTAssertFalse(session.isDrawing)
        XCTAssertFalse(session.brushEnabled)
        session.setBrush(true)
        XCTAssertFalse(session.brushEnabled)
        XCTAssertFalse(session.begin(try scene(), erase: false))
        XCTAssertFalse(doc.isDirty)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
    }
    func testDismantledCanvasCannotCancelNewCanvasStroke() throws {
        let old = WSSCanvasScrollView(document: doc)
        let current = WSSCanvasScrollView(document: doc)
        defer { current.shutdown() }
        brush()
        XCTAssertTrue(session.begin(try scene(), erase: false))
        old.shutdown()
        XCTAssertTrue(session.isDrawing)
        session.cancelStroke()
        XCTAssertFalse(doc.isDirty)
    }
    func testFullHDTransientStrokeUsesDirtyRegionsWithoutPersistenceOrPreviewReload() async throws {
        let bitmap = try WSSMaskBitmap(
            width: 1920, height: 1080, uvScale: SIMD2(1, 1),
            pixels: Data(repeating: 0, count: 1920 * 1080))
        try bitmap.encoded().write(
            to: helper.helper.project.handle.root.appendingPathComponent("assets/mask.png"))
        doc.close()
        helper.doc = helper.makeDocument(
            try await WSSEditorProjectLoader().load(helper.helper.item))
        _ = try helper.target()
        await session.waitForLoad()
        session.setBrush(true)
        session.setDiameter(100)
        session.setOpacity(0.35)
        let geometry = try XCTUnwrap(session.geometry)
        let files = try helper.helper.helper.snapshot()
        let resources = doc.previewResources
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(session.begin(geometry.scene(SIMD2(100, 500)), erase: false))
        for x in stride(from: 180, through: 1780, by: 80) {
            session.append(geometry.scene(SIMD2(Double(x), 500)))
        }
        XCTAssertLessThan(try XCTUnwrap(session.dirtyRegion).width, 200)
        XCTAssertEqual(try helper.helper.helper.snapshot(), files)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertFalse(doc.isDirty)
        XCTAssertTrue(doc.previewResources === resources)
        print(
            "Full-HD mask transient path: \(ProcessInfo.processInfo.systemUptime - start) seconds")
        session.finish(geometry.scene(SIMD2(1820, 500)))
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertTrue(doc.isDirty)
        XCTAssertGreaterThan(try XCTUnwrap(session.pixels?[500 * 1920 + 1820]), 0)
    }
    func testFailedFinalizationRestoresOverlayAndUnlocksWithoutPartialMutation() async throws {
        brush()
        let original = doc.state.workingModel
        let pixels = session.pixels
        let point = try scene()
        XCTAssertTrue(session.begin(point, erase: false))
        try Data("external change".utf8).write(
            to: helper.helper.project.handle.root.appendingPathComponent("assets/mask.png"))
        session.finish(point)
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertEqual(session.pixels, pixels)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertFalse(doc.interactionLocked)
        XCTAssertFalse(session.finalizing)
        XCTAssertNotNil(session.error)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testUnsupportedEffectNeverOffersBrush() async throws {
        let fixture = WSSEditorLivePreviewTests()
        try await fixture.setUp()
        defer { try? fixture.helper.tearDownWithError() }
        let project = try await fixture.project("WSS-Flow-v1")
        let value = WSSEditorDocument(project: project)
        defer { value.close() }
        value.select(.effect(value.identity.layers[0].id, value.identity.layers[0].effects[0]))
        let mask = value.maskCanvas
        await mask.waitForLoad()
        mask.setBrush(true)
        XCTAssertNil(mask.loaded)
        XCTAssertFalse(mask.brushEnabled)
        XCTAssertFalse(mask.begin(.zero, erase: false))
    }
    func testOutsideReentryNeverPaintsBridgeAndUpPositionIsApplied() async throws {
        // Exercise the Canvas layer with a wider generated mask, not just engine inputs.
        let bitmap = try WSSMaskBitmap(
            width: 64, height: 8, uvScale: SIMD2(1, 1), pixels: Data(repeating: 0, count: 512))
        try bitmap.encoded().write(
            to: helper.helper.project.handle.root.appendingPathComponent("assets/mask.png"))
        doc.close()
        helper.doc = helper.makeDocument(
            try await WSSEditorProjectLoader().load(helper.helper.item))
        _ = try helper.target()
        await session.waitForLoad()
        brush()
        session.setDiameter(1)
        let geometry = try XCTUnwrap(session.geometry)
        XCTAssertTrue(session.begin(geometry.scene(SIMD2(2, 4)), erase: false))
        session.append(SIMD2(-1000, -1000))
        session.append(geometry.scene(SIMD2(60, 4)))
        session.finish(geometry.scene(SIMD2(62, 4)))
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertEqual(session.pixels?[4 * 64 + 30], 0)
        XCTAssertGreaterThan(try XCTUnwrap(session.pixels?[4 * 64 + 62]), 0)
    }
}
