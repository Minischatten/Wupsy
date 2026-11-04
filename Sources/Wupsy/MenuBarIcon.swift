import AppKit

/// A separate template mask; the app icon remains independent.
enum MenuBarIcon {
    static let resourceName = "Wupsy-MenuBar-Icon-v1"
    static let image: NSImage = {
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "png"),
            let image = load(from: url)
        {
            return image
        }
        // Preserve the native symbol when running without the packaged resources.
        return NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "Wupsy")!
    }()

    static func load(from url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0
        else { return nil }
        let ratio = image.size.width / image.size.height
        image.size = NSSize(width: 24, height: 24 / ratio)
        image.isTemplate = true
        image.accessibilityDescription = "Wupsy"
        return image
    }
}
