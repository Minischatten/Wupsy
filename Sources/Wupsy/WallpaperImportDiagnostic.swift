import Foundation

// Structured diagnostics shared by native project, media and web imports.
struct WallpaperImportDiagnostic: LocalizedError, Equatable {
    enum Category: String {
        case invalidProject
        case invalidResource, unsafePath
        case resourceLimit, storage, publish, rollback, cleanup
    }
    enum Disposition: String { case unsupported, invalidOrUnsafe }
    let category: Category
    let disposition: Disposition
    let file: String?
    let field: String?
    let expected: String?
    let actual: String?
    let detail: String?

    init(
        _ category: Category, disposition: Disposition = .unsupported,
        file: String? = nil, field: String? = nil, expected: String? = nil,
        actual: String? = nil, detail: String? = nil
    ) {
        self.category = category
        self.disposition = disposition
        self.file = file
        self.field = field
        self.expected = expected
        self.actual = actual
        self.detail = detail
    }
    var errorDescription: String? {
        let reason: String
        switch category {
        case .invalidProject: reason = "The project contains missing or invalid format data."
        case .invalidResource: reason = "A required resource is missing or invalid."
        case .unsafePath: reason = "The project contains an unsafe file path or link."
        case .resourceLimit: reason = "The project exceeds an import resource limit."
        case .storage: reason = "The imported wallpaper could not be stored."
        case .publish: reason = "The imported wallpaper could not be published."
        case .rollback: reason = "Import failed and its published files could not be rolled back."
        case .cleanup: reason = "Import staging could not be cleaned up."
        }
        return "This wallpaper could not be imported. " + reason
    }
    var technicalDetails: String {
        var lines = ["Category: \(category.rawValue)", "Disposition: \(disposition.rawValue)"]
        for (key, value) in [
            ("File", file), ("Field", field), ("Expected", expected), ("Actual", actual),
            ("Detail", detail),
        ] {
            if let value { lines.append(key + ": " + value) }
        }
        return lines.joined(separator: "\n")
    }
    // Preserve typed errors across storage stages; keep raw evidence out of main UI text.
    static func wrapping(_ error: Error, as category: Category) -> WallpaperImportDiagnostic {
        if let diagnostic = error as? WallpaperImportDiagnostic { return diagnostic }
        if let scene = error as? SceneError {
            switch scene {
            case .invalid(let text):
                return Self(.invalidResource, disposition: .invalidOrUnsafe, detail: text)
            case .unsupported(let text): return Self(category, detail: text)
            }
        }
        return Self(
            category,
            disposition: category == .invalidProject ? .invalidOrUnsafe : .unsupported,
            detail: String(describing: error))
    }
}
