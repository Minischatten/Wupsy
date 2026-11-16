import Foundation

// Independent optional configuration/seed. No coupling to STAR or METEOR random streams.
struct WSSMilkyWay: Codable, Equatable {
    var enabled = false
    var positionX: Double = 0.5
    var positionY: Double = 0.5
    var angle: Double = 30
    var width: Double = 0.22
    var intensity: Double = 0.45
    var structure: Double = 0.75
    var dust: Double = 0.7
    var red: Double = 0.8
    var green: Double = 0.86
    var blue: Double = 1
    var seed: UInt32 = 1
    init() {}
    enum CodingKeys: String, CodingKey, CaseIterable {
        case enabled, positionX, positionY, angle, width, intensity, structure, dust, red, green,
            blue, seed
    }
    init(from decoder: Decoder) throws {
        try decoder.fields(CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        positionX = try c.decode(Double.self, forKey: .positionX)
        positionY = try c.decode(Double.self, forKey: .positionY)
        angle = try c.decode(Double.self, forKey: .angle)
        width = try c.decode(Double.self, forKey: .width)
        intensity = try c.decode(Double.self, forKey: .intensity)
        structure = try c.decode(Double.self, forKey: .structure)
        dust = try c.decode(Double.self, forKey: .dust)
        red = try c.decode(Double.self, forKey: .red)
        green = try c.decode(Double.self, forKey: .green)
        blue = try c.decode(Double.self, forKey: .blue)
        seed = try c.decode(UInt32.self, forKey: .seed)
        try validate()
    }
    var isEffective: Bool { enabled && intensity > 0 && max(red, max(green, blue)) > 0 }
    func validate() throws {
        guard
            WSSMilkyWayParameter.allCases.allSatisfy({
                let value = $0.value(self)
                return value.isFinite && $0.range.contains(value)
            }),
            [red, green, blue].allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else { throw WSSSceneError.invalid("milky way parameters") }
    }
}
enum WSSMilkyWayParameter: String, CaseIterable {
    case positionX, positionY, angle, width, intensity, structure, dust, seed
    var title: String { WSSStarfieldText.text("milkyWay." + rawValue) }
    var range: ClosedRange<Double> {
        switch self {
        case .positionX, .positionY, .structure, .dust: return 0...1
        case .angle: return 0...360
        case .width: return 0.03...1
        case .intensity: return 0...2
        case .seed: return 0...Double(UInt32.max)
        }
    }
    private var keyPath: WritableKeyPath<WSSMilkyWay, Double>? {
        switch self {
        case .positionX: return \.positionX
        case .positionY: return \.positionY
        case .angle: return \.angle
        case .width: return \.width
        case .intensity: return \.intensity
        case .structure: return \.structure
        case .dust: return \.dust
        case .seed: return nil
        }
    }
    func value(_ m: WSSMilkyWay) -> Double { self == .seed ? Double(m.seed) : m[keyPath: keyPath!] }
    func apply(_ value: Double, to m: inout WSSMilkyWay) throws {
        guard value.isFinite, range.contains(value), self != .seed || value.rounded() == value
        else { throw WSSSceneError.invalid("milky way parameter") }
        if self == .seed { m.seed = UInt32(value) } else { m[keyPath: keyPath!] = value }
        try m.validate()
    }
}
enum WSSStarfieldColorRole { case stars, milkyWay }
extension WSSScene {
    var hasEffectiveMilkyWay: Bool {
        layers.contains {
            if case .starfield(let layer) = $0 {
                return layer.visible && layer.starfield.milkyWay.isEffective
            }
            return false
        }
    }
}
