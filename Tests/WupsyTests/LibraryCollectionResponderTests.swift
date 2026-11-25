import AppKit
import SwiftUI
import XCTest

@testable import Wupsy

// Real NSWindow event dispatch, not an assertion about an eligibility predicate.
@MainActor final class LibraryCollectionResponderTests: XCTestCase {
    private func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        return window
    }
    private func delete(in window: NSWindow, forward: Bool = false) throws {
        let characters = forward ? "\u{f728}" : "\u{7f}"
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: forward ? 117 : 51))
        window.sendEvent(event)
    }
    private func pressReturn(in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(event)
    }
    private func pressArrow(
        in window: NSWindow, code: UInt16 = 123, characters: String = "\u{f702}",
        modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false
    ) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: code))
        window.sendEvent(event)
    }

    func testCollectionConsumesArrowsAndRepeatsWithoutDispatchingOtherCommands() throws {
        let window = window()
        defer { window.close() }
        let target = LibraryCollectionKeyView(frame: .zero)
        window.contentView!.addSubview(target)
        XCTAssertTrue(window.makeFirstResponder(target))
        var directions: [LibraryGridDirection] = []
        target.navigate = { directions.append($0) }
        target.remove = { XCTFail("Arrow triggered removal") }
        target.rename = { XCTFail("Arrow triggered rename") }
        try pressArrow(in: window)
        try pressArrow(in: window, code: 124, characters: "\u{f703}", repeatKey: true)
        try pressArrow(in: window, code: 126, characters: "\u{f700}")
        try pressArrow(in: window, code: 125, characters: "\u{f701}")
        try pressArrow(in: window, modifiers: .shift)
        XCTAssertEqual(directions, [.left, .right, .up, .down])
    }

    func testHostedCollectionDispatchesBackspaceAndReturn() async throws {
        let window = window()
        defer { window.close() }
        let focus = LibraryCollectionFocus()
        var removes = 0
        var renames = 0
        let ready = expectation(description: "Hosted collection appeared")
        let host = NSHostingView(
            rootView:
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible())]) {
                        Button("Wallpaper") { focus.focus() }
                            .frame(width: 240, height: 80).buttonStyle(.plain)
                    }
                }.background(
                    LibraryCollectionResponder(
                        focus: focus, remove: { removes += 1 }, rename: { renames += 1 }
                    )
                    .allowsHitTesting(false)
                )
                .onAppear { ready.fulfill() })
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        await fulfillment(of: [ready], timeout: 3)
        host.layoutSubtreeIfNeeded()
        let target = try XCTUnwrap(focus.responder)
        // Exercise the same focus request used by the card action. Physical clicks
        // in the complete Library window still require manual acceptance.
        XCTAssertTrue(focus.focus())
        XCTAssertTrue(window.firstResponder === target)
        XCTAssertEqual(target.focusRingType, .none)
        try delete(in: window)
        XCTAssertEqual(removes, 1)
        try pressReturn(in: window)
        XCTAssertEqual(renames, 1)
        try pressReturn(in: window, modifiers: .command)
        XCTAssertEqual(renames, 1)
    }
    func testWindowDispatchesDeleteOnlyToExplicitlyFocusedLocalTargetAndCanReopen() throws {
        let focus = LibraryCollectionFocus()
        for _ in 0..<2 {
            let window = window()
            let target = LibraryCollectionKeyView(frame: .zero)
            window.contentView!.addSubview(target)
            focus.responder = target
            var removes = 0
            target.remove = { removes += 1 }
            XCTAssertTrue(focus.focus())
            XCTAssertTrue(window.firstResponder === target)
            XCTAssertFalse(target.canBecomeKeyView)
            XCTAssertNil(target.hitTest(.zero))
            try delete(in: window)
            try delete(in: window, forward: true)
            XCTAssertEqual(removes, 2)
            window.makeFirstResponder(window.contentView)
            target.deleteBackward(nil)
            XCTAssertEqual(removes, 2)
            window.close()
        }
    }
    func testTextFieldEditorReceivesBackspaceAndReturnInsteadOfCollection() throws {
        let window = window()
        defer { window.close() }
        let target = LibraryCollectionKeyView(frame: .zero)
        window.contentView!.addSubview(target)
        var removes = 0
        var renames = 0
        target.remove = { removes += 1 }
        target.rename = { renames += 1 }
        target.navigate = { _ in XCTFail("Field editor redirected an arrow") }
        XCTAssertTrue(window.makeFirstResponder(target))
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        field.stringValue = "Search"
        window.contentView!.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        try pressArrow(in: window)
        XCTAssertEqual(editor.selectedRange().location, 5)
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        try delete(in: window)
        XCTAssertEqual(editor.string, "Searc")
        try pressReturn(in: window)
        target.deleteBackward(nil)
        XCTAssertEqual(removes, 0)
        XCTAssertEqual(renames, 0)
    }
    func testFocusedButtonKeepsReturnAwayFromCollection() throws {
        let window = window()
        defer { window.close() }
        let target = LibraryCollectionKeyView(frame: .zero)
        let button = NSButton(title: "Apply", target: nil, action: nil)
        window.contentView!.addSubview(target)
        window.contentView!.addSubview(button)
        var renames = 0
        target.rename = { renames += 1 }
        target.navigate = { _ in XCTFail("Button redirected an arrow") }
        XCTAssertTrue(window.makeFirstResponder(target))
        XCTAssertTrue(window.makeFirstResponder(button))
        XCTAssertTrue(window.firstResponder === button)
        try pressArrow(in: window)
        try pressReturn(in: window)
        XCTAssertEqual(renames, 0)
    }
    func testAnotherWindowsTextDeletionNeverReachesLibraryTarget() throws {
        let libraryWindow = window()
        let otherWindow = window()
        defer {
            otherWindow.close()
            libraryWindow.close()
        }
        let target = LibraryCollectionKeyView(frame: .zero)
        libraryWindow.contentView!.addSubview(target)
        var removes = 0
        target.remove = { removes += 1 }
        XCTAssertTrue(libraryWindow.makeFirstResponder(target))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        text.string = "Rename"
        otherWindow.contentView = text
        XCTAssertTrue(otherWindow.makeFirstResponder(text))
        text.setSelectedRange(NSRange(location: 6, length: 0))
        try delete(in: otherWindow)
        XCTAssertEqual(text.string, "Renam")
        XCTAssertEqual(removes, 0)
    }
    func testAttachedSheetPreventsCollectionFocusAndDelete() throws {
        let window = window()
        let sheet = self.window()
        defer {
            window.endSheet(sheet)
            sheet.close()
            window.close()
        }
        let focus = LibraryCollectionFocus()
        let target = LibraryCollectionKeyView(frame: .zero)
        window.contentView!.addSubview(target)
        focus.responder = target
        var removes = 0
        target.remove = { removes += 1 }
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(focus.focus())
        window.beginSheet(sheet)
        XCTAssertFalse(focus.focus())
        target.deleteBackward(nil)
        XCTAssertEqual(removes, 0)
    }
}
