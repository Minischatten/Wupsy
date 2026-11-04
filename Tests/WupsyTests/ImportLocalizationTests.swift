import AppKit
import XCTest

@testable import Wupsy

final class ImportLocalizationTests: XCTestCase {
    let source = URL(fileURLWithPath: "/Volumes/Private/Überblick 🖼 %/scene.wss.json")

    func testEveryImportResourceHasEnglishGermanAndEnglishFallback() throws {
        for resource in ImportText.allCases {
            for language in ["en", "de"] {
                let path = try XCTUnwrap(
                    Localization.bundle.path(forResource: language, ofType: "lproj"))
                let bundle = try XCTUnwrap(Bundle(path: path))
                XCTAssertNotEqual(
                    bundle.localizedString(
                        forKey: resource.rawValue, value: "__missing__", table: nil), "__missing__",
                    resource.rawValue)
                let value = resource.localized(language: language)
                XCTAssertFalse(value.isEmpty)
                XCTAssertNotEqual(value, "Wupsy")
                XCTAssertNotEqual(value, resource.rawValue)
            }
            XCTAssertEqual(resource.localized(language: "zz"), resource.localized(language: "en"))
        }
    }

    func testAllNativeCategoriesAndBothDispositionsPreserveTechnicalEvidenceAcrossLanguages() {
        let cases: [(WallpaperImportDiagnostic.Category, ImportText, ImportText)] = [
            (.invalidProject, .invalidProjectTitle, .invalidProject),
            (.invalidResource, .failed, .invalidResource),
            (.unsafePath, .unsafeTitle, .unsafePath),
            (.resourceLimit, .failed, .resourceLimit),
            (.storage, .failed, .storage), (.publish, .failed, .publish),
            (.rollback, .failed, .rollback), (.cleanup, .failed, .cleanup),
        ]
        XCTAssertEqual(cases.count, 8)
        for (category, title, reason) in cases {
            for disposition: WallpaperImportDiagnostic.Disposition in [
                .unsupported, .invalidOrUnsafe,
            ] {
                let diagnostic = WallpaperImportDiagnostic(
                    category, disposition: disposition, file: "assets/🖼.png", field: "version",
                    expected: "0 or 1", actual: "5", detail: "W7 evidence\ncode=13; 100%")
                let before = diagnostic
                for language in ["en", "de", "zz"] {
                    let value = ImportFailurePresentation(
                        source: source, error: diagnostic, language: language)
                    let explanation = reason
                    XCTAssertEqual(value.title, title.localized(language: language))
                    XCTAssertEqual(value.explanation, explanation.localized(language: language))
                    XCTAssertFalse((value.title + value.explanation).contains("W7"))
                    XCTAssertEqual(value.sourceName, "Überblick 🖼 %/scene.wss.json")
                    let fields: [(ImportText, String)] = [
                        (.diagnosticCategory, category.rawValue),
                        (.diagnosticDisposition, disposition.rawValue),
                        (.diagnosticFile, diagnostic.file!), (.diagnosticField, diagnostic.field!),
                        (.diagnosticExpected, diagnostic.expected!),
                        (.diagnosticActual, diagnostic.actual!),
                        (.diagnosticDetail, diagnostic.detail!),
                    ]
                    XCTAssertEqual(
                        value.technicalDetails,
                        fields.map { $0.0.format($0.1, language: language) }.joined(separator: "\n")
                    )
                    XCTAssertEqual(
                        value.copyText,
                        ImportText.diagnosticHeading.localized(language: language) + "\n\n"
                            + value.technicalDetails)
                    XCTAssertEqual(diagnostic, before)
                    XCTAssertEqual(diagnostic.category, category)
                    XCTAssertEqual(diagnostic.disposition, disposition)
                }
            }
        }
        XCTAssertEqual(
            ImportText.failed.localized(language: "en"), "This wallpaper could not be imported.")
        XCTAssertEqual(
            ImportText.failed.localized(language: "de"),
            "Dieses Hintergrundbild konnte nicht importiert werden.")
    }

