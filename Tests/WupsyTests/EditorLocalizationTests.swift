import AppKit
import XCTest

@testable import Wupsy

final class EditorLocalizationTests: XCTestCase {
    func testEveryEditorResourceExistsInBothBundlesAndFallsBackToEnglish() throws {
        for resource in EditorText.allCases {
            for language in ["en", "de"] {
                let path = try XCTUnwrap(
                    Localization.bundle.path(forResource: language, ofType: "lproj"))
                let bundle = try XCTUnwrap(Bundle(path: path))
                XCTAssertNotEqual(
                    bundle.localizedString(
                        forKey: resource.rawValue, value: "__missing__", table: nil), "__missing__",
                    resource.rawValue)
                XCTAssertFalse(resource.localized(language: language).isEmpty)
                XCTAssertNotEqual(resource.localized(language: language), resource.rawValue)
                XCTAssertNotEqual(resource.localized(language: language), "Wupsy")
            }
            XCTAssertEqual(resource.localized(language: "zz"), resource.localized(language: "en"))
        }
    }

    func testBasicSurfaceCommandsAndAccessibilityTerminology() {
        let pairs: [(EditorText, String, String)] = [
            (.canvas, "Edit Canvas", "Arbeitsfläche"),
            (.canvasZoom, "Canvas zoom", "Zoom der Arbeitsfläche"),
            (.canvasStatus, "Canvas status", "Status der Arbeitsfläche"),
            (.saveAs, "Save As…", "Sichern unter …"),
            (.revert, "Revert to Saved", "Zurück zur gesicherten Version"),
            (.zoomIn, "Zoom In", "Vergrößern"),
            (.zoomOut, "Zoom Out", "Verkleinern"),
            (.fit, "Fit", "Ansicht anpassen"),
            (.actualSize, "Actual Size", "Originalgröße"),
            (.livePreview, "Live Preview", "Live-Vorschau"),
            (.pausePreview, "Pause live preview", "Live-Vorschau pausieren"),
            (.playPreview, "Play live preview", "Live-Vorschau wiedergeben"),
            (.layersEffects, "Layers / Effects", "Ebenen / Effekte"),
            (.hideLayer, "Hide Layer", "Ebene ausblenden"),
            (.showLayer, "Show Layer", "Ebene einblenden"),
            (.deleteLayer, "Delete Layer", "Ebene löschen"),
            (.layerVisibility, "Layer Visibility", "Ebenensichtbarkeit"),
            (.moveLayer, "Move Layer", "Ebene verschieben"),
            (.moveImage, "Move Image", "Bild verschieben"),
            (.scaleImage, "Scale Image", "Bild skalieren"),
            (.rotateImage, "Rotate Image", "Bild drehen"),
            (.transformHint, "Double-click to transform", "Zum Transformieren doppelklicken"),
            (.imageOpacity, "Image opacity", "Deckkraft des Bilds"),
            (.dontSave, "Don't Save", "Nicht sichern"),
        ]
        for (resource, en, de) in pairs {
            XCTAssertEqual(resource.localized(language: "en"), en)
            XCTAssertEqual(resource.localized(language: "de"), de)
        }
    }

    func testImagePropertyPresentationNeverChangesTechnicalIDsOrRanges() {
        XCTAssertEqual(
            WSSImageProperty.allCases.map(\.rawValue),
            ["opacity", "centerX", "centerY", "width", "height", "scaleX", "scaleY", "rotation"])
        let german = [
            "Deckkraft", "Mittelpunkt X", "Mittelpunkt Y", "Breite", "Höhe", "Skalierung X",
            "Skalierung Y", "Drehung (Grad)",
        ]
        let english = [
            "Opacity", "Center X", "Center Y", "Width", "Height", "Scale X", "Scale Y",
            "Rotation (degrees)",
        ]
        for (index, property) in WSSImageProperty.allCases.enumerated() {
            let range = property.range
            XCTAssertEqual(property.localizedTitle(language: "de"), german[index])
            XCTAssertEqual(property.localizedTitle(language: "en"), english[index])
            XCTAssertEqual(property.localizedTitle(language: "zz"), english[index])
            XCTAssertEqual(property.title, property.localizedTitle())
            XCTAssertEqual(property.range, range)
        }
        XCTAssertEqual(WSSImageProperty.opacity.range, 0...1)
        XCTAssertEqual(WSSImageProperty.rotation.range, -57_295_776...57_295_776)
    }

    func testInterpolationPreservesUserTextAndTechnicalEvidence() {
        let name = "Image · Untitled Wallpaper Copy % @ 🐈 e\u{301}"
        for language in ["en", "de", "zz"] {
            let editor = EditorText.windowTitle.format(name, language: language)
            XCTAssertTrue(editor.hasPrefix(name + " — "))
            XCTAssertTrue(
                EditorText.previewTitle.format(name, language: language).hasPrefix(name + " — "))
            XCTAssertEqual(
                EditorText.layerOrdinal.format(2, name, language: language), "2 · " + name)
            XCTAssertTrue(EditorText.imageFilename.format(name, language: language).hasSuffix(name))
            let diagnostic = "decoded image budget: /tmp/🖼.png %"
            XCTAssertTrue(
                EditorText.canvasNotCurrent.format(diagnostic, language: language).hasSuffix(
                    diagnostic))
            XCTAssertTrue(
                EditorText.previewNotCurrentDetail.format(diagnostic, language: language).hasSuffix(
                    diagnostic))
            XCTAssertTrue(
                EditorText.saveConflictDetail.format(diagnostic, language: language).hasPrefix(
                    diagnostic + "\n"))
        }
        XCTAssertEqual(WSSStructureDragPayload.Kind.layer.rawValue, "layer")
        XCTAssertEqual(WSSStructureDragPayload.Kind.effect.rawValue, "effect")
    }

