import AppKit
import XCTest

@testable import Wupsy

final class WidgetLocalizationTests: XCTestCase {
    func testAllWidgetResourcesHaveEnglishGermanAndEnglishFallback() {
        for resource in WidgetText.allCases {
            let english = resource.localized(language: "en")
            let german = resource.localized(language: "de")
            XCTAssertFalse(english.isEmpty)
            XCTAssertFalse(german.isEmpty)
            XCTAssertNotEqual(english, resource.rawValue)
            XCTAssertNotEqual(german, resource.rawValue)
            XCTAssertNotEqual(english, "Wupsy")
            XCTAssertNotEqual(german, "Wupsy")
            XCTAssertEqual(resource.localized(language: "zz"), english)
        }
        XCTAssertEqual(ProductText.allDisplays.localized(language: "de"), "Alle Bildschirme")
        XCTAssertEqual(EditorText.height.localized(language: "de"), "Höhe")
        XCTAssertEqual(
            ProductText.widgetsEdit.localized(language: "de"), "Desktop-Widgets bearbeiten")
        XCTAssertEqual(WidgetText.saved.localized(language: "de"), "Gesichert")
        XCTAssertEqual(
            WidgetText.unapplied.localized(language: "de"), "Noch nicht angewendete Änderungen")
        XCTAssertEqual(WidgetText.applyCode.localized(language: "de"), "Code anwenden")
        XCTAssertEqual(
            WidgetText.resetLayout.localized(language: "de"), "Größen und Positionen zurücksetzen")
    }

    func testSixNamesDoNotChangeKindsOrEncodedIdentity() throws {
        let english = ["Clock", "Date", "CPU", "Memory", "Network graph", "Custom HTML"]
        let german = ["Uhr", "Datum", "CPU", "Arbeitsspeicher", "Netzwerkdiagramm", "Eigenes HTML"]
        let raw = ["clock", "date", "cpu", "memory", "network", "custom"]
        for (index, kind) in WidgetKind.allCases.enumerated() {
            let encoded = try JSONEncoder().encode(kind)
            XCTAssertEqual(kind.title(language: "en"), english[index])
            XCTAssertEqual(kind.title(language: "de"), german[index])
            XCTAssertEqual(kind.title(language: "zz"), english[index])
            XCTAssertEqual(kind.rawValue, raw[index])
            XCTAssertEqual(kind.id, raw[index])
            XCTAssertEqual(try JSONDecoder().decode(WidgetKind.self, from: encoded), kind)
            XCTAssertEqual(try JSONEncoder().encode(kind), encoded)
        }
    }

    func testCompleteAccessibilityTemplatesKeepDynamicValues() {
        for language in ["en", "de", "zz"] {
            let name = WidgetKind.network.title(language: language)
            XCTAssertEqual(
                WidgetText.sizeAX.format(name, language: language),
                language == "de" ? "Größe von Netzwerkdiagramm" : "Network graph size")
            XCTAssertEqual(
                WidgetText.dragAX.format(name, language: language),
                language == "de" ? "Netzwerkdiagramm verschieben" : "Drag Network graph")
            let rates = WidgetText.networkValuesAX.format(
                "1,5 KB/s", "2,3 MB/s", language: language)
            XCTAssertTrue(rates.contains("1,5 KB/s"))
            XCTAssertTrue(rates.contains("2,3 MB/s"))
            XCTAssertFalse(WidgetText.graphAX.localized(language: language).contains("%@"))
            XCTAssertFalse(WidgetText.editHint.localized(language: language).isEmpty)
            let action = ProductText.widgetsFinish.localized(language: language)
            let hint = WidgetText.movementHint.format(action, language: language)
            XCTAssertTrue(hint.contains(action))
            XCTAssertFalse(hint.contains("%1$@"))
            let help = WidgetText.codeHint.localized(language: language)
            for token in [
                "data-ambient", "time", "date", "cpu", "memory", "download", "upload", "--cpu",
                "--memory",
            ] {
                XCTAssertTrue(help.contains(token))
            }
        }
    }

    func testNumericPresentationKeepsPrecisionUnitsAndThresholds() {
        let en = Locale(identifier: "en_US")
        let de = Locale(identifier: "de_DE")
        XCTAssertEqual(WidgetValues.percent(12.5, digits: 1, locale: en), "12.5%")
        let germanPercent = WidgetValues.percent(12.5, digits: 1, locale: de)
        XCTAssertTrue(germanPercent.hasPrefix("12,5"))
        XCTAssertTrue(germanPercent.hasSuffix("%"))
        XCTAssertEqual(WidgetValues.percent(149, digits: 0, locale: en), "149%")
        XCTAssertEqual(WidgetValues.memory(1_610_612_736, locale: en, language: "en"), "1.50 GB")
        XCTAssertEqual(WidgetValues.memory(1_610_612_736, locale: de, language: "de"), "1,50 GB")
        XCTAssertEqual(WidgetValues.rate(1536, locale: en, language: "en"), "1.5 KB/s")
        XCTAssertEqual(WidgetValues.rate(1536, locale: de, language: "de"), "1,5 KB/s")
        XCTAssertEqual(WidgetValues.rate(1_572_864, locale: en, language: "en"), "1.50 MB/s")
        XCTAssertEqual(WidgetValues.rate(1_572_864, locale: de, language: "de"), "1,50 MB/s")
        XCTAssertTrue(WidgetValues.rate(1_048_575, locale: en).hasSuffix("KB/s"))
        XCTAssertEqual(WidgetValues.rate(1_048_576, locale: en), "1.00 MB/s")
        XCTAssertEqual(WidgetValues.rate(0, locale: de), "0,0 KB/s")
    }

