import Foundation
import simd

// Original native procedural star layer. No textures, imported assets or simulation state.
struct WSSStarfieldConfiguration: Codable, Equatable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1920
    var height: Double = 1080
    var count: Int = 1500
    var size: Double = 1
    var brightness: Double = 0.8
    var red: Double = 1
    var green: Double = 1
    var blue: Double = 1
    var colorVariation: Double = 0.15
    var seed: UInt32 = 1
    var twinkleEnabled = false
    var twinkleIntensity: Double = 0.3
    var twinkleSpeed: Double = 0.3
    var driftX: Double = 0
    var driftY: Double = 0
    var shootingStars = WSSStarfieldShootingStars()
    var milkyWay = WSSMilkyWay()
    init() {}
    enum CodingKeys: String, CodingKey, CaseIterable {
        case x, y, width, height, count, size, brightness, red, green, blue, colorVariation, seed
        case twinkleEnabled, twinkleIntensity, twinkleSpeed, driftX, driftY, shootingStars, milkyWay
    }
    init(from decoder: Decoder) throws {
        try decoder.fields(CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        count = try c.decode(Int.self, forKey: .count)
        size = try c.decode(Double.self, forKey: .size)
        brightness = try c.decode(Double.self, forKey: .brightness)
        red = try c.decode(Double.self, forKey: .red)
        green = try c.decode(Double.self, forKey: .green)
        blue = try c.decode(Double.self, forKey: .blue)
        colorVariation = try c.decode(Double.self, forKey: .colorVariation)
        seed = try c.decode(UInt32.self, forKey: .seed)
        twinkleEnabled = try c.decode(Bool.self, forKey: .twinkleEnabled)
        twinkleIntensity = try c.decode(Double.self, forKey: .twinkleIntensity)
        twinkleSpeed = try c.decode(Double.self, forKey: .twinkleSpeed)
        driftX = try c.decode(Double.self, forKey: .driftX)
        driftY = try c.decode(Double.self, forKey: .driftY)
        shootingStars =
            try c.decodeIfPresent(WSSStarfieldShootingStars.self, forKey: .shootingStars) ?? .init()
        milkyWay = try c.decodeIfPresent(WSSMilkyWay.self, forKey: .milkyWay) ?? .init()
        try validate()
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        for parameter in WSSStarfieldParameter.allCases {
            let key = CodingKeys(rawValue: parameter.rawValue)!
            switch parameter {
            case .count: try c.encode(count, forKey: key)
            case .seed: try c.encode(seed, forKey: key)
            default: try c.encode(parameter.value(self), forKey: key)
            }
        }
        try c.encode(red, forKey: .red)
        try c.encode(green, forKey: .green)
        try c.encode(blue, forKey: .blue)
        try c.encode(twinkleEnabled, forKey: .twinkleEnabled)
        if milkyWay != WSSMilkyWay() { try c.encode(milkyWay, forKey: .milkyWay) }
        if shootingStars != WSSStarfieldShootingStars() {
            try c.encode(shootingStars, forKey: .shootingStars)
        }
    }
    func validate() throws {
        try shootingStars.validate()
        try milkyWay.validate()
        guard
            WSSStarfieldParameter.allCases.allSatisfy({
                let v = $0.value(self)
                return v.isFinite && $0.range.contains(v)
            }), [red, green, blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
            width * height <= 32 * 1024 * 1024
        else {
            throw WSSSceneError.invalid("starfield parameters")
        }
    }
    var isEffective: Bool { count > 0 && brightness > 0 && max(red, max(green, blue)) > 0 }
    var isAnimated: Bool {
        (isEffective
            && ((twinkleEnabled && twinkleIntensity > 0 && twinkleSpeed > 0) || driftX != 0
                || driftY != 0))
            || (shootingStars.isEffective && max(red, max(green, blue)) > 0)
            || (milkyWay.isEffective && (driftX != 0 || driftY != 0))
    }
    var canvasTransform: WSSSceneDocumentV1.Transform {
        .init(
            center: [Float(x + width / 2), Float(y + height / 2)],
            size: [Float(width), Float(height)])
    }
    func applying(_ t: WSSSceneDocumentV1.Transform) throws -> Self {
        guard t.rotation == 0 else { throw WSSSceneError.invalid("starfield rotation") }
        guard t != canvasTransform else { return self }
        var c = self
        c.width = Double(t.size[0]) * Double(t.scale[0])
        c.height = Double(t.size[1]) * Double(t.scale[1])
        c.x = Double(t.center[0]) - c.width / 2
        c.y = Double(t.center[1]) - c.height / 2
        try c.validate()
        return c
    }
    static func phase(time: Double, speed: Double, period: Double) -> Float {
        guard speed != 0 else { return 0 }
        // Reduce in Double before multiplication, including negative drift and long uptimes.
        return Float(
            ((time.truncatingRemainder(dividingBy: period / abs(speed)) * speed)
                .truncatingRemainder(dividingBy: period) + period).truncatingRemainder(
                    dividingBy: period))
    }
}
struct WSSStarfieldLayer: Equatable {
    var name: String? = nil
    var visible = true
    var starfield = WSSStarfieldConfiguration()
    func validate() throws {
        if let name { _ = try WallpaperTitle.normalized(name) }
        try starfield.validate()
    }
}
struct WSSStarfieldPopulation {
    struct Instance: Equatable {
        let state: SIMD4<Float>
        let variation: SIMD4<Float>
    }
    static let maximumLayers = 8
    static let maximumPerLayer = 16_384
    static let maximumPerScene = 65_536
    let instances: [Instance]
    init(count: Int, seed: UInt32) throws {
        guard (0...Self.maximumPerLayer).contains(count) else {
            throw WSSSceneError.invalid("star count")
        }
        var random = WSSRainRandom(seed: (UInt64(seed) << 32) | 0x5354_4152)
        instances = (0..<count).map { _ in
            let x = random.unit()
            let y = random.unit()
            let size = random.unit()
            let light = random.unit()
            let phase = random.unit() * 2 * Float.pi
            let group = floor(random.unit() * 8)
            return Instance(
                state: SIMD4(x, y, 0.5 + 1.5 * size * size, 0.12 + 0.88 * pow(light, 3)),
                variation: SIMD4(phase, group, random.unit() * 2 - 1, random.unit() * 2 - 1))
        }
    }
    static func color(_ base: SIMD3<Float>, variation: Float, warm: Float, tint: Float) -> SIMD3<
        Float
    > {
        simd_clamp(
            base * (SIMD3(repeating: 1) + variation * 0.15 * SIMD3(warm, tint, -warm)), .zero,
            SIMD3(repeating: 1))
    }
}
enum WSSStarfieldText {
    static func text(_ key: String) -> String {
        Localization.string(key: "editor.starfield." + key)
    }
    static var title: String { text("title") }
}
enum WSSStarfieldParameter: String, CaseIterable {
    case x, y, width, height, count, size, brightness, colorVariation, seed
    case twinkleIntensity, twinkleSpeed, driftX, driftY
    var title: String { WSSStarfieldText.text(rawValue) }
    var integral: Bool { self == .count || self == .seed }
    var range: ClosedRange<Double> {
        switch self {
        case .x, .y: return -1_000_000...1_000_000
        case .width, .height: return 1...8192
        case .count: return 0...16_384
        case .seed: return 0...Double(UInt32.max)
        case .size: return 0.25...16
        case .brightness: return 0...4
        case .colorVariation, .twinkleIntensity: return 0...1
        case .twinkleSpeed: return 0...2
        case .driftX, .driftY: return -10...10
        }
    }
    private var keyPath: WritableKeyPath<WSSStarfieldConfiguration, Double>? {
        switch self {
        case .x: return \.x
        case .y: return \.y
        case .width: return \.width
        case .height: return \.height
        case .size: return \.size
        case .brightness: return \.brightness
        case .colorVariation: return \.colorVariation
        case .twinkleIntensity: return \.twinkleIntensity
        case .twinkleSpeed: return \.twinkleSpeed
        case .driftX: return \.driftX
        case .driftY: return \.driftY
        case .count, .seed: return nil
        }
    }
    func value(_ c: WSSStarfieldConfiguration) -> Double {
        if self == .count { return Double(c.count) }
        if self == .seed { return Double(c.seed) }
        return c[keyPath: keyPath!]
    }
    func apply(_ value: Double, to c: inout WSSStarfieldConfiguration) throws {
        guard value.isFinite, range.contains(value), !integral || value.rounded() == value else {
            throw WSSSceneError.invalid("starfield parameter")
        }
        if self == .count {
            c.count = Int(value)
        } else if self == .seed {
            c.seed = UInt32(value)
        } else {
            c[keyPath: keyPath!] = value
        }
        try c.validate()
    }
}

extension WSSSceneLayer {
    var isStarfield: Bool {
        if case .starfield = self { return true }
        return false
    }
    var isPositionableRegion: Bool {
        if case .storm = self { return true }
        return isStarfield
    }
}
