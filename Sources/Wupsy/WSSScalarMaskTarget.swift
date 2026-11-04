import Foundation

// One scalar-mask address for image effects and independently composed scene layers.
// Geometry always presents top-left mask UV, including lower-left scene regions.
struct WSSScalarMaskContext {
    let layerIndex: Int
    let effectIndex: Int?
    let transform: WSSImageTransform
    let size: [Float]
    let path: String?
    let definition: WSSNativeImageDefinition?
}

extension WSSEditorDocument.Snapshot {
    func maskContext(_ target: WSSMaskTarget) throws -> WSSScalarMaskContext {
        guard target.sessionID == state.sessionID,
            identity.layers.count == state.workingModel.layers.count,
            let index = identity.layers.firstIndex(where: { $0.id == target.layerID })
        else { throw WSSMaskError.stale }
        switch (target.location, state.workingModel.layers[index].content) {
        case (.imageEffect(let id), .image(let image)):
            guard
                let address = identity.checkedAddress(
                    in: state.workingModel, layer: target.layerID, effect: id),
                image.effects[address.effectIndex].scalarMaskSlot == target.slot
            else { throw WSSMaskError.stale }
            let effect = image.effects[address.effectIndex]
            return WSSScalarMaskContext(
                layerIndex: index, effectIndex: address.effectIndex,
                transform: try image.transform.native(), size: image.transform.size,
                path: effect.maskPath, definition: effect.maskDefinition)
        case (.layer, .rain(let rain)):
            guard target.slot == .rain, identity.layers[index].effects.isEmpty else {
                throw WSSMaskError.stale
            }
            let r = rain.region
            return WSSScalarMaskContext(
                layerIndex: index, effectIndex: nil,
                transform: WSSImageTransform(
                    center: SIMD2(r.x + r.width / 2, r.y + r.height / 2),
                    size: SIMD2(r.width, r.height)), size: [r.width, r.height],
                path: rain.mask?.asset, definition: rain.mask)
        default: throw WSSMaskError.unsupported
        }
    }
    func settingMask(_ definition: WSSNativeImageDefinition?, target: WSSMaskTarget) throws
        -> WSSSceneDocumentV1
    {
        let context = try maskContext(target)
        var model = state.workingModel
        switch model.layers[context.layerIndex].content {
        case .image(var image):
            guard let effect = context.effectIndex else { throw WSSMaskError.stale }
            image.effects[effect] = try image.effects[effect].settingMask(
                slot: target.slot, definition: definition)
            model.layers[context.layerIndex].content = .image(image)
        case .rain(var rain):
            rain.mask = definition
            model.layers[context.layerIndex].content = .rain(rain)
        default: throw WSSMaskError.unsupported
        }
        return model
    }
}
