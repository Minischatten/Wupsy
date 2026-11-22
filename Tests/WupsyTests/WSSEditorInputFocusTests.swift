import AppKit
import XCTest

@testable import Wupsy

/// Real native editor/window/field-editor dispatch, with isolated sources and preferences.
@MainActor final class WSSEditorInputFocusTests: XCTestCase {
    var fixture: WSSMaskManagementTests!
    var controller: WSSEditorWindowController!
    var suite: String!
    var defaults: UserDefaults!
    var doc: WSSEditorDocument { fixture.doc }
    var window: NSWindow { controller.window! }

    override func setUp() async throws {
        _ = NSApplication.shared
        fixture = WSSMaskManagementTests()
        try await fixture.setUp()
        suite = "Wupsy-InputFocus-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        controller = WSSEditorWindowController(
            document: doc, onClose: {},
            sizePreferences: .init(defaults: defaults), appearance: .init(defaults: defaults))
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        try await settle()
    }
    override func tearDown() async throws {
        doc.close()
        controller.close()
        controller = nil
        try await fixture.tearDown()
        defaults.removePersistentDomain(forName: suite)
    }
    private func settle() async throws {
        await doc.waitForPreview()
        window.contentView?.layoutSubtreeIfNeeded()
        // Allow SwiftUI's hosted key views and AppKit field editors to finish adoption.
        for _ in 0..<3 { await Task.yield() }
        window.contentView?.layoutSubtreeIfNeeded()
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }
    private var effect: WSSEditorSelection {
        .effect(doc.identity.layers[0].id, doc.identity.layers[0].effects[0])
    }
    private func centerXField() throws -> NSTextField {
        func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField,
                field.accessibilityLabel() == WSSImageProperty.centerX.title
            {
                return field
            }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        return try XCTUnwrap(field(in: window.contentView!))
    }
    private var centerX: Float {
        guard case .image(let image) = doc.state.workingModel.layers[0].content else {
            XCTFail("Expected synthetic image layer")
            return .nan
        }
        return WSSImageProperty.centerX.value(image)
    }
    private func edit(_ value: String) throws -> NSTextView {
        let input = try centerXField()
        XCTAssertTrue(window.makeFirstResponder(input))
        let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText(value, replacementRange: editor.selectedRange())
        return editor
    }

    func testSameEffectSelectionKeepsOutlineResponderWithoutMutation() async throws {
        doc.select(effect)
        let outline = try XCTUnwrap(find(NSOutlineView.self, in: window.contentView!))
        XCTAssertTrue(window.makeFirstResponder(outline))
        let model = doc.state.workingModel
        let revision = doc.state.workingRevision
        let undo = doc.undoManager.canUndo
        doc.select(effect)
        try await settle()
        XCTAssertTrue(window.firstResponder === outline)
        XCTAssertEqual(doc.selection, effect)
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertEqual(doc.state.workingRevision, revision)
        XCTAssertEqual(doc.undoManager.canUndo, undo)
    }

    func testDifferentEffectSelectionKeepsOutlineAndCanvasResponders() async throws {
        doc.select(effect)
        let other = WSSEditorSelection.effect(
            doc.identity.layers[0].id,
            doc.identity.layers[0].effects[1])
        let outline = try XCTUnwrap(find(NSOutlineView.self, in: window.contentView!))
        let canvas = try XCTUnwrap(find(WSSCanvasScrollView.self, in: window.contentView!))
        let model = doc.state.workingModel
        for responder in [outline, canvas] as [NSView] {
            XCTAssertTrue(window.makeFirstResponder(responder))
            doc.select(other)
            try await settle()
            XCTAssertTrue(window.firstResponder === responder)
            XCTAssertEqual(doc.selection, other)
            doc.select(effect)
            try await settle()
            XCTAssertTrue(window.firstResponder === responder)
        }
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertFalse(doc.undoManager.canUndo)
    }

    func testReadOnlyTextFocusIsNotTreatedAsActiveInput() throws {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        text.isEditable = false
        text.isSelectable = true
        // Native siblings, not an unsupported insertion into NSHostingView.
        let host = window.contentView!
        let container = NSView(frame: host.frame)
        window.contentView = container
        container.addSubview(host)
        container.addSubview(text)
        XCTAssertTrue(window.makeFirstResponder(text))
        doc.select(effect)
        XCTAssertTrue(window.firstResponder === text)
    }

    func testValidTextCommitsBeforeSelectionAndUndoRedoSurvive() async throws {
        doc.select(.layer(doc.identity.layers[0].id))
        try await settle()
        let original = centerX
        let editor = try edit("40")
        XCTAssertEqual(centerX, original)  // Text is still a draft.
        doc.select(effect)
        XCTAssertEqual(doc.selection, effect)
        XCTAssertEqual(centerX, 40)
        XCTAssertFalse(window.firstResponder === editor)
        XCTAssertTrue(doc.undoManager.canUndo)
        doc.undoManager.undo()
        XCTAssertEqual(centerX, original)
        doc.undoManager.redo()
        XCTAssertEqual(centerX, 40)
    }

    func testInvalidTextBlocksSelectionAndKeepsEditorUntilCorrected() async throws {
        let layer = WSSEditorSelection.layer(doc.identity.layers[0].id)
        doc.select(layer)
        try await settle()
        let model = doc.state.workingModel
        let editor = try edit("not a number")
        doc.select(effect)
        XCTAssertEqual(doc.selection, layer)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertFalse(doc.undoManager.canUndo)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("41", replacementRange: editor.selectedRange())
        doc.select(effect)
        XCTAssertEqual(doc.selection, effect)
        XCTAssertEqual(centerX, 41)
    }

    func testSameSelectionStillValidatesActiveTextDraft() async throws {
        let layer = WSSEditorSelection.layer(doc.identity.layers[0].id)
        doc.select(layer)
        try await settle()
        let editor = try edit("invalid")
        XCTAssertFalse(doc.finishEditing())
        doc.select(layer)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(doc.selection, layer)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("42", replacementRange: editor.selectedRange())
        doc.select(layer)
        XCTAssertEqual(centerX, 42)
        XCTAssertFalse(window.firstResponder === editor)
    }
    private func renameField() -> NSTextField? {
        func findField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.identifier?.rawValue == "wss.layer.rename" {
                return field
            }
            return view.subviews.lazy.compactMap(findField).first
        }
        return window.contentView.flatMap(findField)
    }

    private func pressKey(_ character: String, code: UInt16) throws {
        window.sendEvent(
            try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: character,
                    charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)))
    }

    private func renameEditor() async throws -> NSTextView {
        XCTAssertNotNil(doc.renamingLayer, "The input event must start a rename")
        for _ in 0..<20 {
            try await settle()
            if renameField()?.currentEditor() != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let field = try XCTUnwrap(
            renameField(),
            "Active rename: \(String(describing: doc.renamingLayer)); selection: \(String(describing: doc.selection))"
        )
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertIdentical(window.firstResponder, editor)
        XCTAssertEqual(
            editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count))
        return editor
    }

    func testReturnRenamesAtEveryInterfaceScaleAndEscapeCancels() async throws {
        let outline = try XCTUnwrap(find(NSOutlineView.self, in: window.contentView!))
        let original = doc.state.workingModel
        let ids = doc.identity
        for scale in WupsyInterfaceScale.allCases {
            controller.appearance.scale = scale
            try await settle()
            doc.select(.layer(ids.layers[0].id))
            XCTAssertTrue(window.makeFirstResponder(outline))
            XCTAssertIdentical(window.firstResponder, outline)
            XCTAssertTrue(doc.permitsStructureEditing)
            XCTAssertEqual(doc.selection, .layer(ids.layers[0].id))
            try pressKey("\r", code: 36)
            let editor = try await renameEditor()
            let field = try XCTUnwrap(renameField())
            XCTAssertGreaterThan(field.frame.width, 40)
            XCTAssertGreaterThan(field.frame.height, 12)
            XCTAssertEqual(field.font?.pointSize, NSFont.systemFontSize * scale.factor)
            let name = String(repeating: "W", count: 256)
            editor.insertText(name, replacementRange: editor.selectedRange())
            try pressKey("\r", code: 36)
            try await settle()
            XCTAssertNil(renameField())
            XCTAssertEqual(doc.state.workingModel.layers[0].name, name)
            XCTAssertEqual(doc.identity, ids)
            doc.undoManager.undo()
            XCTAssertEqual(doc.state.workingModel, original)
            XCTAssertFalse(doc.undoManager.canUndo)
            doc.undoManager.redo()
            XCTAssertEqual(doc.state.workingModel.layers[0].name, name)
            doc.undoManager.undo()

            XCTAssertTrue(window.makeFirstResponder(outline))
            try pressKey("\r", code: 36)
            let cancelled = try await renameEditor()
            cancelled.insertText("Discarded", replacementRange: cancelled.selectedRange())
            try pressKey("\u{1B}", code: 53)
            try await settle()
            XCTAssertNil(renameField())
            XCTAssertEqual(doc.state.workingModel, original)
            XCTAssertFalse(doc.undoManager.canUndo)
        }
    }

    func testDoubleClickTitleAndFocusLossCommitOneRename() async throws {
        let outline = try XCTUnwrap(find(NSOutlineView.self, in: window.contentView!))
        let before = doc.state.workingModel
        let ids = doc.identity
        let marker = try XCTUnwrap(
            find(WSSLayerNameHitRegion.Marker.self, in: window.contentView!))
        let point = marker.convert(NSPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: nil)
        XCTAssertEqual(
            WSSLayerNameHitRegion.Marker.layer(at: point, in: window.contentView!), ids.layers[0].id
        )
        XCTAssertTrue(window.makeFirstResponder(outline))
        for click in 1...2 {
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: click,
                        clickCount: click, pressure: type == .leftMouseDown ? 1 : 0))
            }
            NSApp.postEvent(try event(.leftMouseUp), atStart: true)
            window.sendEvent(try event(.leftMouseDown))
            if let up = NSApp.nextEvent(
                matching: .leftMouseUp, until: nil, inMode: .default, dequeue: true)
            {
                window.sendEvent(up)
            }
            try await settle()
            if click == 1 { XCTAssertNil(renameField()) }
        }
        let editor = try await renameEditor()
        editor.insertText("  Renamed on blur  ", replacementRange: editor.selectedRange())
        let canvas = try XCTUnwrap(find(WSSCanvasScrollView.self, in: window.contentView!))
        XCTAssertTrue(window.makeFirstResponder(canvas))
        try await settle()
        XCTAssertNil(renameField())
        XCTAssertEqual(doc.state.workingModel.layers[0].name, "Renamed on blur")
        XCTAssertEqual(doc.identity, ids)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertFalse(doc.undoManager.canUndo)
    }

}
