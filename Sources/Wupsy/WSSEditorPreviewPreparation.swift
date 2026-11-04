import Foundation
import Metal

actor WSSEditorPreviewPreparation {
    func prepare(
        _ model: WSSSceneDocumentV1, basis: WSSProjectDiskBasis, handle: WSSProjectHandle,
        sessionAssets: [String: WSSImageGeneration] = [:]
    )
        throws -> WSSStaticResources
    {
        try Task.checkCancellation()
        guard try WSSProjectDiskBasis.Identity(handle) == basis.identity else {
            throw WSSSaveError.targetDisappeared
        }
        let capture = WSSProjectReadCapture()
        var assets = try model.assetSource(root: handle.root)
        assets.sessionAssets = sessionAssets
        assets.didRead = { try capture.record($0, $1) }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw WSSSceneError.invalid("Metal unavailable")
        }
        let resources = try WSSStaticResources(scene: model.scene(), assets: assets, device: device)
        guard model.referencedPaths.isSubset(of: Set(basis.assets.keys)),
            capture.assets == basis.assets.filter({ model.referencedPaths.contains($0.key) })
        else { throw WSSSaveError.externalConflict }
        guard try WSSProjectDiskBasis.Identity(handle) == basis.identity else {
            throw WSSSaveError.targetDisappeared
        }
        return resources
    }
}
