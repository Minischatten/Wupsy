import AppKit
import XCTest

@testable import Wupsy

@MainActor final class RestoreLocalizationTests: XCTestCase {
    func testResourcesAndRecoveryPluralInEnglishGermanAndFallback() {
        for resource in RestoreText.allCases {
            for language in ["en", "de", "zz"] {
                XCTAssertFalse(resource.localized(language: language).isEmpty)
                XCTAssertNotEqual(resource.localized(language: language), resource.rawValue)
            }
            XCTAssertEqual(resource.localized(language: "zz"), resource.localized(language: "en"))
        }
        for count: Int64 in [0, 1, 2, 10] {
            for language in ["en", "de", "zz"] {
                let noun =
                    language == "de"
                    ? (count == 1 ? "Recovery-Projekt" : "Recovery-Projekte")
                    : (count == 1 ? "recovery project" : "recovery projects")
                XCTAssertEqual(
                    RestoreText.recoveryCount.format(count, language: language), "\(count) \(noun)")
            }
        }
    }

    func testPresentationPhasesKeepIndependentTypedIdentity() {
        let cases: [(LibraryRestorePresentationPhase, String, String)] = [
            (.validating, "Validating Backup…", "Backup wird validiert …"),
            (.preparing, "Preparing Restore…", "Wiederherstellung wird vorbereitet …"),
            (.waiting, "Waiting for Changes…", "Änderungen werden abgeschlossen …"),
            (.restoring, "Restoring Library…", "Mediathek wird wiederhergestellt …"),
            (.finishing, "Finishing Restore…", "Wiederherstellung wird abgeschlossen …"),
        ]
        XCTAssertEqual(cases.count, LibraryRestorePresentationPhase.allCases.count)
        for (phase, english, german) in cases {
            let original = phase
            XCTAssertEqual(phase.localized(language: "en"), english)
            XCTAssertEqual(phase.localized(language: "de"), german)
            XCTAssertEqual(phase.localized(language: "zz"), english)
            XCTAssertEqual(phase, original)
        }
        // These are persisted technical contracts, never presentation phases.
        let phases: [LibraryRestoreJournal.Phase] = [
            .prepared, .publishing, .newStatePublished, .rollingBack, .metadataCommitted,
            .cleanupPending, .cleanupComplete, .rolledBack, .rollbackCleanupComplete,
        ]
        XCTAssertEqual(
            phases.map(\.rawValue),
            [
                "prepared", "publishing", "newStatePublished", "rollingBack", "metadataCommitted",
                "cleanupPending", "cleanupComplete", "rolledBack", "rollbackCleanupComplete",
            ])
        let actions: [RestoreMove.Action] = [
            .installParent, .removeParent, .moveOld, .publishNew, .returnNew, .restoreOld,
        ]
        XCTAssertEqual(
            actions.map(\.rawValue),
            ["installParent", "removeParent", "moveOld", "publishNew", "returnNew", "restoreOld"])
    }

    func testPanelMaintenancePreflightAndReversibleFailurePresentation() {
        _ = NSApplication.shared
        for language in ["en", "de", "zz"] {
            let panel = LibraryRestoreUI.openPanel(language: language)
            XCTAssertEqual(panel.title, RestoreText.openTitle.localized(language: language))
            XCTAssertFalse(panel.allowsMultipleSelection)
            XCTAssertFalse(panel.canChooseDirectories)
            XCTAssertTrue(panel.canChooseFiles)
            XCTAssertFalse(panel.allowsOtherFileTypes)
            XCTAssertTrue(panel.treatsFilePackagesAsDirectories)
            XCTAssertEqual(panel.allowedContentTypes.first?.preferredFilenameExtension, "wssbackup")
            let evidence = "NSCocoaErrorDomain code=513 /Users/Synthetic/ä %@.wssbackup"
            let error = NSError(
                domain: "Synthetic", code: 513, userInfo: [NSLocalizedDescriptionKey: evidence])
            let alert = LibraryRestoreUI.unavailableAlert(error, language: language)
            XCTAssertEqual(alert.messageText, RestoreText.unavailable.localized(language: language))
            XCTAssertTrue(alert.informativeText.hasSuffix(evidence))
            XCTAssertEqual(error.domain, "Synthetic")
            XCTAssertEqual(error.code, 513)
            for cleanup in [false, true] {
                let failure = LibraryRestoreUI.preparationFailureAlert(
                    cleanupFailed: cleanup, language: language)
                XCTAssertEqual(
                    failure.messageText, RestoreText.preparationFailed.localized(language: language)
                )
                XCTAssertEqual(
                    failure.informativeText,
                    (cleanup ? RestoreText.cleanupDetail : .preparationDetail).localized(
                        language: language))
                XCTAssertEqual(failure.alertStyle, .warning)
            }
        }
        for error: MaintenanceError in [
            .frozen, .jobActive, .restartRequired, .invalidTransition, .drainFailed,
        ] {
            let original = error
            let technical = error.localizedDescription
            let english = MaintenanceErrorPresentation.message(error, language: "en")
            XCTAssertNotEqual(english, MaintenanceErrorPresentation.message(error, language: "de"))
            XCTAssertEqual(english, MaintenanceErrorPresentation.message(error, language: "zz"))
            XCTAssertEqual(
                RestoreErrorPresentation.detail(error, language: "de"),
                MaintenanceErrorPresentation.message(error, language: "de"))
            XCTAssertEqual(error, original)
            XCTAssertEqual(error.localizedDescription, technical)
        }
    }

