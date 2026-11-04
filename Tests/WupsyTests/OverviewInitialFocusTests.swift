import AppKit
import SwiftUI
import XCTest

@testable import Wupsy

@MainActor final class OverviewInitialFocusTests: XCTestCase {
    func testInitialResponderIsNeutralAndButtonsKeepKeyboardFocus() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(
            rootView:
                HStack {
                    Button("Create") {}
                    Button("Import") {}
                }.buttonStyle(VioletButtonStyle())
                .background(OverviewInitialFocus()))
        let container = NSView(frame: window.contentLayoutRect)
        host.frame = container.bounds
        container.addSubview(host)
        window.contentView = container
        host.layoutSubtreeIfNeeded()
        let neutral = try XCTUnwrap(window.initialFirstResponder as? OverviewInitialFocusView)
        XCTAssertTrue(neutral.acceptsFirstResponder)
        XCTAssertFalse(neutral.canBecomeKeyView)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.firstResponder === neutral)
        // The focus target is local to initial presentation, not subsequent view insertion.
        let button = NSButton(title: "Keyboard action", target: nil, action: nil)
        container.addSubview(button)
        XCTAssertTrue(window.makeFirstResponder(button))
        let later = OverviewInitialFocusView()
        container.addSubview(later)
        XCTAssertTrue(window.firstResponder === button)
        XCTAssertTrue(window.initialFirstResponder === neutral)
        XCTAssertTrue(button.acceptsFirstResponder)
    }
}