    func testNativeAndOpaqueMediaErrorsUseLocalizedMainTextAndStablePrivateDetails() {
        let cases: [(Error, ImportText)] = [
            (WSSDocumentError.version(5), .wssVersion),
            (WSSDocumentError.invalid("decoder codingPath: layers"), .wssInvalid),
            (WSSDocumentError.missingAsset("assets/base.png"), .invalidResource),
            (WSSDocumentError.unsafePath("/Users/Test/Private/base.png"), .unsafePath),
            (WSSDocumentError.effect("future-effect"), .wssUnsupported),
            (WSSSceneError.invalid("image dimensions"), .wssInvalid),
            (WSSSceneError.unsupported("future layer"), .wssUnsupported),
            (WSSSceneError.decodedImageBudget, .decodedBudget),
            (
                ImportFailure.message("Decoder failed: /Users/Test/Private/movie.mp4; code=13"),
                .generic
            ),
            (
                NSError(
                    domain: "Synthetic", code: 13,
                    userInfo: [NSLocalizedDescriptionKey: "Read /Volumes/Secret/file.json; code=13"]
                ), .generic
            ),
        ]
        for (error, reason) in cases {
            for language in ["en", "de", "zz"] {
                let value = ImportFailurePresentation(
                    source: source, error: error, language: language)
                XCTAssertEqual(value.title, ImportText.failed.localized(language: language))
                XCTAssertEqual(
                    value.explanation,
                    reason == .wssVersion
                        ? reason.format(Int64(5), language: language)
                        : reason.localized(language: language))
                XCTAssertEqual(
                    value.technicalDetails,
                    ImportFailurePresentation.privatePaths(
                        "Details: " + error.localizedDescription, source: source))
                XCTAssertFalse(value.copyText.contains("/Users/"))
                XCTAssertFalse(value.copyText.contains("/Volumes/"))
                XCTAssertTrue(value.copyText.hasSuffix(value.technicalDetails))
            }
        }
    }

    @MainActor func testDiagnosticLabelsCopyAndRedactionPreserveExactTechnicalValues() {
        let diagnostic = WallpaperImportDiagnostic(
            .invalidResource, file: "assets/🖼.png", field: "effects.file",
            expected: "supported effect ID",
            actual: "effects/workshop/2554230787/periodic_waterwaves/effect.json",
            detail:
                "Read /Users/Private/Secret/mask.png; code=13\nField: raw parser text stays verbatim"
        )
        let original = diagnostic
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for language in ["en", "de", "zz"] {
            let german = language == "de"
            let labels =
                german
                ? [
                    "Kategorie", "Einstufung", "Datei", "Feld", "Erwarteter Wert",
                    "Tatsächlicher Wert", "Detail",
                ]
                : ["Category", "Disposition", "File", "Field", "Expected", "Actual", "Detail"]
            let values = [
                diagnostic.category.rawValue, diagnostic.disposition.rawValue,
                diagnostic.file!, diagnostic.field!, diagnostic.expected!, diagnostic.actual!,
                "Read [lokaler Pfad]/mask.png; code=13\nField: raw parser text stays verbatim",
            ]
            let expected = zip(labels, values).map { $0 + ": " + $1 }.joined(separator: "\n")
            let value = ImportFailurePresentation(
                source: source, error: diagnostic, language: language)
            XCTAssertEqual(value.technicalDetails, expected)
            XCTAssertEqual(
                value.copyText,
                (german ? "Wallpaper-Importdiagnose" : "Wallpaper Import Diagnostic") + "\n\n"
                    + expected)
            ImportFailureView.copy(value, to: pasteboard)
            XCTAssertEqual(pasteboard.string(forType: .string), value.copyText)
            XCTAssertEqual(diagnostic, original)
            XCTAssertFalse(value.copyText.contains("/Users/"))
        }
    }

    func testSheetPluralTemplatesAndAccessibilityInBothLanguagesAndFallback() {
        for language in ["en", "de", "zz"] {
            let german = language == "de"
            for count: Int64 in [0, 1, 2] {
                let expected: String
                if german {
                    expected =
                        count == 1 ? "1 Import fehlgeschlagen" : "\(count) Imports fehlgeschlagen"
                } else {
                    expected = count == 1 ? "1 import failed" : "\(count) imports failed"
                }
                XCTAssertEqual(ImportText.failures.format(count, language: language), expected)
            }
            let name = "Überblick 🖼 %/scene.wss.json"
            XCTAssertEqual(
                ImportText.sourceNumber.format(Int64(2), name, language: language), "2. " + name)
            XCTAssertEqual(
                ImportText.detailsAccessibility.format(name, language: language),
                (german ? "Technische Details zu " : "Technical details for ") + name)
            XCTAssertEqual(
                ImportText.copyAccessibility.format(name, language: language),
                german ? "Details zu \(name) kopieren" : "Copy details for \(name)")
            XCTAssertEqual(
                ImportText.close.localized(language: language), german ? "Schließen" : "Close")
            XCTAssertEqual(ImportText.details.localized(language: language), "Details")
            XCTAssertEqual(
                ImportText.copyDetails.localized(language: language),
                german ? "Details kopieren" : "Copy details")
            XCTAssertEqual(
                ProductText.expanded.localized(language: language),
                german ? "Ausgeklappt" : "Expanded")
            XCTAssertEqual(
                ProductText.collapsed.localized(language: language),
                german ? "Eingeklappt" : "Collapsed")
        }
    }
}
