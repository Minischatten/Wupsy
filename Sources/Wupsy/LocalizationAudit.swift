import Foundation

// Read-only build verification, before constructing any runtime or opening user
// storage. Also exercises the actual generated Bundle.module accessor in the app.
enum LocalizationAudit {
    static func run(expectedLanguage: String?) throws -> String {
        func require(_ condition: Bool, _ detail: String) throws {
            guard condition else {
                throw NSError(
                    domain: "Wupsy.LocalizationAudit", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: detail])
            }
        }
        let bundle = Localization.bundle
        try require(Set(bundle.localizations).isSuperset(of: ["en", "de"]), "Missing en/de")
        let english = Localization.string(.libraryOpen, language: "en")
        let german = Localization.string(.libraryOpen, language: "de")
        try require(english == "Open Wallpaper Library", "English lookup failed")
        try require(german == "Hintergrundbild-Mediathek öffnen", "German lookup failed")
        try require(
            Localization.wallpaperNamed("A %@ ä", language: "de") == "Hintergrundbild: A %@ ä",
            "Interpolation failed")
        let fallback = Localization.string(.fallbackProbe, language: "en")
        try require(
            fallback == "English fallback", "English fallback missing")
        try require(
            Localization.string(.fallbackProbe, language: "de") == fallback,
            "Missing German translation did not fall back")
        try require(
            Localization.string(.libraryOpen, language: "zz") == english,
            "Unknown language did not fall back")
        for resource in Localization.Resource.allCases {
            for language in ["en", "de", "zz"] {
                let value = Localization.string(resource, language: language)
                try require(
                    !value.isEmpty && value != resource.rawValue && value != "Wupsy",
                    "Missing resource: \(resource.rawValue)/\(language)")
            }
        }
        for language in ["en", "de"] {
            guard let path = bundle.path(forResource: language, ofType: "lproj"),
                let localized = Bundle(path: path)
            else {
                try require(false, "Missing product language bundle")
                continue
            }
            for resource in ProductText.allCases {
                let value = localized.localizedString(
                    forKey: resource.rawValue, value: "__missing__", table: nil)
                try require(
                    !value.isEmpty && value != "__missing__" && value != resource.rawValue,
                    "Missing product resource: \(resource.rawValue)/\(language)")
            }
        }
        try require(
            ProductText.wallpaperCount.format(Int64(2), language: "de") == "2 Hintergrundbilder",
            "Product plural lookup failed")
        try require(
            ProductText.playlistWaiting.format("海 %@", language: "de")
                == "海 %@ · Wiedergabestart wird abgewartet …", "Product name interpolation failed")
        if let expectedLanguage {
            try require(
                Localization.string(.libraryOpen)
                    == Localization.string(.libraryOpen, language: expectedLanguage),
                "App language selection failed: \(expectedLanguage)")
        }
        let result: [String: String] = [
            "bundle": bundle.bundleURL.path, "en": english, "de": german,
            "fallback": fallback, "selected": Localization.string(.libraryOpen),
            "productResources": String(ProductText.allCases.count),
            "germanPlural": ProductText.wallpaperCount.format(Int64(2), language: "de"),
        ]
        return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    }
}
