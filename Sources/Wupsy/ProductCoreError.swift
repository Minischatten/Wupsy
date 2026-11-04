import Foundation

// Presentation errors for core UI actions only. Parser/import diagnostics keep
// their own types and stable technical evidence.
struct ProductCoreError: LocalizedError {
    let resource: ProductText
    init(_ resource: ProductText) { self.resource = resource }
    var errorDescription: String? { resource.text }
    static func nameValidation(_ input: String) -> String? {
        guard let issue = WallpaperTitle.validationIssue(input) else { return nil }
        switch issue {
        case .singleLine: return ProductText.nameSingleLine.text
        case .required: return ProductText.nameRequired.text
        case .length: return ProductText.nameLength.text
        }
    }
}
