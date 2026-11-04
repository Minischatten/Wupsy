import MetalKit
import XCTest

@testable import Wupsy

final class WSSFlowUnificationTests: XCTestCase {
    struct Assets: WSSImageAssetSource {
        let field: WSSVectorFieldAsset
        var repeatImage = false
        var uv = SIMD2<Float>(1, 1)
        var alpha: UInt8 = 255
        func vectorField(for id: WSSAssetID) throws -> WSSVectorFieldAsset { field }
        func image(for id: WSSAssetID) throws -> WSSImageAsset {
            var image = WSSImageAsset(
                width: 128, height: 128, payload: .rgba8(WSSFlowTests().pixels(alpha: alpha)))
            image.edge = repeatImage ? .repeatImage : .clamp
            image.uvScale = uv
            return image
        }
    }
    func resources(_ effect: WSSImageEffect, size: SIMD2<Int>, assets: Assets, over: Bool = false)
        throws -> WSSStaticResources
    {
        let scene = WSSScene(
            width: size.x, height: size.y,
            layers: [
                WSSImageLayer(
                    asset: WSSAssetID(value: "image"),
                    transform: WSSImageTransform(
                        center: SIMD2(Float(size.x) / 2, Float(size.y) / 2),
                        size: SIMD2(Float(size.x), Float(size.y))),
                    composition: over ? .sourceOver : .replace, effects: [effect])
            ])
        return try WSSStaticResources(
            scene: scene, assets: assets, device: WSSStaticTests().device())
    }
    func frozenFrame(
        _ resources: WSSStaticResources, effect: WSSFlowEffect, time: Double,
        over: Bool, density: Int = 1
    ) throws -> Data {
        let device = resources.device
        let library = try device.makeLibrary(
            source: WSSStaticResources.shader + WSSRippleDetailResources.shader
                + Self.frozenFlow, options: nil)
        let p = MTLRenderPipelineDescriptor()
        p.vertexFunction = library.makeFunction(name: "imageQuad")
        p.fragmentFunction = library.makeFunction(
            name: "flowImage")
        let color = p.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = over
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pipeline = try device.makeRenderPipelineState(descriptor: p)
        let width = resources.scene.width
        let height = resources.scene.height
        let target = try WSSRippleChainTests().target(
            device, width: width * density, height: height * density)
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: descriptor))
        let image = try XCTUnwrap(resources.images[WSSAssetID(value: "image")])
        let fields = try XCTUnwrap(resources.vectorFields)
        let field = try XCTUnwrap(fields.fields[effect.flowMap])
        var transform = WSSStaticResources.Uniforms(
            horizontal: SIMD4(Float(width), 0, 0, Float(width)),
            vertical: SIMD4(0, Float(height), 0, Float(height)),
            sampling: SIMD4(image.uvScale.x, image.uvScale.y, 1, over ? 0 : 1))
        let uniforms = [
            SIMD4<Float>(Float(width), Float(height), effect.strength, try effect.phase(at: time)),
            .zero,
        ]
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&transform, length: MemoryLayout.size(ofValue: transform), index: 0)
        encoder.setFragmentBytes(
            &transform, length: MemoryLayout.size(ofValue: transform), index: 0)
        uniforms.withUnsafeBytes {
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
        }
        let ripple = Data(
            repeating: 0, count: MemoryLayout<WSSRippleDetailResources.Uniforms>.stride)
        ripple.withUnsafeBytes {
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2)
        }
        encoder.setFragmentTexture(image.texture, index: 0)
        encoder.setFragmentTexture(field.vectors, index: 1)
        encoder.setFragmentTexture(field.coverage ?? fields.white, index: 2)
        encoder.setFragmentTexture(fields.white, index: 3)
        encoder.setFragmentSamplerState(image.sampler, index: 0)
        encoder.setFragmentSamplerState(fields.sampler, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        var bytes = Data(count: width * height * density * density * 4)
        bytes.withUnsafeMutableBytes {
            target.getBytes(
                $0.baseAddress!, bytesPerRow: width * density * 4,
                from: MTLRegionMake2D(0, 0, width * density, height * density),
                mipmapLevel: 0)
        }
        return bytes
    }
    func testFrozenOldFlowIsByteIdenticalToCanonicalFlow() throws {
        let map = WSSAssetID(value: "map")
        let sizes: [SIMD2<Int>] = [
            SIMD2(128, 128), SIMD2(192, 96), SIMD2(96, 192), SIMD2(1, 1), SIMD2(1, 128),
            SIMD2(512, 512), SIMD2(128, 128), SIMD2(128, 128),
        ]
        let spans: [Float] = [
            0.000000001, 0.1, 12, 16, 18, 128, .leastNonzeroMagnitude, .leastNormalMagnitude / 2,
        ]
        let vectors: [SIMD2<Float>] = [
            SIMD2(1, 0), SIMD2(0, 1), SIMD2(-1, 1), SIMD2(0.2, -0.5), SIMD2(1, 1), SIMD2(-1, 0),
            SIMD2(1, 0), SIMD2(0, 1),
        ]
        for index in sizes.indices {
            let originalField = try WSSVectorFieldPaintTests().field(
                width: 4, height: 3, vector: vectors[index], coverage: index.isMultiple(of: 2))
            var vectors = originalField.vectors
            if index == 2 {
                vectors.withUnsafeMutableBytes { raw in
                    for texel in 0..<12 {
                        raw.storeBytes(
                            of: Float16(Float(texel % 3 - 1)).bitPattern.littleEndian,
                            toByteOffset: texel * 4, as: UInt16.self)
                    }
                }
            }
            let candidate = WSSVectorFieldAsset(
                width: 4, height: 3, vectors: vectors,
                coverage: originalField.coverage == nil
                    ? nil : Data((0..<12).map { [UInt8(0), 128, 255][$0 % 3] }), isNeutral: false)
            let field = WSSVectorFieldAsset(
                width: 4, height: 3, vectors: vectors, coverage: candidate.coverage,
                isNeutral: try candidate.validatedNeutrality())
            let assets = Assets(
                field: field, repeatImage: index.isMultiple(of: 2),
                uv: index.isMultiple(of: 2) ? SIMD2(0.75, 0.8) : SIMD2(1, 1),
                alpha: index.isMultiple(of: 2) ? 127 : 255)
            for _ in [0] {
                let effect = WSSFlowEffect(
                    flowMap: map, speed: index == 5 ? 1024 : 30, strength: spans[index],
                    edgeProtectionPixels: 0)
                let over = index.isMultiple(of: 2)
                let resources = try self.resources(
                    .flow(effect), size: sizes[index], assets: assets, over: over)
                for density in [1, 2] {
                    for time in [0.0, 0.03, 0.35, 1.2, 10000.0] {
                        let actual = try WSSRippleChainTests().render(
                            resources, time: time, width: sizes[index].x * density,
                            height: sizes[index].y * density
                        ).0
                        let expected = try frozenFrame(
                            resources, effect: effect, time: time, over: over,
                            density: density)
                        XCTAssertEqual(
                            actual, expected,
                            "index \(index), time \(time), density \(density)")
                    }
                }
            }
        }
    }

    // Frozen pre-unification shader; never derive expected output from the new shader.
    static let frozenFlow = """
        struct FlowUniforms { float4 geometry; };
        fragment float4 flowImage(ImageVertex v [[stage_in]],
            constant ImageTransform &t [[buffer(0)]], constant FlowUniforms &f [[buffer(1)]],
            texture2d<float> image [[texture(0)]], texture2d<float> vectors [[texture(1)]],
            texture2d<float> coverage [[texture(2)]], sampler filtering [[sampler(0)]],
            sampler mapFiltering [[sampler(1)]]) {
            float2 uv = v.uv;
            float2 gx = dfdx(uv*t.sampling.xy), gy = dfdy(uv*t.sampling.xy);
            float4 original = image.sample(filtering,uv*t.sampling.xy,gradient2d(gx,gy));
            float2 vector = vectors.sample(mapFiltering,uv).rg;
            float amount = coverage.sample(mapFiltering,uv).r;
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
