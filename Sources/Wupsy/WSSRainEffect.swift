import Foundation
import simd

// Independently designed native rain. Logical canvas coordinates; no engine camera,
// texture, simulation, shader or random procedure participates in this model.
struct WSSRainEffect: Equatable {
    struct Opacity: Equatable {
        var min: Float = 0.08
        var max: Float = 0.24
    }
    struct Profile: Codable, Equatable {
        var length: Float
        var width: Float
        enum CodingKeys: String, CodingKey { case length, width }
        init(length: Float, width: Float) {
            self.length = length
            self.width = width
        }
        init(from decoder: Decoder) throws {
            try decoder.fields(["length", "width"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            length = try c.decode(Float.self, forKey: .length)
            width = try c.decode(Float.self, forKey: .width)
        }
    }
    static let authoredProfiles: [Profile] = [
        .init(length: 24, width: 1.2), .init(length: 40, width: 1.6),
        .init(length: 56, width: 2.0),
    ]
    var profiles: [Profile]? = nil
    var direction: Float = 0
    var speed: Float = 900
    var density: Float = 100
    var length: Float = 32
    var width: Float = 1.2
    var opacity = Opacity()
    var seed: UInt32 = 1

    var heading: SIMD2<Float> {
        let a = direction * .pi / 180
        return SIMD2(sin(a), -cos(a))
    }
    var velocity: SIMD2<Float> { heading * speed }
    func validate() throws {
        if let profiles {
            guard profiles.count == 3,
                profiles.allSatisfy({
                    // Includes the full legacy class envelope: 0.5*0.5 through 256*1.5.
                    $0.length.isFinite && (0.25...384).contains($0.length)
                        && $0.width.isFinite && (0.25...8).contains($0.width)
                })
            else { throw WSSSceneError.invalid("rain profiles") }
        }
        guard
            [direction, speed, density, length, width, opacity.min, opacity.max]
                .allSatisfy(\.isFinite),
            direction >= 0, direction < 360, (0...6000).contains(speed),
            (0...2000).contains(density), (0.5...256).contains(length),
            (0.25...8).contains(width), (0...1).contains(opacity.min),
            (opacity.min...1).contains(opacity.max)
        else { throw WSSSceneError.invalid("rain parameters") }
    }
}
struct WSSRainRegion: Equatable {
    var x: Float
    var y: Float
    var width: Float
    var height: Float
    var center: SIMD2<Float> { SIMD2(x + width / 2, y + height / 2) }
    func validate() throws {
        guard [x, y, width, height].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
            width > 0, height > 0, width <= 8192, height <= 8192,
            Double(width) * Double(height) <= 32 * 1024 * 1024
        else { throw WSSSceneError.invalid("rain region") }
    }
}
struct WSSRainLayer {
    enum Composition { case sourceOver, additive }
    var region: WSSRainRegion
    var rain = WSSRainEffect()
    var visible = true
    var composition: Composition = .sourceOver
    var mask: WSSImageMask? = nil
}

// Two aligned float4s (32 bytes, alignment 16). Legacy: length factor, 0, 0, 0.
// Profile mode: absolute length, absolute width, profile index, 0.
struct WSSRainInstance: Equatable {
    let state: SIMD4<Float>  // cross fraction, travel phase, depth group, alpha
    let variation: SIMD4<Float>
    var lengthScale: Float { variation.x }
}

struct WSSRainPopulation {
    static let budget = 8192
    static let groups = 8
    // Equal-probability native classes, independent of the existing depth model.
    // Mean factor 1 keeps length as the reference, not the maximum.
    static let lengthScales: [Float] = [0.5, 1, 1.5]
    let instances: [WSSRainInstance]
    let layer: WSSRainLayer
    let nominalCount: Int
    let crossSpan: Float
    let travelSpan: Float
    static func depthScale(_ group: Int) -> Float {
        // Own 2.5D model: eight equally spaced depth samples, scale in (0.65, 1.35).
        0.65 + 0.7 * (Float(group) + 0.5) / Float(groups)
    }
    init(_ layer: WSSRainLayer) throws {
        try layer.region.validate()
        try layer.rain.validate()
        self.layer = layer
        let r = layer.region
        let e = layer.rain
        let d = e.heading
        // Retain the established cross-axis domain; extra length needs clearance
        // only along travel. Length edits preserve the current generator's layout prefix.
        let maximumLength = e.profiles?.map(\.length).max()
        let maximumWidth = e.profiles?.map(\.width).max()
        let crossPadding = max(maximumLength ?? e.length, maximumWidth ?? e.width) * 1.35 + 2
        let travelPadding =
            max(maximumLength ?? (e.length * Self.lengthScales.max()!), maximumWidth ?? e.width)
            * 1.35 + 2
        crossSpan = abs(d.y) * r.width + abs(d.x) * r.height + crossPadding
        travelSpan = abs(d.x) * r.width + abs(d.y) * r.height + travelPadding
        let area = Double(r.width) * Double(r.height)
        nominalCount = Int((Double(e.density) * area / 1_000_000).rounded())
        // Include off-region instances explicitly, preserving density in the clipped rectangle.
        let count =
            nominalCount == 0
            ? 0 : Int(ceil(Double(nominalCount) * Double(crossSpan) * Double(travelSpan) / area))
        guard count <= Self.budget else {
            throw WSSSceneError.invalid(
                "rain instance budget exceeded (maximum 8192 including margins)")
        }
        var random = WSSRainRandom(seed: e.seed, stream: .layout)
        // Separate state per purpose: adding shape draws cannot shift layout draws.
        var lengths = WSSRainRandom(seed: e.seed, stream: .length)
        var profiles = WSSRainRandom(seed: e.seed, stream: .profile)
        instances = (0..<count).map { _ in
            let cross = random.unit()
            let phase = random.unit()
            let group = min(Self.groups - 1, Int(random.unit() * Float(Self.groups)))
            let alpha = e.opacity.min + random.unit() * (e.opacity.max - e.opacity.min)
            let lengthClass = min(
                Self.lengthScales.count - 1, Int(lengths.unit() * Float(Self.lengthScales.count)))
            if let choices = e.profiles {
                let index = min(2, Int(profiles.unit() * 3))
                return WSSRainInstance(
                    state: SIMD4(cross, phase, Float(group), alpha),
                    variation: SIMD4(choices[index].length, choices[index].width, Float(index), 0))
            }
            return WSSRainInstance(
                state: SIMD4(cross, phase, Float(group), alpha),
                variation: SIMD4(Self.lengthScales[lengthClass], 0, 0, 0))
        }
    }
    func geometricLength(_ index: Int) -> Float {
        let instance = instances[index]
        if layer.rain.profiles != nil {
            return instance.variation.x * Self.depthScale(Int(instance.state.z))
        }
        return layer.rain.length * Self.depthScale(Int(instance.state.z)) * instance.lengthScale
    }
    func phase(at time: Double, group: Int) -> Float {
        guard layer.rain.speed > 0 else { return 0 }
        let period =
            Double(travelSpan) / (Double(layer.rain.speed) * Double(Self.depthScale(group)))
        return Float(time.truncatingRemainder(dividingBy: period) / period)
    }
    // Same native analytic contract as the vertex stage; useful for deterministic diagnostics.
    func position(_ index: Int, at time: Double) -> SIMD2<Float> {
        let p = instances[index].state
        let d = layer.rain.heading
        let q = p.y + phase(at: time, group: Int(p.z))
        return layer.region.center + SIMD2(-d.y, d.x) * ((p.x - 0.5) * crossSpan)
            + d * ((q - floor(q) - 0.5) * travelSpan)
    }
}
