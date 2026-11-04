import XCTest

@testable import Wupsy

final class PlaybackQualityPresentationTests: XCTestCase {
    private let resources: [ProductText] = [
        .pictureQualityHeader, .qualityProfile, .qualityHelp, .qualityChoice,
        .sceneResolution, .sceneMotion, .sceneRenderScope, .sceneProfileLimit,
        .resolutionHelp, .motionHelp, .allDisplays, .allDisplaysHelp,
        .qualityOriginalHelp, .qualityBalancedHelp, .qualityPreparationHelp,
        .qualityEcoDetail, .qualityBalancedDetail, .qualityOriginalDetail, .reducedQualityHint,
    ]

    func testQualityAndRenderTerminologyWithEnglishFallback() {
        let expected: [(ProductText, String, String)] = [
            (.pictureQualityHeader, "PLAYBACK QUALITY", "WIEDERGABEQUALITÄT"),
            (.qualityProfile, "Quality Profile", "Qualitätsprofil"),
            (.sceneResolution, "Resolution", "Auflösung"),
            (.sceneMotion, "FPS", "FPS"),
            (.sceneRenderScope, "Scene Wallpapers", "Szenen-Hintergrundbilder"),
            (.fps24, "24", "24"), (.fps30, "30", "30"), (.fps60, "60", "60"),
            (.allDisplays, "All Displays", "Alle Bildschirme"),
        ]
        for (resource, english, german) in expected {
            XCTAssertEqual(resource.localized(language: "en"), english)
            XCTAssertEqual(resource.localized(language: "de"), german)
            XCTAssertEqual(resource.localized(language: "zz"), english)
        }
        for resource in resources {
            for language in ["en", "de", "zz"] {
                let text = resource.localized(language: language)
                XCTAssertFalse(text.isEmpty)
                XCTAssertNotEqual(text, resource.rawValue)
                XCTAssertNotEqual(text, "Wupsy")
                XCTAssertFalse(text.contains("Szenenauflösung"))
                XCTAssertFalse(text.contains("Szenenbildrate"))
                XCTAssertFalse(text.contains("Scene motion"))
                XCTAssertFalse(text.contains("backingScaleFactor"))
            }
            XCTAssertEqual(resource.localized(language: "zz"), resource.localized(language: "en"))
        }
        // The pre-existing overview label and unrelated display wording are not globally renamed.
        XCTAssertEqual(ProductText.pictureQuality.localized(language: "de"), "Bildqualität")
        XCTAssertEqual(ProductText.pausedSleep.localized(language: "de"), "Display im Ruhezustand")
        XCTAssertTrue(
            ProductText.allDisplaysHelp.localized(language: "de").contains("Hauptbildschirm"))
    }

    func testRenderHelpExplainsScopeAndProfileLimitsWithoutPromisingEffectiveFPS() {
        XCTAssertEqual(
            ProductText.sceneProfileLimit.localized(language: "de"),
            "Das Qualitätsprofil begrenzt Auflösung und FPS.")
        XCTAssertEqual(
            ProductText.sceneProfileLimit.localized(language: "en"),
            "The quality profile limits resolution and FPS.")
        for language in ["en", "de"] {
            let resolution = ProductText.resolutionHelp.localized(language: language)
            let motion = ProductText.motionHelp.localized(language: language)
            XCTAssertTrue(resolution.contains("Standard"))
            XCTAssertTrue(resolution.contains("HiDPI"))
            XCTAssertTrue(resolution.contains(language == "de" ? "Desktop" : "desktop"))
            XCTAssertTrue(motion.contains(language == "de" ? "angeforderte" : "requested"))
            XCTAssertTrue(
                motion.contains(language == "de" ? "Videobildraten" : "Video frame rates"))
            XCTAssertTrue(motion.contains(language == "de" ? "Qualitätsprofil" : "quality profile"))
        }
    }

    func testProfileHelpSeparatesVideoPreparationFromSceneRendering() {
        for language in ["en", "de"] {
            let original = ProductText.qualityOriginalHelp.localized(language: language)
            let limits = ProductText.qualityBalancedHelp.localized(language: language)
            let preparation = ProductText.qualityPreparationHelp.localized(language: language)
            for token in ["1280", "2560", "24 FPS", "30 FPS", "HEVC"] {
                XCTAssertTrue(limits.contains(token))
            }
            XCTAssertTrue(limits.contains(language == "de" ? "nur dann" : "only when"))
            XCTAssertTrue(limits.contains(language == "de" ? "Originaldatei" : "source file"))
            XCTAssertTrue(
                original.contains(language == "de" ? "ohne Neukodierung" : "without re-encoding"))
            XCTAssertTrue(
                original.contains(language == "de" ? "Bilder und GIFs" : "Images and GIFs"))
            XCTAssertTrue(
                original.contains(
                    language == "de"
                        ? "bei jedem Profil unverändert" : "unchanged with every profile"))
            XCTAssertTrue(preparation.contains("CPU-/GPU") || preparation.contains("CPU/GPU"))
            XCTAssertTrue(
                preparation.contains("FPS"))
            XCTAssertTrue(preparation.contains(language == "de" ? "begrenzt" : "limited"))
            XCTAssertTrue(preparation.contains("Web"))
        }
    }

    @MainActor func testGlobalProfileKeepsRenderChoicesAndBackupKeys() throws {
        let domain = "quality-polish.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        let library = Library(
            maintenance: MaintenanceCoordinator(), storage: storage, defaults: defaults,
            restoreOnLaunch: false)
        defer { library.stop() }
        library.sceneRenderResolution = .hiDPI
        library.sceneFPS = 60
        for profile in QualityProfile.allCases {
            library.profile = profile
            XCTAssertEqual(library.sceneRenderResolution, .hiDPI)
            XCTAssertEqual(library.sceneFPS, 60)
            XCTAssertEqual(defaults.string(forKey: "profile"), profile.rawValue)
            XCTAssertEqual(defaults.string(forKey: "sceneRenderResolution"), "hiDPI")
            XCTAssertEqual(defaults.integer(forKey: "sceneFPS"), 60)
            let preferences = try LibraryBackupPreferences(defaults: defaults)
            let data = try JSONEncoder().encode(preferences.settings)
            let values = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(
                Set(values.keys),
                [
                    "profile", "sceneRenderResolution", "sceneFPS", "conserve", "pauseOnBattery",
                    "allDisplays",
                ])
            XCTAssertEqual(values["profile"] as? String, profile.rawValue)
            XCTAssertEqual(values["sceneRenderResolution"] as? String, "hiDPI")
            XCTAssertEqual(values["sceneFPS"] as? Int, 60)
        }
        library.sceneRenderResolution = .standard
        library.profile = .original
        XCTAssertEqual(library.sceneRenderResolution, .standard)
        XCTAssertEqual(SceneRenderResolution.preferenceKey, "sceneRenderResolution")
        XCTAssertEqual(SceneRenderResolution.allCases.map(\.rawValue), ["standard", "hiDPI"])
        XCTAssertEqual(QualityProfile.allCases.map(\.rawValue), ["eco", "balanced", "original"])
    }
}
