import Foundation

// Shared presentation for native WSS failures. Update hints depend only on typed causes.
struct WSSFailurePresentation {
    let explanation: String
    let technicalDetails: String

    init?(_ error: Error, language: String? = nil) {
        func text(_ key: ImportText) -> String { key.localized(language: language) }

        switch error {
        case WSSDocumentError.version(let version):
            if version > WSSSceneDocumentV1.supportedVersion {
                explanation = ImportText.wssNewerVersion.format(
                    Int64(version), Int64(WSSSceneDocumentV1.supportedVersion), language: language)
            } else {
                explanation = ImportText.wssVersion.format(Int64(version), language: language)
            }
        case WSSDocumentError.unknownFields, WSSDocumentError.unknownLayer, WSSDocumentError.effect:
            explanation = text(.wssUnknownFeature)
        case WSSDocumentError.invalid, WSSSceneError.invalid:
            explanation = text(.wssInvalid)
        case WSSDocumentError.missingAsset(let path):
            // Keep the relative asset name in the explanation, with redacted evidence in details.
            explanation = ImportText.wssMissingFile.format(path, language: language)
        case WSSDocumentError.invalidResource, WSSMaskError.invalid:
            explanation = text(.invalidResource)
        case WSSDocumentError.unsafePath:
            explanation = text(.unsafePath)
        case WSSSceneError.unsupported:
            explanation = text(.wssUnsupported)
        case WSSSceneError.decodedImageBudget:
            explanation = text(.decodedBudget)
        case WSSMaskError.budget:
            explanation = text(.resourceLimit)
        case WSSSceneError.preparationFailed:
            explanation = text(.wssPreparationFailed)
        case WSSSceneError.metalUnavailable:
            explanation = text(.wssMetalUnavailable)
        default:
            return nil
        }
        technicalDetails = error.localizedDescription
    }
}
