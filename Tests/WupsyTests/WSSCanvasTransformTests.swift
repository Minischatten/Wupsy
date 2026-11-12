import AppKit
import XCTest
import simd

@testable import Wupsy

@MainActor final class WSSCanvasTransformTests: XCTestCase {
    var helper: WSSEditorWorkspaceTests!
    var doc: WSSEditorDocument!
    override func setUp() async throws {
        helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
        doc = helper.document()
    }
    override func tearDown() async throws {
        doc.close()
        doc = nil
        try await helper.tearDown()
    }
    func transform() throws -> WSSSceneDocumentV1.Transform {
        var t = try XCTUnwrap(doc.state.workingModel.layers[0].imageTransform)
        t.center = [120, 150]
        t.size = [80, 60]
        t.scale = [2, 1]
        t.rotation = .pi / 5
        return t
    }
    func assertPoint(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.x, b.x, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 0.001, file: file, line: line)
    }
    func testInverseQuadRoundtripRotationScaleZoomPanAndYDirection() throws {
        let t = try transform().native()
        for zoom: CGFloat in [0.1, 1, 8] {
            for origin in [CGPoint(x: 40, y: 20), CGPoint(x: -400, y: -900)] {
                for local in [SIMD2<Float>(0, 0), SIMD2(0.5, 0.5), SIMD2(-0.5, -0.5)] {
                    let scene = t.point(local)
                    let view = WSSCanvasGeometry.viewportPoint(
                        scene, origin: origin, zoom: zoom, height: 1080)
                    let back = WSSCanvasGeometry.scenePoint(
                        view, origin: origin, zoom: zoom, height: 1080)
                    assertPoint(scene, back)
                    assertPoint(
                        try XCTUnwrap(WSSCanvasGeometry.uv(back, transform: t)),
                        SIMD2(local.x + 0.5, 0.5 - local.y))
                }
            }
        }
        let bottom = WSSCanvasGeometry.viewportPoint(.zero, origin: .zero, zoom: 1, height: 1080)
        XCTAssertEqual(bottom.y, 1080)
    }
    func hit(_ point: SIMD2<Float>, selected: WSSLayerID? = nil) -> WSSCanvasHit? {
        let origin = CGPoint(x: -80, y: 40)
        let zoom: CGFloat = 3
        let p = WSSCanvasGeometry.viewportPoint(point, origin: origin, zoom: zoom, height: 64)
        return WSSCanvasInteractionGeometry.hit(
            point: p, scene: doc.workingScene, identity: doc.identity, selected: selected,
            origin: origin, zoom: zoom)
    }
    func testTopmostHiddenAndQuadEdgesIgnoreAlpha() throws {
        let top = doc.identity.layers[1].id
        XCTAssertEqual(hit(SIMD2(32, 32)), .image(top))
        // No opacity/alpha decoding participates in hit testing.
        try doc.setImage(.opacity, value: 0, layer: top)
        XCTAssertEqual(hit(SIMD2(32, 32)), .image(top))
        XCTAssertEqual(hit(.zero), .image(top))
        try doc.setVisibility(false, layer: top)
        XCTAssertEqual(hit(SIMD2(32, 32)), .image(doc.identity.layers[0].id))
        try doc.setVisibility(false, layer: doc.identity.layers[0].id)
        XCTAssertNil(hit(SIMD2(32, 32)))
    }
    func testRotatedScaledHitAndStableIdentityAfterReorder() throws {
        let top = doc.identity.layers[1].id
        try doc.setImage(.rotation, value: 45, layer: top)
        try doc.setImage(.scaleX, value: 2, layer: top)
        let native = try XCTUnwrap(doc.state.workingModel.layers[1].imageTransform).native()
        XCTAssertEqual(hit(native.point(SIMD2(0.49, 0.49))), .image(top))
        try doc.moveLayer(top, by: -1)
        XCTAssertEqual(hit(SIMD2(32, 32)), .image(doc.identity.layers[1].id))
        XCTAssertEqual(doc.identity.layers[0].id, top)
    }
    func testHandlePriorityAndPointSizedZonesAcrossZoom() throws {
        let id = doc.identity.layers[0].id
        let t = try transform().native()
        for zoom: CGFloat in [0.1, 1, 8] {
            let origin = CGPoint(x: 50, y: 80)
            let points = WSSCanvasInteractionGeometry.handles(
                transform: t, origin: origin, zoom: zoom, height: 64)
            let top = CGPoint(
                x: (points[2].x + points[3].x) / 2, y: (points[2].y + points[3].y) / 2)
            XCTAssertEqual(hypot(points[4].x - top.x, points[4].y - top.y), 28, accuracy: 0.0001)
        }
        let point = WSSCanvasGeometry.viewportPoint(.zero, origin: .zero, zoom: 5, height: 64)
        XCTAssertEqual(
            WSSCanvasInteractionGeometry.hit(
                point: point, scene: doc.workingScene, identity: doc.identity, selected: id,
                origin: .zero, zoom: 5), .corner(id, 0))
    }
    func testProceduralLayersAreNeverImageHits() throws {
        var model = doc.state.workingModel
        model.layers[1].content = .trail(.init(colors: [.init(r: 1, g: 1, b: 1)]), visible: true)
        model.layers.remove(at: 0)
        let scene = try model.scene()
        XCTAssertNil(
            WSSCanvasInteractionGeometry.hit(
                point: .zero, scene: scene, identity: WSSEditorIdentity(model), selected: nil,
                origin: .zero, zoom: 1))
    }
    func testMoveUsesOriginalSceneDelta() throws {
        let t = try transform()
        var g = WSSCanvasGesture(kind: .move, transform: t, start: SIMD2(20, 30))
        XCTAssertEqual(try g.transform(at: SIMD2(45, 10)).center, [145, 130])
        XCTAssertEqual(try g.transform(at: SIMD2(30, 50)).center, [130, 170])
    }
    func testProportionalScalePreservesRatioSizeAndOppositeAnchor() throws {
        let t = try transform()
        let native = try t.native()
        for index in 0..<4 {
            let corner = WSSCanvasInteractionGeometry.corners[index]
            let start = native.point(corner)
            let anchor = native.point(-corner)
            var g = WSSCanvasGesture(
                kind: .scale(index, independent: false), transform: t, start: start)
            let result = try g.transform(at: anchor + (start - anchor) * 1.5)
            XCTAssertEqual(result.scale[0], 3, accuracy: 0.0001)
            XCTAssertEqual(result.scale[1], 1.5, accuracy: 0.0001)
            XCTAssertEqual(result.size, t.size)
            assertPoint(try result.native().point(-corner), anchor)
        }
    }
    func testIndependentScaleAndUpperBoundWithoutMirroring() throws {
        let t = try transform()
        let n = try t.native()
        let corner = WSSCanvasInteractionGeometry.corners[2]
        let start = n.point(corner)
        let anchor = n.point(-corner)
        var g = WSSCanvasGesture(kind: .scale(2, independent: true), transform: t, start: start)
        let result = try g.transform(at: anchor + n.axisX * 2 + n.axisY * 3)
        XCTAssertEqual(result.scale[0], 4, accuracy: 0.0001)
        XCTAssertEqual(result.scale[1], 3, accuracy: 0.0001)
        assertPoint(try result.native().point(-corner), anchor)
        let bounded = try g.transform(at: anchor + n.axisX * 1000 + n.axisY * 1000)
        XCTAssertEqual(bounded.scale, [100, 100])
        XCTAssertThrowsError(try g.transform(at: anchor - n.axisX - n.axisY))
        XCTAssertThrowsError(try g.transform(at: anchor))
    }
    func testRotationUnwrapsPiAndKeepsCenterSizeScale() throws {
        let t = try transform()
        let c = SIMD2(t.center[0], t.center[1])
        func p(_ degrees: Float) -> SIMD2<Float> {
            c + SIMD2(cos(degrees * .pi / 180), sin(degrees * .pi / 180)) * 100
        }
        var g = WSSCanvasGesture(kind: .rotate, transform: t, start: p(170))
        let a = try g.transform(at: p(-170))
        XCTAssertEqual(a.rotation, t.rotation + 20 * .pi / 180, accuracy: 0.0001)
        XCTAssertEqual(try g.transform(at: c).rotation, a.rotation)
        let b = try g.transform(at: p(-150))
        XCTAssertEqual(b.rotation, t.rotation + 40 * .pi / 180, accuracy: 0.0001)
        XCTAssertEqual(b.center, t.center)
        XCTAssertEqual(b.size, t.size)
        XCTAssertEqual(b.scale, t.scale)
    }
    func testTransactionsUndoRedoAndCancelForAllKinds() throws {
        let id = doc.identity.layers[0].id
        let original = doc.state.workingModel
        for kind: WSSCanvasGesture.Kind in [.move, .scale(2, independent: false), .rotate] {
            XCTAssertTrue(doc.beginCanvasTransform(id, kind: kind))
            var t = try XCTUnwrap(original.layers[0].imageTransform)
            for value: Float in [40, 50, 60] {
                t.center = [value, value]
                t.scale = [2, 1]
                t.rotation = .pi / 3
                try doc.updateCanvasTransform(t)
            }
            let end = doc.state.workingModel
            doc.endCanvasTransform()
            doc.undoManager.undo()
            XCTAssertEqual(doc.state.workingModel, original)
            XCTAssertFalse(doc.undoManager.canUndo)
            doc.undoManager.redo()
            XCTAssertEqual(doc.state.workingModel, end)
            doc.undoManager.undo()
            doc.undoManager.removeAllActions()
            XCTAssertTrue(doc.beginCanvasTransform(id, kind: kind))
            try doc.updateCanvasTransform(t)
            let revision = doc.state.workingRevision
            doc.endCanvasTransform(cancel: true)
            XCTAssertEqual(doc.state.workingModel, original)
            XCTAssertGreaterThan(doc.state.workingRevision, revision)
            XCTAssertFalse(doc.isDirty)
            XCTAssertFalse(doc.undoManager.canUndo)
        }
    }
    func testNoOpInvalidAndSelectionDoNotCreateUndo() throws {
        let id = doc.identity.layers[0].id
        doc.select(.layer(id))
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .move))
        var t = try XCTUnwrap(doc.state.workingModel.layers[0].imageTransform)
        try doc.updateCanvasTransform(t)
        doc.endCanvasTransform()
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .move))
        t.scale[0] = -1
        XCTAssertThrowsError(try doc.updateCanvasTransform(t))
        doc.endCanvasTransform()
        XCTAssertFalse(doc.isDirty)
    }
    func testStructureRevertUndoAndCloseFinishOpenTransaction() throws {
        let id = doc.identity.layers[0].id
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .move))
        var t = try XCTUnwrap(doc.state.workingModel.layers[0].imageTransform)
        t.center[0] += 12
        try doc.updateCanvasTransform(t)
        doc.undoManager.undo()
        XCTAssertNil(doc.canvasTransform)
        XCTAssertFalse(doc.isDirty)
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .move))
        try doc.updateCanvasTransform(t)
        try doc.moveLayer(id, by: 1)
        XCTAssertNil(doc.canvasTransform)
        doc.revert()
        XCTAssertFalse(doc.isDirty)
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .move))
        try doc.updateCanvasTransform(t)
        doc.close()
        XCTAssertNil(doc.canvasTransform)
    }
    func testReuseRejectsAnyNonTransformChangeAndRetainsAllTextures() throws {
        let original = helper.project.document
        var model = original
        if case .image(var image) = model.layers[0].content {
            image.transform.center[0] += 10
            model.layers[0].content = .image(image)
        }
        let resources = helper.project.resources
        let reused = try XCTUnwrap(resources.updatingTransforms(from: original, to: model))
        XCTAssertTrue(reused.sharesPreparedResources(with: resources))
        for (key, image) in resources.images {
            XCTAssertTrue(reused.images[key]?.texture === image.texture)
            XCTAssertTrue(reused.images[key]?.sampler === image.sampler)
        }
        XCTAssertEqual(reused.scene.imageLayers[0].transform.center.x, 42)
        for property in [WSSImageProperty.opacity, .width] {
            var changed = model
            if case .image(var image) = changed.layers[0].content {
                if property == .opacity {
                    image.opacity = 0.5
                } else {
                    image.asset = "assets/other.png"
                }
                changed.layers[0].content = .image(image)
            }
            XCTAssertNil(try resources.updatingTransforms(from: original, to: changed))
        }
        var effects = model
        if case .image(var image) = effects.layers[0].content {
            image.effects.removeAll()
            effects.layers[0].content = .image(image)
        }
        XCTAssertNil(try resources.updatingTransforms(from: original, to: effects))
    }
    func testActualCanvasMouseSelectionMoveThresholdEscapeAndZoomLock() async throws {
        let canvas = WSSCanvasScrollView(document: doc)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        defer {
            canvas.shutdown()
            window.close()
        }
        for zoom: CGFloat in [1, 4] {
            canvas.update(doc, zoom: zoom)
            canvas.layoutSubtreeIfNeeded()
            let center = canvas.viewPoint(for: SIMD2(32, 32))
            func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(
                    with: type, location: canvas.surface.convert(point, to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                    clickCount: type == .leftMouseDown ? 2 : 1, pressure: 1)!
            }
            canvas.surface.mouseDown(with: mouse(.leftMouseDown, center))
            XCTAssertEqual(doc.selection, .layer(doc.identity.layers[1].id))
            XCTAssertFalse(doc.isDirty)
            canvas.surface.mouseDragged(
                with: mouse(.leftMouseDragged, CGPoint(x: center.x + 1, y: center.y)))
            XCTAssertNil(doc.canvasTransform)
            let end = CGPoint(x: center.x + 12 * zoom, y: center.y - 8 * zoom)
            canvas.surface.mouseDragged(with: mouse(.leftMouseDragged, end))
            XCTAssertEqual(doc.state.workingModel.layers[1].imageTransform?.center, [44, 40])
            XCTAssertEqual(doc.canvasModel.layers[1].imageTransform?.center, [44, 40])
            let pointBefore = canvas.viewPoint(for: SIMD2(32, 32))
            canvas.update(doc, zoom: 8)
            XCTAssertEqual(canvas.viewPoint(for: SIMD2(32, 32)), pointBefore)
            let escape = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            canvas.keyDown(with: escape)
            XCTAssertFalse(doc.isDirty)
            XCTAssertFalse(doc.undoManager.canUndo)
            XCTAssertFalse(canvas.isTransforming)
            XCTAssertEqual(doc.transformModeLayer, doc.identity.layers[1].id)
            // The real event path, including an outside-canvas mouseUp, coalesces undo.
            canvas.surface.mouseDown(with: mouse(.leftMouseDown, center))
            canvas.surface.mouseDragged(with: mouse(.leftMouseDragged, end))
            canvas.surface.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: -100, y: -100)))
            doc.undoManager.undo()
            XCTAssertFalse(doc.isDirty)
            XCTAssertFalse(doc.undoManager.canUndo)
            doc.undoManager.redo()
            XCTAssertEqual(doc.state.workingModel.layers[1].imageTransform?.center, [44, 40])
            doc.undoManager.undo()
            doc.undoManager.removeAllActions()
        }
    }
    func testCanvasAndDefaultPreviewDragDoNotReadDecodeOrUploadAgain() async throws {
        let canvas = WSSCanvasScrollView(document: doc)
        defer { canvas.shutdown() }
        for _ in 0..<100 {
            if canvas.surface.resources != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let initialCanvas = try XCTUnwrap(canvas.surface.resources)
        let initialPreview = doc.previewResources
        // Only our generated private temporary fixtures are removed. Any new disk
        // read/decode would now fail; already prepared GPU resources must suffice.
        for path in helper.project.document.referencedPaths {
            try FileManager.default.removeItem(
                at: helper.project.handle.root.appendingPathComponent(path))
        }
        let id = doc.identity.layers[0].id
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .move))
        var t = try XCTUnwrap(doc.state.workingModel.layers[0].imageTransform)
        for value: Float in [33, 35, 40, 50] {
            t.center[0] = value
            try doc.updateCanvasTransform(t)
            canvas.update(doc, zoom: 1)
        }
        doc.endCanvasTransform()
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        XCTAssertEqual(doc.previewResources.scene.imageLayers[0].transform.center.x, 50)
        let endCanvas = try XCTUnwrap(canvas.surface.resources)
        XCTAssertTrue(endCanvas.sharesPreparedResources(with: initialCanvas))
        XCTAssertTrue(doc.previewResources.sharesPreparedResources(with: initialPreview))
        for (key, image) in initialCanvas.images {
            XCTAssertTrue(endCanvas.images[key]?.texture === image.texture)
        }
        XCTAssertEqual(
            doc.previewResources.scene.imageLayers.map(\.effects),
            initialPreview.scene.imageLayers.map(\.effects))
    }
    func testRealPreviewPathKeepsPlayerClockPauseTrailAndReadOnlyEffects() async throws {
        let fixtures = WSSEditorLivePreviewTests()
        try await fixtures.setUp()
        defer { try? fixtures.helper.tearDownWithError() }
        let loaded = try await fixtures.project("WSS-Ripple-v1")
        let editor = WSSEditorDocument(project: loaded)
        let host = WSSPreviewHost(document: editor)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.update(editor)
        defer {
            editor.close()
            window.close()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let player = try XCTUnwrap(host.surface.player)
        let ripple = player.rippleContext
        let trail = player.trailContext
        let before = player.elapsed
        let id = editor.identity.layers[0].id
        XCTAssertTrue(editor.beginCanvasTransform(id, kind: .rotate))
        var t = try XCTUnwrap(editor.state.workingModel.layers[0].imageTransform)
        t.rotation += 0.2
        try editor.updateCanvasTransform(t)
        editor.endCanvasTransform()
        await editor.waitForPreview()
        host.update(editor)
        XCTAssertTrue(host.surface.player === player)
        XCTAssertTrue(player.rippleContext === ripple)
        XCTAssertTrue(player.trailContext === trail)
        XCTAssertGreaterThan(player.elapsed, before)
        XCTAssertEqual(
            player.resources.scene.imageLayers.map(\.effects),
            loaded.scene.imageLayers.map(\.effects))
        XCTAssertTrue(
            editor.canvasModel.layers.allSatisfy {
                if case .image(let image) = $0.content { return image.effects.isEmpty }
                return false
            })
        editor.playing = false
        host.update(editor)
        let frozen = player.elapsed
        host.expand()
        try editor.setImage(.centerX, value: 40, layer: id)
        await editor.waitForPreview()
        host.update(editor)
        XCTAssertTrue(host.surface.player === player)
        XCTAssertEqual(player.elapsed, frozen)
        XCTAssertTrue(player.view.isPaused)
        XCTAssertTrue(host.surface.window === host.expandedWindow)
        host.restore()
        XCTAssertTrue(host.surface.player === player)
    }
    func canvasWindow(zoom: CGFloat = 3) -> (WSSCanvasScrollView, NSWindow) {
        let canvas = WSSCanvasScrollView(document: doc)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        canvas.update(doc, zoom: zoom)
        canvas.layoutSubtreeIfNeeded()
        return (canvas, window)
    }
    func event(
        _ type: NSEvent.EventType, _ point: CGPoint, canvas: WSSCanvasScrollView, window: NSWindow,
        shift: Bool = false
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: canvas.surface.convert(point, to: nil),
            modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: type == .leftMouseDown ? 2 : 1, pressure: 1)!
    }
    func testNativeScaleLocksShiftAtMouseDownAndRotationUsesActualHandle() throws {
        let (canvas, window) = canvasWindow()
        defer {
            canvas.shutdown()
            window.close()
        }
        let id = doc.identity.layers[1].id
        doc.select(.layer(id))
        XCTAssertTrue(doc.activateTransformMode(id))
        canvas.update(doc, zoom: 3)
        for independent in [false, true] {
            let start = canvas.viewPoint(for: SIMD2(64, 64))
            let end = canvas.viewPoint(for: SIMD2(96, 128))
            canvas.surface.mouseDown(
                with: event(
                    .leftMouseDown, start, canvas: canvas, window: window, shift: independent))
            canvas.surface.mouseDragged(
                with: event(
                    .leftMouseDragged, end, canvas: canvas, window: window, shift: !independent))
            let t = try XCTUnwrap(doc.state.workingModel.layers[1].imageTransform)
            if independent {
                XCTAssertEqual(t.scale[0], 1.5, accuracy: 0.0001)
                XCTAssertEqual(t.scale[1], 2, accuracy: 0.0001)
            } else {
                XCTAssertEqual(t.scale[0], t.scale[1], accuracy: 0.0001)
            }
            assertPoint(try t.native().point(SIMD2(-0.5, -0.5)), .zero)
            canvas.surface.mouseUp(with: event(.leftMouseUp, end, canvas: canvas, window: window))
            doc.undoManager.undo()
            XCTAssertFalse(doc.isDirty)
            doc.undoManager.removeAllActions()
        }
        let center = canvas.viewPoint(for: SIMD2(32, 32))
        let top = canvas.viewPoint(for: SIMD2(32, 64))
        let handle = CGPoint(x: top.x, y: top.y - 28)
        let end = CGPoint(x: center.x + 100, y: center.y)
        canvas.surface.mouseDown(
            with: event(.leftMouseDown, handle, canvas: canvas, window: window))
        canvas.surface.mouseDragged(
            with: event(.leftMouseDragged, end, canvas: canvas, window: window))
        XCTAssertEqual(
            try XCTUnwrap(doc.state.workingModel.layers[1].imageTransform).rotation, -.pi / 2,
            accuracy: 0.0001)
        canvas.surface.mouseUp(with: event(.leftMouseUp, end, canvas: canvas, window: window))
        doc.undoManager.undo()
        XCTAssertFalse(doc.isDirty)
    }
    func testEffectSelectionCanvasPromotionFocusLossAndSpacePan() throws {
        let first = doc.identity.layers[0]
        try doc.setVisibility(false, layer: doc.identity.layers[1].id)
        doc.undoManager.removeAllActions()
        doc.select(.effect(first.id, first.effects[0]))
        XCTAssertTrue(doc.maskCanvas.brushEnabled)
        // This test exercises promotion/transform, so explicitly leave direct mask paint.
        doc.maskCanvas.setBrush(false)
        let original = doc.state.workingModel
        let (canvas, window) = canvasWindow(zoom: 16)
        defer {
            canvas.shutdown()
            window.close()
        }
        let center = canvas.viewPoint(for: SIMD2(32, 32))
        canvas.surface.mouseDown(
            with: event(.leftMouseDown, center, canvas: canvas, window: window))
        XCTAssertEqual(doc.selection, .layer(first.id))
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertFalse(doc.undoManager.canUndo)
        let end = CGPoint(x: center.x + 80, y: center.y)
        canvas.surface.mouseDragged(
            with: event(.leftMouseDragged, end, canvas: canvas, window: window))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertNil(doc.canvasTransform)
        XCTAssertFalse(canvas.isTransforming)
        XCTAssertTrue(doc.undoManager.canUndo)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        let space = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        window.makeFirstResponder(canvas)
        canvas.keyDown(with: space)
        let oldOrigin = canvas.contentView.bounds.origin
        canvas.surface.mouseDown(
            with: event(.leftMouseDown, center, canvas: canvas, window: window))
        canvas.surface.mouseDragged(
            with: event(
                .leftMouseDragged, CGPoint(x: center.x + 60, y: center.y), canvas: canvas,
                window: window))
        canvas.surface.mouseUp(with: event(.leftMouseUp, center, canvas: canvas, window: window))
        canvas.keyUp(with: space)
        XCTAssertNotEqual(canvas.contentView.bounds.origin, oldOrigin)
        XCTAssertEqual(doc.state.workingModel, original)
    }
    func testEscapeLatestPreviewAndSaveReopenUseFinalTransform() async throws {
        let storage = helper.helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([helper.item!]).write(to: storage)
        let store = ManagedWallpaperStore(storage: storage)
        doc.close()
        doc = WSSEditorDocument(
            project: helper.project,
            save: { snapshot in
                let candidate = try await WSSManifestSaveValidator().prepare(
                    snapshot, handle: self.helper.project.handle)
                return try await store.commitWSSManifest(candidate)
            })
        let original = doc.state.workingModel
        let id = doc.identity.layers[0].id
        var t = try XCTUnwrap(original.layers[0].imageTransform)
        t.center[0] = 99
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .move))
        try doc.updateCanvasTransform(t)
        doc.endCanvasTransform(cancel: true)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        XCTAssertEqual(doc.previewResources.scene.imageLayers[0].transform.center.x, 32)
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .move))
        try doc.updateCanvasTransform(t)
        // Save finalizes the transaction and serializes only its final transform.
        let success = await doc.save()
        XCTAssertTrue(success)
        XCTAssertNil(doc.canvasTransform)
        let reopened = try await WSSEditorProjectLoader().load(helper.item)
        XCTAssertEqual(reopened.document, doc.state.workingModel)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertTrue(doc.isDirty)
    }

    private func singleMouseEvent(
        _ type: NSEvent.EventType, at point: CGPoint,
        canvas: WSSCanvasScrollView, window: NSWindow
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: canvas.surface.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1,
            clickCount: 1, pressure: 1)!
    }
    private func freeCanvasPoint(_ canvas: WSSCanvasScrollView) throws -> CGPoint {
        let rect = canvas.surface.visibleRect
        let point = CGPoint(x: rect.minX + 12, y: rect.minY + 12)
        XCTAssertTrue(rect.contains(point))
        XCTAssertNil(canvas.canvasHit(at: point))
        return point
    }
    func testBackgroundSingleClickLeavesTransformModeWithoutChangingSelectionOrModel() throws {
        let (canvas, window) = canvasWindow()
        defer {
            canvas.shutdown()
            window.close()
        }
        let id = doc.identity.layers[1].id
        doc.select(.layer(id))
        XCTAssertTrue(doc.activateTransformMode(id))
        canvas.update(doc, zoom: 3)
        let before = doc.state.workingModel
        let point = try freeCanvasPoint(canvas)
        canvas.surface.mouseDown(
            with: singleMouseEvent(.leftMouseDown, at: point, canvas: canvas, window: window))
        canvas.surface.mouseUp(
            with: singleMouseEvent(.leftMouseUp, at: point, canvas: canvas, window: window))
        XCTAssertNil(doc.transformModeLayer)
        XCTAssertFalse(canvas.surface.showsTransformHandles)
        XCTAssertEqual(doc.selection, .layer(id))
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertFalse(doc.isDirty)
    }
    func testImageAndHandleSingleClicksKeepTransformMode() throws {
        let (canvas, window) = canvasWindow()
        defer {
            canvas.shutdown()
            window.close()
        }
        let id = doc.identity.layers[1].id
        doc.select(.layer(id))
        XCTAssertTrue(doc.activateTransformMode(id))
        canvas.update(doc, zoom: 3)
        let before = doc.state.workingModel
        let center = canvas.viewPoint(for: SIMD2(32, 32))
        let corner = canvas.viewPoint(for: SIMD2(64, 64))
        XCTAssertEqual(canvas.canvasHit(at: center), .image(id))
        XCTAssertEqual(canvas.canvasHit(at: corner), .corner(id, 2))
        for point in [center, corner] {
            canvas.surface.mouseDown(
                with: singleMouseEvent(.leftMouseDown, at: point, canvas: canvas, window: window))
            XCTAssertEqual(doc.transformModeLayer, id)
            canvas.surface.mouseUp(
                with: singleMouseEvent(.leftMouseUp, at: point, canvas: canvas, window: window))
            XCTAssertEqual(doc.transformModeLayer, id)
            XCTAssertTrue(canvas.surface.showsTransformHandles)
        }
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testBackgroundWithoutTransformModePreservesSelectionAndModel() throws {
        let (canvas, window) = canvasWindow()
        defer {
            canvas.shutdown()
            window.close()
        }
        let selection = doc.selection
        let before = doc.state.workingModel
        let point = try freeCanvasPoint(canvas)
        canvas.surface.mouseDown(
            with: singleMouseEvent(.leftMouseDown, at: point, canvas: canvas, window: window))
        canvas.surface.mouseUp(
            with: singleMouseEvent(.leftMouseUp, at: point, canvas: canvas, window: window))
        XCTAssertNil(doc.transformModeLayer)
        XCTAssertEqual(doc.selection, selection)
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testBackgroundDownDuringPendingOrActiveDragDoesNotLeaveMode() throws {
        let (canvas, window) = canvasWindow()
        defer {
            canvas.shutdown()
            window.close()
        }
        let id = doc.identity.layers[1].id
        doc.select(.layer(id))
        XCTAssertTrue(doc.activateTransformMode(id))
        canvas.update(doc, zoom: 3)
        let center = canvas.viewPoint(for: SIMD2(32, 32))
        let background = try freeCanvasPoint(canvas)
        canvas.surface.mouseDown(
            with: singleMouseEvent(.leftMouseDown, at: center, canvas: canvas, window: window))
        canvas.surface.mouseDown(
            with: singleMouseEvent(.leftMouseDown, at: background, canvas: canvas, window: window))
        XCTAssertEqual(doc.transformModeLayer, id)
        let moved = CGPoint(x: center.x + 12, y: center.y)
        canvas.surface.mouseDragged(
            with: singleMouseEvent(.leftMouseDragged, at: moved, canvas: canvas, window: window))
        XCTAssertNotNil(doc.canvasTransform)
        canvas.surface.mouseDown(
            with: singleMouseEvent(.leftMouseDown, at: background, canvas: canvas, window: window))
        XCTAssertEqual(doc.transformModeLayer, id)
        XCTAssertNotNil(doc.canvasTransform)
        canvas.surface.mouseUp(
            with: singleMouseEvent(.leftMouseUp, at: moved, canvas: canvas, window: window))
        XCTAssertEqual(doc.transformModeLayer, id)
        XCTAssertNil(doc.canvasTransform)
    }

    func testSelectionAndSingleDragDoNotActivateTransformOrMutate() throws {
        let (canvas, window) = canvasWindow()
        defer {
            canvas.shutdown()
            window.close()
        }
        let before = doc.state.workingModel
        let center = canvas.viewPoint(for: SIMD2(32, 32))
        func click(_ type: NSEvent.EventType, _ point: CGPoint, count: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: canvas.surface.convert(point, to: nil), modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count,
                pressure: 1)!
        }
        XCTAssertNil(doc.transformModeLayer)
        XCTAssertFalse(canvas.surface.showsTransformHandles)
        canvas.surface.mouseDown(with: click(.leftMouseDown, center))
        canvas.surface.mouseDragged(
            with: click(.leftMouseDragged, CGPoint(x: center.x + 90, y: center.y)))
        canvas.surface.mouseUp(with: click(.leftMouseUp, center))
        XCTAssertEqual(doc.selection, .layer(doc.identity.layers[1].id))
        XCTAssertNil(doc.transformModeLayer)
        XCTAssertFalse(canvas.surface.showsTransformHandles)
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertFalse(doc.isDirty)
        let corner = canvas.viewPoint(for: SIMD2(64, 64))
        XCTAssertEqual(canvas.canvasHit(at: corner), .image(doc.identity.layers[1].id))
        canvas.surface.mouseDown(with: click(.leftMouseDown, center, count: 2))
        canvas.surface.mouseUp(with: click(.leftMouseUp, center))
        XCTAssertEqual(doc.transformModeLayer, doc.identity.layers[1].id)
        XCTAssertTrue(canvas.surface.showsTransformHandles)
        XCTAssertEqual(canvas.canvasHit(at: corner), .corner(doc.identity.layers[1].id, 2))
        XCTAssertFalse(doc.isDirty)
        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        canvas.keyDown(with: escape)
        XCTAssertNil(doc.transformModeLayer)
        XCTAssertFalse(canvas.surface.showsTransformHandles)
        XCTAssertEqual(doc.state.workingModel, before)
    }
    func testModeSelectionChangesBackgroundAndOnlyOneOutline() throws {
        let (canvas, window) = canvasWindow()
        defer {
            canvas.shutdown()
            window.close()
        }
        let model = doc.state.workingModel
        let image = doc.identity.layers[0]
        doc.select(.layer(image.id))
        XCTAssertTrue(doc.activateTransformMode(image.id))
        canvas.update(doc, zoom: 3)
        XCTAssertTrue(canvas.surface.showsTransformHandles)
        func outlines(_ view: NSView) -> Int {
            (view.accessibilityIdentifier() == "wss.transform-outline" ? 1 : 0)
                + view.subviews.reduce(0) { $0 + outlines($1) }
        }
        XCTAssertEqual(outlines(canvas), 1)
        doc.select(.effect(image.id, image.effects[0]))
        canvas.update(doc, zoom: 3)
        XCTAssertNil(doc.transformModeLayer)
        XCTAssertFalse(canvas.surface.showsTransformHandles)
        doc.select(.layer(doc.identity.layers[1].id))
        XCTAssertTrue(doc.activateTransformMode(doc.identity.layers[1].id))
        doc.select(.layer(image.id))
        XCTAssertNil(doc.transformModeLayer)
        // v1 background is RGB data, not a layer or a selectable image ID.
        XCTAssertFalse(doc.activateTransformMode(WSSLayerID()))
        XCTAssertEqual(doc.state.workingModel.background, model.background)
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertFalse(doc.isDirty)
        doc.close()
        XCTAssertNil(doc.transformModeLayer)
    }

}
