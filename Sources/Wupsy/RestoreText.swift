import Foundation

enum RestoreText: String, CaseIterable {
    case openTitle = "restore.openTitle"
    case confirmTitle = "restore.confirmTitle"
    case replace = "restore.replace"
    case windowTitle = "restore.windowTitle"
    case validating = "restore.validating"
    case preparing = "restore.preparing"
    case waiting = "restore.waiting"
    case restoring = "restore.restoring"
    case finishing = "restore.finishing"
    case preparationFailed = "restore.preparationFailed"
    case preparationDetail = "restore.preparationDetail"
    case cleanupDetail = "restore.cleanupDetail"
    case completed = "restore.completed"
    case completedDetail = "restore.completedDetail"
    case rolledBack = "restore.rolledBack"
    case rolledBackDetail = "restore.rolledBackDetail"
    case unresolved = "restore.unresolved"
    case unresolvedDetail = "restore.unresolvedDetail"
    case unavailable = "restore.unavailable"
    case datedSummary = "restore.datedSummary"
    case additionalLine = "restore.additionalLine"
    case incomplete = "restore.incomplete"
    case confirmation = "restore.confirmation"
    case maintenanceJobActive = "restore.maintenanceJobActive"
    case maintenanceRestart = "restore.maintenanceRestart"
    case maintenanceTransition = "restore.maintenanceTransition"
    case recoveryCount = "restore.recoveryCount"

    var text: String { localized() }
    static func presentationLanguage(_ language: String) -> String {
        Localization.bundle.path(forResource: language, ofType: "lproj") == nil ? "en" : language
    }
    func localized(language: String? = nil) -> String {
        Localization.string(key: rawValue, language: language.map(Self.presentationLanguage))
    }
    func format(_ arguments: CVarArg..., language: String? = nil) -> String {
        let language = language.map(Self.presentationLanguage)
        return String(
            format: localized(language: language),
            locale: language.map(Locale.init(identifier:)) ?? .current, arguments: arguments)
    }
}

// Presentation identity only, independent of preparer checkpoints and journal phases.
enum LibraryRestorePresentationPhase: CaseIterable, Sendable {
    case validating, preparing, waiting, restoring, finishing
    func localized(language: String? = nil) -> String {
        let resource: RestoreText
        switch self {
        case .validating: resource = .validating
        case .preparing: resource = .preparing
        case .waiting: resource = .waiting
        case .restoring: resource = .restoring
        case .finishing: resource = .finishing
        }
        return resource.localized(language: language)
    }
}

enum MaintenanceErrorPresentation {
    static func message(_ error: MaintenanceError, language: String? = nil) -> String {
        let resource: RestoreText
        switch error {
        case .jobActive: resource = .maintenanceJobActive
        case .restartRequired: resource = .maintenanceRestart
        case .invalidTransition: resource = .maintenanceTransition
        // These remain internal orchestration failures. The existing reversible
        // failure dialog supplies context; no additional UI or per-case resource.
        case .frozen, .drainFailed: resource = .preparationFailed
        }
        return resource.localized(language: language)
    }
}

enum RestoreErrorPresentation {
    static func detail(_ error: Error, language: String? = nil) -> String {
        if let maintenance = error as? MaintenanceError {
            return MaintenanceErrorPresentation.message(maintenance, language: language)
        }
        return BackupText.errorDetail.format(error.localizedDescription, language: language)
    }
}

struct RestoreTerminalPresentation {
    let outcome: LibraryRestoreCoordinator.Outcome
    let title: String
    let detail: String
    init(_ outcome: LibraryRestoreCoordinator.Outcome, language: String? = nil) {
        self.outcome = outcome
        let titleResource: RestoreText
        let detailResource: RestoreText
        switch outcome {
        case .committed:
            titleResource = .completed
            detailResource = .completedDetail
        case .restoredA:
            titleResource = .rolledBack
            detailResource = .rolledBackDetail
        case .unresolved:
            titleResource = .unresolved
            detailResource = .unresolvedDetail
        }
        title = titleResource.localized(language: language)
        detail = detailResource.localized(language: language)
    }
}