    @MainActor func testNativeNamingSheetBothLanguagesPreservesProposedDataAndKeys() throws {
        _ = NSApplication.shared
        for language in ["en", "de", "zz"] {
            for titleResource: EditorText in [.saveWallpaper, .saveWallpaperAs] {
                let proposed = "Image Untitled Wallpaper Copy % 🐈"
                let title = titleResource.localized(language: language)
                let alert = WSSWallpaperNameRequest.alert(
                    title: title, proposedName: proposed, language: language)
                let field = try XCTUnwrap(alert.accessoryView as? NSTextField)
                XCTAssertEqual(alert.messageText, title)
                XCTAssertEqual(field.stringValue, proposed)
                XCTAssertEqual(
                    field.accessibilityLabel(),
                    ProductText.wallpaperName.localized(language: language))
                XCTAssertEqual(
                    alert.buttons.map(\.title),
                    [
                        ProductText.save.localized(language: language),
                        ProductText.cancel.localized(language: language),
                    ])
                XCTAssertEqual(alert.buttons.map(\.keyEquivalent), ["\r", "\u{1b}"])
                XCTAssertTrue(alert.window.initialFirstResponder === field)
                XCTAssertEqual(try WSSSaveAsSnapshot.title(proposed), proposed)
            }
        }
    }
    @MainActor func testPresentationLookupsPreserveManifestIdentityNamesAndUndoPayload()
        async throws
    {
        let helper = WSSEditorEditingTests()
        let (fixture, project) = try await helper.fixture()
        defer { try? fixture.tearDownWithError() }
        let doc = helper.editor(project)
        defer { doc.close() }
        let original = doc.state.workingModel
        let bytes = try original.encoded()
        let identity = doc.identity
        let selection = doc.selection
        let disk = try fixture.snapshot()
        for language in ["en", "de", "zz"] {
            for property in WSSImageProperty.allCases {
                _ = property.localizedTitle(language: language)
            }
            _ = EditorText.windowTitle.format(original.title, language: language)
            _ = doc.layerNames
            _ = doc.inspectorSections
            XCTAssertEqual(try doc.state.workingModel.encoded(), bytes)
            XCTAssertEqual(doc.identity, identity)
            XCTAssertEqual(doc.selection, selection)
            XCTAssertFalse(doc.undoManager.canUndo)
            XCTAssertFalse(doc.isDirty)
        }
        let layer = identity.layers[0].id
        try doc.setImage(.centerX, value: 123, layer: layer)
        XCTAssertEqual(doc.undoManager.undoActionName, WSSImageProperty.centerX.title)
        XCTAssertEqual(doc.identity, identity)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertEqual(doc.identity, identity)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        XCTAssertEqual(doc.undoManager.undoActionName, WSSImageProperty.centerX.title)
        XCTAssertEqual(doc.identity, identity)
        XCTAssertEqual(try fixture.snapshot(), disk)
        XCTAssertEqual(
            WSSImageLayerName.fromSource(URL(fileURLWithPath: "/synthetic/   .png")), "Image")
    }

    func testCloseHintOnlyExplainsLossOfUnsavedChanges() {
        let german = EditorText.closeHint.localized(language: "de")
        XCTAssertEqual(german, "Nicht gesicherte Änderungen gehen verloren.")
        XCTAssertFalse(german.contains("Desktop"))
        for language in ["en", "zz"] {
            let value = EditorText.closeHint.localized(language: language)
            XCTAssertEqual(value, "Your changes will be lost if you don’t save them.")
            XCTAssertFalse(value.contains("desktop"))
        }
    }

    func testSaveAsOrdinaryGuidanceKeepsBackendDiagnosticsStable() {
        for language in ["en", "de", "zz"] {
            XCTAssertEqual(
                EditorText.saveAsDetail(.busy, language: language),
                EditorText.waitSaveAs.localized(language: language))
            XCTAssertEqual(
                EditorText.saveAsDetail(.name, language: language),
                EditorText.nameBytes.localized(language: language))
            for error: WSSSaveAsError in [
                .budget, .conflict, .collision, .storage, .invalid, .cleanup, .library,
            ] {
                XCTAssertEqual(
                    EditorText.saveAsDetail(error, language: language),
                    EditorErrorPresentation.message(error, language: language))
            }
        }
        XCTAssertEqual(
            WSSSaveAsError.name.localizedDescription,
            "Use a wallpaper name with at most 1024 UTF-8 bytes.")
        XCTAssertEqual(
            WSSSaveAsError.busy.localizedDescription,
            "Wait for Save As to finish before opening this copy.")
    }

}
