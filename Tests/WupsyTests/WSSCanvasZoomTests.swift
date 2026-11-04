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
    func key(_ characters: String, ignoring: String? = nil, flags: NSEvent.ModifierFlags = .command)
        throws -> NSEvent
    {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: 24))
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
    func testInvalidOrZeroMagnificationIsNoOp() {
        for delta: CGFloat in [0, -.infinity, .nan, -1] {
            canvas.applyMagnification(delta, at: CGPoint(x: 100, y: 100))
            XCTAssertEqual(canvas.presentationZoom, 1)
        }
        XCTAssertFalse(doc.isDirty)
    }
}
