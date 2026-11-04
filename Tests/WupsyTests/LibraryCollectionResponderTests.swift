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
    func testHostedCollectionInstallsNativeFirstResponderAndDispatchesBackspace() async throws {
        let window = window()
        defer { window.close() }
        let focus = LibraryCollectionFocus()
        var removes = 0
        let ready = expectation(description: "Hosted collection appeared")
        let host = NSHostingView(
            rootView:
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible())]) {
                        Button("Wallpaper") { focus.focus() }
                            .frame(width: 240, height: 80).buttonStyle(.plain)
                    }
                }.background(
                    LibraryCollectionResponder(focus: focus, remove: { removes += 1 })
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
    func testTextFieldEditorReceivesBackspaceInsteadOfCollection() throws {
        let window = window()
        defer { window.close() }
        let target = LibraryCollectionKeyView(frame: .zero)
        window.contentView!.addSubview(target)
        var removes = 0
        target.remove = { removes += 1 }
        XCTAssertTrue(window.makeFirstResponder(target))
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        field.stringValue = "Search"
        window.contentView!.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        try delete(in: window)
        XCTAssertEqual(editor.string, "Searc")
        target.deleteBackward(nil)
        XCTAssertEqual(removes, 0)
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
