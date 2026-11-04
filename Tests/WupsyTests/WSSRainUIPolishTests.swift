import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSRainUIPolishTests: XCTestCase {
    func testMenuUsesExistingLocalizedEffectName() {
        XCTAssertEqual(EditorText.effectRain.localized(language: "de"), "Regen")
        XCTAssertEqual(EditorText.effectRain.localized(language: "en"), "Rain")
    }
    func testDisplayPrecisionUsesLocaleWithoutGroupingOrFloatTails() {
        for parameter in WSSRainParameter.allCases {
            let expected: Int
            if case .width = parameter { expected = 2 } else { expected = 1 }
            XCTAssertEqual(parameter.displayFractionDigits, expected)
        }
        for (digits, value, english, german): (Int, Float, String, String) in [
            (1, 45.424652, "45.4", "45,4"), (1, 42.4487, "42.4", "42,4"),
            (2, 1.7535415, "1.75", "1,75"), (2, 1.405856, "1.41", "1,41"),
            (1, 48, "48", "48"), (1, 2345.678, "2345.7", "2345,7"),
        ] {
            XCTAssertEqual(
                WSSParameterNumberPresentation(
                    maximumFractionDigits: digits,
                    locale: Locale(identifier: "en_US")
                ).display(value), english)
            XCTAssertEqual(
                WSSParameterNumberPresentation(
                    maximumFractionDigits: digits,
                    locale: Locale(identifier: "de_DE")
                ).display(value), german)
        }
    }
    func testRoundedDisplayAndUntouchedFocusNeverCommitOrLosePrecision() {
        let original: Float = 1.7535415
        var stored = original
        var commits = 0
        let input = WSSParameterTextField(
            value: original, range: 0.25...8, title: "Width",
            maximumFractionDigits: 2, locale: Locale(identifier: "de_DE")
        ) {
            stored = $0
            commits += 1
        }
        let coordinator = input.makeCoordinator()
        let field = NSTextField(string: input.presentation.display(original))
        XCTAssertEqual(field.stringValue, "1,75")
        XCTAssertTrue(coordinator.accept(field))
        coordinator.controlTextDidBeginEditing(
            Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        XCTAssertEqual(field.stringValue, "1,75")
        XCTAssertTrue(coordinator.accept(field))
        XCTAssertEqual(field.stringValue, "1,75")
        XCTAssertTrue(coordinator.accept(field))
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(stored.bitPattern, original.bitPattern)
    }
    func testPreciseCommaAndPointInputCommitOnceThenDisplayRounded() {
        for (locale, text, display) in [("de_DE", "1,375", "1,38"), ("en_US", "1.375", "1.38")] {
            var stored: Float = 1.2
            var commits = 0
            let input = WSSParameterTextField(
                value: stored, range: 0.25...8, title: "Width",
                maximumFractionDigits: 2, locale: Locale(identifier: locale)
            ) {
                stored = $0
                commits += 1
            }
            let coordinator = input.makeCoordinator()
            let field = NSTextField(string: text)
            XCTAssertTrue(
                coordinator.control(
                    field, textView: NSTextView(),
                    doCommandBy: #selector(NSResponder.insertNewline(_:))))
            XCTAssertEqual(stored, 1.375)
            XCTAssertEqual(field.stringValue, display)
            // Return and native end-editing can both call validation. The second call
            // must not commit the rounded presentation as a new model value.
            XCTAssertTrue(coordinator.control(field, textShouldEndEditing: NSTextView()))
            XCTAssertEqual(stored, 1.375)
            XCTAssertEqual(commits, 1)
        }
    }
    func testEscapeAndInvalidInputPreserveExactValueAndOtherControlsKeepFormatting() {
        let original: Float = 1.405856
        var commits = 0
        let input = WSSParameterTextField(
            value: original, range: 0.25...8, title: "Width",
            maximumFractionDigits: 2, locale: Locale(identifier: "en_US")
        ) { _ in commits += 1 }
        let coordinator = input.makeCoordinator()
        let field = NSTextField(string: "9")
        XCTAssertFalse(coordinator.accept(field))
        XCTAssertTrue(
            coordinator.control(
                field, textView: NSTextView(),
                doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(field.stringValue, "1.41")
        XCTAssertTrue(coordinator.accept(field))
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(
            WSSParameterNumberPresentation(locale: Locale(identifier: "de_DE")).display(original),
            String(original))
    }
    func testFullAreaRetainsRemoveAvailabilityUndoAndRegionSemantics() async throws {
        let helper = WSSRainAuthoringTests()
        try await helper.setUp()
        let doc = helper.doc
        defer { doc.close() }
        let id = try helper.add()
        let unmasked = doc.state.workingModel
        XCTAssertFalse(doc.canManageMask(.remove))
        try await doc.manageMask(.create)
        try await doc.manageMask(.fill)
        let masked = doc.state.workingModel
        let region = doc.rainLayer(id)?.region
        let generationCount = doc.state.sessionAssets.count
        XCTAssertTrue(doc.canManageMask(.remove))
        await doc.performMaskAction(.remove)
        XCTAssertEqual(doc.state.workingModel, unmasked)
        XCTAssertEqual(doc.rainLayer(id)?.region, region)
        XCTAssertEqual(doc.state.sessionAssets.count, generationCount)
        XCTAssertFalse(doc.canManageMask(.remove))
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, masked)
        XCTAssertTrue(doc.canManageMask(.remove))
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, unmasked)
        try await helper.tearDown()
    }
}
