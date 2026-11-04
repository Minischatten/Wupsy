import MetalKit

// WSS-owned resources and independently designed appearance: three hierarchical samples
// of our CPU-generated tile, smooth density coverage, neutral white fog preserving
// the source alpha. No compatibility effect computation is used.
final class WSSCloudsResources {
    struct Mask {
        let texture: MTLTexture
        let uvScale: SIMD2<Float>
    }
    struct Uniforms {
        var domain: SIMD4<Float>
        var appearance: SIMD4<Float>
        var maskUV: SIMD4<Float>
        var detailPhases: SIMD4<Float>
        var secondary: SIMD4<Float>
        var controls: SIMD4<Float>
        var lightSteps: SIMD4<Float>
    }
    let noise: [UInt32: MTLTexture]
    let masks: [WSSAssetID: Mask]
    let white: MTLTexture
    let noiseSampler: MTLSamplerState
    let maskSampler: MTLSamplerState
    var textureBytes: Int {
        noise.values.reduce(white.allocatedSize) { $0 + $1.allocatedSize }
            + masks.values.reduce(0) { $0 + $1.texture.allocatedSize }
    }
    init(scene: WSSScene, assets: any WSSImageAssetSource, device: MTLDevice) throws {
        func upload(_ bytes: Data, width: Int, height: Int) throws -> MTLTexture {
            guard width > 0, height > 0, width <= 8192, height <= 8192,
                bytes.count == width * height
            else { throw WSSSceneError.invalid("mask pixels") }
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
            d.storageMode = .shared
            d.usage = .shaderRead
            guard let t = device.makeTexture(descriptor: d) else {
                throw WSSSceneError.invalid("scalar texture allocation")
            }
            bytes.withUnsafeBytes {
                t.replace(
                    region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: $0.baseAddress!, bytesPerRow: width)
            }
            return t
        }
        var generated: [UInt32: MTLTexture] = [:]
        var loaded: [WSSAssetID: Mask] = [:]
        var budget = 0
        for layer in scene.imageLayers {
            for case .clouds(let effect) in layer.effects {
                if generated[effect.seed] == nil {
                    generated[effect.seed] = try upload(
                        WSSCloudsNoise.pixels(seed: effect.seed),
                        width: WSSCloudsNoise.size, height: WSSCloudsNoise.size)
                }
                if let id = effect.mask?.asset, loaded[id] == nil {
                    let asset = try assets.mask(for: id)
                    budget += asset.pixels.count
                    guard budget <= 32 * 1024 * 1024,
                        asset.uvScale.x.isFinite, asset.uvScale.y.isFinite,
                        asset.uvScale.x > 0, asset.uvScale.x <= 1,
                        asset.uvScale.y > 0, asset.uvScale.y <= 1
                    else { throw WSSSceneError.invalid("mask budget or UV") }
                    loaded[id] = Mask(
                        texture: try upload(
                            asset.pixels,
                            width: asset.width, height: asset.height), uvScale: asset.uvScale)
                }
            }
        }
        noise = generated
        masks = loaded
        white = try upload(Data([255]), width: 1, height: 1)
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.sAddressMode = .repeat
        s.tAddressMode = .repeat
        guard let n = device.makeSamplerState(descriptor: s) else {
            throw WSSSceneError.invalid("noise sampler")
        }
        noiseSampler = n
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        guard let m = device.makeSamplerState(descriptor: s) else {
            throw WSSSceneError.invalid("mask sampler")
        }
        maskSampler = m
    }
    static let shader = """
        struct CloudsUniforms { float4 domain, appearance, maskUV, detailPhases; };
        fragment float4 cloudsColor(ImageVertex v [[stage_in]],
            constant ImageTransform &t [[buffer(0)]], constant CloudsUniforms &c [[buffer(1)]],
            texture2d<float> image [[texture(0)]], texture2d<float> noise [[texture(1)]],
            texture2d<float> mask [[texture(2)]], sampler filtering [[sampler(0)]],
            sampler repeating [[sampler(1)]], sampler maskFiltering [[sampler(2)]]) {
            float4 pixel = image.sample(filtering, v.uv * t.sampling.xy);
            float2 q = v.uv * c.domain.xy;
            q = float2(c.maskUV.z * q.x - c.maskUV.w * q.y,
                       c.maskUV.w * q.x + c.maskUV.z * q.y);
            float body = noise.sample(repeating, q - c.domain.zw).r;
            float middle = noise.sample(repeating, q * c.appearance.z + float2(0.31, 0.73) - c.detailPhases.xy).r;
            float fine = noise.sample(repeating, q * c.appearance.w + float2(0.83, 0.19) - c.detailPhases.zw).r;
            // Large connected shapes dominate. Bounded finer modulation adds
            // contour/interior variation without turning clear regions into noise.
            float field = clamp(body + (middle - 0.5) * 0.30 + (fine - 0.5) * 0.08, 0.0, 1.0);
            float threshold = 1.15 - c.appearance.y * 1.3;
            float shape = smoothstep(threshold - 0.12, threshold + 0.12, field);
            float interior = 0.55 + middle * 0.30 + fine * 0.15;
            // Preserve density endpoints and monotonic coverage, including full
            // configured effect at density=1, without another public parameter.
            interior = mix(interior, 1.0, smoothstep(0.8, 1.0, c.appearance.y));
            float coverage = shape * interior;
            float amount = coverage * c.appearance.x * mask.sample(maskFiltering, v.uv * c.maskUV.xy).r;
            pixel.rgb = mix(pixel.rgb, float3(pixel.a), amount);
            if (t.sampling.w > 0.5) {
                return float4(pixel.a > 0 ? pixel.rgb / pixel.a : float3(0), pixel.a * t.sampling.z);
            }
            return pixel * t.sampling.z;
        }
        """
    static let extendedShader = """
        struct ExtendedCloudsUniforms {
            float4 domain, appearance, maskUV, detailPhases, secondary, controls, lightSteps;
        };
        fragment float4 cloudsExtendedColor(ImageVertex v [[stage_in]],
            constant ImageTransform &t [[buffer(0)]], constant ExtendedCloudsUniforms &c [[buffer(1)]],
            texture2d<float> image [[texture(0)]], texture2d<float> noise [[texture(1)]],
            texture2d<float> mask [[texture(2)]], sampler filtering [[sampler(0)]],
            sampler repeating [[sampler(1)]], sampler maskFiltering [[sampler(2)]]) {
            float4 pixel = image.sample(filtering, v.uv * t.sampling.xy);
            float2 q = v.uv * c.domain.xy;
            q = float2(c.maskUV.z*q.x-c.maskUV.w*q.y, c.maskUV.w*q.x+c.maskUV.z*q.y);
            float body = noise.sample(repeating, q-c.domain.zw).r;
            float middle = noise.sample(repeating, q*c.appearance.z+float2(0.31,0.73)-c.detailPhases.xy).r;
            float fine = noise.sample(repeating, q*c.appearance.w+float2(0.83,0.19)-c.detailPhases.zw).r;
            float field = clamp(body+(middle-0.5)*0.30+(fine-0.5)*0.08,0.0,1.0);
            float2 s = v.uv * c.secondary.xy;
            // Independent basis, offset, scale and time phase, using the same own noise tile.
            s = float2(0.6*s.x+0.8*s.y, -0.8*s.x+0.6*s.y)+float2(0.47,0.29)-c.secondary.zw;
            if (c.controls.x > 0.0) {
                float detail = noise.sample(repeating,s).r;
                field = clamp(field+c.controls.x*0.55*(detail-0.5),0.0,1.0);
            }
            float threshold = 1.15-c.appearance.y*1.3;
            float shape = smoothstep(threshold-0.12,threshold+0.12,field);
            float interior = 0.55+middle*0.30+fine*0.15;
            interior = mix(interior,1.0,smoothstep(0.8,1.0,c.appearance.y));
            float coverage = shape*interior;
            float tone = 1.0;
            if (c.controls.z > 0.0) {
                // Own bounded directional finite difference, not normals/3D illumination.
                float slope = noise.sample(repeating,q-c.domain.zw-c.lightSteps.xy).r
                            - noise.sample(repeating,q-c.domain.zw+c.lightSteps.xy).r;
                if (c.controls.x > 0.0) {
                    slope += c.controls.x*0.55*(noise.sample(repeating,s-c.lightSteps.zw).r
                                             -noise.sample(repeating,s+c.lightSteps.zw).r);
                }
                tone = 1.0-c.controls.z*0.45+c.controls.z*0.65*clamp(slope*4.0,-1.0,1.0);
            }
            tone = clamp(tone*c.controls.y,0.0,1.0);
            float amount = coverage*c.appearance.x*mask.sample(maskFiltering,v.uv*c.maskUV.xy).r;
            pixel.rgb = mix(pixel.rgb,float3(pixel.a*tone),amount);
            if (t.sampling.w > 0.5) {
                return float4(pixel.a > 0 ? pixel.rgb/pixel.a : float3(0),pixel.a*t.sampling.z);
            }
            return pixel*t.sampling.z;
        }
        """

