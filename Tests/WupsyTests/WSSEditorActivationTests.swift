import AppKit
import SwiftUI
import XCTest

@testable import Wupsy

@MainActor final class WSSEditorActivationTests: XCTestCase {
    var helper: WSSEditorWorkspaceTests!
    var doc: WSSEditorDocument!
    var controller: WSSEditorWindowController!
    override func setUp() async throws {
        helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
        doc = helper.document()
        controller = WSSEditorWindowController(document: doc, onClose: {})
        controller.showWindow(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
    }
    override func tearDown() async throws {
        doc.close()
        controller.close()
        controller = nil
        doc = nil
        try await helper.tearDown()
    }
    func testNativeTransformHelpIsPureAndUsesSharedEligibility() async throws {
        try await settle()
        let a = doc.identity.layers[0]
        let original = doc.state.workingModel
        let revision = doc.state.workingRevision
        let selection = doc.selection
        let canvas = try XCTUnwrap(
            find(WSSCanvasScrollView.self, in: controller.window!.contentView!))
        XCTAssertEqual(doc.transformHelp(for: .layer(a.id)), EditorText.transformHint.text)
        XCTAssertNil(doc.transformHelp(for: .effect(a.id, a.effects[0])))
        XCTAssertEqual(
            canvas.transformHelp(at: canvas.viewPoint(for: SIMD2(32, 32))),
            EditorText.transformHint.text)
        XCTAssertNil(canvas.transformHelp(at: CGPoint(x: -100, y: -100)))
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertEqual(doc.state.workingRevision, revision)
        XCTAssertEqual(doc.selection, selection)
        XCTAssertNil(doc.transformModeLayer)
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertTrue(doc.activateStructureRow(.layer(a.id)))
        try doc.setVisibility(false, layer: a.id)
        XCTAssertNil(doc.transformHelp(for: .layer(a.id)))
    }
    func testNativeEyeButtonDispatchDoesNotActivateRow() async throws {
        try await settle()
        let a = doc.identity.layers[0].id
        doc.select(.layer(a))
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        let eyes = buttons(in: controller.window!.contentView!).filter {
            $0.accessibilityLabel() == EditorText.hideLayer.text
        }
        let eye = try XCTUnwrap(eyes.last)
        eye.performClick(nil)
        try await settle()
        XCTAssertEqual(doc.selection, .layer(a))
        XCTAssertNil(doc.transformModeLayer)
        XCTAssertFalse(doc.workingScene.layers[1].visible)
        for _ in 0..<40 {
            if doc.previewRevision == doc.state.workingRevision { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(doc.previewRevision, doc.state.workingRevision)
        XCTAssertFalse(doc.previewResources.scene.layers[1].visible)
        XCTAssertFalse(try doc.canvasModel.scene().layers[1].visible)
    }
    func testEyeUsesStableIDPreservesOtherSelectionAndOneUndo() throws {
        let a = doc.identity.layers[0].id
        let b = doc.identity.layers[1].id
        try doc.moveLayer(b, by: -1)
        doc.undoManager.removeAllActions()
        doc.select(.layer(a))
        let before = doc.state.workingModel
        XCTAssertEqual(doc.visibilityHelp(b), EditorText.hideLayer.text)
        try doc.toggleVisibility(b)
        XCTAssertEqual(doc.selection, .layer(a))
        XCTAssertNil(doc.transformModeLayer)
        XCTAssertFalse(doc.workingScene.layers[0].visible)
        XCTAssertTrue(doc.workingScene.layers[1].visible)
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.visibilityHelp(b), EditorText.showLayer.text)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        XCTAssertFalse(doc.workingScene.layers[0].visible)
        XCTAssertEqual(doc.selection, .layer(a))
        XCTAssertNil(doc.transformModeLayer)
    }
    func testHideEndsModeAndHandlesWithoutReactivationOnShowOrUndo() async throws {
        try await settle()
        let id = doc.identity.layers[1].id
        let canvas = try XCTUnwrap(
            find(WSSCanvasScrollView.self, in: controller.window!.contentView!))
        XCTAssertTrue(doc.activateStructureRow(.layer(id)))
        try await settle()
        XCTAssertTrue(canvas.surface.showsTransformHandles)
        try doc.toggleVisibility(id)
        try await settle()
        XCTAssertNil(doc.transformModeLayer)
        XCTAssertEqual(doc.selection, .layer(id))
        XCTAssertFalse(canvas.surface.showsTransformHandles)
        XCTAssertNotEqual(canvas.canvasHit(at: canvas.viewPoint(for: SIMD2(32, 32)))?.layer, id)
        doc.undoManager.undo()
        XCTAssertTrue(doc.workingScene.layers[1].visible)
        XCTAssertNil(doc.transformModeLayer)
        doc.undoManager.redo()
        try doc.toggleVisibility(id)
        XCTAssertTrue(doc.workingScene.layers[1].visible)
        XCTAssertNil(doc.transformModeLayer)
    }
    func escape() throws -> NSEvent {
        let window = try XCTUnwrap(controller.window)
        return try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }
    func testEscapeFromHostingResponderLeavesModeWithoutCanvasKeyDown() throws {
        let id = doc.identity.layers[0].id
        doc.select(.layer(id))
        XCTAssertTrue(doc.activateTransformMode(id))
        let window = try XCTUnwrap(controller.window)
        let host = try XCTUnwrap(window.contentView)
        XCTAssertTrue(window.makeFirstResponder(host))
        XCTAssertTrue(window.firstResponder === host)
        let before = doc.state.workingModel
        // Standard AppKit Escape binding dispatches cancelOperation through the
        // hosting responder, not WSSCanvasScrollView.keyDown.
        host.interpretKeyEvents([try escape()])
        XCTAssertNil(doc.transformModeLayer)
        XCTAssertEqual(doc.selection, .layer(id))
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }
    func settle() async throws { try await Task.sleep(nanoseconds: 80_000_000) }
    func testTreeSingleSelectionAndDoubleActivationUseStableIDsWithoutUndo() async throws {
        try await settle()
        let rows = doc.structureRows
        let a = rows[0].id
        let b = try XCTUnwrap(rows.last?.id)
        let original = doc.state.workingModel
        doc.select(a)  // The native List's single-click binding.
        XCTAssertNil(doc.transformModeLayer)
        let canvas = try XCTUnwrap(
            find(WSSCanvasScrollView.self, in: controller.window!.contentView!))
        let viewPoint = canvas.viewPoint(for: SIMD2(32, 32))
        let scrollOrigin = canvas.contentView.bounds.origin
        XCTAssertFalse(canvas.surface.showsTransformHandles)
        XCTAssertTrue(doc.activateStructureRow(a))  // Exact production double-tap dispatch.
        try await settle()
        XCTAssertEqual(doc.transformModeLayer, a.layer)
        XCTAssertTrue(canvas.surface.showsTransformHandles)
        XCTAssertEqual(canvas.viewPoint(for: SIMD2(32, 32)), viewPoint)
        XCTAssertEqual(canvas.contentView.bounds.origin, scrollOrigin)
        doc.select(b)
        try await settle()
        XCTAssertNil(doc.transformModeLayer)
        XCTAssertFalse(canvas.surface.showsTransformHandles)
        XCTAssertTrue(doc.activateStructureRow(b))
        try await settle()
        XCTAssertEqual(doc.transformModeLayer, b.layer)
        XCTAssertTrue(canvas.surface.showsTransformHandles)
        try doc.moveLayer(b.layer, by: -1)
        doc.undoManager.removeAllActions()
        let afterMove = doc.state.workingModel
        doc.select(a)
        XCTAssertTrue(doc.activateStructureRow(b))
        XCTAssertEqual(doc.transformModeLayer, b.layer)
        XCTAssertEqual(doc.state.workingModel, afterMove)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.revert()
        XCTAssertEqual(doc.state.workingModel, original)
        doc.undoManager.removeAllActions()
        XCTAssertTrue(doc.activateStructureRow(a))
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testEffectAndProceduralTreeRowsNeverActivateOwningImage() async throws {
        let layer = doc.identity.layers[0]
        XCTAssertTrue(doc.activateStructureRow(.layer(layer.id)))
        let effect = WSSEditorSelection.effect(layer.id, layer.effects[0])
        XCTAssertFalse(doc.activateStructureRow(effect))
        XCTAssertEqual(doc.selection, effect)
        XCTAssertNil(doc.transformModeLayer)
        let fixtures = WSSEditorLivePreviewTests()
        try await fixtures.setUp()
        defer { try? fixtures.helper.tearDownWithError() }
        let loaded = try await fixtures.project("WSS-Rain-v1")
        var model = loaded.document
        var trail = model.layers[0]
        trail.content = .trail(.init(colors: [.init(r: 1, g: 1, b: 1)]), visible: true)
        model.layers.append(trail)
        try model.encoded().write(to: loaded.handle.entry)
        let procedural = WSSEditorDocument(
            project: try await WSSEditorProjectLoader().load(loaded.handle.wallpaper))
        defer { procedural.close() }
        for (index, node) in model.layers.enumerated() {
            if case .image = node.content { continue }
            XCTAssertNil(
                procedural.transformHelp(for: .layer(procedural.identity.layers[index].id)))
            XCTAssertFalse(
                procedural.activateStructureRow(.layer(procedural.identity.layers[index].id)))
            XCTAssertNil(procedural.transformModeLayer)
        }
        XCTAssertFalse(procedural.isDirty)
        XCTAssertFalse(procedural.undoManager.canUndo)
    }
    func testTreeAndActualCanvasDoubleClickShareOneMode() async throws {
        try await settle()
        let id = doc.identity.layers[1].id
        XCTAssertTrue(doc.activateStructureRow(.layer(id)))
        let treeMode = doc.transformModeLayer
        doc.leaveTransformMode()
        let canvas = try XCTUnwrap(
            find(WSSCanvasScrollView.self, in: controller.window!.contentView!))
        let point = canvas.viewPoint(for: SIMD2(32, 32))
        let window = controller.window!
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: canvas.surface.convert(point, to: nil), modifierFlags: [],
                    timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2,
                    pressure: 1))
            if type == .leftMouseDown {
                canvas.surface.mouseDown(with: event)
            } else {
                canvas.surface.mouseUp(with: event)
            }
        }
        XCTAssertEqual(doc.transformModeLayer, treeMode)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testEscapeKeyEventFromNativeTreeResponderConsumesMode() async throws {
        try await settle()
        let id = doc.identity.layers[1].id
        XCTAssertTrue(doc.activateStructureRow(.layer(id)))
        let window = try XCTUnwrap(controller.window)
        let table = try XCTUnwrap(find(NSTableView.self, in: window.contentView!))
        XCTAssertTrue(window.makeFirstResponder(table))
        let revision = doc.state.workingRevision
        // Native key delivery, not a direct call to the document or canvas.
        window.sendEvent(try escape())
        XCTAssertNil(doc.transformModeLayer)
        XCTAssertEqual(doc.selection, .layer(id))
        XCTAssertEqual(doc.state.workingRevision, revision)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
        try await settle()
        let canvas = try XCTUnwrap(find(WSSCanvasScrollView.self, in: window.contentView!))
        XCTAssertFalse(canvas.surface.showsTransformHandles)
    }
    func testResponderEscapeDuringGestureCancelsAllKindsThenLeavesMode() throws {
        let id = doc.identity.layers[0].id
        let window = try XCTUnwrap(controller.window)
        let host = try XCTUnwrap(window.contentView)
        let original = doc.state.workingModel
        for kind: WSSCanvasGesture.Kind in [.move, .scale(2, independent: false), .rotate] {
            XCTAssertTrue(doc.activateStructureRow(.layer(id)))
            XCTAssertTrue(window.makeFirstResponder(host))
            XCTAssertTrue(doc.beginCanvasTransform(id, kind: kind))
            var value = try XCTUnwrap(original.layers[0].imageTransform)
            value.center[0] += 10
            value.scale = [2, 1]
            value.rotation = 0.5
            try doc.updateCanvasTransform(value)
            let revision = doc.state.workingRevision
            host.interpretKeyEvents([try escape()])
            XCTAssertNil(doc.canvasTransform)
            XCTAssertEqual(doc.transformModeLayer, id)
            XCTAssertEqual(doc.state.workingModel, original)
            XCTAssertGreaterThan(doc.state.workingRevision, revision)
            XCTAssertFalse(doc.undoManager.canUndo)
            host.interpretKeyEvents([try escape()])
            XCTAssertNil(doc.transformModeLayer)
            XCTAssertEqual(doc.selection, .layer(id))
            XCTAssertFalse(doc.isDirty)
        }
        XCTAssertFalse(doc.cancelTransformInteraction())  // No blanket Escape consumption.
    }
    func testNumericFieldEscapeStillCancelsOnlyTextInput() async throws {
        let id = doc.identity.layers[0].id
        XCTAssertTrue(doc.activateStructureRow(.layer(id)))
        try await settle()
        let window = try XCTUnwrap(controller.window)
        func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField,
                field.accessibilityLabel() == WSSImageProperty.centerX.title
            {
                return field
            }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        let input = try XCTUnwrap(field(in: window.contentView!))
        XCTAssertTrue(window.makeFirstResponder(input))
        let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
        editor.string = "invalid pending input"
        window.sendEvent(try escape())
        XCTAssertEqual(input.stringValue, "32.0")
        XCTAssertEqual(doc.transformModeLayer, id)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
    }

    func testWindowPassesEscapeWithoutModeAndUnrelatedKeysToFirstResponder() throws {
        let window = WSSEditorNativeWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.editorDocument = doc
        let receiver = ActivationKeyReceiver(frame: .zero)
        window.contentView = receiver
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func key(_ code: UInt16, _ text: String) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: text,
                    charactersIgnoringModifiers: text,
                    isARepeat: false, keyCode: code))
        }
        XCTAssertTrue(window.makeFirstResponder(receiver))
        window.sendEvent(try key(53, "\u{1b}"))
        XCTAssertEqual(receiver.keys, [53])
        let id = doc.identity.layers[0].id
        XCTAssertTrue(doc.activateStructureRow(.layer(id)))
        XCTAssertTrue(window.makeFirstResponder(receiver))
        window.sendEvent(try key(0, "a"))
        XCTAssertEqual(receiver.keys, [53, 0])
        XCTAssertEqual(doc.transformModeLayer, id)
        window.sendEvent(try key(53, "\u{1b}"))
        XCTAssertEqual(receiver.keys, [53, 0])  // Consumed before the first responder can beep.
        XCTAssertNil(doc.transformModeLayer)
    }

}

@MainActor private final class ActivationKeyReceiver: NSView {
    var keys: [UInt16] = []
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
}
