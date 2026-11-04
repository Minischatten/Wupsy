import Foundation

// Presentation only. Compatibility decisions and raw diagnostic data remain in
// Phase 11A; this layer neither retries nor authorizes an unsupported import.
struct ImportFailurePresentation: Identifiable {
    let id = UUID()
    let sourceName: String
    let title: String
    let explanation: String
    let technicalDetails: String
    private let diagnosticHeading: String
    var copyText: String { diagnosticHeading + "\n\n" + technicalDetails }

    init(source: URL, error: Error, language: String? = nil) {
        diagnosticHeading = ImportText.diagnosticHeading.localized(language: language)
        // Canonical entry names need their immediate project name for batch
        // identification. Never display the complete selected path.
        sourceName =
            ["scene.wss.json"].contains(source.lastPathComponent)
            ? source.deletingLastPathComponent().lastPathComponent + "/" + source.lastPathComponent
            : source.lastPathComponent
        guard let diagnostic = error as? WallpaperImportDiagnostic else {
            title = ImportText.failed.localized(language: language)
            switch error {
            case WSSDocumentError.version(let version):
                explanation = ImportText.wssVersion.format(Int64(version), language: language)
            case WSSDocumentError.invalid:
                explanation = ImportText.wssInvalid.localized(language: language)
            case WSSDocumentError.missingAsset:
                explanation = ImportText.invalidResource.localized(language: language)
            case WSSDocumentError.unsafePath:
                explanation = ImportText.unsafePath.localized(language: language)
            case WSSDocumentError.effect, WSSSceneError.unsupported:
                explanation = ImportText.wssUnsupported.localized(language: language)
            case WSSSceneError.invalid:
                explanation = ImportText.wssInvalid.localized(language: language)
            case WSSSceneError.decodedImageBudget:
                explanation = ImportText.decodedBudget.localized(language: language)
            default:
                // ImportFailure.message and foreign errors have no finer typed identity.
                explanation = ImportText.generic.localized(language: language)
            }
            technicalDetails = Self.privatePaths(
                "Details: " + error.localizedDescription, source: source)
            return
        }
        switch diagnostic.category {
        case .invalidProject:
            title = ImportText.invalidProjectTitle.localized(language: language)
        case .unsafePath:
            title = ImportText.unsafeTitle.localized(language: language)
        case .storage, .publish, .rollback, .cleanup, .invalidResource, .resourceLimit:
            title = ImportText.failed.localized(language: language)
        default:
            title = ImportText.unsupportedTitle.localized(language: language)
        }
        switch diagnostic.category {
        case .invalidProject: explanation = ImportText.invalidProject.localized(language: language)
        case .invalidResource:
            explanation = ImportText.invalidResource.localized(language: language)
        case .unsafePath: explanation = ImportText.unsafePath.localized(language: language)
        case .resourceLimit:
            explanation = ImportText.resourceLimit.localized(language: language)
        case .storage: explanation = ImportText.storage.localized(language: language)
        case .publish: explanation = ImportText.publish.localized(language: language)
        case .rollback:
            explanation =
                ImportText.rollback.localized(language: language)
        case .cleanup:
            explanation = ImportText.cleanup.localized(language: language)
        }
        // Localize labels from structured fields; retain values and multiline details.
        // Only unnecessary absolute directory prefixes are removed for sharing.
        var lines = [
            ImportText.diagnosticCategory.format(diagnostic.category.rawValue, language: language),
            ImportText.diagnosticDisposition.format(
                diagnostic.disposition.rawValue, language: language),
        ]
        for (label, value): (ImportText, String?) in [
            (.diagnosticFile, diagnostic.file), (.diagnosticField, diagnostic.field),
            (.diagnosticExpected, diagnostic.expected), (.diagnosticActual, diagnostic.actual),
            (.diagnosticDetail, diagnostic.detail),
        ] {
            if let value { lines.append(label.format(value, language: language)) }
        }
        technicalDetails = Self.privatePaths(lines.joined(separator: "\n"), source: source)
    }

    static func privatePaths(_ text: String, source: URL) -> String {
        let root = source.hasDirectoryPath ? source.path : source.deletingLastPathComponent().path
        var result = text
        if root != "/" {
            result = result.replacingOccurrences(of: "file://" + root + "/", with: "")
            result = result.replacingOccurrences(of: root + "/", with: "")
        }
        // NSError descriptions can contain quoted paths, file URLs or NSFilePath
        // values with spaces. Keep the leaf name; redact only the local directory.
        let roots = "(?:Users|Volumes|private|var|tmp|home|mnt|media)"
        let pattern =
            #"(?<![\p{L}\p{N}_./])(?:file://)?/"# + roots + "/(?:(?!(?:file://)?/" + roots
            + #"/)[^\n\r\"'<>\[\]{};,()])*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let path = String(result[range])
            guard let slash = path.lastIndex(of: "/") else { continue }
            // Preserve the entire leaf and following prose verbatim. This avoids
            // dropping error codes or other evidence following an unquoted path.
            let tail = path[path.index(after: slash)...]
            result.replaceSubrange(range, with: "[lokaler Pfad]/" + tail)
        }
        return result
    }
}

struct ImportFailureReport: Identifiable {
    let id = UUID()
    let failures: [ImportFailurePresentation]
}
