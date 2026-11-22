import AppKit
import SwiftUI

// Keep the hit region with the label so native double-click routing follows
// List layout, scrolling and interface scale without changing single clicks.
struct WSSLayerNameHitRegion: NSViewRepresentable {
    let layer: WSSLayerID

    func makeNSView(context: Context) -> Marker { Marker() }

    func updateNSView(_ view: Marker, context: Context) { view.layerID = layer }

    final class Marker: NSView {
        var layerID: WSSLayerID?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        static func layer(at point: NSPoint, in view: NSView) -> WSSLayerID? {
            guard !view.isHidden,
                view.visibleRect.contains(view.convert(point, from: nil))
            else { return nil }
            if let marker = view as? Marker { return marker.layerID }
            for child in view.subviews.reversed() {
                if let id = layer(at: point, in: child) { return id }
            }
            return nil
        }
    }
}

struct WSSLayerNameField: NSViewRepresentable {
    @Environment(\.wupsyMetrics) private var metrics
    let initialName: String
    let finish: (String?, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: initialName)
        field.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(EditorText.renameLayer.text)
        field.identifier = NSUserInterfaceItemIdentifier("wss.layer.rename")
        field.delegate = context.coordinator
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window, window.makeFirstResponder(field),
                let editor = field.currentEditor() as? NSTextView
            else { return }
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
            editor.allowsUndo = false
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.controlSize = metrics.nativeControlSize
        field.font = .systemFont(ofSize: metrics.points(NSFont.systemFontSize))
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let finish: (String?, Bool) -> Void
        private var finished = false
        private var keyboard = false
        private var cancelled = false

        init(finish: @escaping (String?, Bool) -> Void) { self.finish = finish }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !finished, let field = notification.object as? NSTextField else { return }
            finished = true
            finish(cancelled ? nil : field.stringValue, keyboard)
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.cancelOperation(_:)): cancelled = true
            case #selector(NSResponder.insertNewline(_:)): break
            default: return false
            }
            keyboard = true
            control.window?.makeFirstResponder(nil)
            return true
        }
    }
}
