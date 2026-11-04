import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSCanvasSpacePanTests: XCTestCase {
    var helper: WSSMaskCanvasTests!
    var doc: WSSEditorDocument { helper.doc }
    var canvas: WSSCanvasScrollView!
    var window: WSSEditorNativeWindow!
    override func setUp() async throws {
        helper = WSSMaskCanvasTests()
        try await helper.setUp()
        _ = NSApplication.shared
        window = WSSEditorNativeWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.editorDocument = doc
        canvas = WSSCanvasScrollView(document: doc)
        window.contentView = canvas
        XCTAssertTrue(window.makeFirstResponder(canvas))
        XCTAssertTrue(window.firstResponder === canvas)
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        canvas.update(doc, zoom: 4)
        canvas.layoutSubtreeIfNeeded()
        try await doc.manageMask(.clear)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        doc.undoManager.removeAllActions()
        await doc.maskCanvas.waitForLoad()
        helper.brush()
    }
    override func tearDown() async throws {
        canvas.shutdown()
        canvas = nil
        window.close()
        window = nil
        try await helper.tearDown()
        helper = nil
    }
    func key(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = [], characters: String = " ")
        throws -> NSEvent
    {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: 49))
    }
    func mouse(
        _ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = [], offset: SIMD2<Float> = .zero
    ) throws -> NSEvent {
        try helper.event(type, canvas: canvas, scene: helper.scene() + offset, flags: flags)
    }
    func pan() throws {
        window.sendEvent(try key(.keyDown))
        canvas.beginInteraction(try mouse(.leftMouseDown))
        XCTAssertEqual(canvas.interactionPhase, .panning)
        canvas.dragInteraction(try mouse(.leftMouseDragged, offset: SIMD2(5, 5)))
        XCTAssertFalse(doc.activeCanvasPaint?.isDrawing == true)
        canvas.endInteraction(try mouse(.leftMouseUp))
        window.sendEvent(try key(.keyUp))
        XCTAssertFalse(doc.canvasSpaceDown)
        XCTAssertEqual(canvas.interactionPhase, .idle)
    }
    func testWindowLevelSpaceReleaseCannotLeaveCanvasLatchedInPan() throws {
        // sendEvent records Space even when keyUp is consumed above the Canvas responder.
        doc.canvasSpaceDown = true
        canvas.keyDown(with: try key(.keyDown))
        canvas.beginInteraction(try mouse(.leftMouseDown))
        XCTAssertEqual(canvas.interactionPhase, .panning)
        canvas.endInteraction(try mouse(.leftMouseUp))
        doc.canvasSpaceDown = false
        canvas.beginInteraction(try mouse(.leftMouseDown))
        XCTAssertTrue(doc.maskCanvas.isDrawing)
        XCTAssertEqual(canvas.interactionPhase, .painting)
        doc.maskCanvas.cancelStroke()
    }
    func testBothReleaseOrdersStopPanAndNeverConvertTrailingDragToPaint() throws {
        canvas.frame.size = CGSize(width: 160, height: 160)
        canvas.update(doc, zoom: 4)
        canvas.layoutSubtreeIfNeeded()
        for keyFirst in [false, true] {
            let before = doc.state.workingModel
            let generations = doc.state.sessionAssets.count
            canvas.contentView.scroll(to: CGPoint(x: 40, y: 40))
            window.sendEvent(try key(.keyDown))
            canvas.beginInteraction(try mouse(.leftMouseDown))
            let originalOrigin = canvas.contentView.bounds.origin
            canvas.dragInteraction(try mouse(.leftMouseDragged, offset: SIMD2(5, 5)))
            XCTAssertNotEqual(canvas.contentView.bounds.origin, originalOrigin)
            if keyFirst {
                window.sendEvent(try key(.keyUp))
                let releasedOrigin = canvas.contentView.bounds.origin
                canvas.dragInteraction(try mouse(.leftMouseDragged, offset: SIMD2(10, 10)))
                XCTAssertEqual(canvas.contentView.bounds.origin, releasedOrigin)
                XCTAssertFalse(doc.maskCanvas.isDrawing)
                canvas.endInteraction(try mouse(.leftMouseUp))
            } else {
                canvas.endInteraction(try mouse(.leftMouseUp))
                window.sendEvent(try key(.keyUp))
            }
            XCTAssertEqual(canvas.interactionPhase, .idle)
            XCTAssertFalse(doc.canvasSpaceDown)
            XCTAssertTrue(doc.maskCanvas.brushEnabled)
            XCTAssertEqual(doc.state.workingModel, before)
            XCTAssertEqual(doc.state.sessionAssets.count, generations)
            XCTAssertFalse(doc.isDirty)
            XCTAssertFalse(doc.undoManager.canUndo)
            canvas.beginInteraction(try mouse(.leftMouseDown))
            XCTAssertTrue(doc.maskCanvas.isDrawing)
            doc.maskCanvas.cancelStroke()
        }
    }
    func testSpaceWithoutDragAndAutoRepeatKeepToolAndDocumentUntouched() throws {
        let before = doc.state.workingModel
        let revision = doc.state.workingRevision
        let origin = canvas.contentView.bounds.origin
        for _ in 0..<3 {
            window.sendEvent(try key(.keyDown))
            window.sendEvent(try key(.keyDown))
            XCTAssertTrue(doc.canvasSpaceDown)
            XCTAssertFalse(doc.maskCanvas.isDrawing)
            window.sendEvent(try key(.keyUp))
            XCTAssertFalse(doc.canvasSpaceDown)
        }
        XCTAssertEqual(canvas.contentView.bounds.origin, origin)
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertEqual(doc.state.workingRevision, revision)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertTrue(doc.maskCanvas.brushEnabled)
        canvas.beginInteraction(try mouse(.leftMouseDown))
        XCTAssertTrue(doc.maskCanvas.isDrawing)
        doc.maskCanvas.cancelStroke()
    }
    func testRepeatedPanPaintAndEraseUseNormalSingleStrokeUndo() async throws {
        for opacity: Double in [1, 0.5, 0.25] {
            let before = doc.state.workingModel
            doc.maskCanvas.setOpacity(opacity)
            try pan()
            XCTAssertEqual(doc.state.workingModel, before)
            canvas.beginInteraction(try mouse(.leftMouseDown))
            canvas.dragInteraction(try mouse(.leftMouseDragged))
            canvas.endInteraction(try mouse(.leftMouseUp))
            await doc.maskCanvas.waitForFinish()
            await doc.maskCanvas.waitForLoad()
            XCTAssertNotEqual(doc.state.workingModel, before)
            doc.undoManager.undo()
            XCTAssertEqual(doc.state.workingModel, before)
            XCTAssertFalse(doc.undoManager.canUndo)
            XCTAssertFalse(doc.isDirty)
            await doc.maskCanvas.waitForLoad()
        }
        doc.maskCanvas.setOpacity(1)
        canvas.beginInteraction(try mouse(.leftMouseDown))
        canvas.endInteraction(try mouse(.leftMouseUp))
        await doc.maskCanvas.waitForFinish()
        await doc.maskCanvas.waitForLoad()
        let painted = doc.state.workingModel
        try pan()
        canvas.beginInteraction(try mouse(.leftMouseDown, flags: .option))
        // The initial erase modifier remains frozen even when Option is released.
        canvas.dragInteraction(try mouse(.leftMouseDragged))
        canvas.endInteraction(try mouse(.leftMouseUp))
        await doc.maskCanvas.waitForFinish()
        await doc.maskCanvas.waitForLoad()
        XCTAssertTrue(try XCTUnwrap(doc.maskCanvas.pixels).allSatisfy { $0 == 0 })
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, painted)
    }
    func testFocusWindowAndAppResetsDoNotChangeSelectedBrush() throws {
        let selected = doc.selection
        for notification in [
            NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification,
        ] {
            window.sendEvent(try key(.keyDown))
            canvas.beginInteraction(try mouse(.leftMouseDown))
            NotificationCenter.default.post(
                name: notification,
                object: notification == NSWindow.didResignKeyNotification
                    ? window : NSApplication.shared)
            XCTAssertFalse(doc.canvasSpaceDown)
            XCTAssertEqual(canvas.interactionPhase, .idle)
            XCTAssertEqual(doc.selection, selected)
            XCTAssertTrue(doc.maskCanvas.brushEnabled)
            XCTAssertFalse(doc.isDirty)
            canvas.beginInteraction(try mouse(.leftMouseDown))
            XCTAssertTrue(doc.maskCanvas.isDrawing)
            doc.maskCanvas.cancelStroke()
        }
        window.sendEvent(try key(.keyDown))
        canvas.beginInteraction(try mouse(.leftMouseDown))
        XCTAssertTrue(window.firstResponder === canvas)
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(doc.canvasSpaceDown)
        XCTAssertEqual(canvas.interactionPhase, .idle)
        XCTAssertTrue(window.makeFirstResponder(canvas))
        XCTAssertTrue(doc.maskCanvas.brushEnabled)
        canvas.beginInteraction(try mouse(.leftMouseDown))
        XCTAssertTrue(doc.maskCanvas.isDrawing)
        _ = canvas.resignFirstResponder()
        XCTAssertFalse(doc.maskCanvas.isDrawing)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testOutsideReleaseAndLostMouseUpCannotKeepPanOnNextDown() throws {
        for deliverMouseUp in [true, false] {
            window.sendEvent(try key(.keyDown))
            canvas.beginInteraction(try mouse(.leftMouseDown))
            canvas.dragInteraction(try mouse(.leftMouseDragged, offset: SIMD2(-1000, -1000)))
            window.sendEvent(try key(.keyUp))
            if deliverMouseUp {
                canvas.endInteraction(try mouse(.leftMouseUp, offset: SIMD2(-1000, -1000)))
            }
            canvas.beginInteraction(try mouse(.leftMouseDown))
            XCTAssertTrue(doc.maskCanvas.isDrawing)
            XCTAssertEqual(canvas.interactionPhase, .painting)
            doc.maskCanvas.cancelStroke()
        }
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testCanvasDetachAndShutdownResetTransientSpaceState() throws {
        window.sendEvent(try key(.keyDown))
        canvas.beginInteraction(try mouse(.leftMouseDown))
        canvas.removeFromSuperview()
        XCTAssertFalse(doc.canvasSpaceDown)
        XCTAssertEqual(canvas.interactionPhase, .idle)
        window.contentView = canvas
        XCTAssertTrue(window.makeFirstResponder(canvas))
        window.sendEvent(try key(.keyDown))
        canvas.shutdown()
        XCTAssertFalse(doc.canvasSpaceDown)
        XCTAssertNil(doc.canvasSpaceChanged)
        XCTAssertFalse(doc.isDirty)
    }
    func testRainMasklessPanDoesNotLazilyCreateAnyMask() async throws {
        try doc.addRain()
        let id = try XCTUnwrap(doc.selection?.layer)
        doc.maskCanvas.setDiameter(8)
        let before = doc.state.workingModel
        let generations = doc.state.sessionAssets.count
        try pan()
        XCTAssertNil(doc.selectedMaskTarget)
        XCTAssertNil(doc.rainLayer(id)?.mask)
        XCTAssertEqual(doc.state.sessionAssets.count, generations)
        XCTAssertEqual(doc.state.workingModel, before)
        canvas.beginInteraction(try mouse(.leftMouseDown))
        XCTAssertTrue(doc.maskCanvas.isDrawing)
        canvas.endInteraction(try mouse(.leftMouseUp))
        await doc.maskCanvas.waitForFinish()
        XCTAssertNotNil(doc.rainLayer(id)?.mask)
    }
    func testCloudMaskUsesSamePanReleasePathAndPinchStillWorks() async throws {
        _ = try helper.helper.target(layer: 1)
        await doc.maskCanvas.waitForLoad()
        helper.brush()
        let before = doc.state.workingModel
        try pan()
        XCTAssertEqual(doc.maskManagementTarget?.slot, .clouds)
        canvas.beginInteraction(try mouse(.leftMouseDown))
        XCTAssertTrue(doc.maskCanvas.isDrawing)
        doc.maskCanvas.cancelStroke()
        canvas.update(doc, zoom: 2)
        canvas.applyMagnification(0.25, at: canvas.viewPoint(for: SIMD2(32, 32)))
        XCTAssertEqual(canvas.presentationZoom, 2.5)
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertFalse(doc.isDirty)
    }

    func testOptionSpaceReleaseUsesPhysicalKeyWithoutChangingEraseTool() throws {
        canvas.keyDown(with: try key(.keyDown, flags: .option, characters: "\u{a0}"))
        XCTAssertTrue(doc.canvasSpaceDown)
        canvas.beginInteraction(try mouse(.leftMouseDown, flags: .option))
        XCTAssertEqual(canvas.interactionPhase, .panning)
        XCTAssertFalse(doc.maskCanvas.isDrawing)
        canvas.keyUp(with: try key(.keyUp, flags: .option, characters: "\u{a0}"))
        canvas.endInteraction(try mouse(.leftMouseUp, flags: .option))
        XCTAssertFalse(doc.canvasSpaceDown)
        canvas.beginInteraction(try mouse(.leftMouseDown, flags: .option))
        XCTAssertTrue(doc.maskCanvas.isDrawing)
        doc.maskCanvas.cancelStroke()
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
    }

}
