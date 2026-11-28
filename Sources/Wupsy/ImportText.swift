import Foundation

// Import presentation resources share the catalog, bundle lookup and fallback.
// Technical diagnostics and copy payloads never use these strings as identities.
enum ImportText: String, CaseIterable {
    case failed = "import.failed"
    case invalidProjectTitle = "import.invalidProjectTitle"
    case unsafeTitle = "import.unsafeTitle"
    case unsupportedSource = "import.unsupportedSource"
    case projectComponent = "import.projectComponent"
    case singleHTMLNotice = "import.singleHTMLNotice"
    case folderWithoutProject = "import.folderWithoutProject"
    case webFolderMissingIndex = "import.webFolderMissingIndex"
    case succeeded = "import.succeeded"
    case partialResult = "import.partialResult"
    case unreadableDrop = "import.unreadableDrop"
    case panelHint = "import.panelHint"
    case unsupportedTitle = "import.unsupportedTitle"
    case generic = "import.generic"
    case invalidProject = "import.invalidProject"
    case invalidResource = "import.invalidResource"
    case unsafePath = "import.unsafePath"
    case resourceLimit = "import.resourceLimit"
    case storage = "import.storage"
    case publish = "import.publish"
    case rollback = "import.rollback"
    case cleanup = "import.cleanup"
    case wssNewerVersion = "import.wssNewerVersion"
    case wssUnknownFeature = "import.wssUnknownFeature"
    case wssMissingFile = "import.wssMissingFile"
    case wssPreparationFailed = "import.wssPreparationFailed"
    case wssMetalUnavailable = "import.wssMetalUnavailable"
    case wallpaperFailureDiagnostic = "import.wallpaperFailureDiagnostic"
    case wssVersion = "import.wssVersion"
    case wssInvalid = "import.wssInvalid"
    case wssUnsupported = "import.wssUnsupported"
    case decodedBudget = "import.decodedBudget"
    case close = "import.close"
    case details = "import.details"
    case copyDetails = "import.copyDetails"
    case sourceNumber = "import.sourceNumber"
    case detailsAccessibility = "import.detailsAccessibility"
    case copyAccessibility = "import.copyAccessibility"
    case failures = "import.failures"

    case diagnosticHeading = "import.diagnosticHeading"
    case diagnosticCategory = "import.diagnosticCategory"
    case diagnosticDisposition = "import.diagnosticDisposition"
    case diagnosticFile = "import.diagnosticFile"
    case diagnosticField = "import.diagnosticField"
    case diagnosticExpected = "import.diagnosticExpected"
    case diagnosticActual = "import.diagnosticActual"
    case diagnosticDetail = "import.diagnosticDetail"

    var text: String { localized() }
    func localized(language: String? = nil) -> String {
        Localization.string(key: rawValue, language: language)
    }
    func format(_ arguments: CVarArg..., language: String? = nil) -> String {
        // A missing test/audit language uses English resources and English plural rules.
        let locale =
            language.map {
                Locale(
                    identifier: Localization.bundle.path(forResource: $0, ofType: "lproj") == nil
                        ? "en" : $0)
            } ?? .current
        return String(
            format: localized(language: language),
            locale: locale, arguments: arguments)
    }
}
