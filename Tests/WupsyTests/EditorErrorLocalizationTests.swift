import XCTest

@testable import Wupsy

final class EditorErrorLocalizationTests: XCTestCase {
    func testTypedVisibleErrorFamiliesHaveEnglishGermanAndFallbackWithoutChangingIdentity() {
        let errors: [Error] = [
            WSSImageImportError.unsupported, WSSImageImportError.corrupt,
            WSSImageImportError.dimensions, WSSImageImportError.pixels,
            WSSImageImportError.decodedBudget, WSSImageImportError.fileSize,
            WSSImageImportError.layerLimit, WSSImageImportError.stagingBudget,
            WSSImageImportError.incompatible, WSSImageImportError.stale,
            WSSImageImportError.storage, WSSImageImportError.cleanup,
            WSSSaveError.validationFailed("evidence"), WSSSaveError.externalConflict,
            WSSSaveError.targetDisappeared, WSSSaveError.writeFailed("evidence"),
            WSSSaveError.commitFailed("evidence"),
            WSSSaveAsError.busy, WSSSaveAsError.name, WSSSaveAsError.budget,
            WSSSaveAsError.conflict, WSSSaveAsError.collision, WSSSaveAsError.storage,
            WSSSaveAsError.invalid, WSSSaveAsError.cleanup, WSSSaveAsError.library,
            WSSMaskError.stale, WSSMaskError.unsupported, WSSMaskError.invalid,
            WSSMaskError.budget, WSSMaskError.transaction,
            WSSVectorFieldEditError.invalid, WSSVectorFieldEditError.budget,
            WSSDocumentError.version(7), WSSDocumentError.invalid("evidence"),
            WSSDocumentError.missingAsset("assets/🖼.png"), WSSDocumentError.unsafePath("../asset"),
            WSSDocumentError.effect("futureEffect"),
            WSSSceneError.invalid("evidence"), WSSSceneError.unsupported("evidence"),
            WSSSceneError.decodedImageBudget,
        ]
        XCTAssertEqual(errors.count, 41)
        for error in errors {
            let backend = error.localizedDescription
            let reflection = String(reflecting: error)
            let english = EditorErrorPresentation.message(error, language: "en")
            let german = EditorErrorPresentation.message(error, language: "de")
            XCTAssertFalse(english.isEmpty)
            XCTAssertFalse(german.isEmpty)
            XCTAssertNotEqual(english, "Wupsy")
            XCTAssertNotEqual(german, "Wupsy")
            XCTAssertNotEqual(english, german)
            XCTAssertEqual(EditorErrorPresentation.message(error, language: "zz"), english)
            XCTAssertEqual(error.localizedDescription, backend)
            XCTAssertEqual(String(reflecting: error), reflection)
        }
    }

    func testFlowCreationResourceFailuresKeepTypedIdentityAndLocalizedGuidance() {
        do {
            _ = try WSSNewVectorField.generation(SIMD2(64, 64), remainingBudget: 0)
            XCTFail("Expected vector budget rejection")
        } catch {
            guard case WSSVectorFieldEditError.budget = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(
                EditorErrorPresentation.message(error, language: "de"),
                "Die Vektorfeldänderung überschreitet das Editor-Ressourcenbudget von 128 MiB.")
        }
        do {
            _ = try WSSNewVectorField.dimensions(SIMD2(0, 64))
            XCTFail("Expected invalid vector geometry")
        } catch {
            guard case WSSVectorFieldEditError.invalid = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(
                EditorErrorPresentation.message(error, language: "en"),
                "The vector field data is invalid.")
        }
    }

    func testInvalidMaskUsesPlainUserWordingAndEnglishFallback() {
        let error = WSSMaskError.invalid
        XCTAssertEqual(
            EditorErrorPresentation.message(error, language: "de"),
            "Die Maske oder die Pinseldaten sind ungültig.")
        XCTAssertFalse(
            EditorErrorPresentation.message(error, language: "de").contains("skalare Maske"))
        for language in ["en", "zz"] {
            XCTAssertEqual(
                EditorErrorPresentation.message(error, language: language),
                "The mask or brush data is invalid.")
            XCTAssertFalse(
                EditorErrorPresentation.message(error, language: language).contains("scalar mask"))
        }
        XCTAssertEqual(error.localizedDescription, "The scalar mask or brush data is invalid.")
    }

    func testDynamicLimitsAndVersionInBothLanguages() {
        XCTAssertEqual(
            EditorErrorPresentation.message(WSSImageImportError.dimensions, language: "de"),
            "Bilder dürfen auf keiner Achse größer als 8.192 Pixel sein.")
        XCTAssertEqual(
            EditorErrorPresentation.message(WSSImageImportError.corrupt, language: "de"),
            "Das Bild konnte nicht dekodiert werden. Wähle ein gültiges PNG- oder JPEG-Bild.")
        XCTAssertEqual(
            EditorErrorPresentation.message(WSSImageImportError.layerLimit, language: "en"),
            "The wallpaper already has 128 layers.")
        XCTAssertEqual(
            EditorErrorPresentation.message(WSSSaveAsError.budget, language: "de"),
            "Das neue Hintergrundbild überschreitet das Projektbudget von 512 MiB.")
        XCTAssertEqual(
            EditorErrorPresentation.message(WSSDocumentError.version(7), language: "de"),
            "Die WSS-Szenenversion 7 wird nicht unterstützt. Nur Version 1 wird unterstützt.")
        for language in ["en", "de", "zz"] {
            XCTAssertEqual(
                EditorErrorPresentation.message(
                    WSSSceneError.decodedImageBudget, language: language),
                EditorErrorPresentation.message(
                    WSSImageImportError.decodedBudget, language: language))
            XCTAssertEqual(
                EditorErrorPresentation.message(WSSSaveAsError.name, language: language),
                EditorText.nameBytes.localized(language: language))
            XCTAssertEqual(
                EditorErrorPresentation.message(WSSSaveAsError.busy, language: language),
                EditorText.waitSaveAs.localized(language: language))
        }
    }

    func testOpaqueEvidenceIsPassedVerbatimWithoutParsingOrTranslation() {
        let evidence =
            "Field: effects.file\n/Users/Synthetic/Private/🖼 %.png; code=13; actual=futureEffect"
        let errors: [Error] = [
            WSSSaveError.validationFailed(evidence), WSSSaveError.writeFailed(evidence),
            WSSSaveError.commitFailed(evidence), WSSDocumentError.invalid(evidence),
            WSSDocumentError.missingAsset(evidence), WSSDocumentError.unsafePath(evidence),
            WSSDocumentError.effect(evidence), WSSSceneError.invalid(evidence),
            WSSSceneError.unsupported(evidence),
            NSError(domain: "Synthetic", code: 13, userInfo: [NSLocalizedDescriptionKey: evidence]),
        ]
        for error in errors {
            for language in ["en", "de", "zz"] {
                let value = EditorErrorPresentation.message(error, language: language)
                XCTAssertTrue(value.hasSuffix(evidence))
                XCTAssertTrue(
                    value.contains(language == "de" ? "Technische Details:" : "Technical details:"))
            }
        }
    }
}
