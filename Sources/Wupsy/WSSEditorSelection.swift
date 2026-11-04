import Foundation

struct WSSLayerID: Hashable { let rawValue = UUID() }
struct WSSEffectID: Hashable { let rawValue = UUID() }
struct WSSEditorIdentity: Equatable {
    struct Layer: Equatable {
        let id: WSSLayerID
        var effects: [WSSEffectID]
    }
    var layers: [Layer]
    init(_ model: WSSSceneDocumentV1) {
        layers = model.layers.map { node in
            let count: Int
            if case .image(let image) = node.content {
                count = image.effects.count
            } else {
                count = 0
            }
            return Layer(id: WSSLayerID(), effects: (0..<count).map { _ in WSSEffectID() })
        }
    }
    // Resource resolution must never trust an identity index without its model shape.
    func checkedAddress(
        in model: WSSSceneDocumentV1, layer: WSSLayerID, effect: WSSEffectID
    ) -> WSSEffectAddress? {
        guard layers.count == model.layers.count,
            let address = address(layer, effect: effect),
            model.layers.indices.contains(address.layerIndex),
            case .image(let image) = model.layers[address.layerIndex].content,
            layers[address.layerIndex].effects.count == image.effects.count,
            image.effects.indices.contains(address.effectIndex)
        else { return nil }
        return address
    }
    func address(_ layer: WSSLayerID, effect: WSSEffectID) -> WSSEffectAddress? {
        guard let l = layers.firstIndex(where: { $0.id == layer }),
            let e = layers[l].effects.firstIndex(of: effect)
        else { return nil }
        return WSSEffectAddress(layerIndex: l, effectIndex: e)
    }
}
enum WSSEditorSelection: Hashable {
    case layer(WSSLayerID)
    case effect(WSSLayerID, WSSEffectID)
    var layer: WSSLayerID {
        switch self {
        case .layer(let id), .effect(let id, _): return id
        }
    }
}
struct WSSEditTarget: Equatable {
    enum Role: Equatable { case image, mask, vectorField, coverage }
    let layer: WSSLayerID
    var effect: WSSEffectID?
    var role: Role
}

enum WSSImageProperty: String, CaseIterable {
    case opacity, centerX, centerY, width, height, scaleX, scaleY, rotation
    var title: String { localizedTitle() }
    func localizedTitle(language: String? = nil) -> String {
        switch self {
        case .opacity: return EditorText.opacity.localized(language: language)
        case .centerX: return EditorText.centerX.localized(language: language)
        case .centerY: return EditorText.centerY.localized(language: language)
        case .width: return EditorText.width.localized(language: language)
        case .height: return EditorText.height.localized(language: language)
        case .scaleX: return EditorText.scaleX.localized(language: language)
        case .scaleY: return EditorText.scaleY.localized(language: language)
        case .rotation: return EditorText.rotation.localized(language: language)
        }
    }
    var range: ClosedRange<Float> {
        switch self {
        case .opacity: return 0...1
        case .width, .height: return Float.leastNormalMagnitude...8192
        case .scaleX, .scaleY: return Float.leastNormalMagnitude...100
        case .rotation: return -57_295_776...57_295_776
        default: return -1_000_000...1_000_000
        }
    }
    func value(_ image: WSSSceneDocumentV1.Image) -> Float {
        switch self {
        case .opacity: return image.opacity
        case .centerX: return image.transform.center[0]
        case .centerY: return image.transform.center[1]
        case .width: return image.transform.size[0]
        case .height: return image.transform.size[1]
        case .scaleX: return image.transform.scale[0]
        case .scaleY: return image.transform.scale[1]
        case .rotation: return image.transform.rotation * 180 / .pi
        }
    }
    func apply(_ value: Float, to image: inout WSSSceneDocumentV1.Image) throws {
        guard value.isFinite, range.contains(value) else {
            throw WSSDocumentError.invalid("image property")
        }
        switch self {
        case .opacity: image.opacity = value
        case .centerX: image.transform.center[0] = value
        case .centerY: image.transform.center[1] = value
        case .width: image.transform.size[0] = value
        case .height: image.transform.size[1] = value
        case .scaleX: image.transform.scale[0] = value
        case .scaleY: image.transform.scale[1] = value
        case .rotation: image.transform.rotation = value * .pi / 180
        }
    }
}

// Structural targets retain session identity rather than a transient array index.
enum WSSDeletableTarget: Equatable {
    case layer(WSSLayerID)
    case effect(WSSLayerID, WSSEffectID)
    var title: String {
        switch self {
        case .layer: return EditorText.deleteLayer.text
        case .effect: return EditorText.deleteEffect.text
        }
    }
}