    func testTypedValidationAndUnknownErrorsKeepEvidence() throws {
        let cases: [(CustomWidgetError, WidgetText)] = [
            (.unsupportedVersion, .unsupportedVersion), (.invalidPackage, .invalidPackage),
            (.packageTooLarge, .packageTooLarge),
        ]
        for (error, text) in cases {
            let original = error.localizedDescription
            for language in ["en", "de", "zz"] {
                XCTAssertEqual(
                    WidgetErrorPresentation.message(error, language: language),
                    text.localized(language: language))
                XCTAssertEqual(error.localizedDescription, original)
            }
        }
        var package = CustomWidgetPackage.starter
        package.version = 2
        XCTAssertThrowsError(try package.validated()) {
            XCTAssertEqual($0 as? CustomWidgetError, .unsupportedVersion)
        }
        package.version = 1
        for invalid in ["", String(repeating: "x", count: 121)] {
            package.name = invalid
            XCTAssertThrowsError(try package.validated()) {
                XCTAssertEqual($0 as? CustomWidgetError, .invalidPackage)
            }
        }
        let evidence = "NSCocoaErrorDomain code=513 /Users/Synthetic/Private/ä %@.json"
        let error = NSError(
            domain: "Synthetic", code: 513, userInfo: [NSLocalizedDescriptionKey: evidence])
        for language in ["en", "de", "zz"] {
            XCTAssertTrue(
                WidgetErrorPresentation.message(error, language: language).hasSuffix(evidence))
            XCTAssertTrue(
                WidgetErrorPresentation.updateFailed(error, language: language).hasSuffix(evidence))
            XCTAssertTrue(
                WidgetErrorPresentation.message(error, language: language).hasPrefix(
                    language == "de" ? "Das eigene Widget" : "The custom widget"))
            XCTAssertFalse(WidgetText.webStopped.localized(language: language).isEmpty)
        }
    }

    func testStarterAndUserPackageStayLanguageIndependent() throws {
        let starter = CustomWidgetPackage.starter
        XCTAssertEqual(starter.name, "Violet pulse")
        XCTAssertTrue(starter.html.contains("MY WUPSY SPACE"))
        XCTAssertTrue(starter.html.contains("data-ambient=\"time\""))
        XCTAssertTrue(starter.css.contains("var(--cpu)"))
        var user = starter
        user.name = "Mein widget / 私の %@"
        user.html += "<p data-ambient=\"download\">User text</p>"
        user.css += "\n/* User CSS */"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for package in [starter, user] {
            let bytes = try encoder.encode(package)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["version", "name", "html", "css", "height"])
            for language in ["en", "de", "zz"] {
                _ = WidgetText.loadStarter.localized(language: language)
                _ = WidgetKind.custom.title(language: language)
                XCTAssertEqual(try encoder.encode(package.validated()), bytes)
                XCTAssertEqual(
                    try JSONDecoder().decode(CustomWidgetPackage.self, from: bytes), package)
                XCTAssertTrue(package.document.contains(package.html))
                XCTAssertTrue(package.document.contains(package.css))
                XCTAssertTrue(package.document.contains("script-src 'none'"))
            }
        }
    }

    @MainActor func testWebTerminationUsesExistingFailureCallbackWithoutChangingPackage() {
        _ = NSApplication.shared
        let package = CustomWidgetPackage.starter
        let host = CustomWidgetHost(
            package: package, size: NSSize(width: 360, height: 190), scale: 1)
        defer { host.stop() }
        var failures: [String] = []
        host.error = { failures.append($0) }
        host.webViewWebContentProcessDidTerminate(host.view)
        XCTAssertFalse(host.ready)
        XCTAssertEqual(failures, [WidgetText.webStopped.localized()])
        XCTAssertEqual(package, .starter)
        XCTAssertFalse(host.view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }

    @MainActor func testGermanEditHintNeedsWiderPanel() {
        let hint = WidgetText.editHint.localized(language: "de")
        let width = (hint as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
            .width
        // Allow icon, Done button, spacing and padding in the existing single-row panel.
        XCTAssertGreaterThan(width + 215, 470)
        XCTAssertLessThan(width + 215, 640)
    }

    @MainActor func testLocalizedWindowsKeepTechnicalIDsAndPositionKeys() throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("Requires an active display session") }
        let domain = "widget-localization.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let widgets = DesktopWidgets(defaults: defaults)
        defer { widgets.shutdownForMaintenance() }
        widgets.setEnabled(.network, true)
        widgets.setEditing(true)
        let window = try XCTUnwrap(widgets.windows.first)
        XCTAssertTrue(window.identifier?.rawValue.hasPrefix("widget-network@") == true)
        XCTAssertEqual(window.title, WidgetKind.network.title)
        let drag = try XCTUnwrap(
            window.contentView?.subviews.compactMap { $0 as? WidgetDragSurface }.first)
        XCTAssertEqual(
            drag.accessibilityLabel(), WidgetText.dragAX.format(WidgetKind.network.title))
        let point = NSPoint(x: window.frame.midX, y: window.frame.midY)
        drag.beginDrag(at: point)
        drag.drag(to: NSPoint(x: point.x + 10, y: point.y - 10))
        drag.endDrag()
        let data = try XCTUnwrap(defaults.data(forKey: "widgetPositions"))
        let positions = try JSONDecoder().decode([String: WidgetPosition].self, from: data)
        XCTAssertEqual(
            Array(positions.keys),
            [String(try XCTUnwrap(window.identifier).rawValue.dropFirst("widget-".count))])
        let original = widgets.custom
        var invalid = original
        invalid.height = 601
        widgets.applyCustom(invalid)
        XCTAssertEqual(widgets.custom, original)
        XCTAssertEqual(
            widgets.error, WidgetErrorPresentation.message(CustomWidgetError.invalidPackage))
    }
}
