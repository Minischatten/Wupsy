import AppKit

// One native naming UI for first publication and independent copies.
@MainActor enum WSSWallpaperNameRequest {
    static func alert(title: String, proposedName: String, language: String? = nil) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = EditorText.nameLabel.localized(language: language)
        let field = NSTextField(string: proposedName)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        field.setAccessibilityLabel(ProductText.wallpaperName.localized(language: language))
        alert.accessoryView = field
        alert.addButton(withTitle: ProductText.save.localized(language: language)).keyEquivalent =
            "\r"
        alert.addButton(withTitle: ProductText.cancel.localized(language: language)).keyEquivalent =
            "\u{1b}"
        alert.window.initialFirstResponder = field
        return alert
    }
    static func present(title: String, proposedName: String, window: NSWindow) async -> String? {
        let alert = alert(title: title, proposedName: proposedName)
        guard let field = alert.accessoryView as? NSTextField else { return nil }
        while true {
            // AppKit installs the initial field editor as the sheet is presented.
            field.selectText(nil)
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else {
                return nil
            }
            do { return try WSSSaveAsSnapshot.title(field.stringValue) } catch {
                alert.informativeText =
                    ProductCoreError.nameValidation(field.stringValue)
                    ?? (error as? WSSSaveAsError == .name
                        ? EditorText.nameBytes.text : error.localizedDescription)
            }
        }
    }
}
