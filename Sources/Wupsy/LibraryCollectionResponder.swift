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
    let rename: () -> Void
    var navigate: (LibraryGridDirection) -> Void = { _ in }
    func makeNSView(context: Context) -> LibraryCollectionKeyView {
        let view = LibraryCollectionKeyView()
        view.focusRingType = .none
        view.setAccessibilityElement(false)
        focus.responder = view
        return view
    }
    func updateNSView(_ view: LibraryCollectionKeyView, context: Context) {
        view.remove = remove
        view.rename = rename
        view.navigate = navigate
        focus.responder = view
    }
}

@MainActor final class LibraryCollectionKeyView: NSView {
    var remove: () -> Void = {}
    var rename: () -> Void = {}
    var navigate: (LibraryGridDirection) -> Void = { _ in }
    override var acceptsFirstResponder: Bool { true }
    // Programmatic card focus only; do not add a new stop to Tab navigation.
    override var canBecomeKeyView: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func keyDown(with event: NSEvent) {
        let unmodified = event.modifierFlags.intersection([.command, .control, .option, .shift])
            .isEmpty
        if unmodified, let direction = arrowDirection(for: event), canHandleCollectionCommand {
            navigate(direction)
            return
        }
        if event.keyCode == 36, unmodified {
            if canHandleCollectionCommand && !event.isARepeat { rename() }
            return
        }
        interpretKeyEvents([event])
    }
    private func arrowDirection(for event: NSEvent) -> LibraryGridDirection? {
        switch event.keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: nil
        }
    }
    override func deleteBackward(_ sender: Any?) { removeIfFocused() }
    override func deleteForward(_ sender: Any?) { removeIfFocused() }
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }
    private var canHandleCollectionCommand: Bool {
        guard let window, window.firstResponder === self,
            window.attachedSheet == nil, NSApp.modalWindow == nil
        else { return false }
        return true
    }
    private func removeIfFocused() {
        guard canHandleCollectionCommand else { return }
        remove()
    }
}
