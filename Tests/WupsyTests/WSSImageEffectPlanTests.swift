import MetalKit
import XCTest

@testable import Wupsy

final class WSSImageEffectPlanTests: XCTestCase {
    func plan(_ effects: [WSSImageEffect], active: Bool = true) throws -> WSSImageEffectPlan {
        try WSSImageEffectPlan(
            effects: effects, binding: { _ in .init() },
            flowActive: { _ in active })
    }
    func testOrderedPositionsIncludingEqualValuesAndLongPlans() throws {
        let ripple = WSSImageEffect.ripple(WSSRippleEffect())
        let flow = WSSImageEffect.flow(WSSFlowTests().effect)
        let p = try plan([flow, ripple, flow, ripple])
        XCTAssertEqual(p.stages.map(\.manifestIndex), [0, 1, 2, 3])
        XCTAssertEqual(p.effects, [flow, ripple, flow, ripple])
        XCTAssertEqual(p.passCount, 4)
        XCTAssertEqual(p.intermediateCount, 2)
        // Long prepared plans are now admitted under the same budgets.
        var scene = try WSSFlowTests().resources([]).scene
        scene.testImages[0].effects = p.effects
        XCTAssertNoThrow(try scene.validate())
    }
    func testFrozenIdentityRules() throws {
        var zero = WSSRippleEffect()
        zero.amplitude = 0
        XCTAssertEqual(try plan([.ripple(zero)]).passCount, 1)
        let pair = try plan([.ripple(zero), .ripple(zero)])
        XCTAssertEqual(pair.activeStages.map(\.manifestIndex), [0])
        XCTAssertEqual(try plan([.flow(WSSFlowTests().effect)], active: false).passCount, 0)
    }
    func testBudgetPrecedesBindings() throws {
        var calls = 0
        XCTAssertThrowsError(
            try WSSImageEffectPlan(
                effects: Array(repeating: .ripple(WSSRippleEffect()), count: 33),
                binding: { _ in
                    calls += 1
                    return .init()
                },
                flowActive: { _ in true }))
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(
            try plan(Array(repeating: .ripple(WSSRippleEffect()), count: 32)).passCount, 32)
    }
    func testStageLocalFieldsAndImmutableSharing() throws {
        let device = try WSSStaticTests().device()
        let fields = try WSSVectorFieldResources(
            ids: [WSSAssetID(value: "A.wssvf"), WSSAssetID(value: "B.wssvf")], device: device,
            load: { _ in WSSFlowTestSupport().field(SIMD2(1, 0)) })
        let effects: [WSSImageEffect] = ["A.wssvf", "B.wssvf", "A.wssvf"].map {
            .flow(WSSFlowEffect(flowMap: WSSAssetID(value: $0), speed: 30, strength: 12))
        }
        let p = try WSSImageEffectPlan(
            effects: effects,
            binding: { effect in
                guard case .flow(let flow) = effect else { return .init() }
                return .init(field: fields.fields[flow.flowMap])
            }, flowActive: { _ in true })
        let a = try XCTUnwrap(p.stages[0].binding.field)
        let b = try XCTUnwrap(p.stages[1].binding.field)
        let shared = try XCTUnwrap(p.stages[2].binding.field)
        XCTAssertFalse(a.vectors === b.vectors)
        XCTAssertFalse(a.coverage === b.coverage)
        XCTAssertTrue(a.vectors === shared.vectors)
        XCTAssertEqual(p.stages.map(\.manifestIndex), [0, 1, 2])
    }
    func testPreparedMaskAndNoiseBindings() throws {
        var a = WSSRippleChainTests().a
        var b = WSSRippleChainTests().b
        a.mask = WSSImageMask(asset: WSSRippleChainTests().maskA)
        b.mask = WSSImageMask(asset: WSSRippleChainTests().maskB)
        let r = try WSSRippleChainTests().resources([a, b])
        let stages = try XCTUnwrap(r.effectPlans[0]).stages
        XCTAssertEqual(stages.map(\.manifestIndex), [0, 1])
        XCTAssertTrue(stages[0].binding.ripple === stages[1].binding.ripple)
        XCTAssertNotNil(stages[0].binding.mask)
        XCTAssertFalse(stages[0].binding.mask === stages[1].binding.mask)
        for stage in stages {
            guard case .ripple(let effect) = stage.declaredEffect else { return XCTFail() }
            XCTAssertTrue(
                stage.binding.mask === effect.mask.flatMap { r.ripple?.masks[$0.asset]?.texture })
        }
    }
    func testPublicFixturePlansAndCloudsResources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Test-Wallpaper")
        let device = try WSSStaticTests().device()
        for name in [
            "WSS-Ripple-v1", "WSS-Ripple-Chain-v1", "WSS-Flow-v1", "WSS-Flow-Ripple-v1",

            "WSS-Clouds-v1", "WSS-Clouds-v2", "WSS-Clouds-Storm",
        ] {
            let folder = root.appendingPathComponent(name)
            let document = try WSSSceneDocumentV1.load(
                entry: folder.appendingPathComponent("scene.wss.json"), root: folder)
            let resources = try WSSStaticResources(
                scene: document.scene(), assets: document.assetSource(root: folder), device: device)
            for (index, node) in resources.scene.layers.enumerated() {
                guard case .image(let layer) = node else { continue }
                let plan = try XCTUnwrap(resources.effectPlans[index])
                XCTAssertEqual(plan.stages.map(\.declaredEffect), layer.effects, name)
                XCTAssertLessThanOrEqual(plan.intermediateCount, 1)
                for stage in plan.stages {
                    if case .clouds = stage.declaredEffect {
                        XCTAssertNotNil(stage.binding.clouds)
                        XCTAssertNotNil(stage.binding.noise)
                    }
                }
            }
        }
    }
    func testMultipleTargetsSlotsPlanChangesAndInputAlias() throws {
        let d = try WSSStaticTests().device()
        let output = try WSSRippleChainTests().target(d)
        let c = WSSImageEffectRenderContext(device: d)
        let a = WSSImageEffectRenderContext.Target(layer: 0, scratch: 0)
        let b = WSSImageEffectRenderContext.Target(layer: 0, scratch: 1)
        let other = WSSImageEffectRenderContext.Target(layer: 2, scratch: 0)
        let requests = [a: SIMD2(64, 64), b: SIMD2(64, 64), other: SIMD2(32, 32)]
        let one = try c.acquire(requests: requests, output: output)
        let two = try c.acquire(requests: requests, output: output)
        let textures = Array(one.intermediateTargets.values) + Array(two.intermediateTargets.values)
        XCTAssertEqual(Set(textures.map(ObjectIdentifier.init)).count, 6)
        c.release(one)
        XCTAssertThrowsError(
            try c.acquire(requests: requests, output: output, inputs: textures))
        // Failed acquisition did not consume a slot.
        let again = try c.acquire(requests: requests, output: output)
        XCTAssertTrue(again.intermediateTargets[a] === one.intermediateTargets[a])
        c.release(again)
        let changed = try c.acquire(requests: [b: SIMD2(128, 64)], output: output)
        XCTAssertEqual(changed.intermediateTargets.count, 1)
        XCTAssertEqual(changed.intermediateTargets[b]?.width, 128)
        c.release(changed)
        c.release(two)
    }
}
