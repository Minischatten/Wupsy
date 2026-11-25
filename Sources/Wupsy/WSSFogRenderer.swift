import MetalKit

struct WSSFogMasks {
    struct Mask {
        let texture: MTLTexture?
        let uvScale: SIMD2<Float>
    }

    let masks: [String: Mask]
    var textureBytes: Int {
        masks.values.reduce(0) { $0 + ($1.texture?.allocatedSize ?? 0) }
    }

    init(
        scene: WSSScene, assets: any WSSImageAssetSource, device: MTLDevice,
        upload: Bool = true
    ) throws {
        var masks: [String: Mask] = [:]
        var decodedBytes = 0
        for node in scene.layers {
            guard case .fog(let layer) = node, let definition = layer.mask,
                masks[definition.asset] == nil
            else { continue }
            try Task.checkCancellation()
            guard definition.filter == "linear", definition.edge == "clamp", !definition.mipmapped
            else { throw WSSMaskError.invalid }
            let asset = try assets.mask(for: WSSAssetID(value: definition.asset))
            let bitmap = try WSSMaskBitmap(asset)
            guard bitmap.width == definition.width, bitmap.height == definition.height,
                definition.uvScale == [bitmap.uvScale.x, bitmap.uvScale.y]
            else { throw WSSMaskError.invalid }
            decodedBytes += bitmap.pixels.count
            guard decodedBytes <= 32 * 1024 * 1024 else { throw WSSMaskError.budget }
            var texture: MTLTexture?
            if bitmap.pixels.contains(where: { $0 != 0 }) {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .r8Unorm, width: bitmap.width, height: bitmap.height,
                    mipmapped: false)
                descriptor.storageMode = .shared
                descriptor.usage = .shaderRead
                guard let allocation = device.makeTexture(descriptor: descriptor) else {
                    throw WSSMaskError.budget
                }
                if upload {
                    bitmap.pixels.withUnsafeBytes {
                        allocation.replace(
                            region: MTLRegionMake2D(0, 0, bitmap.width, bitmap.height),
                            mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: bitmap.width)
                    }
                }
                texture = allocation
            }
            masks[definition.asset] = Mask(texture: texture, uvScale: bitmap.uvScale)
        }
        self.masks = masks
    }

    func isEmpty(_ layer: WSSFogLayer) -> Bool {
        guard let path = layer.mask?.asset, let mask = masks[path] else { return false }
        return mask.texture == nil
    }
}

// Two independently drifting samples of Wupsy's periodic Clouds noise.
final class WSSFogRenderer {
    private let pipeline: MTLRenderPipelineState
    private let noise: MTLTexture
    private let repeating: MTLSamplerState
    private let maskSampler: MTLSamplerState
    var textureBytes: Int { noise.allocatedSize }

    private struct Uniforms {
        var domain: SIMD4<Float>
        var phases: SIMD4<Float>
        var bases: SIMD4<Float>
        var color: SIMD4<Float>
        var vertical: SIMD4<Float>
        var maskUV: SIMD4<Float>
    }

    init(device: MTLDevice) throws {
        let library = try device.makeLibrary(
            source: WSSStaticResources.shader + Self.verticalEnvelopeShader + Self.shader,
            options: nil)
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
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        guard let maskSampler = device.makeSamplerState(descriptor: sampler) else {
            throw WSSSceneError.invalid("fog mask sampler")
        }
        self.maskSampler = maskSampler
    }

    func encode(
        _ fog: WSSFogConfiguration, canvas: SIMD2<Float>, crop: SIMD2<Float>,
        time: Double, encoder: MTLRenderCommandEncoder, mask: WSSFogMasks.Mask? = nil
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
        let maskUV = mask?.uvScale ?? SIMD2(1, 1)
        var uniforms = Uniforms(
            domain: SIMD4(
                canvas.x / primary.scale, drawHeight / primary.scale,
                canvas.x / secondary.scale, drawHeight / secondary.scale),
            phases: SIMD4(a.x, a.y, b.x, b.y),
            bases: SIMD4(primaryBasis.x, primaryBasis.y, secondaryBasis.x, secondaryBasis.y),
            color: SIMD4(fog.color.red, fog.color.green, fog.color.blue, fog.density),
            vertical: SIMD4(coverage, fog.height, fog.softness, 0),
            maskUV: SIMD4(maskUV.x, maskUV.y, mask == nil ? 0 : 1, 0))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&transform, length: MemoryLayout.size(ofValue: transform), index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(noise, index: 0)
        encoder.setFragmentSamplerState(repeating, index: 0)
        encoder.setFragmentTexture(mask?.texture ?? noise, index: 1)
        encoder.setFragmentSamplerState(maskSampler, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    static let verticalEnvelopeShader = """
        float fogVerticalEnvelope(float bottomY, float height, float softness, float coverage) {
            float fade = coverage * mix(0.20, 0.48, softness);
            return 1.0 - smoothstep(height - fade, height, bottomY);
        }
        """

    private static let shader = """
        struct FogUniforms { float4 domain, phases, bases, color, vertical, maskUV; };
        fragment float4 fogColor(ImageVertex v [[stage_in]], constant FogUniforms &fog [[buffer(0)]],
            texture2d<float> noise [[texture(0)]], sampler repeating [[sampler(0)]],
            texture2d<float> mask [[texture(1)]], sampler maskSampler [[sampler(1)]]) {
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
            float envelope = fogVerticalEnvelope(bottomY, fog.vertical.y, softness, fog.vertical.x);
            float alpha = fog.color.a * envelope * mix(0.12, 1.0, structure);
            if (fog.maskUV.z > 0) {
                float2 canvasUV = float2(v.uv.x, 1.0 - bottomY);
                alpha *= mask.sample(maskSampler, canvasUV * fog.maskUV.xy).r;
            }
            return float4(fog.color.rgb * alpha, alpha);
        }
        """
}
