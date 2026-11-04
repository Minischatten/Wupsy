import AppKit
import XCTest

@testable import Wupsy

final class EditorEffectLocalizationTests: XCTestCase {
    func testEffectNamesAndAddableRawValuesInBothLanguages() {
        let resources: [(EditorText, String, String)] = [
            (.effectFlow, "Flow", "Strömung"), (.effectRipple, "Ripple", "Wellen"),
            (.effectClouds, "Clouds", "Wolken"),
            (.effectRain, "Rain", "Regen"), (.effectTrail, "Cursor Trail", "Maustrail"),
        ]
        for (resource, en, de) in resources {
            XCTAssertEqual(resource.localized(language: "en"), en)
            XCTAssertEqual(resource.localized(language: "de"), de)
            XCTAssertEqual(resource.localized(language: "zz"), en)
        }
        XCTAssertEqual(WSSAddableEffect.allCases.map(\.rawValue), ["Ripple", "Clouds", "Flow"])
        for (kind, de) in zip(WSSAddableEffect.allCases, ["Wellen", "Wolken", "Strömung"]) {
            XCTAssertEqual(kind.localizedTitle(language: "en"), kind.rawValue)
            XCTAssertEqual(kind.localizedTitle(language: "de"), de)
        }
    }

    func testEditableParameterLabelsAndRawIDs() {
        let values: [(WSSEditorParameter, String, String)] = [
            (.flowSpeed, "Speed", "Geschwindigkeit"), (.flowStrength, "Strength", "Stärke"),
            (.flowEdgeProtection, "Edge protection (px)", "Randberuhigung (px)"),
            (.rippleAmplitude, "Amplitude", "Wellenstärke"),
            (.rippleWavelength, "Wavelength", "Wellenlänge"),
            (.rippleTravelSpeed, "Travel speed", "Ausbreitungsgeschwindigkeit"),
            (.rippleStretch, "Stretch", "Streckung"),
            (.rippleDirection, "Movement direction (°)", "Bewegungsrichtung (°)"),
            (.rippleStructureRotation, "Structure rotation (°)", "Strukturrotation (°)"),
            (.rippleEvolution, "Evolution", "Evolution"),
            (.rippleLateralDetail, "Lateral detail", "Seitliches Detail"),
            (.cloudsVelocityX, "Horizontal speed (px/s)", "Horizontalgeschwindigkeit (px/s)"),
            (.cloudsVelocityY, "Vertical speed (px/s)", "Vertikalgeschwindigkeit (px/s)"),
            (.cloudsBrightness, "Brightness", "Helligkeit"),
            (
                .cloudsSecondaryVelocityX, "Secondary horizontal speed (px/s)",
                "Zweites Feld: Horizontalgeschwindigkeit (px/s)"
            ),
            (
                .cloudsSecondaryVelocityY, "Secondary vertical speed (px/s)",
                "Zweites Feld: Vertikalgeschwindigkeit (px/s)"
            ),
            (.cloudsIntensity, "Intensity", "Intensität"), (.cloudsDensity, "Density", "Dichte"),
            (.cloudsScale, "Primary scale", "Primärskalierung"),
        ]
        XCTAssertEqual(
            WSSEditorParameter.allCases.map(\.rawValue),
            [
                "rippleAmplitude", "rippleWavelength", "rippleTravelSpeed", "rippleStretch",
                "rippleDirection", "rippleStructureRotation",
                "rippleEvolution", "rippleLateralDetail", "cloudsIntensity",
                "cloudsDensity", "cloudsScale", "cloudsVelocityX", "cloudsVelocityY",
                "cloudsBrightness", "cloudsSecondaryVelocityX", "cloudsSecondaryVelocityY",
                "flowSpeed", "flowStrength", "flowEdgeProtection",
            ])
        for (parameter, en, de) in values {
            XCTAssertEqual(parameter.localizedTitle(language: "en"), en)
            XCTAssertEqual(parameter.localizedTitle(language: "de"), de)
            XCTAssertEqual(parameter.localizedTitle(language: "zz"), en)
            XCTAssertEqual(parameter.title, parameter.localizedTitle())
        }
    }

    func testAdvancedRippleGroupAndHelpInBothLanguages() {
        XCTAssertEqual(EditorText.rippleAdvanced.localized(language: "en"), "Advanced settings")
        XCTAssertEqual(
            EditorText.rippleAdvanced.localized(language: "de"), "Erweiterte Einstellungen")
        XCTAssertEqual(EditorText.rippleSeed.localized(language: "de"), "Seed")
        XCTAssertTrue(
            EditorText.rippleLateralHelp.localized(language: "de").contains(
                "nicht grundsätzlich weniger Bewegung"))
        XCTAssertTrue(
            EditorText.rippleLateralHelp.localized(language: "en").contains(
                "not necessarily less movement"))
    }

