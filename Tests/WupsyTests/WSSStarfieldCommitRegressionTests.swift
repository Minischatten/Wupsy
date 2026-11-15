import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSStarfieldCommitRegressionTests: XCTestCase {
    var helper: WSSMaskEditingTests!
    var doc: WSSEditorDocument { helper.doc }
    var id: WSSLayerID!
    override func setUp() async throws {
        helper = WSSMaskEditingTests()
        try await helper.setUp()
        try doc.addStarfield()
        id = try XCTUnwrap(doc.selection?.layer)
        doc.undoManager.removeAllActions()
    }
    override func tearDown() async throws {
        doc.finishInput = nil
        try await helper.tearDown()
    }
    func input(_ parameter: WSSStarfieldParameter, commit: @escaping (Double) throws -> Void) throws
        -> WSSParameterTextField
    {
        let value = parameter.value(try XCTUnwrap(doc.starfieldLayer(id)).starfield)
        return WSSParameterTextField(
            value: Float(value),
            range: Float(parameter.range.lowerBound)...Float(parameter.range.upperBound),
            title: parameter.title,
            maximumFractionDigits: 3, locale: Locale(identifier: "en_US"), exactValue: value,
            exactRange: parameter.range, commitExact: commit, commit: { try commit(Double($0)) })
    }
    func canvasWindow() -> (WSSCanvasScrollView, NSWindow, NSTextField) {
        let canvas = WSSCanvasScrollView(document: doc)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        canvas.frame = CGRect(x: 0, y: 0, width: 640, height: 420)
        let field = NSTextField(frame: CGRect(x: 20, y: 440, width: 140, height: 24))
        root.addSubview(canvas)
        root.addSubview(field)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        canvas.update(doc, zoom: 2)
        canvas.layoutSubtreeIfNeeded()
        return (canvas, window, field)
    }
    func testOriginalReturnCommitCannotReenterNativeEndEditing() throws {
        let (canvas, window, field) = canvasWindow()
        defer {
            doc.finishInput = nil
            canvas.shutdown()
            window.close()
        }
        var commits = 0
        let coordinator = try input(.width) { [self] value in
            commits += 1
            try doc.setStarfield(.width, value: value, layer: id)
        }.makeCoordinator()
        coordinator.field = field
        field.stringValue = "92.125"
        var focusRequests = 0
        // Model the exact crash edge: finishInput -> native delegate -> accept ->
        // setStarfield -> finishEditing. Bound only the test double so the old
        // implementation fails assertions rather than overflowing the test process.
        doc.finishInput = {
            focusRequests += 1
            guard focusRequests < 3 else { return false }
            return coordinator.control(field, textShouldEndEditing: NSTextView())
        }
        XCTAssertTrue(
            coordinator.control(
                field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))
            ))
        XCTAssertEqual(focusRequests, 0)
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.width, 92.125)
        XCTAssertTrue(coordinator.control(field, textShouldEndEditing: NSTextView()))
        XCTAssertEqual(commits, 1)
        doc.finishInput = nil
        doc.undoManager.undo()
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.width, 64)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.width, 92.125)
    }
    func testNativeFocusChangeAndReturnCommitEachDraftOnce() throws {
        let (canvas, window, field) = canvasWindow()
        var commits = 0
        let coordinator = try input(.height) { [self] value in
            commits += 1
            try doc.setStarfield(.height, value: value, layer: id)
        }.makeCoordinator()
        field.delegate = coordinator
        coordinator.field = field
        coordinator.showExact(64, in: field)
        defer {
            doc.finishInput = nil
            field.delegate = nil
            canvas.shutdown()
            window.close()
        }
        var focusRequests = 0
        doc.finishInput = {
            focusRequests += 1
            // Safety only in the regression fixture; the real callback has no guard.
            guard focusRequests < 3 else { return false }
            guard let text = window.firstResponder as? NSText, text.isEditable else { return true }
            return window.makeFirstResponder(nil)
        }
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText(
            "80.375", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertEqual(field.stringValue, "80.375")
        XCTAssertTrue(doc.finishEditing())  // Same boundary used by Save and canvas selection.
        XCTAssertEqual(focusRequests, 1)
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.height, 80.375)
        XCTAssertTrue(window.makeFirstResponder(canvas))
        XCTAssertTrue(window.makeFirstResponder(field))
        let nextEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        nextEditor.insertText(
            "96.625", replacementRange: NSRange(location: 0, length: nextEditor.string.utf16.count))
        XCTAssertEqual(field.stringValue, "96.625")
        XCTAssertTrue(
            coordinator.control(
                field, textView: nextEditor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(commits, 2)
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.height, 96.625)
        XCTAssertEqual(field.stringValue, "96.625")
        XCTAssertTrue(window.makeFirstResponder(canvas))
        XCTAssertEqual(commits, 2)
        doc.finishInput = nil
        doc.undoManager.undo()
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.height, 80.375)
        doc.undoManager.undo()
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.height, 64)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testCanvasHandleScaleThenNumericCommitFinishesGestureAndSaves() async throws {
        let (canvas, window, _) = canvasWindow()
        defer {
            canvas.shutdown()
            window.close()
        }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: canvas.surface.convert(point, to: nil),
                    modifierFlags: .shift, timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        let start = canvas.viewPoint(for: SIMD2(64, 64))
        let end = canvas.viewPoint(for: SIMD2(96, 80))
        canvas.surface.mouseDown(with: try event(.leftMouseDown, start))
        canvas.surface.mouseDragged(with: try event(.leftMouseDragged, end))
        XCTAssertNotNil(doc.canvasTransform)
        XCTAssertTrue(canvas.isTransforming)
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.width, 96)
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.height, 80)
        // A numeric commit during the still-open drag must finish it exactly once,
        // then adopt the new width without resurrecting the pending mouse gesture.
        let coordinator = try input(.width) { [self] in
            try doc.setStarfield(.width, value: $0, layer: id)
        }.makeCoordinator()
        XCTAssertTrue(coordinator.accept(NSTextField(string: "100.125")))
        XCTAssertNil(doc.canvasTransform)
        XCTAssertFalse(canvas.isTransforming)
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.width, 100.125)
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.height, 80)
        canvas.finishTransform()  // Subsequent mouse-up/focus notification is a no-op.
        doc.undoManager.undo()
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.width, 96)
        doc.undoManager.undo()
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.width, 64)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        doc.undoManager.redo()
        let snapshot = doc.state.workingModel
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, snapshot)
    }
    func testInvalidNumericDraftRetainsFocusAndAcceptsCorrection() throws {
        let input = try input(.width) { [self] in try doc.setStarfield(.width, value: $0, layer: id)
        }
        let coordinator = input.makeCoordinator()
        let field = NSTextField(string: "9000")
        XCTAssertFalse(coordinator.control(field, textShouldEndEditing: NSTextView()))
        XCTAssertEqual(field.stringValue, "9000")
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.width, 64)
        XCTAssertFalse(doc.undoManager.canUndo)
        field.stringValue = "72.875"
        XCTAssertTrue(coordinator.control(field, textShouldEndEditing: NSTextView()))
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.width, 72.875)
    }
}
