import Foundation
import simd

// Optional native v1 extension. Scheduling has no mutable state or timer.
struct WSSStarfieldShootingStars: Codable, Equatable {
    var enabled = false
    var frequency: Double = 2  // Events per minute; mean spacing, not a fixed cadence.
    var speed: Double = 700
    var tailLength: Double = 180
    var brightness: Double = 1.5
    var direction: Double = 315  // 0 right, 90 up in lower-left scene coordinates.
    var directionVariation: Double = 12
    init() {}
    enum CodingKeys: String, CodingKey, CaseIterable {
        case enabled, frequency, speed, tailLength, brightness, direction, directionVariation
    }
    init(from decoder: Decoder) throws {
        try decoder.fields(CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        frequency = try c.decode(Double.self, forKey: .frequency)
        speed = try c.decode(Double.self, forKey: .speed)
        tailLength = try c.decode(Double.self, forKey: .tailLength)
        brightness = try c.decode(Double.self, forKey: .brightness)
        direction = try c.decode(Double.self, forKey: .direction)
        directionVariation = try c.decode(Double.self, forKey: .directionVariation)
        try validate()
    }
    var isEffective: Bool { enabled && frequency > 0 && brightness > 0 }
    func validate() throws {
        guard
            WSSShootingStarParameter.allCases.allSatisfy({
                let v = $0.value(self)
                return v.isFinite && $0.range.contains(v)
            })
        else { throw WSSSceneError.invalid("shooting star parameters") }
    }
}
enum WSSShootingStarParameter: String, CaseIterable {
    case frequency, speed, tailLength, brightness, direction, directionVariation
    var title: String { WSSStarfieldText.text("shootingStars." + rawValue) }
    var range: ClosedRange<Double> {
        switch self {
        case .frequency: return 0...12
        case .speed: return 50...3000
        case .tailLength: return 0...1024
        case .brightness: return 0...4
        case .direction: return 0...360
        case .directionVariation: return 0...90
        }
    }
    private var keyPath: WritableKeyPath<WSSStarfieldShootingStars, Double> {
        switch self {
        case .frequency: return \.frequency
        case .speed: return \.speed
        case .tailLength: return \.tailLength
        case .brightness: return \.brightness
        case .direction: return \.direction
        case .directionVariation: return \.directionVariation
        }
    }
    func value(_ c: WSSStarfieldShootingStars) -> Double { c[keyPath: keyPath] }
    func apply(_ value: Double, to c: inout WSSStarfieldShootingStars) throws {
        guard value.isFinite, range.contains(value) else {
            throw WSSSceneError.invalid("shooting star parameter")
        }
        c[keyPath: keyPath] = value
        try c.validate()
    }
}
struct WSSShootingStarEvent: Equatable {
    let slot: UInt64
    let origin: SIMD2<Double>  // Normalized inside the region; independent of drift/count/color.
    let heading: SIMD2<Double>
    let speedFactor: Double
    let radius: Double
    let brightness: Double
    let duration: Double
    let age: Double
    var envelope: Double {
        let t = age / duration
        func smooth(_ x: Double) -> Double {
            let v = min(1, max(0, x))
            return v * v * (3 - 2 * v)
        }
        return smooth(t / 0.15) * smooth((1 - t) / 0.3)
    }
    func head(_ c: WSSStarfieldConfiguration) -> SIMD2<Double> {
        SIMD2(c.x, c.y) + origin * SIMD2(c.width, c.height)
            + heading * (c.shootingStars.speed * speedFactor * age)
    }
}
enum WSSShootingStarEvents {
    static let cycleSlots: UInt64 = 1 << 32
    static let maximumActivePerLayer = 2
    static let maximumDuration: Double = 2
    static func samples(seed: UInt32, slot: UInt64) -> [Double] {
        // Separate METEOR domain; fixed bounded draws do not consume the STAR stream.
        var rng = WSSRainRandom(
            seed: ((UInt64(seed) << 32) | 0x4D45_5445) ^ (slot &* 0x9E37_79B9_7F4A_7C15))
        return (0..<8).map { _ in Double(rng.unit()) }
    }
    static func events(_ c: WSSStarfieldConfiguration, at time: Double) -> [WSSShootingStarEvent] {
        let m = c.shootingStars
        guard m.isEffective, time.isFinite, time >= 0,
            (try? m.validate()) != nil
        else { return [] }
        let period = 60 / m.frequency
        // Bounded cycle avoids overflowing integer slot IDs even at enormous seeks.
        // At maximum frequency the cycle exceeds 680 years.
        let phase = time.truncatingRemainder(dividingBy: period * Double(cycleSlots))
        let slot = min(cycleSlots - 1, UInt64(floor(phase / period)))
        let local = phase - Double(slot) * period
        var result: [WSSShootingStarEvent] = []
        for previous in 0..<maximumActivePerLayer {
            if previous == 1 && slot == 0 && time < period { continue }
            let id = previous == 0 ? slot : (slot == 0 ? cycleSlots - 1 : slot - 1)
            let s = samples(seed: c.seed, slot: id)
            let age = local + Double(previous) * period - period * (0.1 + 0.8 * s[0])
            let duration = 1.1 + 0.9 * s[3]
            guard age >= 0, age < duration else { continue }
            let angle = (m.direction + (2 * s[4] - 1) * m.directionVariation) * .pi / 180
            result.append(
                .init(
                    slot: id, origin: SIMD2(0.1 + 0.8 * s[1], 0.15 + 0.7 * s[2]),
                    heading: SIMD2(cos(angle), sin(angle)), speedFactor: 0.85 + 0.3 * s[5],
                    radius: 1 + 0.8 * s[6], brightness: 0.8 + 0.2 * s[7], duration: duration,
                    age: age))
        }
        return result
    }
}
