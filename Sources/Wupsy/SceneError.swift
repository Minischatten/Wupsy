import Foundation

enum SceneError: LocalizedError {
    case invalid(String)
    case unsupported(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let text):
            return WallpaperImportDiagnostic(
                .invalidResource, disposition: .invalidOrUnsafe, detail: text
            )
            .errorDescription
        case .unsupported(let text):
            return WallpaperImportDiagnostic(.invalidResource, detail: text).errorDescription
        }
    }
}
