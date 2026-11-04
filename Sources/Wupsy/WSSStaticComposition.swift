import Foundation
import Metal

enum WSSStaticComposition {
    static func model(_ model: WSSSceneDocumentV1) -> WSSSceneDocumentV1 {
        var result = model
        result.layers = model.layers.compactMap { layer in
            guard case .image(var image) = layer.content else { return nil }
            image.effects = []
            var node = layer
            node.content = .image(image)
            return node
        }
        return result
    }
    static func scene(_ model: WSSSceneDocumentV1) throws -> WSSScene {
        WSSScene(
            width: model.canvas.width, height: model.canvas.height,
            background: SIMD3(model.background[0], model.background[1], model.background[2]),
            layers: try model.layers.map { try $0.makeNative() })
    }
}
actor WSSStaticCanvasPreparation {
    func prepare(
        _ model: WSSSceneDocumentV1, handle: WSSProjectHandle,
        catalog: [String: WSSContentFingerprint],
        sessionAssets: [String: WSSImageGeneration] = [:]
    ) throws -> WSSStaticResources {
        try Task.checkCancellation()
        let capture = WSSProjectReadCapture()
        var assets = try model.assetSource(root: handle.root)
        assets.sessionAssets = sessionAssets
        assets.didRead = { try capture.record($0, $1) }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw WSSSceneError.invalid("Metal unavailable")
        }
        let resources = try WSSStaticResources(
            scene: WSSStaticComposition.scene(model), assets: assets, device: device,
            staticCanvas: true)
        guard capture.assets == catalog.filter({ model.referencedPaths.contains($0.key) }),
            model.referencedPaths.isSubset(of: Set(catalog.keys))
        else { throw WSSSaveError.externalConflict }
        try Task.checkCancellation()
        return resources
    }
}
