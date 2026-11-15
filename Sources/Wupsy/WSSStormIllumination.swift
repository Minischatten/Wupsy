import Foundation
import simd

// Optional additive v1 configuration. RGB is linear light, as in the native picker.
struct WSSStormIllumination: Codable, Equatable {
    var enabled = false
    var intensity: Double = 1.5
    var red: Double = 1
    var green: Double = 1
    var blue: Double = 1
    var shadowLift: Double = 0.02
    init() {}
    enum CodingKeys: String, CodingKey, CaseIterable {
        case enabled, intensity, red, green, blue, shadowLift
    }
    init(from decoder: Decoder) throws {
        try decoder.fields(CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        intensity = try c.decode(Double.self, forKey: .intensity)
        red = try c.decode(Double.self, forKey: .red)
        green = try c.decode(Double.self, forKey: .green)
        blue = try c.decode(Double.self, forKey: .blue)
        shadowLift = try c.decode(Double.self, forKey: .shadowLift)
        try validate()
    }
    func validate() throws {
        guard [intensity, red, green, blue, shadowLift].allSatisfy(\.isFinite),
            (0...4).contains(intensity), (0...0.25).contains(shadowLift),
            [red, green, blue].allSatisfy({ (0...1).contains($0) })
        else { throw WSSSceneError.invalid("storm illumination parameters") }
    }
    var isEffective: Bool {
        enabled && (intensity > 0 || shadowLift > 0) && max(red, max(green, blue)) > 0
    }
}
struct WSSStormLightingFrame: Equatable {
    // Per-channel EV and linear shadow contribution, aggregated before one final pass.
    let exposure: SIMD3<Float>
    let shadowLift: SIMD3<Float>
    var isEffective: Bool { simd_reduce_max(exposure) > 0 || simd_reduce_max(shadowLift) > 0 }
    static func illumination(scene: WSSScene, at time: Double) -> Self {
        var exposure = SIMD3<Double>.zero
        var lift = SIMD3<Double>.zero
        for node in scene.layers {
            guard case .storm(let layer) = node, layer.visible,
                layer.storm.illumination.isEffective,
                let event = WSSStormEvents.event(layer.storm, at: time)
            else { continue }
            let light = layer.storm.illumination
            let t = Double(event.intensity)
            // Same event and zero intervals, with a smooth falloff for illumination only.
            let pulse = t * t * (3 - 2 * t)
            let color = SIMD3(light.red, light.green, light.blue)
            exposure += color * (light.intensity * pulse)
            lift += color * (light.shadowLift * pulse)
        }
        return Self(
            exposure: SIMD3<Float>(simd_min(exposure, SIMD3(repeating: 4))),
            shadowLift: SIMD3<Float>(simd_min(lift, SIMD3(repeating: 0.25))))
    }
}
extension WSSScene {
    var hasEffectiveStormIllumination: Bool {
        layers.contains { node in
            if case .storm(let layer) = node {
                return layer.visible && layer.storm.illumination.isEffective
            }
            return false
        }
    }
}

enum WSSStormColorRole { case bolt, illumination }
enum WSSStormIlluminationParameter: String, CaseIterable {
    case intensity, shadowLift
    var range: ClosedRange<Double> { self == .intensity ? 0...4 : 0...0.25 }
    var title: String { Localization.string(key: "editor.storm.light." + rawValue) }
    func value(_ c: WSSStormIllumination) -> Double {
        self == .intensity ? c.intensity : c.shadowLift
    }
    func apply(_ value: Double, to c: inout WSSStormIllumination) throws {
        guard value.isFinite, range.contains(value) else {
            throw WSSSceneError.invalid("storm illumination parameter")
        }
        if self == .intensity { c.intensity = value } else { c.shadowLift = value }
    }
}
