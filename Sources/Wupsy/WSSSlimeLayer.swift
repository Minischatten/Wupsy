import Foundation
import simd

struct WSSSlimeLayer: Equatable {
    static let maximumLayers = 16
    static let referenceSize: Float = 32
    static let sizeRange: ClosedRange<Float> = 4...128
    // Longest diagonal under the WSS 8192-axis and 32 Mi-pixel limits.
    static let maximumDistance = ceil(hypot(Float(8192), Float(4096)))

    func distanceInspectorLimit(canvas: WSSSceneDocumentV1.Canvas) -> Float {
        let down = WSSSlimePrototype.fallAxis(direction: configuration.direction)
        let span = abs(down.x) * Float(canvas.width) + abs(down.y) * Float(canvas.height)
        return min(Self.maximumDistance, max(450, configuration.distance, ceil(span)))
    }

    var transform: WSSSceneDocumentV1.Transform
    var configuration = WSSSlimeConfiguration()
    var visible = true

    var isAnimated: Bool { visible && configuration.opacity > 0 && configuration.speed > 0 }

    func nativeTransform() throws -> WSSImageTransform {
        let native = try transform.native()
        guard
            zip(transform.size, transform.scale).allSatisfy({
                Self.sizeRange.contains($0 * $1)
            })
        else { throw WSSDocumentError.invalid("slime transform size") }
        return native
    }
}

struct WSSSlimeConfiguration: Codable, Equatable {
    static let defaultReflectionColor = WSSFogConfiguration.Color(
        red: 0.87, green: 0.97, blue: 0.93)

    var reflectionColor = Self.defaultReflectionColor
    var color = WSSFogConfiguration.Color(red: 0.13, green: 0.26, blue: 0.15)
    var opacity: Float = 1
    var gloss: Float = 1
    var width: Float = 18
    var length: Float = 97
    var speed: Float = 1
    var cycleOffset: Float = 0
    var dropSize: Float = 19
    var direction: Float = 180
    var distance: Float = 258

    enum Value: String, CodingKey, CaseIterable {
        case color, reflectionColor, opacity, gloss, width, length, speed, dropSize, direction,
            distance, cycleOffset

        static var numeric: [Self] {
            allCases.filter { $0 != .color && $0 != .reflectionColor && $0 != .cycleOffset }
        }

        var range: ClosedRange<Float> {
            switch self {
            case .color, .reflectionColor, .opacity: return 0...1
            case .cycleOffset: return 0...Float(1).nextDown
            case .gloss: return 0...2
            case .width: return 9...36
            case .dropSize: return 9.5...38
            case .length: return 24...300
            case .speed: return 0...3
            case .direction: return 0...360
            case .distance: return 24...WSSSlimeLayer.maximumDistance
            }
        }

        var keyPath: WritableKeyPath<WSSSlimeConfiguration, Float> {
            switch self {
            case .color, .reflectionColor: preconditionFailure("Slime color has three components")
            case .opacity: return \.opacity
            case .gloss: return \.gloss
            case .width: return \.width
            case .length: return \.length
            case .speed: return \.speed
            case .cycleOffset: return \.cycleOffset
            case .dropSize: return \.dropSize
            case .direction: return \.direction
            case .distance: return \.distance
            }
        }
    }

    static func nextCycleOffset(occupied: [Float]) -> Float {
        let phases = occupied.map(Double.init).sorted()
        guard let first = phases.first else { return 0 }
        // Visit gaps by ascending start phase. Equal gaps keep the first one.
        var longest = -1.0
        var midpoint = 0.0
        for (start, end) in zip(phases, Array(phases.dropFirst()) + [first + 1]) {
            let gap = end - start
            if gap > longest {
                longest = gap
                midpoint = start + gap * 0.5
            }
        }
        return min(Float(midpoint.truncatingRemainder(dividingBy: 1)), Float(1).nextDown)
    }

    init() {}

    init(from decoder: Decoder) throws {
        try decoder.fields(Value.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: Value.self)
        color = try c.decode(WSSFogConfiguration.Color.self, forKey: .color)
        if c.contains(.reflectionColor) {
            reflectionColor = try c.decode(WSSFogConfiguration.Color.self, forKey: .reflectionColor)
        }
        cycleOffset = try c.decodeIfPresent(Float.self, forKey: .cycleOffset) ?? 0
        for parameter in Value.numeric {
            self[keyPath: parameter.keyPath] = try c.decode(Float.self, forKey: parameter)
        }
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: Value.self)
        try c.encode(color, forKey: .color)
        try c.encode(cycleOffset, forKey: .cycleOffset)
        if reflectionColor != Self.defaultReflectionColor {
            try c.encode(reflectionColor, forKey: .reflectionColor)
        }
        for parameter in Value.numeric {
            try c.encode(self[keyPath: parameter.keyPath], forKey: parameter)
        }
    }

    func validate() throws {
        for (key, tint) in [(Value.color, color), (.reflectionColor, reflectionColor)] {
            guard [tint.red, tint.green, tint.blue].allSatisfy(key.range.contains) else {
                throw WSSDocumentError.invalid("slime." + key.rawValue)
            }
        }
        guard Value.cycleOffset.range.contains(cycleOffset) else {
            throw WSSDocumentError.invalid("slime.cycleOffset")
        }
        for parameter in Value.numeric
        where !parameter.range.contains(self[keyPath: parameter.keyPath]) {
            throw WSSDocumentError.invalid("slime." + parameter.rawValue)
        }
    }
}
