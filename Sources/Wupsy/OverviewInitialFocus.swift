import AppKit
import SwiftUI

/// A neutral initial responder for the overview's first window presentation.
/// It never enters the Tab chain or changes focus in an already visible window.
struct OverviewInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> OverviewInitialFocusView {
        OverviewInitialFocusView()
    }
    func updateNSView(_ view: OverviewInitialFocusView, context: Context) {}
}

@MainActor final class OverviewInitialFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !window.isVisible else { return }
        // Without an explicit target, the hosting view gives its first eligible
        // action initial keyboard focus when the new window is presented.
        window.initialFirstResponder = self
    }
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }
    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
}
