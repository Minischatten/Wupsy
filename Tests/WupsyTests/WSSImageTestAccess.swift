@testable import Wupsy

// Image-only regression fixtures: preserve their original assertions after the layer enum.
extension WSSScene {
    var testImages: [WSSImageLayer] {
        get {
            layers.map { node in
                guard case .image(let image) = node else {
                    preconditionFailure("image-only fixture")
                }
                return image
            }
        }
        set { layers = newValue.map(WSSSceneLayer.image) }
    }
}
