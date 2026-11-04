import MetalKit

// Prepared per layer. Array positions, never parameter equality, identify stages.
// Resources are immutable/shared; each stage still has its own binding value.
struct WSSImageEffectPlan {
    struct Binding {
        var ripple: WSSRippleResources?
        var clouds: WSSCloudsResources?
        var flow: WSSFlowResources?
        var mask: MTLTexture?
        var field: WSSVectorFieldResources.Field?
        var noise: MTLTexture?
        var maskUV = SIMD2<Float>(1, 1)
    }
    struct Stage {
        let manifestIndex: Int
        let declaredEffect: WSSImageEffect
        let effect: WSSImageEffect?
        let binding: Binding
        var passCount: Int { effect.map(WSSImageEffectPlan.passCost) ?? 0 }
    }
    let stages: [Stage]
    let activeStages: [Stage]
    let effects: [WSSImageEffect]
    let passCount: Int
    var intermediateCount: Int { min(2, max(0, passCount - 1)) }

    init(stages: [Stage]) {
        self.stages = stages
        activeStages = stages.filter { $0.effect != nil }
        effects = stages.compactMap(\.effect)
        passCount = stages.reduce(0) { $0 + $1.passCount }
    }
    // Charge manifest stages before elision, GPU preparation or asset loading.
    static let maximumStages = 32
    static let maximumPassesPerStage = 8
    static let maximumPassesPerLayer = 64
    static let maximumPassesPerScene = 256

    static func passCost(_ effect: WSSImageEffect) -> Int {
        switch effect {
        case .ripple, .clouds, .flow: return 1
        }
    }
    @discardableResult static func validateBudget(_ effects: [WSSImageEffect]) throws -> Int {
        guard effects.count <= maximumStages else {
            throw WSSSceneError.invalid("image effect count budget exceeded (32)")
        }
        let costs = effects.map(passCost)
        let total = costs.reduce(0, +)
        guard costs.allSatisfy({ $0 <= maximumPassesPerStage }), total <= maximumPassesPerLayer
        else {
            throw WSSSceneError.invalid("image effect pass budget")
        }
        return total
    }

    init(
        effects: [WSSImageEffect],
        binding: (WSSImageEffect) throws -> Binding,
        flowActive: (WSSFlowEffect) -> Bool
    ) throws {
        try Self.validateBudget(effects)
        // Preserve the old all-neutral Ripple-pair raster path byte for byte.
        let retainFirstZeroRipple =
            effects.count == 2
            && effects.allSatisfy {
                if case .ripple(let r) = $0 { return r.amplitude == 0 }
                return false
            }
        stages = try effects.enumerated().map { index, declared in
            // Resolve even elided resources: identities must not conceal bad assets.
            let resources = try binding(declared)
            var active: WSSImageEffect? = declared
            switch declared {
            case .flow(let e): if !flowActive(e) { active = nil }
            case .ripple(let e):
                if effects.count > 1, e.amplitude == 0, !(retainFirstZeroRipple && index == 0) {
                    active = nil
                }
            case .clouds: break
            }
            return Stage(
                manifestIndex: index, declaredEffect: declared, effect: active, binding: resources)
        }
        activeStages = stages.filter { $0.effect != nil }
        self.effects = stages.compactMap(\.effect)
        passCount = stages.reduce(0) { $0 + $1.passCount }
    }
}
