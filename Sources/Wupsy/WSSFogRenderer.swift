import MetalKit

// Two independently drifting samples of Wupsy's periodic Clouds noise.
final class WSSFogRenderer {
    private let pipeline: MTLRenderPipelineState
    private let noise: MTLTexture
    private let repeating: MTLSamplerState
    var textureBytes: Int { noise.allocatedSize }

    private struct Uniforms {
        var domain: SIMD4<Float>
        var phases: SIMD4<Float>
        var bases: SIMD4<Float>
        var color: SIMD4<Float>
        var vertical: SIMD4<Float>
    }

    init(device: MTLDevice) throws {
        let library = try device.makeLibrary(
            source: WSSStaticResources.shader + Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "imageQuad")
        descriptor.fragmentFunction = library.makeFunction(name: "fogColor")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let size = WSSCloudsNoise.size
        let texture = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: size, height: size, mipmapped: false)
        texture.storageMode = .shared
        texture.usage = .shaderRead
        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.sAddressMode = .repeat
        sampler.tAddressMode = .repeat
        guard let noise = device.makeTexture(descriptor: texture),
            let repeating = device.makeSamplerState(descriptor: sampler)
        else { throw WSSSceneError.invalid("fog noise resources") }
        WSSCloudsNoise.pixels(seed: 0x464F_4721).withUnsafeBytes {
            noise.replace(
                region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: size)
        }
        self.noise = noise
        self.repeating = repeating
    }

    func encode(
        _ fog: WSSFogConfiguration, canvas: SIMD2<Float>, crop: SIMD2<Float>,
        time: Double, encoder: MTLRenderCommandEncoder
    ) throws {
        guard fog.density > 0 else { return }
        let coverage = min(fog.height, 1)
        let drawHeight = canvas.y * coverage
        var transform = WSSStaticResources.Uniforms(
            horizontal: SIMD4(canvas.x, 0, 0, canvas.x * crop.x),
            vertical: SIMD4(0, drawHeight, (drawHeight - canvas.y) / 2, canvas.y * crop.y),
            sampling: .zero)
        let primary = WSSCloudsEffect(velocity: SIMD2(fog.driftX, fog.driftY), scale: fog.scale)
        let secondary = WSSCloudsEffect(
            velocity: SIMD2(
                0.43 * fog.driftX + 0.19 * fog.driftY,
                0.47 * fog.driftY - 0.11 * fog.driftX),
            scale: fog.scale * 0.57)
        let primaryBasis = WSSCloudsNoise.orientation
        let secondaryBasis = WSSCloudsNoise.secondaryOrientation
        let a = try primary.phase(at: time, orientation: primaryBasis)
        let b = try secondary.phase(at: time, orientation: secondaryBasis)
        var uniforms = Uniforms(
            domain: SIMD4(
                canvas.x / primary.scale, drawHeight / primary.scale,
                canvas.x / secondary.scale, drawHeight / secondary.scale),
            phases: SIMD4(a.x, a.y, b.x, b.y),
            bases: SIMD4(primaryBasis.x, primaryBasis.y, secondaryBasis.x, secondaryBasis.y),
            color: SIMD4(fog.color.red, fog.color.green, fog.color.blue, fog.density),
            vertical: SIMD4(coverage, fog.height, fog.softness, 0))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&transform, length: MemoryLayout.size(ofValue: transform), index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(noise, index: 0)
        encoder.setFragmentSamplerState(repeating, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private static let shader = """
        struct FogUniforms { float4 domain, phases, bases, color, vertical; };
        fragment float4 fogColor(ImageVertex v [[stage_in]], constant FogUniforms &fog [[buffer(0)]],
            texture2d<float> noise [[texture(0)]], sampler repeating [[sampler(0)]]) {
            float2 a = v.uv * fog.domain.xy;
            float2 b = v.uv * fog.domain.zw;
            float4 r = fog.bases;
            a = float2(r.x*a.x - r.y*a.y, r.y*a.x + r.x*a.y);
            b = float2(r.z*b.x - r.w*b.y, r.w*b.x + r.z*b.y);
            float broad = noise.sample(repeating, a - fog.phases.xy).r;
            float detail = noise.sample(repeating, b - fog.phases.zw + float2(0.37, 0.61)).r;
            float softness = fog.vertical.z;
            float field = mix(broad, detail, mix(0.32, 0.18, softness));
            float structure = mix(smoothstep(0.10, 0.86, field), field, softness);
            float bottomY = (1.0 - v.uv.y) * fog.vertical.x;
            float top = fog.vertical.y;
            float fade = fog.vertical.x * mix(0.20, 0.48, softness);
            float envelope = 1.0 - smoothstep(top - fade, top, bottomY);
            float alpha = fog.color.a * envelope * mix(0.12, 1.0, structure);
            return float4(fog.color.rgb * alpha, alpha);
        }
        """
}
