import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSCanvasZoomTests: XCTestCase {
    var helper: WSSMaskEditingTests!
    var canvas: WSSCanvasScrollView!
    var window: WSSEditorNativeWindow!
    var doc: WSSEditorDocument { helper.doc }
    override func setUp() async throws {
        _ = NSApplication.shared
        helper = WSSMaskEditingTests()
        try await helper.setUp()
        let entry = helper.helper.item.url
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: entry)) as? [String: Any])
        json["canvas"] = ["width": 1920, "height": 1080]
        var layers = json["layers"] as! [[String: Any]]
        for i in layers.indices {
            layers[i]["transform"] = ["center": [960, 540], "size": [1920, 1080]]
        }
        json["layers"] = layers
        try JSONSerialization.data(withJSONObject: json).write(to: entry)
        helper.doc.close()
        helper.doc = helper.makeDocument(
            try await WSSEditorProjectLoader().load(helper.helper.item))
        window = WSSEditorNativeWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.editorDocument = doc
        canvas = WSSCanvasScrollView(document: doc)
        window.contentView = canvas
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        canvas.update(doc, zoom: 1)
        canvas.layoutSubtreeIfNeeded()
    }
    override func tearDown() async throws {
        canvas.shutdown()
        window.close()
        canvas = nil
        window = nil
        try await helper.tearDown()
        helper = nil
    }
    func key(
        _ characters: String, ignoring: String? = nil,
        flags: NSEvent.ModifierFlags = .command, keyCode: UInt16 = 24
    )
        throws -> NSEvent
    {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false,
                keyCode: keyCode))
    }
    func testWindowCommandsHandlePlusEqualsShiftPlusMinusAndFitWithoutCanvasFocus() throws {
        var state: CGFloat? = 1
        canvas.onZoom = { state = $0 }
        XCTAssertTrue(
            window.performKeyEquivalent(
                with: try key("+", ignoring: "=", flags: [.command, .shift])))
        XCTAssertEqual(state, 1.25)
        XCTAssertTrue(window.performKeyEquivalent(with: try key("-")))
        XCTAssertEqual(state, 1)
        XCTAssertTrue(window.performKeyEquivalent(with: try key("=")))
        XCTAssertEqual(state, 1.25)
        XCTAssertTrue(window.performKeyEquivalent(with: try key("+")))
        XCTAssertEqual(state, 1.5625)
        XCTAssertTrue(window.performKeyEquivalent(with: try key("0")))
        XCTAssertNil(state)
        XCTAssertNil(canvas.presentationZoom)
        XCTAssertTrue(window.performKeyEquivalent(with: try key("1")))
        XCTAssertEqual(canvas.presentationZoom, 1)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertNil(WSSCanvasZoomCommand.decode(try key("+", flags: [.command, .option])))
    }
    func testCommandBoundsAndPinchShareSameZoomState() {
        var state: CGFloat? = 1
        canvas.onZoom = { state = $0 }
        for _ in 0..<50 { XCTAssertTrue(canvas.performZoom(.zoomIn)) }
        XCTAssertEqual(state, 4)
        for _ in 0..<50 { XCTAssertTrue(canvas.performZoom(.zoomOut)) }
        XCTAssertEqual(state, 0.05)
        canvas.applyMagnification(1, at: CGPoint(x: 200, y: 150))
        XCTAssertEqual(state, 0.1)
        canvas.applyMagnification(100, at: CGPoint(x: 200, y: 150))
        XCTAssertEqual(state, 4)
        canvas.applyMagnification(-0.999, at: CGPoint(x: 200, y: 150))
        XCTAssertEqual(state, 0.05)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testPinchPreservesGestureAnchorInScrollableCanvas() throws {
        let scene = SIMD2<Float>(120, 960)
        let anchor = canvas.viewPoint(for: scene)
        let before = canvas.surface.convert(anchor, to: canvas)
        canvas.applyMagnification(0.5, at: anchor)
        XCTAssertEqual(canvas.presentationZoom, 1.5)
        let after = canvas.surface.convert(canvas.viewPoint(for: scene), to: canvas)
        XCTAssertEqual(after.x, before.x, accuracy: 0.01)
        XCTAssertEqual(after.y, before.y, accuracy: 0.01)
        canvas.applyMagnification(-1.0 / 3, at: canvas.viewPoint(for: scene))
        XCTAssertEqual(try XCTUnwrap(canvas.presentationZoom), 1, accuracy: 0.001)
        let restored = canvas.surface.convert(canvas.viewPoint(for: scene), to: canvas)
        XCTAssertEqual(restored.x, before.x, accuracy: 0.01)
        XCTAssertEqual(restored.y, before.y, accuracy: 0.01)
    }
    func testMagnificationDuringStrokeIsIgnoredAndCursorScalesWhenIdle() async throws {
        _ = try helper.target()
        await doc.maskCanvas.waitForLoad()
        let session = doc.maskCanvas
        session.setBrush(true)
        session.setDiameter(2)
        let geometry = try XCTUnwrap(session.geometry)
        let point = geometry.scene(.zero)
        func cursorWidth() -> CGFloat {
            let points = geometry.footprint(center: point, diameter: session.diameter).map {
                canvas.viewPoint(for: $0)
            }
            return hypot(points[0].x - points[32].x, points[0].y - points[32].y)
        }
        let commands = WSSEditorCommands(document: doc, window: window)
        XCTAssertTrue(commands.canPerform(.zoom(.zoomIn)))
        let width = cursorWidth()
        canvas.applyMagnification(0.5, at: canvas.viewPoint(for: point))
        XCTAssertEqual(cursorWidth(), width * 1.5, accuracy: 0.01)
        XCTAssertTrue(session.begin(point, erase: false))
        XCTAssertFalse(commands.canPerform(.zoom(.zoomIn)))
        XCTAssertFalse(commands.canPerform(.delete))
        let zoom = canvas.presentationZoom
        canvas.applyMagnification(0.5, at: canvas.viewPoint(for: point))
        XCTAssertEqual(canvas.presentationZoom, zoom)
        XCTAssertTrue(window.performKeyEquivalent(with: try key("+")))
        XCTAssertEqual(canvas.presentationZoom, zoom)
        XCTAssertTrue(session.isDrawing)
        session.cancelStroke()
        XCTAssertTrue(commands.canPerform(.zoom(.zoomIn)))
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testTextFieldKeepsItsOwnCommandHandling() throws {
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        canvas.surface.addSubview(text)
        XCTAssertTrue(window.makeFirstResponder(text))
        let old = canvas.presentationZoom
        _ = window.performKeyEquivalent(with: try key("+"))
        XCTAssertEqual(canvas.presentationZoom, old)
        XCTAssertFalse(doc.isDirty)
    }
    func testPlainFieldEditorZoomDoesNotChangeTextOrSelection() throws {
        let field = NSTextField(string: "50")
        field.frame = CGRect(x: 0, y: 0, width: 100, height: 30)
        canvas.surface.addSubview(field)
        field.selectText(nil)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        let text = editor.string
        let range = editor.selectedRange()
        XCTAssertTrue(window.performKeyEquivalent(with: try key("+")))
        XCTAssertEqual(canvas.presentationZoom, 1.25)
        XCTAssertEqual(editor.string, text)
        XCTAssertEqual(editor.selectedRange(), range)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testGermanPlusAndWindowDispatchApplyEachZoomExactlyOnce() throws {
        var changes: [CGFloat?] = []
        canvas.onZoom = { changes.append($0) }
        window.sendEvent(try key("+", ignoring: "+", keyCode: 30))
        XCTAssertEqual(canvas.presentationZoom, 1.25)
        XCTAssertEqual(changes.count, 1)
        window.sendEvent(try key("+", ignoring: "+", flags: [.command, .shift], keyCode: 30))
        XCTAssertEqual(canvas.presentationZoom, 1.5625)
        XCTAssertEqual(changes.count, 2)
        window.sendEvent(try key("-", keyCode: 44))
        XCTAssertEqual(canvas.presentationZoom, 1.25)
        XCTAssertEqual(changes.count, 3)
        for (characters, flags): (String, NSEvent.ModifierFlags) in [
            ("+", []), ("+", [.command, .option]), ("-", [.command, .control]),
            ("s", .command), ("o", .command), ("p", [.command, .shift]),
        ] {
            XCTAssertNil(WSSCanvasZoomCommand.decode(try key(characters, flags: flags)))
        }
    }
    func testCommandZeroUsesFitGeometryAndUpdatesSharedPresentationState() throws {
        var state: CGFloat? = 1
        canvas.onZoom = { state = $0 }
        XCTAssertTrue(canvas.performZoom(.actualSize))
        window.sendEvent(try key("0", keyCode: 29))
        XCTAssertNil(state)
        XCTAssertNil(canvas.presentationZoom)
        let expected = WSSCanvasGeometry.fit(
            scene: canvas.surface.sceneSize,
            viewport: CGSize(
                width: max(1, canvas.contentSize.width - 56),
                height: max(1, canvas.contentSize.height - 56)))
        let left = canvas.viewPoint(for: SIMD2(0, 0))
        let right = canvas.viewPoint(for: SIMD2(1920, 0))
        XCTAssertEqual((right.x - left.x) / 1920, expected, accuracy: 0.000001)
        XCTAssertLessThan(expected, 1)
        let center = canvas.viewPoint(for: SIMD2(960, 540))
        canvas.applyMagnification(0.25, at: center)
        XCTAssertEqual(try XCTUnwrap(state), expected * 1.25, accuracy: 0.000001)
        XCTAssertEqual(state, canvas.presentationZoom)
    }
    func testKeyboardZoomPreservesBrushSettingsForEffectAndImageSelection() async throws {
        _ = try helper.target()
        await doc.maskCanvas.waitForLoad()
        doc.maskCanvas.setDiameter(17)
        doc.maskCanvas.setOpacity(0.4)
        doc.maskCanvas.setBrush(true)
        let diameter = doc.maskCanvas.diameter
        let opacity = doc.maskCanvas.opacity
        let model = doc.state.workingModel
        let layer = doc.identity.layers[0]
        for selection in [WSSEditorSelection.effect(layer.id, layer.effects[0]), .layer(layer.id)] {
            doc.select(selection)
            for character in ["+", "-", "0"] {
                XCTAssertTrue(window.performKeyEquivalent(with: try key(character)))
                XCTAssertEqual(doc.selection, selection)
                XCTAssertEqual(doc.maskCanvas.diameter, diameter)
                XCTAssertEqual(doc.maskCanvas.opacity, opacity)
                XCTAssertEqual(doc.state.workingModel, model)
            }
        }
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testZoomCommandsAreUnavailableInLibraryWindowAndClosedEditor() throws {
        let library = NSWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        library.isReleasedWhenClosed = false
        defer { library.close() }
        XCTAssertNil(WSSEditorCommands.inWindow(library))
        XCTAssertNil(WSSEditorCommands.inWindow(nil))
        let commands = WSSEditorCommands(document: doc, window: window)
        XCTAssertTrue(commands.canPerform(.zoom(.zoomIn)))
        doc.close()
        for action: WSSCanvasZoomCommand in [.zoomIn, .zoomOut, .fit] {
            XCTAssertFalse(commands.canPerform(.zoom(action)))
            XCTAssertFalse(canvas.performZoom(action))
        }
        XCTAssertEqual(canvas.presentationZoom, 1)
    }
    func testKeyboardZoomIsConsumedWithoutChangingPendingOrActiveTransform() throws {
        let id = doc.identity.layers.last!.id
        doc.select(.layer(id))
        XCTAssertTrue(doc.activateTransformMode(id))
        canvas.update(doc, zoom: 1)
        let center = canvas.viewPoint(for: SIMD2(960, 540))
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: canvas.surface.convert(point, to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                    clickCount: 1, pressure: 1))
        }
        canvas.surface.mouseDown(with: try mouse(.leftMouseDown, center))
        XCTAssertTrue(canvas.isTransforming)
        for character in ["+", "-", "0"] {
            XCTAssertTrue(window.performKeyEquivalent(with: try key(character)))
            XCTAssertEqual(canvas.presentationZoom, 1)
        }
        let moved = CGPoint(x: center.x + 12, y: center.y)
        canvas.surface.mouseDragged(with: try mouse(.leftMouseDragged, moved))
        XCTAssertNotNil(doc.canvasTransform)
        let model = doc.state.workingModel
        for character in ["+", "-", "0"] {
            XCTAssertTrue(window.performKeyEquivalent(with: try key(character)))
            XCTAssertEqual(canvas.presentationZoom, 1)
            XCTAssertEqual(doc.state.workingModel, model)
            XCTAssertNotNil(doc.canvasTransform)
        }
        canvas.surface.mouseUp(with: try mouse(.leftMouseUp, moved))
        XCTAssertEqual(doc.transformModeLayer, id)
    }
    func testInvalidOrZeroMagnificationIsNoOp() {
        for delta: CGFloat in [0, -.infinity, .nan, -1] {
            canvas.applyMagnification(delta, at: CGPoint(x: 100, y: 100))
            XCTAssertEqual(canvas.presentationZoom, 1)
        }
        XCTAssertFalse(doc.isDirty)
    }
}
