import XCTest

@testable import Wupsy

final class RuntimeDiagnosticLocalizationTests: XCTestCase {
    func testDiagnosticFamiliesAndFallbackPreserveIdentityAndEvidence() {
        let cases: [(RuntimeDiagnostic, String, String)] = [
            (
                .videoResuming, "Video stalled; resuming playback",
                "Das Video stockt; die Wiedergabe wird fortgesetzt."
            ),
            (
                .decoderRebuilding, "Recreating video decoder after a stall",
                "Der Videodecoder wird nach einer Unterbrechung neu erstellt."
            ),
            (
                .memoryRecovered, "Memory pressure eased; resuming wallpaper",
                "Wieder ausreichend Arbeitsspeicher verfügbar; das Hintergrundbild wird fortgesetzt."
            ),
            (
                .imageDecode, "The image could not be decoded.",
                "Das Bild konnte nicht dekodiert werden."
            ),
            (
                .videoRecoveryFailed,
                "The video repeatedly failed to recover. Your wallpaper is kept; choose Resume or try another file.",
                "Die Videowiedergabe konnte wiederholt nicht wiederhergestellt werden. Dein Hintergrundbild bleibt erhalten. Wähle „Fortsetzen“ oder versuche eine andere Datei."
            ),
            (
                .webStopped, "The web wallpaper stopped unexpectedly. Apply it again to restart.",
                "Das Web-Hintergrundbild wurde unerwartet beendet. Wende es erneut an, um es neu zu starten."
            ),
            (
                .wssGPU, "The WSS static renderer reported a GPU error.",
                "Der WSS-Renderer hat einen GPU-Fehler gemeldet."
            ),
        ]
        for (diagnostic, english, german) in cases {
            let original = diagnostic
            XCTAssertEqual(diagnostic.technicalDescription, english)
            XCTAssertEqual(diagnostic.localized(language: "en"), english)
            XCTAssertEqual(diagnostic.localized(language: "de"), german)
            XCTAssertEqual(diagnostic.localized(language: "zz"), english)
            XCTAssertEqual(diagnostic, original)
        }
        XCTAssertEqual(
            RuntimeDiagnostic.gifRead.localized(language: "de"),
            "Dieses GIF konnte nicht gelesen werden.")
        XCTAssertEqual(
            RuntimeDiagnostic.gifFrames.localized(language: "en"),
            "This GIF has no frames or exceeds 20,000 frames. Convert it to MP4 for efficient playback."
        )
        XCTAssertEqual(
            RuntimeDiagnostic.gifFrames.localized(language: "de"),
            "Dieses GIF enthält keine oder mehr als 20.000 Einzelbilder. Konvertiere es für eine effiziente Wiedergabe in MP4."
        )
        for diagnostic in [
            RuntimeDiagnostic.gifRead, .gifFrames, .sceneUnsupported("shader: xyz %@"),
        ] {
            for language in ["en", "de", "zz"] {
                XCTAssertEqual(RuntimeDiagnostic.capturing(diagnostic), diagnostic)
                XCTAssertEqual(diagnostic.localizedDescription, diagnostic.technicalDescription)
                XCTAssertFalse(diagnostic.localized(language: language).isEmpty)
            }
            XCTAssertEqual(
                diagnostic.localized(language: "zz"), diagnostic.localized(language: "en"))
        }
        XCTAssertTrue(
            RuntimeDiagnostic.sceneUnsupported("shader: xyz %@").localized(language: "de")
                .hasSuffix("shader: xyz %@"))
        let evidence = "AVFoundationErrorDomain -11800 /Users/test/Film %@ ä.mp4 • decoder=hevc"
        let diagnostic = RuntimeDiagnostic.failure(evidence)
        for language in ["en", "de", "zz"] {
            XCTAssertTrue(diagnostic.localized(language: language).hasSuffix(evidence))
            XCTAssertEqual(diagnostic, .failure(evidence))
            XCTAssertEqual(diagnostic.technicalDescription, evidence)
        }
        XCTAssertTrue(diagnostic.localized(language: "de").hasPrefix("Das Hintergrundbild"))
        XCTAssertEqual(diagnostic.localized(language: "zz"), diagnostic.localized(language: "en"))
    }

    func testStatusActivityUsesExistingPresentationAndNativeTime() {
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let statuses: [LibraryPlaybackStatus] = [
            .ready, .stopped, .preparing(.balanced), .playing(displayCount: 1),
            .playing(displayCount: 2),
        ]
        let allStatuses =
            statuses + QualityProfile.allCases.map { .preparing($0) }
            + [PauseReason.manual, .sleep, .session, .battery, .lowPower, .thermal, .memory].map {
                .paused($0)
            }
        for status in allStatuses {
            let activity = PlaybackActivity(time: time, event: .status(status))
            let technical = status.technicalTitle
            for language in ["en", "de"] {
                let timestamp = time.formatted(
                    Date.FormatStyle(date: .omitted, time: .standard).locale(
                        Locale(identifier: language)))
                XCTAssertEqual(
                    activity.localized(language: language),
                    timestamp + " · " + status.localizedTitle(language: language))
                XCTAssertEqual(activity.time, time)
                XCTAssertEqual(activity.event, .status(status))
                XCTAssertEqual(status.technicalTitle, technical)
            }
        }
    }

    @MainActor func testActivityLimitOrderParametersAndNoPersistence() throws {
        let helper = ManagedLibraryTests()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let suite = "WupsyRuntimeDiagnostics-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = Library(storage: helper.store.storage, defaults: defaults)
        let beforePreferences = defaults.dictionaryRepresentation() as NSDictionary
        let beforeDisk = try helper.snapshot(helper.root)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<60 {
            library.recordPlayback(
                .diagnostic(.failure("decoder-\(index)")),
                at: start.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(library.playbackEvents.count, 50)
        let history = library.playbackEvents
        for (offset, activity) in history.enumerated() {
            let index = offset + 10
            XCTAssertEqual(activity.time, start.addingTimeInterval(Double(index)))
            XCTAssertEqual(activity.event, .diagnostic(.failure("decoder-\(index)")))
            for language in ["en", "de", "zz"] {
                XCTAssertTrue(activity.localized(language: language).hasSuffix("decoder-\(index)"))
            }
        }
        XCTAssertEqual(library.playbackEvents, history)
        XCTAssertEqual(
            Array(history.suffix(6).reversed()).map(\.time),
            (54..<60).reversed().map { start.addingTimeInterval(Double($0)) })
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, beforePreferences)
        XCTAssertEqual(try helper.snapshot(helper.root), beforeDisk)
    }

    func testAllResourcesResolveInBothLanguagesAndFallback() {
        for resource in RuntimeText.allCases {
            for language in ["en", "de", "zz"] {
                XCTAssertNotEqual(resource.localized(language: language), resource.rawValue)
                XCTAssertFalse(resource.localized(language: language).isEmpty)
            }
            XCTAssertEqual(resource.localized(language: "zz"), resource.localized(language: "en"))
        }
    }
}
