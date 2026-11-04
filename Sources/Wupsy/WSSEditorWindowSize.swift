import AppKit

/// Only the shared normal window size, in AppKit points. No position or document state.
struct WSSEditorWindowSize {
    static let key = "editorWindowSize"
    static let minimumContent = NSSize(width: 1000, height: 600)
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var saved: NSSize? {
        guard let values = defaults.array(forKey: Self.key) as? [Double], values.count == 2 else {
            return nil
        }
        let size = NSSize(width: values[0], height: values[1])
        return Self.isValid(size) ? size : nil
    }
    func recordUserSize(_ size: NSSize) {
        guard Self.isValid(size) else { return }
        defaults.set([Double(size.width), Double(size.height)], forKey: Self.key)
    }
    private static func isValid(_ size: NSSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            && size.width <= 32768 && size.height <= 32768
    }
    func initialFrame(in visible: NSRect, minimum: NSSize) -> NSRect {
        let preferred =
            saved
            ?? NSSize(
                width: min(1800, visible.width * 0.95), height: min(1200, visible.height * 0.95))
        let size = Self.bounded(preferred, available: visible.size, minimum: minimum)
        return NSRect(
            x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
            width: size.width, height: size.height)
    }
    static func bounded(_ size: NSSize, available: NSSize, minimum: NSSize) -> NSSize {
        NSSize(
            width: min(available.width, max(minimum.width, size.width)),
            height: min(available.height, max(minimum.height, size.height)))
    }
    static func constrained(_ frame: NSRect, to visible: NSRect, minimum: NSSize) -> NSRect {
        let size = bounded(frame.size, available: visible.size, minimum: minimum)
        return NSRect(
            x: min(max(frame.minX, visible.minX), visible.maxX - size.width),
            y: min(max(frame.maxY - size.height, visible.minY), visible.maxY - size.height),
            width: size.width, height: size.height)
    }
}
