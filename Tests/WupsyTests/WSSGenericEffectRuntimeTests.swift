import MetalKit
import XCTest

@testable import Wupsy

final class WSSGenericEffectRuntimeTests: XCTestCase {
    func testPublicFramesAndOptionalPre9BBaseline() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
                "Test-Wallpaper")
        let device = try WSSStaticTests().device()
        let baseline = ProcessInfo.processInfo.environment["AMBIENT_9B_BASELINE"].map {
            URL(fileURLWithPath: $0)
        }
        let capture = ProcessInfo.processInfo.environment["AMBIENT_9B_CAPTURE"] == "1"
        for name in [
            "WSS-Ripple-v1", "WSS-Ripple-Chain-v1", "WSS-Flow-v1", "WSS-Flow-Ripple-v1",

            "WSS-Clouds-v1", "WSS-Clouds-v2", "WSS-Clouds-Storm",
        ] {
            let folder = root.appendingPathComponent(name)
            let doc = try WSSSceneDocumentV1.load(
                entry: folder.appendingPathComponent("scene.wss.json"), root: folder)
            let resources = try WSSStaticResources(
                scene: doc.scene(), assets: doc.assetSource(root: folder), device: device)
            let context = WSSRippleRenderContext(device: device)
            for (index, time) in [0.0, 0.7, 4].enumerated() {
                let pixels = try WSSRippleChainTests().render(
                    resources, context: context, time: time, width: 96, height: 64
                ).0
                XCTAssertEqual(
                    pixels,
                    try WSSRippleChainTests().render(
                        resources, context: context, time: time, width: 96, height: 64
                    ).0)
                if let baseline {
                    let path = baseline.appendingPathComponent("\(name)-\(index).bgra")
                    if capture {
                        try pixels.write(to: path, options: .withoutOverwriting)
                    } else {
                        XCTAssertEqual(pixels, try Data(contentsOf: path), "\(name) at \(time)")
                    }
                }
            }
        }
    }
    // Independent reference: materialize a single stage, upload its pixels as a
    // new source, then execute the second stage without the stack scheduler.
    func testPreviousOutputForAllCurrentlyAllowedPairs() throws {
        let h = WSSFlowTestSupport()
        let ripple = WSSRippleEffect(amplitude: 8, wavelength: 35, stretch: 1.2, seed: 17)
        let pairs: [[WSSImageEffect]] = [
            [.ripple(ripple), .ripple(WSSRippleEffect(amplitude: 5, wavelength: 21, seed: 42))],
            [.flow(h.helper.effect), .ripple(ripple)],
        ]
        for pair in pairs {
            let first = try h.render(h.resources([pair[0]]))
            let expected = try h.render(
                h.resources([pair[1]], base: WSSRippleChainTests().rgba(first)))
            let actual = try h.render(h.resources(pair))
            XCTAssertEqual(actual, expected)
            XCTAssertNotEqual(actual, try h.render(h.resources([pair[1]])))
        }
    }

    func renderStage(
        _ stage: WSSImageEffectPlan.Stage?, resources: WSSStaticResources,
        input: WSSStaticResources.Image, layer: WSSImageLayer,
        intermediate: Bool = false, size: Int = 64
    ) throws -> Data {
        let target = try WSSRippleChainTests().target(resources.device, width: size, height: size)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        do {
            try resources.encodeImageStage(
                stage, input: input, layer: layer,
                mode: intermediate ? .intermediate : .composition(crop: SIMD2(1, 1)),
                time: 0.37, encoder: encoder)
        } catch {
            encoder.endEncoding()
            throw error
        }
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        var pixels = Data(count: size * size * 4)
        pixels.withUnsafeMutableBytes {
            target.getBytes(
                $0.baseAddress!, bytesPerRow: size * 4,
                from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        return pixels
    }

    func testCloudsDispatchIgnoresManifestPositionAndUsesExplicitInput() throws {
        var effect = WSSCloudsEffect()
        effect.mask = WSSImageMask(asset: WSSCloudsTests().mask)
        effect.softness = 0.4
        effect.secondaryField = WSSCloudsField(velocity: SIMD2(-7, 3), scale: 128)
        let r = try WSSCloudsTests().resources(effect, maskValue: 173)
        let original = try XCTUnwrap(r.effectPlans[0]?.activeStages.first)
        // Isolated dispatch contract; no invalid manifest is admitted to playback.
        let relocated = WSSImageEffectPlan.Stage(
            manifestIndex: 7,
            declaredEffect: original.declaredEffect, effect: original.effect,
            binding: original.binding)
        var layer = r.scene.imageLayers[0]
        layer.effects = []
        let input = try XCTUnwrap(r.images[layer.asset])
        let expected = try WSSCloudsTests().render(r, time: 0.37, clearAlpha: 0).0
        XCTAssertEqual(
            try renderStage(relocated, resources: r, input: input, layer: layer), expected)
        let alternative = try WSSCloudsTests().resources(nil, alpha: 80)
        let explicitInput = try XCTUnwrap(alternative.images[layer.asset])
        XCTAssertNotEqual(
            try renderStage(relocated, resources: r, input: explicitInput, layer: layer), expected)
        let intermediate = try renderStage(
            relocated, resources: r, input: input, layer: layer, intermediate: true)
        layer.opacity = 0.2
        XCTAssertEqual(
            intermediate,
            try renderStage(relocated, resources: r, input: input, layer: layer, intermediate: true)
        )
    }

    func testPreparedFieldAndCoverageAreUsedByDispatch() throws {
        let h = WSSFlowTestSupport()
        let a = try h.resources([.flow(h.helper.effect)], vector: SIMD2(1, 0), coverage: 255)
        let b = try h.resources([.flow(h.helper.effect)], vector: SIMD2(0, 1), coverage: 128)
        let c = try h.resources([.flow(h.helper.effect)], vector: SIMD2(-1, 0), coverage: 200)
        let stages = try [a, b, c].map { try XCTUnwrap($0.effectPlans[0]?.activeStages.first) }
        let input = try XCTUnwrap(a.images[a.scene.imageLayers[0].asset])
        // Use one dispatcher with bindings from independently prepared stages.
        // Field A/B even have the same asset ID: the concrete prepared binding wins.
        for (index, r) in [a, b, c].enumerated() {
            XCTAssertEqual(
                try renderStage(
                    stages[index], resources: a, input: input, layer: a.scene.imageLayers[0],
                    size: 128),
                try h.helper.render(r, time: 0.37))
        }
        XCTAssertNotEqual(try h.helper.render(a, time: 0.37), try h.helper.render(b, time: 0.37))
    }

    func testIntermediateAlphaAndFinalOpacityComposition() throws {
        let h = WSSRippleChainTests()
        for alpha: UInt8 in [0, 128, 255] {
            for over in [false, true] {
                let chain = try h.resources([h.a, h.b], alpha: alpha, opacity: 0.4, over: over)
                let actual = try h.render(chain).0
                let full = try h.render(
                    h.resources([h.a, h.b], alpha: alpha, opacity: 1, over: true)
                ).0
                for i in stride(from: 0, to: actual.count, by: 4) {
                    XCTAssertEqual(Double(actual[i + 3]), Double(alpha) * 0.4, accuracy: 1)
                    for channel in 0..<3 {
                        let expected =
                            over
                            ? Double(full[i + channel]) * 0.4
                            : (alpha == 0 ? 0 : Double(full[i + channel]) * 255 / Double(alpha))
                        XCTAssertEqual(Double(actual[i + channel]), expected, accuracy: 2)
                    }
                }
            }
        }
    }

    struct GeometryAssets: WSSImageAssetSource {
        var base: WSSImageAsset
        func image(for id: WSSAssetID) throws -> WSSImageAsset { base }
        func mask(for id: WSSAssetID) throws -> WSSMaskAsset {
            WSSMaskAsset(
                width: 2, height: 2, pixels: Data([0, 255, 180, 75]), uvScale: SIMD2(0.8, 1))
        }
        func vectorField(for id: WSSAssetID) throws -> WSSVectorFieldAsset {
            WSSFlowTestSupport().field(SIMD2(0.7, -0.3), coverage: 180)
        }
    }

    func testCroppedSourceAndIntermediateUVUnderTransformsAtBothDensities() throws {
        let h = WSSFlowTests()
        let device = try WSSStaticTests().device()
        var ripple = WSSRippleEffect(amplitude: 9, wavelength: 27, seed: 37)
        ripple.mask = WSSImageMask(asset: WSSAssetID(value: "mask"))
        let original = WSSImageAsset(
            width: 128, height: 128, payload: .rgba8(h.pixels()),
            uvScale: SIMD2(0.75, 0.5), filter: .linear, edge: .repeatImage, mipmapped: true)
        let transform = WSSImageTransform(
            center: SIMD2(59, 67), size: SIMD2(128, 128),
            scale: SIMD2(0.7, 1.2), rotation: 0.43)
        for pair: [WSSImageEffect] in [
            [.flow(h.effect), .ripple(ripple)], [.ripple(ripple), .ripple(ripple)],
            [.flow(h.effect), .ripple(ripple), .flow(h.effect)],
        ] {
            let layer = WSSImageLayer(asset: h.image, transform: transform, effects: pair)
            let scene = WSSScene(width: 128, height: 128, layers: [layer])
            let actualResources = try WSSStaticResources(
                scene: scene,
                assets: GeometryAssets(base: original), device: device)
            for density in [1, 2] {
                let width = 96 * density
                let height = 64 * density
                // Cover projection has uniform 0.75*density raster density here.
                let localWidth = Int(ceil(simd_length(transform.axisX) * 0.75 * Float(density)))
                let localHeight = Int(ceil(simd_length(transform.axisY) * 0.75 * Float(density)))
                var intermediateSource = original
                for effect in pair.dropLast() {
                    let firstLayer = WSSImageLayer(
                        asset: h.image,
                        transform: WSSImageTransform(
                            center: SIMD2(Float(localWidth) / 2, Float(localHeight) / 2),
                            size: SIMD2(128, 128),
                            scale: SIMD2(Float(localWidth) / 128, Float(localHeight) / 128)),
                        effects: [effect])
                    let first = try WSSStaticResources(
                        scene: WSSScene(
                            width: localWidth, height: localHeight, layers: [firstLayer]),
                        assets: GeometryAssets(base: intermediateSource), device: device)
                    let pixels = try WSSRippleChainTests().render(
                        first, time: 0.37,
                        width: localWidth, height: localHeight
                    ).0
                    intermediateSource = WSSImageAsset(
                        width: localWidth, height: localHeight,
                        payload: .rgba8(WSSRippleChainTests().rgba(pixels)))
                }
                var finalLayer = layer
                finalLayer.effects = [pair.last!]
                let final = try WSSStaticResources(
                    scene: WSSScene(width: 128, height: 128, layers: [finalLayer]),
                    assets: GeometryAssets(base: intermediateSource),
                    device: device)
                XCTAssertEqual(
                    try WSSRippleChainTests().render(
                        actualResources, time: 0.37, width: width, height: height
                    ).0,
                    try WSSRippleChainTests().render(
                        final, time: 0.37, width: width, height: height
                    ).0)
            }
        }
    }

    func testMissingStageResourcesAndElidedStageFailExplicitly() throws {
        let r = try WSSFlowTests().resources([])
        let layer = r.scene.imageLayers[0]
        let input = try XCTUnwrap(r.images[layer.asset])
        let effect = WSSImageEffect.flow(WSSFlowTests().effect)
        let broken = WSSImageEffectPlan.Stage(
            manifestIndex: 0,
            declaredEffect: effect, effect: effect, binding: .init())
        XCTAssertThrowsError(try renderStage(broken, resources: r, input: input, layer: layer))
        let elided = WSSImageEffectPlan.Stage(
            manifestIndex: 0,
            declaredEffect: effect, effect: nil, binding: .init())
        XCTAssertThrowsError(try renderStage(elided, resources: r, input: input, layer: layer))
    }

}
