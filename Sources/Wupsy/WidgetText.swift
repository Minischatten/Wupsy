import Foundation

enum WidgetText: String, CaseIterable {
    case eyebrow = "widget.eyebrow"
    case studio = "widget.studio"
    case subtitle = "widget.subtitle"
    case movementHint = "widget.movementHint"
    case samplingHint = "widget.samplingHint"
    case resetLayout = "widget.resetLayout"
    case buildOwn = "widget.buildOwn"
    case buildHint = "widget.buildHint"
    case importJSON = "widget.importJSON"
    case exportJSON = "widget.exportJSON"
    case namePlaceholder = "widget.namePlaceholder"
    case code = "widget.code"
    case codeHint = "widget.codeHint"
    case loadStarter = "widget.loadStarter"
    case saved = "widget.saved"
    case unapplied = "widget.unapplied"
    case applyCode = "widget.applyCode"
    case readingsHint = "widget.readingsHint"
    case size = "widget.size"
    case sizeAX = "widget.sizeAX"
    case dragAX = "widget.dragAX"
    case clock = "widget.clock"
    case date = "widget.date"
    case cpu = "widget.cpu"
    case memory = "widget.memory"
    case network = "widget.network"
    case custom = "widget.custom"
    case ramEstimate = "widget.ramEstimate"
    case networkHistory = "widget.networkHistory"
    case graphAX = "widget.graphAX"
    case networkValuesAX = "widget.networkValuesAX"
    case downloadValue = "widget.downloadValue"
    case uploadValue = "widget.uploadValue"
    case editHint = "widget.editHint"
    case importPanel = "widget.importPanel"
    case exportPanel = "widget.exportPanel"
    case unsupportedVersion = "widget.unsupportedVersion"
    case invalidPackage = "widget.invalidPackage"
    case packageTooLarge = "widget.packageTooLarge"
    case updateFailed = "widget.updateFailed"
    case webStopped = "widget.webStopped"
    case operationFailed = "widget.operationFailed"
    case memoryValue = "widget.memoryValue"
    case megabyteRate = "widget.megabyteRate"
    case kilobyteRate = "widget.kilobyteRate"

    func localized(language: String? = nil) -> String {
        Localization.string(key: rawValue, language: language)
    }
    func format(_ arguments: CVarArg..., language: String? = nil) -> String {
        String(
            format: localized(language: language),
            locale: language.map(Locale.init(identifier:)) ?? .current, arguments: arguments)
    }
}

// Technical validation identity is independent of the language displayed by the UI.
enum CustomWidgetError: Error, LocalizedError, Equatable {
    case unsupportedVersion, invalidPackage, packageTooLarge
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "This widget uses an unsupported package version."
        case .invalidPackage:
            return "Use a name, HTML/CSS under 256 KB, and a height from 80 to 600 points."
        case .packageTooLarge: return "Widget packages must be under 300 KB."
        }
    }
}
enum WidgetErrorPresentation {
    static func message(_ error: Error, language: String? = nil) -> String {
        switch error {
        case CustomWidgetError.unsupportedVersion:
            return WidgetText.unsupportedVersion.localized(language: language)
        case CustomWidgetError.invalidPackage:
            return WidgetText.invalidPackage.localized(language: language)
        case CustomWidgetError.packageTooLarge:
            return WidgetText.packageTooLarge.localized(language: language)
        default:
            return WidgetText.operationFailed.format(error.localizedDescription, language: language)
        }
    }
    static func updateFailed(_ error: Error, language: String? = nil) -> String {
        WidgetText.updateFailed.format(error.localizedDescription, language: language)
    }
}
enum WidgetValues {
    static func percent(_ value: Double, digits: Int, locale: Locale = .current) -> String {
        // Measurements use 0...100; scale uses 0...1 and is converted by its caller.
        (value / 100).formatted(.percent.precision(.fractionLength(digits)).locale(locale))
    }
    static func memory(_ bytes: UInt64, locale: Locale = .current, language: String? = nil)
        -> String
    {
        let value = (Double(bytes) / 1_073_741_824).formatted(
            .number.grouping(.never).precision(.fractionLength(2)).locale(locale))
        return WidgetText.memoryValue.format(value, language: language)
    }
    static func rate(_ bytes: Double, locale: Locale = .current, language: String? = nil) -> String
    {
        let large = bytes >= 1_048_576
        let value = (bytes / (large ? 1_048_576 : 1024)).formatted(
            .number.grouping(.never).precision(.fractionLength(large ? 2 : 1)).locale(locale))
        return (large ? WidgetText.megabyteRate : .kilobyteRate).format(value, language: language)
    }
}
