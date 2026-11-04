import AppKit

// The existing startup failure boundary only. Recovery identity, ordering and
// decisions stay in WupsyStartup; no successful-start presentation is added.
enum StartupRecoveryText: String, CaseIterable {
    case title = "startupRecovery.title"
    case detail = "startupRecovery.detail"

    func localized(language: String? = nil) -> String {
        Localization.string(key: rawValue, language: language)
    }
}

enum StartupRecoveryPresentation {
    static func detail(_ error: Error, language: String? = nil) -> String {
        let evidence: String
        switch error {
        case WupsyStartupError.fatalRecovery(let detail): evidence = detail
        default: evidence = error.localizedDescription
        }
        return String(
            format: StartupRecoveryText.detail.localized(language: language),
            locale: language.map(Locale.init(identifier:)) ?? .current, evidence)
    }

    @MainActor static func alert(_ error: Error, language: String? = nil) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = StartupRecoveryText.title.localized(language: language)
        alert.informativeText = detail(error, language: language)
        alert.addButton(withTitle: ProductText.quit.localized(language: language))
        return alert
    }
}
