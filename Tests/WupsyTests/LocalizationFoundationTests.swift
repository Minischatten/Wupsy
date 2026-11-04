import XCTest

@testable import Wupsy

final class LocalizationFoundationTests: XCTestCase {
    func testEnglishAndGermanAreLoadedFromModuleBundle() throws {
        XCTAssertNotEqual(Localization.bundle.bundleURL, Bundle.main.bundleURL)
        XCTAssertEqual(Localization.bundle.developmentLocalization, "en")
        for language in ["en", "de"] {
            XCTAssertNotNil(Localization.bundle.path(forResource: language, ofType: "lproj"))
        }
        XCTAssertEqual(Localization.string(.libraryOpen, language: "en"), "Open Wallpaper Library")
        XCTAssertEqual(
            Localization.string(.libraryOpen, language: "de"), "Hintergrundbild-Mediathek öffnen")
    }

    func testMissingTranslationAndUnknownLanguageUseEnglish() throws {
        let german = try XCTUnwrap(
            Localization.bundle.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:))
        )
        XCTAssertEqual(
            german.localizedString(
                forKey: "foundation.fallbackProbe", value: "missing", table: nil),
            "missing")
        for language in ["en", "de", "zz"] {
            XCTAssertEqual(
                Localization.string(.fallbackProbe, language: language),
                "English fallback")
        }
        XCTAssertEqual(
            Localization.string(.libraryOpen, language: "zz"), "Open Wallpaper Library")
    }

    func testNoResourceExposesAKey() {
        for resource in Localization.Resource.allCases {
            for language in ["en", "de", "zz"] {
                let value = Localization.string(resource, language: language)
                XCTAssertFalse(value.isEmpty)
                XCTAssertNotEqual(value, resource.rawValue)
                XCTAssertNotEqual(value, "Wupsy", "Development translation must exist")
            }
        }
    }

    func testLocalizedInterpolationPreservesUserContent() {
        let name = "A %@ — ä 👋 / 100%"
        XCTAssertEqual(Localization.wallpaperNamed(name, language: "en"), "Wallpaper: " + name)
        XCTAssertEqual(
            Localization.wallpaperNamed(name, language: "de"), "Hintergrundbild: " + name)
    }

    func testExplicitBundleDoesNotSilentlyUseModuleBundle() {
        // The test runner main bundle does not own Wupsy's semantic resources.
        // Even a packaging failure must not display a localization key.
        XCTAssertEqual(
            Localization.string(.libraryOpen, language: "de", bundle: .main), "Wupsy")
    }

    func testProductionAuditExercisesAllLookupsWithoutRuntime() throws {
        let report = try LocalizationAudit.run(expectedLanguage: nil)
        XCTAssertTrue(report.contains("Hintergrundbild-Mediathek"))
        XCTAssertTrue(report.contains("Wupsy_Wupsy.bundle"))
    }
}
