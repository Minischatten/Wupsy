import AppKit
import XCTest

@testable import Wupsy

final class StartupRecoveryLocalizationTests: XCTestCase {
    func testEnglishGermanFallbackAndOpaqueEvidenceKeepErrorIdentity() {
        let evidence =
            "NSCocoaErrorDomain code=513\n/Users/Synthetic/Private/ä %@.json; phase=rollingBack"
        let errors: [Error] = [
            WupsyStartupError.fatalRecovery(evidence),
            NSError(
                domain: "Synthetic", code: 513, userInfo: [NSLocalizedDescriptionKey: evidence]),
        ]
        XCTAssertEqual(
            StartupRecoveryText.title.localized(language: "en"),
            "Wupsy could not recover the library safely.")
        XCTAssertEqual(
            StartupRecoveryText.title.localized(language: "de"),
            "Wupsy konnte die Mediathek nicht sicher wiederherstellen.")
        for resource in StartupRecoveryText.allCases {
            for language in ["en", "de", "zz"] {
                XCTAssertFalse(resource.localized(language: language).isEmpty)
                XCTAssertNotEqual(resource.localized(language: language), resource.rawValue)
            }
            XCTAssertEqual(resource.localized(language: "zz"), resource.localized(language: "en"))
        }
        for error in errors {
            let original = String(reflecting: error)
            for language in ["en", "de", "zz"] {
                let detail = StartupRecoveryPresentation.detail(error, language: language)
                XCTAssertTrue(detail.hasSuffix(evidence))
                XCTAssertTrue(
                    detail.contains(language == "de" ? "Technische Details:" : "Technical details:")
                )
                XCTAssertTrue(
                    detail.hasPrefix(
                        language == "de" ? "Wupsy kann nicht starten" : "Wupsy cannot start"))
                XCTAssertEqual(error.localizedDescription, evidence)
                XCTAssertEqual(String(reflecting: error), original)
            }
            XCTAssertEqual(
                StartupRecoveryPresentation.detail(error, language: "zz"),
                StartupRecoveryPresentation.detail(error, language: "en"))
        }
    }

    @MainActor func testNativeCriticalAlertHasOnlyExistingQuitAction() {
        _ = NSApplication.shared
        let error = WupsyStartupError.fatalRecovery("POSIX errno=13")
        for language in ["en", "de", "zz"] {
            let alert = StartupRecoveryPresentation.alert(error, language: language)
            XCTAssertEqual(alert.alertStyle, .critical)
            XCTAssertEqual(
                alert.messageText, StartupRecoveryText.title.localized(language: language))
            XCTAssertEqual(
                alert.informativeText, StartupRecoveryPresentation.detail(error, language: language)
            )
            XCTAssertEqual(alert.buttons.count, 1)
            XCTAssertEqual(
                alert.buttons[0].title, language == "de" ? "Wupsy beenden" : "Quit Wupsy")
            XCTAssertEqual(alert.buttons[0].title, ProductText.quit.localized(language: language))
        }
    }

    func testBothRecoveryFailuresBlockStartupBeforePresentationAndRetainJournal() throws {
        for journal in ["metadata-recovery.json", "journal.json"] {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("startup-localization.tests." + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appendingPathComponent(".restore")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent(journal)
            let bytes = Data("{}".utf8)
            try bytes.write(to: path)
            let context = WupsyLaunchContext(
                supportRoot: root,
                preferenceDomain: "startup-localization.tests." + UUID().uuidString)
            var constructed = false
            var probed = false
            XCTAssertThrowsError(
                try WupsyStartup.run(
                    context: context,
                    probe: { context in
                        probed = true
                        return try WupsyStartup.needsRecovery(context)
                    }, constructRuntime: { constructed = true })
            ) { error in
                guard case WupsyStartupError.fatalRecovery(let detail) = error else {
                    return XCTFail("Expected typed startup recovery failure")
                }
                for language in ["en", "de", "zz"] {
                    XCTAssertTrue(
                        StartupRecoveryPresentation.detail(error, language: language).hasSuffix(
                            detail))
                    XCTAssertFalse(constructed)
                    XCTAssertEqual(try? Data(contentsOf: path), bytes)
                    XCTAssertEqual(error.localizedDescription, detail)
                }
            }
            XCTAssertFalse(constructed)
            XCTAssertEqual(probed, journal == "journal.json")
            XCTAssertEqual(try Data(contentsOf: path), bytes)
        }
    }
}