    func testTerminalDialogsKeepOutcomesAndQuitOnlyAction() {
        _ = NSApplication.shared
        for outcome: LibraryRestoreCoordinator.Outcome in [.committed, .restoredA, .unresolved] {
            let original = outcome
            for language in ["en", "de", "zz"] {
                let presentation = RestoreTerminalPresentation(outcome, language: language)
                let alert = LibraryRestoreUI.completionAlert(outcome, language: language)
                XCTAssertEqual(presentation.outcome, outcome)
                XCTAssertEqual(alert.messageText, presentation.title)
                XCTAssertEqual(alert.informativeText, presentation.detail)
                if outcome == .committed {
                    let expected =
                        language == "de"
                        ? "Die Hintergrundbild-Mediathek wurde erfolgreich wiederhergestellt.\n\nWupsy muss jetzt beendet werden. Öffne es anschließend erneut, um die wiederhergestellte Mediathek zu verwenden."
                        : "The wallpaper library was restored successfully.\n\nWupsy must now quit. Open it again afterward to use the restored library."
                    XCTAssertEqual(alert.informativeText, expected)
                    XCTAssertEqual(
                        alert.buttons[0].title, language == "de" ? "Wupsy beenden" : "Quit Wupsy")
                }
                XCTAssertEqual(alert.buttons.count, 1)
                XCTAssertEqual(
                    alert.buttons[0].title, ProductText.quit.localized(language: language))
                XCTAssertEqual(outcome, original)
                if outcome == .restoredA { XCTAssertEqual(alert.alertStyle, .warning) }
                if outcome == .unresolved { XCTAssertEqual(alert.alertStyle, .critical) }
                if language == "zz" {
                    XCTAssertEqual(
                        presentation.title,
                        RestoreTerminalPresentation(outcome, language: "en").title)
                }
            }
        }
    }

    func testValidatedConfirmationSummaryAndLookupsDoNotMutatePlanOrBackup() async throws {
        let helper = LibraryRestoreTransactionTests()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let prepared = try await helper.b()
        defer { try? prepared.discard() }
        let plan = prepared.plan
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(plan.manifest)
        for language in ["en", "de", "zz"] {
            let alert = LibraryRestoreUI.confirmationAlert(plan, language: language)
            let summary = LibraryRestoreSummary.text(plan, language: language)
            XCTAssertEqual(alert.informativeText, summary)
            let actionNotice =
                language == "de"
                ? "Die aktuelle Wupsy-Hintergrundbild-Mediathek wird durch das ausgewählte Backup ersetzt.\n\nWährend der Wiederherstellung wird die aktuelle Hintergrundbild-Wiedergabe beendet."
                : "This will replace the current Wupsy wallpaper library with the selected backup.\n\nThe current wallpaper playback will stop during the restore."
            XCTAssertTrue(summary.hasSuffix("\n\n" + actionNotice))
            XCTAssertEqual(
                RestoreText.confirmation.format("SUMMARY", language: language),
                "SUMMARY\n\n" + actionNotice)
            XCTAssertFalse(summary.contains("erneut öffnen"))
            XCTAssertFalse(summary.contains("reopened"))
            XCTAssertFalse(summary.contains("quit"))
            XCTAssertTrue(
                summary.contains(
                    LibraryRestoreSummary.date(plan.manifest.createdAt, language: language)))
            XCTAssertTrue(
                summary.contains(
                    LibraryBackupCompletionSummary.string(
                        wallpapers: plan.library.count, playlists: plan.playlists.definitions.count,
                        bytes: plan.manifest.totalLogicalSize, language: language)))
            XCTAssertEqual(
                alert.buttons[0].title, RestoreText.replace.localized(language: language))
            XCTAssertTrue(alert.buttons[0].hasDestructiveAction)
            XCTAssertEqual(alert.buttons[0].keyEquivalent, "")
            XCTAssertEqual(alert.buttons[1].title, ProductText.cancel.localized(language: language))
            XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}")
            XCTAssertFalse(summary.contains(RestoreText.incomplete.localized(language: language)))
            XCTAssertEqual(try encoder.encode(plan.manifest), before)
            XCTAssertEqual(plan.manifest.backupFormatVersion, 1)
            XCTAssertFalse(plan.incomplete)
        }
        let value = Date(timeIntervalSince1970: 1_700_000_000)
        let utc = TimeZone(secondsFromGMT: 0)!
        let german = LibraryRestoreSummary.date(value, language: "de", timeZone: utc)
        let english = LibraryRestoreSummary.date(value, language: "en", timeZone: utc)
        XCTAssertNotEqual(german, english)
        XCTAssertEqual(LibraryRestoreSummary.date(value, language: "zz", timeZone: utc), english)
        XCTAssertEqual(value.timeIntervalSince1970, 1_700_000_000)
    }
}
