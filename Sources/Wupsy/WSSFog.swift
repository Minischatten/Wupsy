import Foundation

struct WSSFogLayer: Equatable {
    var visible: Bool
    var fog: WSSFogConfiguration
    var preset: WSSFogPreset

    init(visible: Bool = true, fog: WSSFogConfiguration, preset: WSSFogPreset? = nil) {
        self.visible = visible
        self.fog = fog
        self.preset = preset ?? WSSFogPreset.inferred(from: fog)
    }
}

struct WSSFogConfiguration: Codable, Equatable {
    var density: Float
    var softness: Float
    var driftX: Float
    var driftY: Float
    var scale: Float
    var height: Float
    // SDR sRGB components, matching the native scene's BGRA8 output.
    var color = Color(red: 0.94, green: 0.95, blue: 0.96)

    struct Color: Codable, Equatable {
        var red: Float
        var green: Float
        var blue: Float

        enum CodingKeys: String, CodingKey, CaseIterable { case red, green, blue }
        init(red: Float, green: Float, blue: Float) {
            self.red = red
            self.green = green
            self.blue = blue
        }
        init(from decoder: Decoder) throws {
            try decoder.fields(CodingKeys.allCases.map(\.rawValue))
            let c = try decoder.container(keyedBy: CodingKeys.self)
            red = try c.decode(Float.self, forKey: .red)
            green = try c.decode(Float.self, forKey: .green)
            blue = try c.decode(Float.self, forKey: .blue)
        }
    }

    var driftSpeed: Double { hypot(Double(driftX), Double(driftY)) }

    var driftUnitDirection: SIMD2<Double>? {
        let speed = driftSpeed
        guard speed > 0 else { return nil }
        return SIMD2(Double(driftX), Double(driftY)) / speed
    }

    static func driftSpeedLimit(in direction: SIMD2<Double>) -> Double {
        min(
            Double(WSSFogParameter.driftX.range.upperBound) / abs(direction.x),
            Double(WSSFogParameter.driftY.range.upperBound) / abs(direction.y))
    }

    mutating func setDriftSpeed(_ speed: Double, in direction: SIMD2<Double>) {
        guard speed.isFinite, speed >= 0 else { return }
        let magnitude = min(speed, Self.driftSpeedLimit(in: direction))
        driftX = Float(magnitude * direction.x)
        driftY = Float(magnitude * direction.y)
    }

    var isAnimated: Bool { density > 0 && (driftX != 0 || driftY != 0) }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case density, softness, driftX, driftY, scale, height, color
    }

    init(density: Float, softness: Float, driftX: Float, driftY: Float, scale: Float, height: Float)
    {
        self.density = density
        self.softness = softness
        self.driftX = driftX
        self.driftY = driftY
        self.scale = scale
        self.height = height
    }

    init(from decoder: Decoder) throws {
        try decoder.fields(CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        density = try c.decode(Float.self, forKey: .density)
        softness = try c.decode(Float.self, forKey: .softness)
        driftX = try c.decode(Float.self, forKey: .driftX)
        driftY = try c.decode(Float.self, forKey: .driftY)
        scale = try c.decode(Float.self, forKey: .scale)
        height = try c.decode(Float.self, forKey: .height)
        color = try c.decode(Color.self, forKey: .color)
        try validate()
    }

    func validate() throws {
        guard WSSFogParameter.allCases.allSatisfy({ $0.range.contains(self[keyPath: $0.keyPath]) }),
            [color.red, color.green, color.blue].allSatisfy({ (0...1).contains($0) })
        else { throw WSSSceneError.invalid("fog parameters") }
    }
}

enum WSSFogPreset: String, Codable, CaseIterable {
    case ground, atmosphere

    static func inferred(from configuration: WSSFogConfiguration) -> Self {
        configuration == Self.atmosphere.configuration ? .atmosphere : .ground
    }

    var configuration: WSSFogConfiguration {
        switch self {
        case .ground:
            return .init(
                density: 0.48, softness: 0.75, driftX: 9, driftY: 0, scale: 1500, height: 0.38)
        case .atmosphere:
            return .init(
                density: 0.23, softness: 0.9, driftX: 4, driftY: -0.5, scale: 2200, height: 1.5)
        }
    }
}

enum WSSFogParameter: String, CaseIterable {
    case density, softness, driftX, driftY, scale, height

    var keyPath: WritableKeyPath<WSSFogConfiguration, Float> {
        switch self {
        case .density: return \.density
        case .softness: return \.softness
        case .driftX: return \.driftX
        case .driftY: return \.driftY
        case .scale: return \.scale
        case .height: return \.height
        }
    }

    var range: ClosedRange<Float> {
        switch self {
        case .density, .softness: return 0...1
        case .driftX, .driftY: return -128...128
        case .scale: return 32...8192
        case .height: return 0.05...1.5
        }
    }
}
