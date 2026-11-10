import Metal

// Preserve directional admission's deterministic upload budgets without shader
// compilation, image uploads or region-distance construction. Shared IDs can
// split after an edit even though each field keeps its dimensions. Empty
// allocation probes give the same device-specific allocatedSize as the renderer;
// probes are released individually, never retained as another complete preview.
enum WSSDirectionResourceValidation {
    static func validate(_ scene: WSSScene, assets: WSSNativeAssets) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw WSSSceneError.invalid("Metal unavailable")
        }
        func allocation(_ width: Int, _ height: Int, _ format: MTLPixelFormat) throws -> Int {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw WSSVectorFieldEditError.budget
            }
            return texture.allocatedSize
        }
        var fields: Set<WSSAssetID> = []
        var regions: [(WSSAssetID, SIMD2<Float>)] = []
        var fieldBytes = try allocation(1, 1, .r8Unorm)
        var regionBytes = 0
        for layer in scene.imageLayers {
            for effect in layer.effects {
                try Task.checkCancellation()
                guard case .flow(let flow) = effect else { continue }
                if fields.insert(flow.flowMap).inserted {
                    let field = try assets.vectorField(for: flow.flowMap)
                    guard
                        field.vectors.count + (field.coverage?.count ?? 0)
                            <= WSSVectorFieldAsset.byteLimit - fieldBytes
                    else { throw WSSVectorFieldEditError.budget }
                    fieldBytes += try allocation(field.width, field.height, .rg16Float)
                    if field.coverage != nil {
                        fieldBytes += try allocation(field.width, field.height, .r8Unorm)
                    }
                    guard fieldBytes <= WSSVectorFieldAsset.byteLimit else {
                        throw WSSVectorFieldEditError.budget
                    }
                }
                if let id = flow.flowRegion,
                    !regions.contains(where: { $0.0 == id && $0.1 == layer.transform.localSize })
                {
                    let region = try assets.flowRegion(for: id)
                    guard
                        region.pixels.count * 5 <= WSSFlowRegionDistanceCache.byteLimit
                            - regionBytes
                    else { throw WSSVectorFieldEditError.budget }
                    regionBytes += try allocation(region.width, region.height, .r8Unorm)
                    regionBytes += try allocation(region.width, region.height, .r32Float)
                    guard regionBytes <= WSSFlowRegionDistanceCache.byteLimit else {
                        throw WSSVectorFieldEditError.budget
                    }
                    regions.append((id, layer.transform.localSize))
                }
            }
        }
        var masks: Set<WSSAssetID> = []
        var maskBytes = 0
        var maskTextureBytes = 0
        for node in scene.layers {
            guard case .rain(let layer) = node, let id = layer.mask?.asset,
                masks.insert(id).inserted
            else { continue }
            let mask = try assets.mask(for: id)
            maskBytes += mask.pixels.count
            guard maskBytes <= 32 * 1024 * 1024 else { throw WSSMaskError.budget }
            maskTextureBytes += try allocation(mask.width, mask.height, .r8Unorm)
        }
        var images: Set<WSSAssetID> = []
        var decodedBytes = fieldBytes + regionBytes + maskTextureBytes
        for layer in scene.imageLayers where images.insert(layer.asset).inserted {
            try Task.checkCancellation()
            let image = try assets.image(for: layer.asset)
            decodedBytes += image.width * image.height * 4
            guard decodedBytes <= 128 * 1024 * 1024 else {
                throw WSSSceneError.decodedImageBudget
            }
        }
    }
}
