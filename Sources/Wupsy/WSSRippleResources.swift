import MetalKit

// Immutable native resources, shared safely by in-flight draws. Six analytical
// components evaluated directly; one image read and one linear scalar mask read.
final class WSSRippleResources {
    struct Mask {
        let texture: MTLTexture
        let uv: SIMD2<Float>
    }
    struct Uniforms {
        var geometry: SIMD4<Float>
        var maskUV: SIMD4<Float>
        var waves:
            (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        var vectors:
            (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    }
    let detail: WSSRippleDetailResources?
    let masks: [WSSAssetID: Mask]
    let white: MTLTexture
    let sampler: MTLSamplerState
    let replace: MTLRenderPipelineState
    let over: MTLRenderPipelineState
    var textureBytes: Int {
        masks.values.reduce(white.allocatedSize) { $0 + $1.texture.allocatedSize }
    }
    init(scene: WSSScene, assets: any WSSImageAssetSource, device: MTLDevice, library: MTLLibrary)
        throws
    {
        detail =
            try scene.imageLayers.contains { layer in
                layer.effects.contains {
                    if let effect = $0.samplingRipple { return effect.lateralDetail != 1 }
                    return false
                }
            } ? WSSRippleDetailResources(device: device) : nil
        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.vertexFunction = library.makeFunction(name: "imageQuad")
        pipeline.fragmentFunction = library.makeFunction(name: "rippleImage")
        let color = pipeline.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        replace = try device.makeRenderPipelineState(descriptor: pipeline)
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        over = try device.makeRenderPipelineState(descriptor: pipeline)
        func upload(_ asset: WSSMaskAsset) throws -> MTLTexture {
            guard (1...8192).contains(asset.width), (1...8192).contains(asset.height),
                asset.pixels.count == asset.width * asset.height,
                asset.uvScale.x.isFinite, asset.uvScale.y.isFinite,
                asset.uvScale.x > 0, asset.uvScale.x <= 1,
                asset.uvScale.y > 0, asset.uvScale.y <= 1
            else { throw WSSSceneError.invalid("ripple mask dimensions or UV") }
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,
                width: asset.width, height: asset.height, mipmapped: false)
            d.storageMode = .shared
            d.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: d) else {
                throw WSSSceneError.invalid("ripple mask allocation")
            }
            asset.pixels.withUnsafeBytes {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, asset.width, asset.height),
                    mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: asset.width)
            }
            return texture
        }
        var loaded: [WSSAssetID: Mask] = [:]
        var bytes = 0
        for layer in scene.imageLayers {
            for effect in layer.effects.compactMap(\.samplingRipple) {
                if let id = effect.mask?.asset, loaded[id] == nil {
                    let asset = try assets.mask(for: id)
                    bytes += asset.pixels.count
                    guard bytes <= 32 * 1024 * 1024 else {
                        throw WSSSceneError.invalid("ripple mask budget")
                    }
                    loaded[id] = Mask(texture: try upload(asset), uv: asset.uvScale)
                }
            }
        }
        masks = loaded
        white = try upload(
            WSSMaskAsset(width: 1, height: 1, pixels: Data([255]), uvScale: SIMD2(1, 1)))
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        guard let sampling = device.makeSamplerState(descriptor: s) else {
            throw WSSSceneError.invalid("ripple mask sampler")
        }
        sampler = sampling
    }
    func bind(
        _ effect: WSSRippleEffect, size: SIMD2<Float>, time: Double,
        composition: WSSImageLayer.Composition, encoder: MTLRenderCommandEncoder
    ) throws {
        if effect.lateralDetail != 1, let detail {
            try detail.bind(
                effect, size: size, time: time, composition: composition,
                owner: self, encoder: encoder)
            return
        }
        let mask = effect.mask.flatMap { masks[$0.asset] }
        let waves = effect.waves
        let w = try waves.map { wave in
            SIMD4(
                Float(wave.k.x * 2 * .pi), Float(wave.k.y * 2 * .pi),
                try effect.phase(wave, at: time), 0)
        }
        let v = waves.map { SIMD4($0.displacement.x, $0.displacement.y, 0, 0) }
        var uniforms = Uniforms(
            geometry: SIMD4(size.x, size.y, effect.amplitude, 0),
            maskUV: SIMD4(mask?.uv.x ?? 1, mask?.uv.y ?? 1, 0, 0),
            waves: (w[0], w[1], w[2], w[3], w[4], w[5]),
            vectors: (v[0], v[1], v[2], v[3], v[4], v[5]))
        encoder.setRenderPipelineState(composition == .replace ? replace : over)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentTexture(mask?.texture ?? white, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 1)
    }
    static let shader = """
        struct RippleImageUniforms { float4 geometry, maskUV; float4 waves[6]; float4 vectors[6]; };
        fragment float4 rippleImage(ImageVertex v [[stage_in]],
            constant ImageTransform &t [[buffer(0)]], constant RippleImageUniforms &r [[buffer(1)]],
            texture2d<float> image [[texture(0)]], texture2d<float> mask [[texture(1)]],
            sampler filtering [[sampler(0)]], sampler maskFiltering [[sampler(1)]]) {
            float2 p = v.uv * r.geometry.xy;
            float2 delta = float2(0);
            for (uint i = 0; i < 6; ++i)
                delta += r.vectors[i].xy * sin(dot(p, r.waves[i].xy) + r.waves[i].z);
            float influence = clamp(mask.sample(maskFiltering, v.uv * r.maskUV.xy).r, 0.0, 1.0);
            float2 uv = v.uv + delta * (r.geometry.z * influence) / r.geometry.xy;
            // Keep the original image LOD footprint, including at zero-mask pixels.
            // Mask data never passes through RGB/sRGB upload or premultiplication.
            float4 pixel = image.sample(filtering, uv * t.sampling.xy,
                gradient2d(dfdx(v.uv * t.sampling.xy), dfdy(v.uv * t.sampling.xy)));
            if (t.sampling.w > 0.5)
                return float4(pixel.a > 0 ? pixel.rgb / pixel.a : float3(0), pixel.a * t.sampling.z);
            return pixel * t.sampling.z;
        }
        """
}
