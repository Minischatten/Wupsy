import AppKit

enum WSSCanvasZoomCommand {
    case zoomIn, zoomOut, fit, actualSize
    static func decode(_ event: NSEvent) -> Self? {
        guard event.type == .keyDown,
            event.modifierFlags.intersection([.command, .control, .option]) == .command
        else { return nil }
        // macOS keyboard layouts may expose Shift-Plus as '+' or as the underlying '='.
        let keys = [event.characters, event.charactersIgnoringModifiers].compactMap { $0 }
        if keys.contains("+") || keys.contains("=") { return .zoomIn }
        if keys.contains("-") || keys.contains("−") { return .zoomOut }
        if keys.contains("0") { return .fit }
        if keys.contains("1") { return .actualSize }
        return nil
    }
}
