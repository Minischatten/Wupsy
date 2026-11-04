import Foundation

// The catalog is the only edited translation source. Language injection is local
// to a lookup (tests/audits); production follows the bundle's preferred language.
enum Localization {
    enum Resource: String, CaseIterable {
        case libraryOpen = "library.open"
        case libraryRestartHint = "library.restartHint"
        case wallpaperNamed = "wallpaper.named"
        case fallbackProbe = "foundation.fallbackProbe"
    }

    static var bundle: Bundle { .module }

    static func string(
        _ resource: Resource, language: String? = nil, bundle: Bundle = .module
    ) -> String {
        string(key: resource.rawValue, language: language, bundle: bundle)
    }

    static func string(key: String, language: String? = nil, bundle: Bundle = .module) -> String {
        let english = localizedBundle("en", in: bundle)
        // An absent development resource is a packaging error, caught by tests
        // and the pre-signing app audit. Never expose a semantic key in the UI.
        let fallback =
            english?.localizedString(
                forKey: key, value: "Wupsy", table: nil) ?? "Wupsy"
        let selected: Bundle
        if let language {
            selected = localizedBundle(language, in: bundle) ?? english ?? bundle
        } else {
            selected = bundle
        }
        return selected.localizedString(forKey: key, value: fallback, table: nil)
    }

    static func wallpaperNamed(
        _ name: String, language: String? = nil, bundle: Bundle = .module
    ) -> String {
        String(
            format: string(.wallpaperNamed, language: language, bundle: bundle),
            locale: language.map(Locale.init(identifier:)) ?? .current, arguments: [name])
    }

    private static func localizedBundle(_ language: String, in bundle: Bundle) -> Bundle? {
        bundle.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
    }
}
