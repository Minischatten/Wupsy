import MetalKit
import simd

// Additive independently authored lateral-detail path. The original six-wave
// generator, shader and uniforms remain untouched for lateralDetail == 1.
final class WSSRippleDetailResources {
    struct Uniforms {
        var geometry: SIMD4<Float>
        var maskUV: SIMD4<Float>
        var waves:
            (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        var vectors:
            (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        var lateral:
            (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    }
    let replace: MTLRenderPipelineState
    let over: MTLRenderPipelineState
    init(device: MTLDevice) throws {
        let library = try device.makeLibrary(
            source: WSSStaticResources.shader + Self.shader, options: nil)
        let p = MTLRenderPipelineDescriptor()
        p.vertexFunction = library.makeFunction(name: "imageQuad")
        p.fragmentFunction = library.makeFunction(name: "rippleDetailImage")
        let color = p.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        replace = try device.makeRenderPipelineState(descriptor: p)
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        over = try device.makeRenderPipelineState(descriptor: p)
    }
    static func uniforms(
        _ effect: WSSRippleEffect, size: SIMD2<Float>, uv: SIMD2<Float>,
        time: Double
    ) throws -> Uniforms {
        func pack(_ waves: [WSSRippleEffect.Wave]) throws -> [SIMD4<Float>] {
            try waves.map {
                SIMD4(
                    Float($0.k.x * 2 * .pi), Float($0.k.y * 2 * .pi),
                    try effect.phase($0, at: time), 0)
            }
        }
        let w = try pack(effect.waves)
        let x = try pack(effect.lateralWaves)
        let axis = effect.lateralAxis
        let v = effect.waves.map {
            SIMD4($0.displacement.x, $0.displacement.y, simd_dot(axis, $0.displacement), 0)
        }
        return Uniforms(
            geometry: SIMD4(size.x, size.y, effect.amplitude, 0),
            maskUV: SIMD4(uv.x, uv.y, axis.x, axis.y),
            waves: (w[0], w[1], w[2], w[3], w[4], w[5]),
            vectors: (v[0], v[1], v[2], v[3], v[4], v[5]),
            lateral: (x[0], x[1], x[2], x[3], x[4], x[5]))
    }
    func bind(
        _ effect: WSSRippleEffect, size: SIMD2<Float>, time: Double,
        composition: WSSImageLayer.Composition, owner: WSSRippleResources,
        encoder: MTLRenderCommandEncoder
    ) throws {
        let mask = effect.mask.flatMap { owner.masks[$0.asset] }
        var u = try Self.uniforms(
            effect, size: size,
            uv: mask?.uv ?? SIMD2(1, 1), time: time)
        encoder.setRenderPipelineState(composition == .replace ? replace : over)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentTexture(mask?.texture ?? owner.white, index: 1)
        encoder.setFragmentSamplerState(owner.sampler, index: 1)
    }

    static let shader = """
        struct RippleDetailUniforms {
            float4 geometry, maskUV;
            float4 waves[6], vectors[6], lateral[6];
        };
        float2 rippleDetailDelta(float2 p, constant RippleDetailUniforms &r) {
            float2 delta = float2(0);
            for (uint i = 0; i < 6; ++i)
                delta += r.vectors[i].xy * sin(dot(p, r.waves[i].xy) + r.waves[i].z);
            float lateral = 0;
            for (uint i = 0; i < 6; ++i)
                lateral += r.vectors[i].z * sin(dot(p, r.lateral[i].xy) + r.lateral[i].z);
            float2 axis = r.maskUV.zw;
            if (axis.y == 0) return float2(axis.x * lateral, delta.y);
            if (axis.x == 0) return float2(delta.x, axis.y * lateral);
            return delta + axis * (lateral - dot(axis, delta));
        }
        fragment float4 rippleDetailImage(ImageVertex v [[stage_in]],
            constant ImageTransform &t [[buffer(0)]], constant RippleDetailUniforms &r [[buffer(1)]],
            texture2d<float> image [[texture(0)]], texture2d<float> mask [[texture(1)]],
            sampler filtering [[sampler(0)]], sampler maskFiltering [[sampler(1)]]) {
            float2 p = v.uv * r.geometry.xy;
            float2 delta = rippleDetailDelta(p, r);
            float influence = clamp(mask.sample(maskFiltering, v.uv * r.maskUV.xy).r, 0.0, 1.0);
            float2 uv = v.uv + delta * (r.geometry.z * influence) / r.geometry.xy;
            float4 pixel = image.sample(filtering, uv * t.sampling.xy,
                gradient2d(dfdx(v.uv * t.sampling.xy), dfdy(v.uv * t.sampling.xy)));
            if (t.sampling.w > 0.5)
                return float4(pixel.a > 0 ? pixel.rgb / pixel.a : float3(0), pixel.a * t.sampling.z);
            return pixel * t.sampling.z;
        }
        """
}
