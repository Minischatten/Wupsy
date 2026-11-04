import Foundation

extension WSSImageEffect {
    func editorTitle(language: String? = nil) -> String {
        let resource: EditorText
        switch self {
        case .flow: resource = .effectFlow
        case .ripple: resource = .effectRipple
        case .clouds: resource = .effectClouds
        }
        return resource.localized(language: language)
    }
}

extension EditorText {
    static func directionCanvasHelp(
        hasRegion: Bool, operation: WSSVectorBrush.Operation,
        language: String? = nil
    ) -> String {
        let resource: EditorText
        switch operation {
        case .direction: resource = hasRegion ? .flowRegionCanvas : .directionCanvas
        case .neutralize: resource = .neutralizeCanvas
        case .erase: resource = hasRegion ? .eraseRegionCanvas : .eraseVectorCanvas
        }
        return resource.localized(language: language)
    }
}

extension EditorText {
    static func effectHeading(index: Int, name: String, language: String? = nil) -> String {
        EditorText.effectHeading.format(index + 1, name, language: language)
    }
}
