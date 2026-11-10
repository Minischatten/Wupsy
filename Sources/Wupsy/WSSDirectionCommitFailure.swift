import Foundation

// Internal typed evidence only; never log the underlying project path or bytes.
struct WSSDirectionCommitFailure {
    enum Stage: Equatable { case paint, adoption }
    enum Category: Equatable { case budget, storage, validation, stale, cancelled, other }
    let stage: Stage
    let cause: Error
    let retainedVectorBytes: Int
    var category: Category { Self.classify(cause) }
    private static func classify(_ error: Error) -> Category {
        if let wrapped = error as? WSSDirectionPaintFailure { return classify(wrapped.cause) }
        if error is CancellationError { return .cancelled }
        if let error = error as? WSSVectorFieldEditError {
            switch error {
            case .budget: return .budget
            case .stale: return .stale
            case .invalid, .unsupported: return .validation
            }
        }
        if let error = error as? WSSImageImportError {
            switch error {
            case .stagingBudget: return .budget
            case .storage, .cleanup: return .storage
            default: return .validation
            }
        }
        if let error = error as? WSSVectorPaintError {
            switch error {
            case .budget: return .budget
            default: return .validation
            }
        }
        if let error = error as? WSSSceneError, error == .decodedImageBudget { return .budget }
        if error is WSSDocumentError || error is WSSSceneError { return .validation }
        if error is WSSSaveError { return .stale }
        return .other
    }
    var message: String {
        switch category {
        case .budget: return EditorText.directionResourceBudget.text
        case .storage: return EditorText.directionStorageError.text
        case .stale: return EditorText.directionTargetChanged.text
        default: return EditorText.directionCommitError.text
        }
    }
}
