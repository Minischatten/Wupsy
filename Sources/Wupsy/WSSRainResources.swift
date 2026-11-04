import MetalKit

// Analytic streak renderer: immutable instances, optional scalar mask, no per-frame simulation.
final class WSSRainResources {
    struct Prepared {
        let population: WSSRainPopulation
        let buffer: MTLBuffer?
    }
    struct Mask {
        let texture: MTLTexture
        let uv: SIMD2<Float>
    }
    let masks: [WSSAssetID: Mask]
    let sampler: MTLSamplerState?
    let maskedSourceOver: MTLRenderPipelineState
    let maskedAdditive: MTLRenderPipelineState
    var textureBytes: Int { masks.values.reduce(0) { $0 + $1.texture.allocatedSize } }
    struct Uniforms {
        var projection: SIMD4<Float>
        var region: SIMD4<Float>
        var motion: SIMD4<Float>
        var shape: SIMD4<Float>
        var phases0: SIMD4<Float>
        var phases1: SIMD4<Float>
        var maskUV: SIMD4<Float>
    }
    let layers: [Int: Prepared]
    let sourceOver: MTLRenderPipelineState
    let additive: MTLRenderPipelineState
    var bufferBytes: Int { layers.values.reduce(0) { $0 + ($1.buffer?.length ?? 0) } }
    init(scene: WSSScene, assets: any WSSImageAssetSource, device: MTLDevice, library: MTLLibrary)
        throws
    {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "rainQuad")
        descriptor.fragmentFunction = library.makeFunction(name: "rainStreak")
        let c = descriptor.colorAttachments[0]!
        c.pixelFormat = .bgra8Unorm
        c.isBlendingEnabled = true
        // Native premultiplied RGB. Additive changes RGB only; alpha remains source-over.
        c.sourceRGBBlendFactor = .one
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.sourceAlphaBlendFactor = .one
        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        sourceOver = try device.makeRenderPipelineState(descriptor: descriptor)
        c.destinationRGBBlendFactor = .one
        additive = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "rainMaskedStreak")
        maskedAdditive = try device.makeRenderPipelineState(descriptor: descriptor)
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        maskedSourceOver = try device.makeRenderPipelineState(descriptor: descriptor)
        var loaded: [WSSAssetID: Mask] = [:]
        var bytes = 0
        for node in scene.layers {
            guard case .rain(let layer) = node, let id = layer.mask?.asset, loaded[id] == nil else {
                continue
            }
            let asset = try assets.mask(for: id)
            guard (1...8192).contains(asset.width), (1...8192).contains(asset.height),
                asset.pixels.count == asset.width * asset.height,
                asset.uvScale.x.isFinite, asset.uvScale.y.isFinite,
                asset.uvScale.x > 0, asset.uvScale.x <= 1,
                asset.uvScale.y > 0, asset.uvScale.y <= 1
            else { throw WSSMaskError.invalid }
            bytes += asset.pixels.count
            guard bytes <= 32 * 1024 * 1024 else { throw WSSMaskError.budget }
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,
                width: asset.width, height: asset.height, mipmapped: false)
            d.storageMode = .shared
            d.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: d) else { throw WSSMaskError.budget }
            asset.pixels.withUnsafeBytes {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, asset.width, asset.height),
                    mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: asset.width)
            }
            loaded[id] = Mask(texture: texture, uv: asset.uvScale)
        }
        masks = loaded
        if loaded.isEmpty {
            sampler = nil
        } else {
            let settings = MTLSamplerDescriptor()
            settings.minFilter = .linear
            settings.magFilter = .linear
            settings.sAddressMode = .clampToEdge
            settings.tAddressMode = .clampToEdge
            guard let value = device.makeSamplerState(descriptor: settings) else {
                throw WSSMaskError.invalid
            }
            sampler = value
        }
        var prepared: [Int: Prepared] = [:]
        for (index, node) in scene.layers.enumerated() {
            guard case .rain(let layer) = node else { continue }
            let population = try WSSRainPopulation(layer)
            let buffer: MTLBuffer?
            if population.instances.isEmpty {
                buffer = nil
            } else {
                buffer = population.instances.withUnsafeBytes {
                    device.makeBuffer(
                        bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
                }
                guard buffer != nil else { throw WSSSceneError.invalid("rain instance allocation") }
            }
            prepared[index] = Prepared(population: population, buffer: buffer)
        }
        layers = prepared
    }
    func encode(
        _ index: Int, encoder: MTLRenderCommandEncoder, canvas: SIMD2<Float>, crop: SIMD2<Float>,
        time: Double
    ) {
        guard let prepared = layers[index], let buffer = prepared.buffer else { return }
        let p = prepared.population
        let l = p.layer
        let e = l.rain
        let r = l.region
        let mask = l.mask.flatMap { masks[$0.asset] }
        var u = Uniforms(
            projection: SIMD4(canvas.x, canvas.y, canvas.x * crop.x, canvas.y * crop.y),
            region: SIMD4(r.x, r.y, r.width, r.height),
            motion: SIMD4(e.heading.x, e.heading.y, p.crossSpan, p.travelSpan),
            shape: SIMD4(e.length, e.width, e.profiles == nil ? 0 : 1, 0),
            phases0: SIMD4(
                p.phase(at: time, group: 0), p.phase(at: time, group: 1),
                p.phase(at: time, group: 2), p.phase(at: time, group: 3)),
            phases1: SIMD4(
                p.phase(at: time, group: 4), p.phase(at: time, group: 5),
                p.phase(at: time, group: 6), p.phase(at: time, group: 7)),
            maskUV: SIMD4(mask?.uv.x ?? 1, mask?.uv.y ?? 1, 0, 0))
        if let mask {
            encoder.setRenderPipelineState(
                l.composition == .additive ? maskedAdditive : maskedSourceOver)
            encoder.setFragmentTexture(mask.texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
        } else {
            encoder.setRenderPipelineState(l.composition == .additive ? additive : sourceOver)
        }
        encoder.setVertexBuffer(buffer, offset: 0, index: 1)
        encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(
            type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: p.instances.count)
    }
    static let shader = """
        struct RainInstance { float4 state, variation; };
        struct RainUniforms { float4 projection, region, motion, shape, phases0, phases1, maskUV; };
        struct RainVertex { float4 position [[position]]; float2 uv; float2 logical; float alpha; };
        vertex RainVertex rainQuad(uint corner [[vertex_id]], uint id [[instance_id]],
            constant RainUniforms &u [[buffer(0)]], device const RainInstance *instances [[buffer(1)]]) {
            float4 p = instances[id].state;
            uint group = uint(p.z);
            float phase = group < 4 ? u.phases0[group] : u.phases1[group-4];
            float depth = 0.65 + 0.7 * (float(group) + 0.5) / 8.0;
            float2 d = u.motion.xy, n = float2(-d.y, d.x);
            float2 uv = float2(corner % 2, corner / 2);
            float2 center = u.region.xy + u.region.zw * 0.5
                + n * ((p.x - 0.5) * u.motion.z)
                + d * ((fract(p.y + phase) - 0.5) * u.motion.w);
            float2 logical = center + n * ((uv.x - 0.5) * u.shape.y * depth)
                + d * ((uv.y - 0.5) * u.shape.x * depth * instances[id].variation.x);
            if (u.shape.z > 0) {
                logical = center + n * ((uv.x - 0.5) * instances[id].variation.y * depth)
                    + d * ((uv.y - 0.5) * instances[id].variation.x * depth);
            }
            float2 clip = (logical - u.projection.xy * 0.5) * 2.0 / u.projection.zw;
            return { float4(clip, 0, 1), uv, logical, p.w };
        }
        fragment float4 rainStreak(RainVertex v [[stage_in]], constant RainUniforms &u [[buffer(0)]]) {
            if (any(v.logical < u.region.xy) || any(v.logical > u.region.xy + u.region.zw)) discard_fragment();
            float cross = abs(v.uv.x * 2.0 - 1.0);
            float aa = max(fwidth(cross), 0.001);
            float body = (1.0 - smoothstep(0.15, 1.0, cross))
                * (1.0 - smoothstep(1.0-aa, 1.0, cross));
            float ends = smoothstep(0.0, 0.18, v.uv.y) * (1.0 - smoothstep(0.72, 1.0, v.uv.y));
            float alpha = clamp(v.alpha * body * ends, 0.0, 1.0);
            return float4(float3(alpha), alpha);
        }
        fragment float4 rainMaskedStreak(RainVertex v [[stage_in]], constant RainUniforms &u [[buffer(0)]],
            texture2d<float> mask [[texture(0)]], sampler filtering [[sampler(0)]]) {
            if (any(v.logical < u.region.xy) || any(v.logical > u.region.xy + u.region.zw)) discard_fragment();
            float cross = abs(v.uv.x * 2.0 - 1.0);
            float aa = max(fwidth(cross), 0.001);
            float body = (1.0 - smoothstep(0.15, 1.0, cross))
                * (1.0 - smoothstep(1.0-aa, 1.0, cross));
            float ends = smoothstep(0.0, 0.18, v.uv.y) * (1.0 - smoothstep(0.72, 1.0, v.uv.y));
            float alpha = clamp(v.alpha * body * ends, 0.0, 1.0);
            float2 local = (v.logical - u.region.xy) / u.region.zw;
            float2 maskUV = float2(local.x, 1.0 - local.y) * u.maskUV.xy;
            alpha *= mask.sample(filtering, maskUV).r;
            return float4(float3(alpha), alpha);
        }
        """
}