    func testMaskActionsKeepEnglishIdentityWithLocalizedUndoPresentation() {
        XCTAssertEqual(
            WSSMaskAction.allCases.map(\.rawValue),
            ["Create Mask", "Import Mask…", "Remove Mask", "Clear Mask", "Fill Mask"])
        let german = [
            "Maske erstellen", "Maske importieren …", "Maske entfernen", "Maske leeren",
            "Maske füllen",
        ]
        for (index, action) in WSSMaskAction.allCases.enumerated() {
            XCTAssertEqual(action.localizedTitle(language: "en"), action.rawValue)
            XCTAssertEqual(action.localizedTitle(language: "de"), german[index])
            XCTAssertEqual(action.localizedTitle(language: "zz"), action.rawValue)
        }
        XCTAssertEqual(EditorText.paintMask.localized(language: "de"), "Maske malen")
        XCTAssertEqual(EditorText.moveEffect.localized(language: "de"), "Effekt verschieben")
        XCTAssertEqual(EditorText.deleteEffect.localized(language: "de"), "Effekt löschen")
        XCTAssertEqual(EditorText.replaceVector.localized(language: "de"), "Vektorfeld ersetzen")
        XCTAssertEqual(
            EditorText.addEffectUndo.format("Wellen", language: "de"), "Wellen hinzufügen")
    }

    func testCompleteHeadingsAndInterpolationPreserveUnicodePayload() {
        XCTAssertEqual(
            EditorText.effectHeading(index: 2, name: "Strömung", language: "de"),
            "Effekt 3 · Strömung")
        XCTAssertEqual(
            EditorText.effectHeading(index: 2, name: "Wellen", language: "de"),
            "Effekt 3 · Wellen")
        let payload = "海 % @ 🐈 e\u{301} /assets/custom.wssvf"
        for language in ["en", "de", "zz"] {
            XCTAssertTrue(
                EditorText.effectHeading(index: 0, name: payload, language: language).hasSuffix(
                    payload))
            XCTAssertTrue(
                EditorText.effectAddError.format(payload, language: language).hasSuffix(payload))
            XCTAssertTrue(
                EditorText.maskCreateError.format(payload, language: language).hasSuffix(payload))
        }
    }

    func testCanvasHintsMatchActualModesWithoutFlowNeutralizeCommand() {
        for language in ["en", "de", "zz"] {
            let region = EditorText.directionCanvasHelp(
                hasRegion: true, operation: .direction, language: language)
            XCTAssertEqual(region, EditorText.flowRegionCanvas.localized(language: language))
            XCTAssertFalse(region.localizedCaseInsensitiveContains("neutral"))
            let legacy = EditorText.directionCanvasHelp(
                hasRegion: false, operation: .direction, language: language)
            XCTAssertEqual(legacy, EditorText.directionCanvas.localized(language: language))
            XCTAssertFalse(legacy.localizedCaseInsensitiveContains("neutral"))
            XCTAssertNotEqual(region, legacy)
            XCTAssertEqual(
                EditorText.directionCanvasHelp(
                    hasRegion: false, operation: .neutralize, language: language),
                EditorText.neutralizeCanvas.localized(language: language))
            XCTAssertNotEqual(EditorText.maskCanvas.localized(language: language), region)
            XCTAssertEqual(
                EditorText.directionCanvasHelp(
                    hasRegion: true, operation: .erase, language: language),
                EditorText.eraseRegionCanvas.localized(language: language))
        }
        XCTAssertEqual(EditorText.optionErase.localized(language: "de"), "⌥ Löschen")
        XCTAssertEqual(EditorText.neutralize.localized(language: "de"), "Neutralisieren")
        XCTAssertEqual(EditorText.directionDone.localized(language: "de"), "Fertig")
        XCTAssertEqual(EditorText.brush.localized(language: "de"), "Pinsel")
        XCTAssertEqual(
            EditorText.directionDiameter.localized(language: "de"),
            "Pinselgröße in lokalen Bildeinheiten")
        XCTAssertEqual(
            EditorText.maskOpacityPercent.localized(language: "de"), "Pinseldeckkraft in Prozent")
    }

}
