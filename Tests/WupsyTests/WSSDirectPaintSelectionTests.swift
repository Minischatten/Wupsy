import AppKit
import Combine
import XCTest

@testable import Wupsy

@MainActor final class WSSDirectPaintSelectionTests: XCTestCase {
    var fixture: WSSMaskEditingTests!
    var doc: WSSEditorDocument { fixture.doc }
    var mask: WSSMaskCanvasSession { doc.maskCanvas }
    private var paintTrace: [String] = []
    private var paintSnapshot: (() -> String)?

    override func record(_ issue: XCTIssue) {
        if let paintSnapshot {
            print("DIRECT_PAINT_TRACE\n" + paintTrace.joined(separator: "\n"))
            print("DIRECT_PAINT_FAILURE " + paintSnapshot())
            print("DIRECT_PAINT_ACTUAL_BYTES " + String(describing: mask.pixels.map(Array.init)))
            print("DIRECT_PAINT_ABORT_REASON " + (mask.error ?? "not exposed by session"))
        }
        super.record(issue)
    }

    // Observe only: never await loading, force layout or replace the canvas callbacks.
    private func tracePaint(_ canvas: WSSCanvasScrollView) -> () -> Void {
        paintTrace = []
        paintSnapshot = { [weak self, weak canvas] in
            guard let self, let canvas else { return "host released" }
            let a = canvas.viewPoint(for: SIMD2<Float>(0, 0))
            let b = canvas.viewPoint(for: SIMD2<Float>(1, 0))
            return "drawing=\(self.mask.isDrawing) finalizing=\(self.mask.finalizing) "
                + "loaded=\(String(describing: self.mask.loaded?.resolved.target)) "
                + "geometry=\(String(describing: self.mask.geometry)) "
                + "revision=\(self.doc.state.workingRevision) "
                + "selectionRevision=\(self.doc.selectionRevision) "
                + "zoom=\(b.x - a.x) frame=\(canvas.frame) bounds=\(canvas.bounds) "
                + "surface=\(canvas.surface.frame) clip=\(canvas.contentView.bounds) "
                + "key=\(canvas.window?.isKeyWindow == true) active=\(NSApp.isActive) "
                + "canvasResponder=\(canvas.window?.firstResponder === canvas)"
        }
        let changes = mask.objectWillChange.sink { [weak self] _ in
            self?.traceCheckpoint("session willChange (before mutation)")
        }
        let oldFramePosts = canvas.postsFrameChangedNotifications
        let oldBoundsPosts = canvas.contentView.postsBoundsChangedNotifications
        canvas.postsFrameChangedNotifications = true
        canvas.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        let observers = [
            NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification,
            NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification,
            NSApplication.didResignActiveNotification,
        ].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self, weak canvas] note in
                MainActor.assumeIsolated {
                    guard let canvas,
                        (note.object as? NSView) === canvas
                            || (note.object as? NSView) === canvas.surface
                            || (note.object as? NSView) === canvas.contentView
                            || (note.object as? NSWindow) === canvas.window
                            || (note.object as? NSApplication) === NSApp
                    else { return }
                    self?.traceCheckpoint(name.rawValue)
                }
            }
        }
        traceCheckpoint("trace started")
        return { [weak self, weak canvas] in
            changes.cancel()
            for observer in observers { center.removeObserver(observer) }
            canvas?.postsFrameChangedNotifications = oldFramePosts
            canvas?.contentView.postsBoundsChangedNotifications = oldBoundsPosts
            self?.paintSnapshot = nil
        }
    }

    private func traceCheckpoint(_ phase: String) {
        guard let paintSnapshot else { return }
        paintTrace.append("\(ProcessInfo.processInfo.systemUptime) \(phase): \(paintSnapshot())")
    }
    override func setUp() async throws {
        fixture = WSSMaskEditingTests()
        try await fixture.setUp()
    }
    override func tearDown() async throws {
        await mask.waitForFinish()
        try await fixture.tearDown()
        fixture = nil
    }
    func selectRipple() {
        doc.select(.effect(doc.identity.layers[0].id, doc.identity.layers[0].effects[0]))
    }
    func selectClouds() {
        doc.select(.effect(doc.identity.layers[1].id, doc.identity.layers[1].effects[0]))
    }
    func addFlow() throws -> WSSEditorSelection {
        doc.select(.layer(doc.identity.layers[0].id))
        try doc.addEffect(.flow)
        return try XCTUnwrap(doc.selection)
    }
    func assertScalar(_ slot: WSSMaskSlot, file: StaticString = #filePath, line: UInt = #line) async
    {
        XCTAssertTrue(mask.brushEnabled, file: file, line: line)
        XCTAssertTrue(doc.activeCanvasPaint === mask, file: file, line: line)
        XCTAssertFalse(doc.directionCanvas.brushEnabled, file: file, line: line)
        await mask.waitForLoad()
        XCTAssertEqual(mask.loaded?.resolved.target.slot, slot, file: file, line: line)
    }
    func testExistingScalarSelectionsAreDirectAndDataFreeInEverySwitchDirection() async throws {
        let flow = try addFlow()
        XCTAssertTrue(doc.directionCanvas.brushEnabled)
        let model = doc.state.workingModel
        let revision = doc.state.workingRevision
        let assets = doc.state.sessionAssets.count
        let undoName = doc.undoManager.undoActionName
        selectRipple()
        await assertScalar(.ripple)
        mask.setDiameter(2)
        mask.setOpacity(0.35)
        selectClouds()
        await assertScalar(.clouds)
        selectRipple()
        await assertScalar(.ripple)
        doc.select(flow)
        XCTAssertTrue(doc.directionCanvas.brushEnabled)
        XCTAssertFalse(mask.brushEnabled)
        XCTAssertTrue(doc.activeCanvasPaint === doc.directionCanvas)
        selectRipple()
        await assertScalar(.ripple)
        doc.select(.layer(doc.identity.layers[0].id))
        XCTAssertFalse(doc.paintBrushEnabled)
        XCTAssertNil(doc.activeCanvasPaint)
        selectRipple()
        await assertScalar(.ripple)
        XCTAssertEqual(mask.diameter, 2)
        XCTAssertEqual(mask.opacity, 0.35)
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertEqual(doc.state.workingRevision, revision)
        XCTAssertEqual(doc.state.sessionAssets.count, assets)
        XCTAssertEqual(doc.undoManager.undoActionName, undoName)
    }
    func testEscapeAndExplicitOffStayOffUntilAnotherPaintSelection() async throws {
        selectRipple()
        XCTAssertTrue(mask.brushEnabled)
        XCTAssertTrue(mask.escape())
        await mask.waitForLoad()
        XCTAssertFalse(mask.brushEnabled)
        mask.refresh()
        XCTAssertFalse(mask.brushEnabled)
        selectClouds()
        await assertScalar(.clouds)
        mask.setBrush(false)
        mask.refresh()
        XCTAssertFalse(mask.brushEnabled)
        selectRipple()
        await assertScalar(.ripple)
        XCTAssertFalse(doc.isDirty)
    }
    func nativeCanvas() throws -> (WSSEditorWindowController, WSSCanvasScrollView) {
        _ = NSApplication.shared
        let controller = WSSEditorWindowController(document: doc, onClose: {})
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> WSSCanvasScrollView? {
            if let canvas = view as? WSSCanvasScrollView { return canvas }
            return view.subviews.lazy.compactMap(find).first
        }
        let canvas = try XCTUnwrap(find(try XCTUnwrap(controller.window?.contentView)))
        canvas.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            canvas.shutdown()
            controller.close()
        }
        return (controller, canvas)
    }
    func event(
        _ type: NSEvent.EventType, canvas: WSSCanvasScrollView, point: SIMD2<Float>,
        option: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: canvas.surface.convert(canvas.viewPoint(for: point), to: nil),
                modifierFlags: option ? .option : [], timestamp: 0,
                windowNumber: canvas.window!.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1))
    }
    func down(
        _ controller: WSSEditorWindowController, _ canvas: WSSCanvasScrollView,
        _ point: SIMD2<Float>, option: Bool = false
    ) throws {
        let e = try event(.leftMouseDown, canvas: canvas, point: point, option: option)
        let root = try XCTUnwrap(controller.window?.contentView)
        let parent = try XCTUnwrap(root.superview)
        let hit = try XCTUnwrap(root.hitTest(parent.convert(e.locationInWindow, from: nil)))
        XCTAssertTrue(hit === canvas.surface)
        hit.mouseDown(with: e)
        XCTAssertTrue(mask.isDrawing)
    }
    func testFirstNativePressBeforeExistingMaskLoadUsesScalarBrushAndFrozenErase() async throws {
        let (controller, canvas) = try nativeCanvas()
        let stopTrace = tracePaint(canvas)
        defer { stopTrace() }
        selectRipple()
        XCTAssertTrue(mask.brushEnabled)
        XCTAssertNil(mask.loaded)
        let original = doc.state.workingModel
        try down(controller, canvas, SIMD2(32, 32), option: true)
        traceCheckpoint("first erase mouseDown")
        canvas.surface.mouseDragged(
            with: try event(.leftMouseDragged, canvas: canvas, point: SIMD2(48, 32)))
        canvas.surface.mouseUp(with: try event(.leftMouseUp, canvas: canvas, point: SIMD2(48, 32)))
        traceCheckpoint("erase mouseUp")
        await mask.waitForFinish()
        await mask.waitForLoad()
        traceCheckpoint("erase finished and loaded; expected bytes [0, 0]")
        XCTAssertNil(mask.error)
        XCTAssertFalse(mask.finalizing)
        XCTAssertFalse(doc.hasActivePaintInteraction)
        XCTAssertEqual(
            mask.pixels, Data([0, 0]),
            "actual=\(String(describing: mask.pixels.map(Array.init))) expected=[0, 0]")
        doc.undoManager.undo()
        await mask.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertEqual(
            mask.pixels, Data([0, 255]),
            "actual=\(String(describing: mask.pixels.map(Array.init))) expected=[0, 255]")
    }
    func testMasklessEffectsPrepareOnlyOnFirstNativeStrokeAndKeepTwoUndoSteps() async throws {
        let (controller, canvas) = try nativeCanvas()
        let stopTrace = tracePaint(canvas)
        defer { stopTrace() }
        for kind: WSSAddableEffect in [.ripple, .clouds] {
            doc.select(.layer(doc.identity.layers[0].id))
            try doc.addEffect(kind)
            // New Clouds now starts masked. Keep this regression specifically about
            // the supported legacy maskless path and its two-step lazy preparation.
            if kind == .clouds { try await doc.manageMask(.remove) }
            let selected = try XCTUnwrap(doc.selection)
            let before = doc.state.workingModel
            let assets = doc.state.sessionAssets.count
            XCTAssertTrue(mask.brushEnabled)
            XCTAssertNil(doc.selectedMaskTarget)
            XCTAssertNil(mask.loaded)
            doc.select(.layer(doc.identity.layers[0].id))
            doc.select(selected)
            XCTAssertEqual(doc.state.workingModel, before)
            XCTAssertEqual(doc.state.sessionAssets.count, assets)
            mask.setDiameter(8)
            mask.setOpacity(0.45)
            let frozenDiameter = mask.diameter
            let frozenOpacity = mask.opacity
            try down(controller, canvas, SIMD2(16, 32))
            traceCheckpoint("\(kind) mouseDown")
            canvas.surface.mouseDragged(
                with: try event(.leftMouseDragged, canvas: canvas, point: SIMD2(32, 32)))
            canvas.surface.mouseUp(
                with: try event(.leftMouseUp, canvas: canvas, point: SIMD2(48, 32)))
            traceCheckpoint("\(kind) mouseUp")
            XCTAssertTrue(mask.finalizing)
            XCTAssertEqual(doc.state.workingModel, before)
            XCTAssertFalse(doc.canSave)
            await mask.waitForFinish()
            await mask.waitForLoad()
            await doc.waitForPreview()
            traceCheckpoint("\(kind) finished/loaded/preview; expected nonzero painted bytes")
            XCTAssertNil(mask.error)
            XCTAssertFalse(mask.finalizing)
            XCTAssertFalse(doc.interactionLocked)
            XCTAssertEqual(mask.loaded?.resolved.target.slot, kind == .ripple ? .ripple : .clouds)
            XCTAssertTrue(try XCTUnwrap(mask.pixels).contains { $0 > 0 })
            let painted = doc.state.workingModel
            let paintedPixels = mask.pixels
            doc.undoManager.undo()
            await mask.waitForLoad()
            let created = doc.state.workingModel
            XCTAssertNotEqual(created, before)
            XCTAssertTrue(try XCTUnwrap(mask.pixels).allSatisfy { $0 == 0 })
            let geometry = try XCTUnwrap(mask.geometry)
            var reference = try WSSMaskStrokeTests().stroke(
                XCTUnwrap(mask.loaded?.bitmap), diameter: frozenDiameter, opacity: frozenOpacity,
                start: XCTUnwrap(geometry.texel(SIMD2(16, 32))))
            try reference.append(XCTUnwrap(geometry.texel(SIMD2(32, 32))))
            let expected = try XCTUnwrap(reference.finish(at: geometry.texel(SIMD2(48, 32)))).result
                .pixels
            XCTAssertEqual(
                paintedPixels, expected,
                "Buffered first input must equal the existing streaming scalar painter; "
                    + "actual=\(String(describing: paintedPixels.map(Array.init))) expected=\(Array(expected))"
            )
            doc.undoManager.undo()
            XCTAssertEqual(doc.state.workingModel, before)
            XCTAssertNil(doc.selectedMaskTarget)
            doc.undoManager.redo()
            doc.undoManager.redo()
            await mask.waitForLoad()
            XCTAssertEqual(doc.state.workingModel, painted)
            XCTAssertEqual(
                mask.pixels, paintedPixels,
                "actual=\(String(describing: mask.pixels.map(Array.init))) expected=\(String(describing: paintedPixels.map(Array.init)))"
            )
        }
    }
    func testCancelledPendingInputCannotCreateMaskOrRetargetToClouds() async throws {
        doc.select(.layer(doc.identity.layers[0].id))
        try doc.addEffect(.ripple)
        let before = doc.state.workingModel
        let assets = doc.state.sessionAssets.count
        XCTAssertTrue(mask.begin(SIMD2(16, 32), erase: false))
        XCTAssertFalse(doc.canManageMask(.fill))
        XCTAssertFalse(doc.finishEditing())
        XCTAssertTrue(mask.escape())
        selectClouds()
        await mask.waitForBrushActivation()
        await assertScalar(.clouds)
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertEqual(doc.state.sessionAssets.count, assets)
        XCTAssertFalse(mask.isDrawing)
    }
    func testCapturedPreparationCannotBeRequestedWithoutOwnedInput() async throws {
        doc.select(.layer(doc.identity.layers[0].id))
        try doc.addEffect(.ripple)
        let original = doc.state.workingModel
        do {
            try await doc.manageMask(.create, capturedInput: true)
            XCTFail("Unowned preparation must fail closed")
        } catch {
            XCTAssertTrue(error is WSSMaskError)
        }
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertNil(doc.selectedMaskTarget)
    }
    func testPendingInputLimitCancelsWithoutChangingMaskData() async throws {
        doc.select(.layer(doc.identity.layers[0].id))
        try doc.addEffect(.ripple)
        let before = doc.state.workingModel
        XCTAssertTrue(mask.begin(SIMD2(16, 32), erase: false))
        for _ in 0..<WSSMaskCanvasSession.maximumPendingPoints { mask.append(SIMD2(17, 32)) }
        await mask.waitForBrushActivation()
        XCTAssertFalse(mask.isDrawing)
        XCTAssertNotNil(mask.error)
        XCTAssertEqual(doc.state.workingModel, before)
    }
    func testPreparedHeldFirstStrokeCancelsPaintButKeepsExistingCreateUndoContract() async throws {
        doc.select(.layer(doc.identity.layers[0].id))
        try doc.addEffect(.ripple)
        let unmasked = doc.state.workingModel
        XCTAssertTrue(mask.begin(SIMD2(16, 32), erase: false))
        mask.append(SIMD2(48, 32))
        await mask.waitForBrushActivation()
        XCTAssertTrue(mask.isDrawing)
        XCTAssertFalse(mask.finalizing)
        let created = doc.state.workingModel
        XCTAssertNotEqual(created, unmasked)
        XCTAssertTrue(try XCTUnwrap(mask.pixels).contains { $0 > 0 })
        XCTAssertTrue(mask.escape())
        XCTAssertEqual(doc.state.workingModel, created)
        XCTAssertTrue(try XCTUnwrap(mask.pixels).allSatisfy { $0 == 0 })
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, unmasked)
    }
    func testCloseDrainsPendingPreparationWithoutAdoptingPaint() async throws {
        doc.select(.layer(doc.identity.layers[0].id))
        try doc.addEffect(.ripple)
        let original = doc.state.workingModel
        let files = try fixture.helper.helper.snapshot()
        XCTAssertTrue(mask.begin(SIMD2(16, 32), erase: false))
        mask.finish(SIMD2(48, 32))
        await doc.closeAndDrainForMaintenance()
        XCTAssertTrue(doc.closed)
        XCTAssertFalse(mask.isDrawing)
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertEqual(try fixture.helper.helper.snapshot(), files)
    }
}
