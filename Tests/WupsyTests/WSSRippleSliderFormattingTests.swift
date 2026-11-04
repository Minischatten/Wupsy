import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSRippleSliderFormattingTests: XCTestCase {
    func testRippleDisplayPolicyAndLocalizedFractions() {
        let ripple: [WSSEditorParameter] = [
            .rippleAmplitude, .rippleWavelength, .rippleTravelSpeed, .rippleStretch,
            .rippleDirection, .rippleStructureRotation, .rippleEvolution, .rippleLateralDetail,
        ]
        for parameter in WSSEditorParameter.allCases {
            XCTAssertEqual(
                parameter.displayFractionDigits,
                (ripple.contains(parameter) || parameter.rawValue.hasPrefix("clouds")) ? 2 : nil)
        }
        for (value, german, english): (Float, String, String) in [
            (3, "3", "3"), (1.5, "1,5", "1.5"), (2.34, "2,34", "2.34"),
            (2.3499999046325684, "2,35", "2.35"), (1.375, "1,38", "1.38"),
            (1234.5678, "1234,57", "1234.57"),
        ] {
            for (locale, expected) in [("de_DE", german), ("en_US", english)] {
                XCTAssertEqual(
                    WSSParameterNumberPresentation(
                        maximumFractionDigits: WSSEditorParameter.rippleStretch
                            .displayFractionDigits,
                        locale: Locale(identifier: locale)
                    ).display(value), expected)
            }
        }
    }

    func testRoundedDisplayAndFocusDoNotChangeStoredPrecision() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        let document = WSSEditorEditingTests().editor(project)
        defer { document.close() }
        let address = WSSEffectAddress(layerIndex: 0, effectIndex: 0)
        let original: Float = 2.3498766
        XCTAssertNotEqual(original.bitPattern, Float(2.35).bitPattern)
        try document.setParameter(.rippleStretch, at: address, value: original)
        let before = document.state.workingModel
        let revision = document.state.workingRevision
        var commits = 0
        let input = WSSParameterTextField(
            value: original, range: WSSEditorParameter.rippleStretch.validRange, title: "Stretch",
            maximumFractionDigits: WSSEditorParameter.rippleStretch.displayFractionDigits,
            locale: Locale(identifier: "de_DE")
        ) {
            commits += 1
            try document.setParameter(.rippleStretch, at: address, value: $0)
        }
        let coordinator = input.makeCoordinator()
        let field = NSTextField(string: input.presentation.display(original))
        XCTAssertEqual(field.stringValue, "2,35")
        XCTAssertTrue(coordinator.accept(field))
        coordinator.controlTextDidBeginEditing(
            Notification(
                name: NSControl.textDidBeginEditingNotification, object: field))
        XCTAssertEqual(field.stringValue, "2,35")
        XCTAssertTrue(coordinator.accept(field))
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(document.state.workingModel, before)
        XCTAssertEqual(document.state.workingRevision, revision)

        field.stringValue = "2,3456789"
        let exact = try XCTUnwrap(Float("2.3456789"))
        XCTAssertTrue(coordinator.accept(field))
        XCTAssertEqual(field.stringValue, "2,35")
        XCTAssertTrue(coordinator.accept(field))
        XCTAssertEqual(commits, 1)
        let edited = document.state.workingModel
        XCTAssertEqual(
            WSSEditorParameter.rippleStretch.value(in: edited, at: address)?.bitPattern,
            exact.bitPattern)
        let decoded = try WSSSceneDocumentV1.decode(data: edited.encoded())
        XCTAssertEqual(
            WSSEditorParameter.rippleStretch.value(in: decoded, at: address)?.bitPattern,
            exact.bitPattern)
        document.undoManager.undo()
        XCTAssertEqual(document.state.workingModel, before)
        document.undoManager.redo()
        XCTAssertEqual(document.state.workingModel, edited)
    }

    func testSeedRemainsAnExactInteger() {
        let seed = UInt32.max
        var stored: Double?
        let input = WSSParameterTextField(
            value: Float(seed), range: 0...Float(UInt32.max), title: "Seed",
            maximumFractionDigits: 0, locale: Locale(identifier: "de_DE"),
            exactValue: Double(seed), exactRange: 0...Double(seed),
            commitExact: { stored = $0 }, commit: { _ in XCTFail("Float seed path") })
        let coordinator = input.makeCoordinator()
        let field = NSTextField(string: "")
        coordinator.show(Float(seed), in: field)
        XCTAssertEqual(field.stringValue, "4294967295")
        XCTAssertTrue(coordinator.accept(field))
        XCTAssertNil(stored)
    }
}
