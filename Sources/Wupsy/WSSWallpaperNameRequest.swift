import AppKit

struct WSSImageFirstSaveChoice {
    let name: String
    let replace: Bool
}

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
    static func imageAlert(proposedName: String, language: String? = nil) -> (
        NSAlert, NSTextField, NSPopUpButton
    ) {
        let sheet = alert(
            title: EditorText.saveWallpaper.localized(language: language),
            proposedName: proposedName, language: language)
        let field = sheet.accessoryView as! NSTextField
        let options = NSPopUpButton(frame: .zero, pullsDown: false)
        options.addItems(withTitles: [
            EditorText.imageSaveAdditional.localized(language: language),
            EditorText.imageSaveReplace.localized(language: language),
        ])
        options.selectItem(at: 0)
        options.setAccessibilityLabel(EditorText.imageSaveMode.localized(language: language))
        let hint = NSTextField(
            wrappingLabelWithString: EditorText.imageSaveExplanation.localized(language: language))
        hint.preferredMaxLayoutWidth = 420
        let stack = NSStackView(views: [field, options, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 155)
        sheet.accessoryView = stack
        return (sheet, field, options)
    }
    static func presentImage(proposedName: String, window: NSWindow) async
        -> WSSImageFirstSaveChoice?
    {
        let (sheet, field, options) = imageAlert(proposedName: proposedName)
        while true {
            field.selectText(nil)
            guard await sheet.beginSheetModal(for: window) == .alertFirstButtonReturn else {
                return nil
            }
            do {
                return WSSImageFirstSaveChoice(
                    name: try WSSSaveAsSnapshot.title(field.stringValue),
                    replace: options.indexOfSelectedItem == 1)
            } catch {
                sheet.informativeText =
                    ProductCoreError.nameValidation(field.stringValue) ?? error.localizedDescription
            }
        }
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
