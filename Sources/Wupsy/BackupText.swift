import Foundation

// Backup presentation only; no manifest/Note strings are used as identities.
enum BackupText: String, CaseIterable {
    case unavailable = "backup.unavailable"
    case saveTitle = "backup.saveTitle"
    case saveExplanation = "backup.saveExplanation"
    case filename = "backup.filename"
    case windowTitle = "backup.windowTitle"
    case analysis = "backup.analysis"
    case snapshot = "backup.snapshot"
    case archive = "backup.archive"
    case verification = "backup.verification"
    case publication = "backup.publication"
    case failureAnalysis = "backup.failureAnalysis"
    case failureSnapshot = "backup.failureSnapshot"
    case failureArchive = "backup.failureArchive"
    case failureVerification = "backup.failureVerification"
    case failurePublication = "backup.failurePublication"
    case snapshotProgress = "backup.snapshotProgress"
    case archiveProgress = "backup.archiveProgress"
    case verificationProgress = "backup.verificationProgress"
    case completed = "backup.completed"
    case incomplete = "backup.incomplete"
    case missingSources = "backup.missingSources"
    case summary = "backup.summary"
    case incompleteSummary = "backup.incompleteSummary"
    case errorDetail = "backup.errorDetail"

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
    static func suggestedFilename(
        at date: Date = Date(), timeZone: TimeZone = .current,
        language: String? = nil
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return filename.format(formatter.string(from: date), language: language)
    }
}

enum BackupErrorPresentation {
    static func detail(_ error: Error, language: String? = nil) -> String {
        BackupText.errorDetail.format(error.localizedDescription, language: language)
    }
}
