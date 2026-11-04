import Foundation

enum LibraryBackupPhase: CaseIterable {
    case analysis, snapshot, archive, verification, publication, done

    var title: String { localizedTitle() }
    func localizedTitle(language: String? = nil) -> String {
        switch self {
        case .analysis: return BackupText.analysis.localized(language: language)
        case .snapshot: return BackupText.snapshot.localized(language: language)
        case .archive: return BackupText.archive.localized(language: language)
        case .verification: return BackupText.verification.localized(language: language)
        case .publication: return BackupText.publication.localized(language: language)
        // Internal terminal state closes the panel; no additional UI resource.
        case .done: return "Done"
        }
    }

    var failureTitle: String { localizedFailureTitle() }
    func localizedFailureTitle(language: String? = nil) -> String {
        switch self {
        case .analysis: return BackupText.failureAnalysis.localized(language: language)
        case .snapshot: return BackupText.failureSnapshot.localized(language: language)
        case .archive: return BackupText.failureArchive.localized(language: language)
        case .verification: return BackupText.failureVerification.localized(language: language)
        case .publication: return BackupText.failurePublication.localized(language: language)
        // Defensive legacy fallback, not reached by the worker's error path.
        case .done: return "Backup could not be completed."
        }
    }

}

struct LibraryBackupProgressState {
    let phase: LibraryBackupPhase
    var detail: String? = nil
    var progress: LibraryBackupProgressDetail? = nil
    var title: String { localizedTitle() }
    func localizedTitle(language: String? = nil) -> String {
        progress?.localized(language: language) ?? detail
            ?? phase.localizedTitle(language: language)
    }
}

// Worker callbacks can finish before their UI refresh reaches the main actor.
// Keep the failure phase synchronously, independent of queued presentation work.
final class LibraryBackupPhaseTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LibraryBackupPhase = .analysis
    var phase: LibraryBackupPhase {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

// Structured transient parameters, formatted only by the progress UI.
enum LibraryBackupProgressDetail: Equatable, Sendable {
    case snapshot(current: Int, total: Int)
    case archive(path: String)
    case verification(path: String)

    func localized(language: String? = nil) -> String {
        switch self {
        case .snapshot(let current, let total):
            return BackupText.snapshotProgress.format(
                Int64(current), Int64(total), language: language)
        case .archive(let path): return BackupText.archiveProgress.format(path, language: language)
        case .verification(let path):
            return BackupText.verificationProgress.format(path, language: language)
        }
    }
}
