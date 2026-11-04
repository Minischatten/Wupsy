import MetalKit

// Own native map data and bounded three-window image transport. No engine assets.
final class WSSFlowResources {
    struct Uniforms {
        var geometry: SIMD4<Float>
        var edge: SIMD4<Float>
    }
    struct RegionTextures {
        let id: WSSAssetID
        let size: SIMD2<Float>
        let region: MTLTexture
        let distance: MTLTexture
    }
    let regions: [RegionTextures]
    var regionTextureBytes: Int {
        regions.reduce(0) { $0 + $1.region.allocatedSize + $1.distance.allocatedSize }
    }
    let fields: WSSVectorFieldResources
    var maps: [WSSAssetID: WSSVectorFieldResources.Field] { fields.fields }
    var white: MTLTexture { fields.white }
    var sampler: MTLSamplerState { fields.sampler }
    let replace: MTLRenderPipelineState
    let over: MTLRenderPipelineState
    var textureBytes: Int { fields.textureBytes }
    init(
        scene: WSSScene, assets: any WSSImageAssetSource, device: MTLDevice,
        sharedFields: WSSVectorFieldResources? = nil, referenceShader: String? = nil
    ) throws {
        var regions: [RegionTextures] = []
        var regionBytes = 0
        for layer in scene.imageLayers {
            for effect in layer.effects {
                guard case .flow(let flow) = effect, let id = flow.flowRegion else { continue }
                let size = layer.transform.localSize
                if regions.contains(where: { $0.id == id && $0.size == size }) { continue }
                let region = try assets.flowRegion(for: id)
                try region.validate()
                guard region.pixels.count * 5 <= WSSFlowRegionDistanceCache.byteLimit - regionBytes
                else { throw WSSVectorFieldEditError.budget }
                let distances = try WSSFlowRegionDistanceCache.shared.distance(region, size: size)
                func texture(_ format: MTLPixelFormat, bytes: UnsafeRawPointer, stride: Int) throws
                    -> MTLTexture
                {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: format, width: region.width, height: region.height,
                        mipmapped: false)
                    descriptor.storageMode = .shared
                    descriptor.usage = .shaderRead
                    guard let texture = device.makeTexture(descriptor: descriptor) else {
                        throw WSSVectorFieldEditError.budget
                    }
                    texture.replace(
                        region: MTLRegionMake2D(0, 0, region.width, region.height), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: region.width * stride)
                    return texture
                }
                let mask = try region.pixels.withUnsafeBytes {
                    try texture(.r8Unorm, bytes: $0.baseAddress!, stride: 1)
                }
                let distance = try distances.withUnsafeBytes {
                    try texture(.r32Float, bytes: $0.baseAddress!, stride: 4)
                }
                regionBytes += mask.allocatedSize + distance.allocatedSize
                guard regionBytes <= WSSFlowRegionDistanceCache.byteLimit else {
                    throw WSSVectorFieldEditError.budget
                }
                regions.append(RegionTextures(id: id, size: size, region: mask, distance: distance))
            }
        }
        self.regions = regions
        let library = try device.makeLibrary(
            source: WSSStaticResources.shader + (referenceShader ?? Self.shader), options: nil)
        let p = MTLRenderPipelineDescriptor()
        p.vertexFunction = library.makeFunction(name: "imageQuad")
        p.fragmentFunction = library.makeFunction(name: "flowImage")
        let color = p.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        replace = try device.makeRenderPipelineState(descriptor: p)
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        over = try device.makeRenderPipelineState(descriptor: p)
        let ids = scene.imageLayers.flatMap { layer in
            layer.effects.compactMap { effect -> WSSAssetID? in
                if case .flow(let flow) = effect { return flow.flowMap }
                return nil
            }
        }
        fields =
            try sharedFields
            ?? WSSVectorFieldResources(ids: ids, device: device) {
                try assets.vectorField(for: $0)
            }
    }
    // Editor-only immutable override. Pipelines and all unaffected resources remain
    // shared; uploads never overwrite textures referenced by an in-flight frame.
    init(
        effect: WSSFlowEffect, size: SIMD2<Float>, field: WSSVectorFieldAsset,
        region: WSSFlowRegion?, sharing original: WSSFlowResources, device: MTLDevice
    ) throws {
        replace = original.replace
        over = original.over
        fields = try WSSVectorFieldResources(ids: [effect.flowMap], device: device) { _ in field }
        var updated = original.regions
        if let id = effect.flowRegion {
            guard let region else { throw WSSVectorFieldEditError.invalid }
            try region.validate()
            let distances = try WSSFlowRegionDistanceCache.shared.distance(region, size: size)
            func upload(_ format: MTLPixelFormat, _ bytes: UnsafeRawPointer, _ stride: Int) throws
                -> MTLTexture
            {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: format, width: region.width, height: region.height,
                    mipmapped: false)
                descriptor.storageMode = .shared
                descriptor.usage = .shaderRead
                guard let texture = device.makeTexture(descriptor: descriptor) else {
                    throw WSSVectorFieldEditError.budget
                }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, region.width, region.height), mipmapLevel: 0,
                    withBytes: bytes, bytesPerRow: region.width * stride)
                return texture
            }
            let mask = try region.pixels.withUnsafeBytes {
                try upload(.r8Unorm, $0.baseAddress!, 1)
            }
            let distance = try distances.withUnsafeBytes {
                try upload(.r32Float, $0.baseAddress!, 4)
            }
            updated.removeAll { $0.id == id && $0.size == size }
            updated.append(RegionTextures(id: id, size: size, region: mask, distance: distance))
        } else if region != nil {
            throw WSSVectorFieldEditError.invalid
        }
        regions = updated
        guard regionTextureBytes <= WSSFlowRegionDistanceCache.byteLimit else {
            throw WSSVectorFieldEditError.budget
        }
    }
    func isActive(_ effect: WSSFlowEffect) -> Bool {
        !effect.isIdentity && maps[effect.flowMap]?.isNeutral == false
    }
    func bind(
        _ effect: WSSFlowEffect, size: SIMD2<Float>, time: Double,
        composition: WSSImageLayer.Composition, encoder: MTLRenderCommandEncoder,
        boundField: WSSVectorFieldResources.Field? = nil
    ) throws {
        guard let map = boundField ?? maps[effect.flowMap] else {
            throw WSSSceneError.invalid("missing flow map")
        }
        var u = Uniforms(
            geometry: SIMD4(size.x, size.y, effect.strength, try effect.phase(at: time)),
            edge: SIMD4(
                effect.edgeProtectionPixels, effect.edgeProtectionMode == .region ? 1 : 0, 0, 0))
        encoder.setRenderPipelineState(composition == .replace ? replace : over)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentTexture(map.vectors, index: 1)
        encoder.setFragmentTexture(map.coverage ?? white, index: 2)
        if effect.edgeProtectionMode == .region {
            guard
                let region = regions.first(where: { $0.id == effect.flowRegion && $0.size == size })
            else { throw WSSVectorFieldEditError.invalid }
            encoder.setFragmentTexture(region.region, index: 3)
            encoder.setFragmentTexture(region.distance, index: 4)
        } else {
            encoder.setFragmentTexture(white, index: 3)
            encoder.setFragmentTexture(white, index: 4)
        }
        encoder.setFragmentSamplerState(sampler, index: 1)
    }
    static let shader = """
        struct FlowUniforms { float4 geometry; float4 edge; };
        fragment float4 flowImage(ImageVertex v [[stage_in]],
            constant ImageTransform &t [[buffer(0)]], constant FlowUniforms &f [[buffer(1)]],
            texture2d<float> image [[texture(0)]], texture2d<float> vectors [[texture(1)]],
            texture2d<float> coverage [[texture(2)]], sampler filtering [[sampler(0)]],
            sampler mapFiltering [[sampler(1)]], texture2d<float> region [[texture(3)]],
            texture2d<float> distance [[texture(4)]]) {
            float2 uv = v.uv;
            float2 gx = dfdx(uv*t.sampling.xy), gy = dfdy(uv*t.sampling.xy);
            float4 original = image.sample(filtering,uv*t.sampling.xy,gradient2d(gx,gy));
            float2 vector = vectors.sample(mapFiltering,uv).rg;
            float amount = coverage.sample(mapFiltering,uv).r;
            // N=0 preserves the original arithmetic path, without a support multiply.
            // Inspect the stored positive value before GPU denormal flushing can turn it into zero.
            if (f.edge.y > 0.5) {
                uint2 dimensions = uint2(region.get_width(),region.get_height());
                uint2 cell = min(uint2(max(uv,float2(0))*float2(dimensions)),dimensions-1);
                amount *= region.read(cell).r;
                if ((as_type<uint>(f.edge.x) & 0x7fffffffu) != 0)
                {
                    float2 p = uv*f.geometry.xy;
                    float imageEdge = min(min(p.x,p.y),min(f.geometry.x-p.x,f.geometry.y-p.y));
                    amount *= smoothstep(0.0,f.edge.x,max(0.0,min(imageEdge,distance.sample(mapFiltering,uv).r)));
                }
            } else if ((as_type<uint>(f.edge.x) & 0x7fffffffu) != 0) {
                float2 p = uv*f.geometry.xy;
                float e = min(min(p.x,p.y),min(f.geometry.x-p.x,f.geometry.y-p.y));
                amount *= smoothstep(f.edge.x/2+0.5,f.edge.x+0.5,e);
            }
            float4 pixel = original;
            if (amount > 0 && any(vector != float2(0))) {
                float4 sum = float4(0);
                float weightSum = 0;
                for (uint i=0; i<3; ++i) {
                    float age = fract(f.geometry.w + float(i)/3.0);
                    float weight = sin(M_PI_F*age);
                    weight *= weight;
                    float2 offset = 2*f.geometry.z*(age-0.5)*vector/f.geometry.xy;
                    sum += weight*image.sample(filtering,(uv-offset)*t.sampling.xy,gradient2d(gx,gy));
                    weightSum += weight;
                }
                pixel = mix(original,sum/weightSum,amount);
            }
            if (t.sampling.w > 0.5)
                return float4(pixel.a > 0 ? pixel.rgb/pixel.a : float3(0),pixel.a*t.sampling.z);
            return pixel*t.sampling.z;
        }
        """
}