    // Own semantic structure range. Legacy functions above remain unchanged;
    // softness zero never selects this pipeline. No new textures or samples.
    static let softShader = """
        fragment float4 cloudsSoftColor(ImageVertex v [[stage_in]],
            constant ImageTransform &t [[buffer(0)]], constant ExtendedCloudsUniforms &c [[buffer(1)]],
            texture2d<float> image [[texture(0)]], texture2d<float> noise [[texture(1)]],
            texture2d<float> mask [[texture(2)]], sampler filtering [[sampler(0)]],
            sampler repeating [[sampler(1)]], sampler maskFiltering [[sampler(2)]]) {
            float4 pixel = image.sample(filtering, v.uv * t.sampling.xy);
            float2 q = v.uv * c.domain.xy;
            q = float2(c.maskUV.z*q.x-c.maskUV.w*q.y, c.maskUV.w*q.x+c.maskUV.z*q.y);
            float body = noise.sample(repeating, q-c.domain.zw).r;
            float middle = noise.sample(repeating, q*c.appearance.z+float2(0.31,0.73)-c.detailPhases.xy).r;
            float fine = noise.sample(repeating, q*c.appearance.w+float2(0.83,0.19)-c.detailPhases.zw).r;
            float softness = c.controls.w;
            float retained = 1.0-softness;
            float field = clamp(body+(middle-0.5)*0.30*retained
                                   +(fine-0.5)*0.08*retained*retained,0.0,1.0);
            float2 s = v.uv * c.secondary.xy;
            // Independent basis, offset, scale and time phase, using the same own noise tile.
            s = float2(0.6*s.x+0.8*s.y, -0.8*s.x+0.6*s.y)+float2(0.47,0.29)-c.secondary.zw;
            if (c.controls.x > 0.0) {
                float detail = noise.sample(repeating,s).r;
                field = clamp(field+c.controls.x*0.55*(1.0-0.5*softness)*(detail-0.5),0.0,1.0);
            }
            // Expand transition symmetrically in density space: zero/full endpoints
            // stay outside [0,1] even at maximum softness.
            float width = 0.12+0.38*softness;
            float threshold = 1.15-c.appearance.y*1.3+0.38*softness*(1.0-2.0*c.appearance.y);
            float shape = smoothstep(threshold-width,threshold+width,field);
            float interior = mix(0.55+middle*0.30+fine*0.15,1.0,softness*0.85);
            interior = mix(interior,1.0,smoothstep(0.8,1.0,c.appearance.y));
            float coverage = shape*interior;
            float tone = 1.0;
            if (c.controls.z > 0.0) {
                // Own bounded directional finite difference, not normals/3D illumination.
                float slope = noise.sample(repeating,q-c.domain.zw-c.lightSteps.xy).r
                            - noise.sample(repeating,q-c.domain.zw+c.lightSteps.xy).r;
                if (c.controls.x > 0.0) {
                    slope += c.controls.x*0.55*(1.0-0.5*softness)*(noise.sample(repeating,s-c.lightSteps.zw).r
                                             -noise.sample(repeating,s+c.lightSteps.zw).r);
                }
                tone = 1.0-c.controls.z*0.45+c.controls.z*0.65*clamp(slope*4.0,-1.0,1.0);
            }
            tone = clamp(tone*c.controls.y,0.0,1.0);
            float amount = coverage*c.appearance.x*mask.sample(maskFiltering,v.uv*c.maskUV.xy).r;
            pixel.rgb = mix(pixel.rgb,float3(pixel.a*tone),amount);
            if (t.sampling.w > 0.5) {
                return float4(pixel.a > 0 ? pixel.rgb/pixel.a : float3(0),pixel.a*t.sampling.z);
            }
            return pixel*t.sampling.z;
        }
        """
}
