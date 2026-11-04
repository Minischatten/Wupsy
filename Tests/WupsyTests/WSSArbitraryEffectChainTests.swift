import MetalKit
import XCTest

@testable import Wupsy

final class WSSArbitraryEffectChainTests: XCTestCase {
    let image = WSSAssetID(value: "assets/base.png")
    struct Assets: WSSImageAssetSource {
        var pixels = WSSFlowTests().pixels(size: 64)
        func image(for id: WSSAssetID) throws -> WSSImageAsset {
            WSSImageAsset(width: 64, height: 64, payload: .rgba8(pixels))
        }
        func mask(for id: WSSAssetID) throws -> WSSMaskAsset {
            guard !id.value.contains("missing") else {
                throw WSSDocumentError.missingAsset(id.value)
            }
            let reverse = id.value.contains("B")
            return WSSMaskAsset(
                width: 8, height: 8,
                pixels: Data((0..<64).map { UInt8(reverse ? 255 - $0 * 4 : $0 * 4) }))
        }
        func vectorField(for id: WSSAssetID) throws -> WSSVectorFieldAsset {
            guard !id.value.contains("missing") else {
                throw WSSDocumentError.missingAsset(id.value)
            }
            var data = Data()
            var coverage = Data()
            for y in 0..<8 {
                for x in 0..<8 {
                    let v: SIMD2<Float> =
                        id.value.contains("A")
                        ? SIMD2(0.3 + Float(y) / 12, Float(x) / 15)
                        : SIMD2(-Float(y + 1) / 10, 0.8 - Float(x) / 14)
                    for component in [v.x, v.y] {
                        var bits = Float16(component).bitPattern.littleEndian
                        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
                    }
                    coverage.append(UInt8(70 + (x * 17 + y * 7) % 180))
                }
            }
            return WSSVectorFieldAsset(
                width: 8, height: 8, vectors: data,
                coverage: coverage, isNeutral: false)
        }
    }
    func effects(_ variant: Int = 0) -> [WSSImageEffect] {
        let suffix = variant == 0 ? "A" : "B"
        let field = WSSAssetID(value: "assets/field-\(suffix).wssvf")
        let mask = WSSImageMask(asset: WSSAssetID(value: "assets/mask-\(suffix).png"))
        let ripple = WSSRippleEffect(
            amplitude: variant == 0 ? 5 : 3,
            wavelength: variant == 0 ? 19 : 27, direction: variant == 0 ? 25 : 130,
            mask: mask, seed: UInt32(17 + variant))
        var clouds = WSSCloudsEffect(
            velocity: SIMD2(9, -4), scale: 21,
            intensity: 0.7, density: 0.55, seed: UInt32(31 + variant), mask: mask)
        clouds.secondaryField = WSSCloudsField(velocity: SIMD2(-5, 3), scale: 35)
        return [
            .ripple(ripple), .clouds(clouds),
            .flow(WSSFlowEffect(flowMap: field, speed: 23, strength: 9)),
        ]
    }
    func scene(
        _ effects: [WSSImageEffect], opacity: Float = 1,
        composition: WSSImageLayer.Composition = .sourceOver
    ) -> WSSScene {
        WSSScene(
            width: 64, height: 64,
            layers: [
                WSSImageLayer(
                    asset: image,
                    transform: WSSImageTransform(center: SIMD2(32, 32), size: SIMD2(64, 64)),
                    opacity: opacity, composition: composition, effects: effects)
            ])
    }
    func resources(_ effects: [WSSImageEffect], pixels: Data? = nil) throws -> WSSStaticResources {
        try WSSStaticResources(
            scene: scene(effects),
            assets: Assets(pixels: pixels ?? WSSFlowTests().pixels(size: 64)),
            device: WSSStaticTests().device())
    }
    func render(_ effects: [WSSImageEffect], pixels: Data? = nil) throws -> Data {
        try WSSRippleChainTests().render(resources(effects, pixels: pixels), time: 0.37).0
    }
    func sequential(_ effects: [WSSImageEffect]) throws -> Data {
        var pixels = WSSFlowTests().pixels(size: 64)
        var output = Data()
        for effect in effects {
            output = try render([effect], pixels: pixels)
            pixels = WSSRippleChainTests().rgba(output)
        }
        return output
    }
    func document(_ effects: [WSSImageEffect]) throws -> WSSSceneDocumentV1 {
        let definitions = try effects.map { effect -> WSSSceneDocumentV1.Effect in
            let id: WSSAssetID?
            if case .flow(let f) = effect {
                id = f.flowMap
            } else {
                id = nil
            }
            let field = try id.map { id in
                try JSONDecoder().decode(
                    WSSSceneDocumentV1.Effect.FlowMap.self,
                    from: JSONSerialization.data(withJSONObject: [
                        "asset": id.value,
                        "format": WSSVectorFieldAsset.fileFormat, "version": 1,
                    ]))
            }
            return .init(parameters: effect, mask: nil, field: field)
        }
        let jsonEffects = try JSONSerialization.jsonObject(with: JSONEncoder().encode(definitions))
        return try WSSSceneDocumentV1.decode(
            data: JSONSerialization.data(withJSONObject: [
                "format": "wss-scene", "version": 1, "title": "Synthetic ordered stack",
                "canvas": ["width": 64, "height": 64],
                "layers": [
                    [
                        "image": image.value,
                        "transform": ["center": [32, 32], "size": [64, 64]],
                        "effects": jsonEffects,
                    ]
                ],
            ]))
    }
    func testAll9OrderedPairsAgainstIndependentSequentialExecution() throws {
        for (i, a) in effects().enumerated() {
            for (j, b) in effects(1).enumerated() {
                let chain = [a, b]
                let doc = try document(chain)
                let canonical = chain
                XCTAssertEqual(try doc.scene().imageLayers[0].effects, canonical)
                let r = try resources(chain)
                let plan = try XCTUnwrap(r.effectPlans[0])
                XCTAssertEqual(plan.activeStages.map(\.manifestIndex), [0, 1])
                XCTAssertEqual(plan.effects, chain)
                let context = WSSImageEffectRenderContext(device: r.device)
                XCTAssertEqual(
                    try WSSRippleChainTests().render(r, context: context, time: 0.37).0,
                    try sequential(chain), "pair \(i) -> \(j)")
                XCTAssertEqual(context.targets[0].count, 1)
            }
        }
    }
    func testOptionalGeneratedManualProjects() throws {
        guard let path = ProcessInfo.processInfo.environment["AMBIENT_9C_FIXTURES"] else {
            throw XCTSkip("Set AMBIENT_9C_FIXTURES for generated manual-project validation")
        }
        let root = URL(fileURLWithPath: path)
        var count = 0
        for folder in try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
        where folder.hasDirectoryPath {
            count += 1
            let doc = try WSSSceneDocumentV1.load(
                entry: folder.appendingPathComponent("scene.wss.json"), root: folder)
            let r = try WSSStaticResources(
                scene: doc.scene(), assets: doc.assetSource(root: folder),
                device: WSSStaticTests().device())
            _ = try WSSRippleChainTests().render(r, time: 0.37, width: 128, height: 72)
        }
        XCTAssertEqual(count, 6)
    }
    func testNonCommutativeOrderAndIndependentRepeatedTypes() throws {
        let a = effects()
        let b = effects(1)
        for (i, j) in [(0, 2), (1, 0), (2, 1)] {
            XCTAssertNotEqual(try render([a[i], b[j]]), try render([b[j], a[i]]))
        }
        for i in a.indices {
            XCTAssertEqual(try render([a[i], b[i]]), try sequential([a[i], b[i]]))
            let identical = try resources([a[i], a[i]])
            XCTAssertEqual(identical.effectPlans[0]?.activeStages.map(\.manifestIndex), [0, 1])
        }
    }
    func longChains() -> [[WSSImageEffect]] {
        let a = effects()
        let b = effects(1)
        return [
            [a[2], b[1], a[0]], [a[1], b[0], a[2], b[1]],
            [a[2], b[0], a[2], b[2], a[0]], Array(repeating: a[0], count: 32),
            [a[0], b[0], a[2]], [a[2], b[1], a[0]],
        ]
    }
    func testLongChainsPingPongAndInputsIncludingBudgetBoundary() throws {
        for chain in longChains() {
            let r = try resources(chain)
            let context = WSSImageEffectRenderContext(device: r.device)
            let actual = try WSSRippleChainTests().render(r, context: context, time: 0.37).0
            XCTAssertEqual(actual, try sequential(chain))
            XCTAssertEqual(r.effectPlans[0]?.passCount, chain.count)
            XCTAssertEqual(r.effectPlans[0]?.intermediateCount, 2)
            let count = context.textureBytes
            let old = try context.acquire(
                requests: [
                    .init(layer: 0, scratch: 0): SIMD2(64, 64),
                    .init(layer: 0, scratch: 1): SIMD2(64, 64),
                ], output: WSSRippleChainTests().target(r.device))
            XCTAssertFalse(
                old.intermediateTargets[.init(layer: 0, scratch: 0)]
                    === old.intermediateTargets[.init(layer: 0, scratch: 1)])
            context.release(old)
            _ = try WSSRippleChainTests().render(r, context: context, time: 0.37)
            XCTAssertEqual(context.textureBytes, count)
            _ = try WSSRippleChainTests().render(
                r, context: context, time: 0.37, width: 96, height: 96)
            XCTAssertEqual(context.targets[0][0]?.width, 96)
            let changed = try resources(longChains()[0])
            XCTAssertEqual(
                try WSSRippleChainTests().render(changed, context: context, time: 0.37).0,
                try sequential(longChains()[0]))
        }
    }
    func testLongChainAlphaOpacityAndResourceSharing() throws {
        let a = effects()
        let b = effects(1)
        let chain = [a[2], b[0], a[2], b[2], a[0], a[1]]
        let independent = [
            a[2], b[2],
            WSSImageEffect.flow(
                WSSFlowEffect(
                    flowMap: WSSAssetID(value: "assets/field-C.wssvf"), speed: 15, strength: 6)),
        ]
        let threeFields = try resources(independent)
        XCTAssertEqual(threeFields.vectorFields?.fields.count, 3)
        XCTAssertEqual(try render(independent), try sequential(independent))
        let fieldStages = try XCTUnwrap(threeFields.effectPlans[0]).activeStages
        XCTAssertFalse(
            fieldStages[0].binding.field?.vectors === fieldStages[1].binding.field?.vectors)
        XCTAssertFalse(
            fieldStages[1].binding.field?.vectors === fieldStages[2].binding.field?.vectors)
        let base = WSSFlowTests().pixels(size: 64, alpha: 128)
        let full = try render(chain, pixels: base)
        for composition: WSSImageLayer.Composition in [.sourceOver, .replace] {
            let r = try WSSStaticResources(
                scene: scene(chain, opacity: 0.4, composition: composition),
                assets: Assets(pixels: base), device: WSSStaticTests().device())
            let output = try WSSRippleChainTests().render(r, time: 0.37).0
            for i in stride(from: 0, to: output.count, by: 4) {
                XCTAssertEqual(Double(output[i + 3]), 128 * 0.4, accuracy: 1)
                for c in 0..<3 {
                    XCTAssertEqual(
                        Double(output[i + c]),
                        composition == .sourceOver
                            ? Double(full[i + c]) * 0.4 : Double(full[i + c]) * 255 / 128,
                        accuracy: 2)
                }
            }
            let stages = try XCTUnwrap(r.effectPlans[0]).stages
            XCTAssertFalse(stages[0].binding.field?.vectors === stages[3].binding.field?.vectors)
            XCTAssertTrue(stages[0].binding.field?.vectors === stages[2].binding.field?.vectors)
            XCTAssertEqual(r.vectorFields?.fields.count, 2)
        }
    }
    func testIdentityElisionStillValidatesResourcesAndPreservesActiveOrder() throws {
        let a = effects()
        var zero = WSSRippleEffect()
        zero.amplitude = 0
        let withIdentity = [a[0], .ripple(zero), a[2], a[2]]
        let r = try resources(withIdentity)
        XCTAssertEqual(r.effectPlans[0]?.activeStages.map(\.manifestIndex), [0, 2, 3])
        XCTAssertEqual(try render(withIdentity), try render([a[0], a[2], a[2]]))
        zero.mask = WSSImageMask(asset: WSSAssetID(value: "assets/missing.png"))
        XCTAssertThrowsError(try resources([a[0], .ripple(zero), a[2]]))
    }
    func testLayerAndSceneBudgetsPrecedeAssetLoading() throws {
        struct Forbidden: WSSImageAssetSource {
            func image(for id: WSSAssetID) throws -> WSSImageAsset {
                XCTFail("loaded before budget")
                throw WSSSceneError.invalid("unexpected load")
            }
        }
        let a = effects()[0]
        let device = try WSSStaticTests().device()
        XCTAssertThrowsError(
            try WSSStaticResources(
                scene: scene(Array(repeating: a, count: 33)), assets: Forbidden(), device: device))
        let layer = scene(Array(repeating: a, count: 32)).imageLayers[0]
        XCTAssertNoThrow(
            try WSSScene(width: 64, height: 64, layers: Array(repeating: layer, count: 8))
                .validate())
        var zero = WSSRippleEffect()
        zero.amplitude = 0
        var hidden = scene([.ripple(zero)]).imageLayers[0]
        hidden.visible = false
        for extra in [scene([a]).imageLayers[0], hidden] {
            let boundaryPlusOne = WSSScene(
                width: 64, height: 64,
                layers: Array(repeating: layer, count: 8) + [extra])
            XCTAssertThrowsError(
                try WSSStaticResources(
                    scene: boundaryPlusOne,
                    assets: Forbidden(), device: device))
        }
        var neutralLayer = scene(Array(repeating: .ripple(zero), count: 32)).imageLayers[0]
        neutralLayer.visible = false
        let neutralBoundary = WSSScene(
            width: 64, height: 64,
            layers: Array(repeating: neutralLayer, count: 8))
        XCTAssertNoThrow(try neutralBoundary.validate())
        var neutralPlusOne = neutralBoundary
        neutralPlusOne.layers.append(.image(hidden))
        XCTAssertThrowsError(try neutralPlusOne.validate())

    }
    func testMultipleLongLayersTwoPendingFramesAndTargetBudget() throws {
        let chain = longChains()[2]
        var first = scene(chain).imageLayers[0]
        first.opacity = 0.6
        var second = scene(Array(chain.reversed())).imageLayers[0]
        second.opacity = 0.3
        let r = try WSSStaticResources(
            scene: WSSScene(width: 64, height: 64, layers: [first, second]),
            assets: Assets(), device: WSSStaticTests().device())
        let context = WSSImageEffectRenderContext(device: r.device)
        var commands: [MTLCommandBuffer] = []
        var outputs: [MTLTexture] = []
        for _ in 0..<2 {
            let output = try WSSRippleChainTests().target(r.device)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            let command = try XCTUnwrap(r.queue.makeCommandBuffer())
            try r.encode(
                command: command, descriptor: pass, size: CGSize(width: 64, height: 64), time: 0.37,
                rippleContext: context)
            commands.append(command)
            outputs.append(output)
        }
        XCTAssertFalse(context.targets[0][0] === context.targets[0][1])
        XCTAssertFalse(context.targets[0][0] === context.targets[1][0])
        for command in commands { command.commit() }
        for command in commands {
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
        }
        let one = try render(chain)
        let two = try render(Array(chain.reversed()))
        for output in outputs {
            var pixels = Data(count: 64 * 64 * 4)
            pixels.withUnsafeMutableBytes {
                output.getBytes(
                    $0.baseAddress!, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 64),
                    mipmapLevel: 0)
            }
            for i in stride(from: 0, to: pixels.count, by: 4) {
                XCTAssertEqual(Double(pixels[i + 3]), (0.3 + 0.6 * 0.7) * 255, accuracy: 1)
                for c in 0..<3 {
                    XCTAssertEqual(
                        Double(pixels[i + c]),
                        Double(two[i + c]) * 0.3 + Double(one[i + c]) * 0.6 * 0.7, accuracy: 2)
                }
            }
        }
        XCTAssertThrowsError(
            try WSSRippleChainTests().render(
                r, context: WSSImageEffectRenderContext(device: r.device, byteLimit: 1), time: 0.37)
        )
    }
}
