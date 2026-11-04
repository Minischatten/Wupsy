import Foundation

// Editor-only presentation boundary. Backend descriptions, identities and shared
// runtime diagnostics remain technical; opaque details are never parsed.
enum EditorErrorPresentation {
    static func message(_ error: Error, language: String? = nil) -> String {
        let presentationLanguage = language.map {
            Localization.bundle.path(forResource: $0, ofType: "lproj") == nil ? "en" : $0
        }
        func text(_ resource: EditorText) -> String {
            resource.localized(language: presentationLanguage)
        }
        func detail(_ message: String, _ evidence: String) -> String {
            EditorText.errorWithDetail.format(message, evidence, language: presentationLanguage)
        }
        switch error {
        case is WSSTrailAuthoringError: return text(.trailCapacity)
        case let error as WSSRainAuthoringError:
            switch error {
            case .capacity: return text(.rainCapacity)
            case .smallRegion: return text(.rainSmallRegion)
            }
        case let error as WSSImageImportError:
            switch error {
            case .unsupported: return text(.errorImageUnsupported)
            case .corrupt: return text(.errorImageCorrupt)
            case .dimensions:
                return EditorText.errorImageDimensions.format(
                    Int64(8192), language: presentationLanguage)
            case .pixels:
                return EditorText.errorImagePixels.format(Int64(32), language: presentationLanguage)
            case .decodedBudget:
                return ImportText.decodedBudget.localized(language: presentationLanguage)
            case .fileSize:
                return EditorText.errorImageFileSize.format(
                    Int64(128), language: presentationLanguage)
            case .layerLimit:
                return EditorText.errorImageLayers.format(
                    Int64(128), language: presentationLanguage)
            case .stagingBudget:
                return EditorText.errorImageStaging.format(
                    Int64(512), language: presentationLanguage)
            case .incompatible: return text(.errorImageIncompatible)
            case .stale: return text(.errorImageStale)
            case .storage: return text(.errorImageStorage)
            case .cleanup: return text(.errorImageCleanup)
            }
        case let error as WSSSaveError:
            switch error {
            case .validationFailed(let evidence):
                return detail(text(.errorSaveValidation), evidence)
            case .externalConflict: return text(.errorSaveConflict)
            case .targetDisappeared: return text(.errorSaveTarget)
            case .writeFailed(let evidence): return detail(text(.errorSaveWrite), evidence)
            case .commitFailed(let evidence): return detail(text(.errorSaveCommit), evidence)
            }
        case let error as WSSSaveAsError:
            switch error {
            case .busy: return text(.waitSaveAs)
            case .name: return text(.nameBytes)
            case .budget:
                return EditorText.errorCopyBudget.format(Int64(512), language: presentationLanguage)
            case .conflict: return text(.errorCopyConflict)
            case .collision: return text(.errorCopyCollision)
            case .storage: return text(.errorCopyStorage)
            case .invalid: return text(.errorCopyInvalid)
            case .cleanup: return text(.errorCopyCleanup)
            case .library: return text(.errorCopyLibrary)
            }
        case let error as WSSMaskError:
            switch error {
            case .stale: return text(.errorMaskStale)
            case .unsupported: return text(.errorMaskUnsupported)
            case .invalid: return text(.errorMaskInvalid)
            case .budget: return text(.errorMaskBudget)
            case .transaction: return text(.errorMaskTransaction)
            }
        case let error as WSSVectorFieldEditError:
            // Add Flow can surface these resource-preparation failures. Paint's
            // internal stale/unsupported cases retain the existing C wrappers.
            switch error {
            case .invalid: return text(.errorVectorInvalid)
            case .budget:
                return EditorText.errorVectorBudget.format(
                    Int64(128), language: presentationLanguage)
            case .stale, .unsupported:
                return EditorText.errorOperation.format(
                    error.localizedDescription, language: presentationLanguage)
            }
        case let error as WSSDocumentError:
            switch error {
            case .version(let version):
                return ImportText.wssVersion.format(Int64(version), language: presentationLanguage)
            case .invalid(let evidence):
                return detail(
                    ImportText.wssInvalid.localized(language: presentationLanguage), evidence)
            case .missingAsset(let evidence):
                return detail(
                    ImportText.invalidResource.localized(language: presentationLanguage), evidence)
            case .unsafePath(let evidence):
                return detail(
                    ImportText.unsafePath.localized(language: presentationLanguage), evidence)
            case .effect(let evidence):
                return detail(
                    ImportText.wssUnsupported.localized(language: presentationLanguage), evidence)
            }
        case let error as WSSSceneError:
            switch error {
            case .invalid(let evidence):
                return detail(
                    ImportText.wssInvalid.localized(language: presentationLanguage), evidence)
            case .unsupported(let evidence):
                return detail(
                    ImportText.wssUnsupported.localized(language: presentationLanguage), evidence)
            case .decodedImageBudget:
                return ImportText.decodedBudget.localized(language: presentationLanguage)
            }
        default:
            return EditorText.errorOperation.format(
                error.localizedDescription, language: presentationLanguage)
        }
    }
}
