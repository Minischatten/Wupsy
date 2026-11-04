import Foundation
import XCTest

@testable import Wupsy

final class BackupLocalizationTests: XCTestCase {
    func testResourcesFilenameAndPanelExplanationInEnglishGermanAndFallback() {
        for resource in BackupText.allCases {
            for language in ["en", "de", "zz"] {
                XCTAssertFalse(resource.localized(language: language).isEmpty)
                XCTAssertNotEqual(resource.localized(language: language), resource.rawValue)
            }
            XCTAssertEqual(resource.localized(language: "zz"), resource.localized(language: "en"))
        }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for language in ["en", "de", "zz"] {
            XCTAssertEqual(
                BackupText.suggestedFilename(
                    at: date,
                    timeZone: TimeZone(secondsFromGMT: 0)!, language: language),
                "Wupsy Backup 2023-11-14.wssbackup")
        }
        XCTAssertEqual(
            BackupText.saveTitle.localized(language: "de"), "Hintergrundbild-Mediathek sichern")
        XCTAssertTrue(
            BackupText.saveExplanation.localized(language: "de").contains("nicht verschlüsselt"))
        XCTAssertTrue(
            BackupText.saveExplanation.localized(language: "en").contains("Only saved changes"))
        XCTAssertEqual(ProductText.cancel.localized(language: "de"), "Abbrechen")
    }

    func testPhaseIdentityProgressParametersAndErrorDetailsNeverDependOnLanguage() {
        let phases: [(LibraryBackupPhase, String, String)] = [
            (.analysis, "Analyzing library…", "Mediathek wird analysiert …"),
            (.snapshot, "Creating snapshot…", "Sicherungskopie wird vorbereitet …"),
            (.archive, "Writing backup…", "Backup wird geschrieben …"),
            (.verification, "Verifying backup…", "Backup wird geprüft …"),
            (.publication, "Publishing backup…", "Backup wird fertiggestellt …"),
        ]
        let evidence = "NSCocoaErrorDomain code=513 /Users/Synthetic/Private/ä %@.wssbackup"
        let error = LibraryBackupError(evidence)
        for (phase, english, german) in phases {
            let tracker = LibraryBackupPhaseTracker()
            tracker.phase = phase
            let state = LibraryBackupProgressState(phase: phase)
            XCTAssertEqual(state.localizedTitle(language: "en"), english)
            XCTAssertEqual(state.localizedTitle(language: "de"), german)
            XCTAssertEqual(state.localizedTitle(language: "zz"), english)
            XCTAssertNotEqual(
                phase.localizedFailureTitle(language: "de"),
                phase.localizedFailureTitle(language: "en"))
            XCTAssertEqual(
                phase.localizedFailureTitle(language: "zz"),
                phase.localizedFailureTitle(language: "en"))
            for language in ["en", "de", "zz"] {
                XCTAssertTrue(
                    BackupErrorPresentation.detail(error, language: language).hasSuffix(evidence))
                XCTAssertEqual(tracker.phase, phase)
                XCTAssertEqual(state.phase, phase)
            }
        }
        let snapshot = LibraryBackupProgressDetail.snapshot(current: 2, total: 7)
        XCTAssertEqual(snapshot.localized(language: "de"), "Sicherungskopie wird vorbereitet … 2/7")
        XCTAssertEqual(snapshot.localized(language: "en"), "Creating snapshot… 2/7")
        let path = "payloads/UUID/source/ä %@.png"
        for detail in [LibraryBackupProgressDetail.archive(path: path), .verification(path: path)] {
            let original = detail
            for language in ["en", "de", "zz"] {
                XCTAssertTrue(detail.localized(language: language).hasSuffix(path))
                XCTAssertEqual(detail, original)
            }
        }
        let state = LibraryBackupProgressState(phase: .snapshot, progress: snapshot)
        XCTAssertEqual(state.localizedTitle(language: "de"), snapshot.localized(language: "de"))
        XCTAssertEqual(state.phase, .snapshot)
        XCTAssertEqual(error.localizedDescription, evidence)
    }

    func testStructuredProgressUsesExactCountersAndRelativeArchiveInventory() throws {
        let helper = LibraryBackupTests()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        try helper.save([helper.media()])
        let stage = try LibraryBackupStaging(parent: helper.root)
        defer { try? stage.discard() }
        let values = ProgressValues()
        let plan = try LibraryBackupPlan.analyze(storage: helper.storage)
        let manifest = try plan.snapshot(
            to: stage.url,
            preferences: .init(defaults: helper.defaults), progress: { _ in },
            itemProgress: { values.append(.snapshot(current: $0, total: $1)) })
        XCTAssertFalse(values.all.isEmpty)
        let total = values.all.count
        XCTAssertEqual(values.all, (1...total).map { .snapshot(current: $0, total: total) })
        let output = try LibraryBackupDestination(
            helper.root.appendingPathComponent("progress.wssbackup"))
        defer { try? output.discard() }
        let writing = ProgressValues()
        let verifying = ProgressValues()
        try LibraryBackupArchive.write(
            snapshot: stage.url, manifest: manifest, fd: output.fd,
            progress: { _ in }, entryProgress: { writing.append(.archive(path: $0)) })
        try output.verify(
            expected: manifest,
            entryProgress: { verifying.append(.verification(path: $0)) })
        let inventory = ["backup.json"] + manifest.files.map(\.path)
        XCTAssertEqual(writing.all, inventory.map { .archive(path: $0) })
        XCTAssertEqual(verifying.all, inventory.map { .verification(path: $0) })
        XCTAssertTrue(inventory.allSatisfy { !$0.hasPrefix("/") })
    }

    func testNativeNotesRoundtripAndArchiveVerificationRemainLanguageIndependent() throws {
        let helper = LibraryBackupTests()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let item = try helper.native("Wallpapers/WSS/Test")
        try helper.save([item])
        let (stage, manifest) = try helper.snapshot()
        defer { try? stage.discard() }
        let before = try JSONEncoder().encode(manifest)
        for language in ["en", "de", "zz"] {
            XCTAssertEqual(
                LibraryBackupCompletionSummary.title(manifest, language: language),
                BackupText.completed.localized(language: language))
            XCTAssertFalse(
                LibraryBackupCompletionSummary.detail(manifest, language: language).contains(
                    item.id.uuidString))
        }
        XCTAssertEqual(try JSONDecoder().decode(LibraryBackupManifest.self, from: before), manifest)
        let output = try helper.archive(stage, manifest)
        defer { try? output.discard() }
        try LibraryBackupArchive.verify(fd: output.fd, expected: manifest)
        var changed = manifest
        changed.notes[0] = "Different historical note"
        XCTAssertThrowsError(try LibraryBackupArchive.verify(fd: output.fd, expected: changed))
        XCTAssertEqual(
            try LibraryBackupArchive.read(fd: output.fd, expected: manifest).manifest.notes,
            manifest.notes)
        try FileManager.default.removeItem(at: item.url)
        XCTAssertThrowsError(try helper.snapshot())
    }
}

private final class ProgressValues: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LibraryBackupProgressDetail] = []
    func append(_ value: LibraryBackupProgressDetail) { lock.withLock { values.append(value) } }
    var all: [LibraryBackupProgressDetail] { lock.withLock { values } }
}
