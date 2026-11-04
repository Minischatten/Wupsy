import AppKit
import SwiftUI

// A local command target, explicitly focused by the collection's card action.
@MainActor final class LibraryCollectionFocus: ObservableObject {
    weak var responder: LibraryCollectionKeyView?
    @discardableResult func focus() -> Bool {
        guard let responder, let window = responder.window,
            window.attachedSheet == nil, NSApp.modalWindow == nil
        else { return false }
        return window.makeFirstResponder(responder)
    }
}

struct LibraryCollectionResponder: NSViewRepresentable {
    let focus: LibraryCollectionFocus
    let remove: () -> Void
    func makeNSView(context: Context) -> LibraryCollectionKeyView {
        let view = LibraryCollectionKeyView()
        view.focusRingType = .none
        view.setAccessibilityElement(false)
        focus.responder = view
        return view
    }
    func updateNSView(_ view: LibraryCollectionKeyView, context: Context) {
        view.remove = remove
        focus.responder = view
    }
}

@MainActor final class LibraryCollectionKeyView: NSView {
    var remove: () -> Void = {}
    override var acceptsFirstResponder: Bool { true }
    // Programmatic card focus only; do not add a new stop to Tab navigation.
    override var canBecomeKeyView: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
    override func deleteBackward(_ sender: Any?) { removeIfFocused() }
    override func deleteForward(_ sender: Any?) { removeIfFocused() }
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }
    private func removeIfFocused() {
        guard let window, window.firstResponder === self,
            window.attachedSheet == nil, NSApp.modalWindow == nil
        else { return }
        remove()
    }
}
