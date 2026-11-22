import Foundation

enum WSSMusicNoteSymbol: String, Codable, CaseIterable {
    case quarter, eighth, double, trebleClef

    var atlasIndex: UInt32 {
        switch self {
        case .quarter: return 0
        case .eighth: return 1
        case .double: return 2
        case .trebleClef: return 3
        }
    }
}

struct WSSMusicNotesLayer: Equatable {
    static let maximumCount = 128
    static let maximumLayers = 8
    static let maximumPerScene = 512
    static let sizeRange: ClosedRange<Float> = 4...512
    static let speedRange: ClosedRange<Float> = 0...256

    var visible = true
    var region: WSSSceneDocumentV1.Region
    var notes = Configuration()
    var path: WSSMusicNotesPath? = nil
    var staff: WSSMusicNotesStaff? = nil
    var placement: Placement?
    var freeSymbol: SingleSymbol?
    var anchoredSymbol: SingleSymbol?
    var freePosition: SIMD2<Float>?
    var anchorPosition: Float?
    var alignToPath: Bool?
    var depth: WSSMusicNotesDepth?
    var perspective: WSSMusicNotesPerspective?
    private let staffPreparation = WSSMusicNotesStaff.Preparation()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.visible == rhs.visible && lhs.region == rhs.region && lhs.notes == rhs.notes
            && lhs.path == rhs.path && lhs.staff == rhs.staff
            && lhs.placement == rhs.placement && lhs.freeSymbol == rhs.freeSymbol
            && lhs.anchoredSymbol == rhs.anchoredSymbol && lhs.freePosition == rhs.freePosition
            && lhs.anchorPosition == rhs.anchorPosition && lhs.alignToPath == rhs.alignToPath
            && lhs.depth == rhs.depth && lhs.perspective == rhs.perspective
    }

    var isAnimated: Bool {
        guard visible else { return false }
        if let singleSymbol {
            let mode = singleSymbol.effectiveRotationMode(legacyRocking: notes.rotation)
            return singleSymbol.opacity > 0
                && (notes.hoverAmount > 0 || rockingAmount(for: singleSymbol) > 0
                    || mode == .continuous)
        }
        return notes.isAnimated
    }

    func preparedStaff() throws -> WSSMusicNotesStaff.Geometry? {
        try staffPreparation.geometry(for: self)
    }

    enum MotionParameter: String, CaseIterable {
        case hoverStrength, hoverFrequency, rotationStrength, rotationFrequency

        var defaultValue: Double {
            switch self {
            case .hoverStrength: return 12
            case .hoverFrequency: return 0.23
            case .rotationStrength: return 100
            case .rotationFrequency: return 0.13
            }
        }

        var range: ClosedRange<Double> {
            switch self {
            case .hoverStrength: return 0...25
            case .rotationStrength: return 0...200
            case .hoverFrequency, .rotationFrequency: return 0.05...1
            }
        }

        var isStrength: Bool { self == .hoverStrength || self == .rotationStrength }

        private var property: WritableKeyPath<Configuration, Double?> {
            switch self {
            case .hoverStrength: return \.hoverStrength
            case .hoverFrequency: return \.hoverFrequency
            case .rotationStrength: return \.rotationStrength
            case .rotationFrequency: return \.rotationFrequency
            }
        }

        func stored(in notes: Configuration) -> Double? { notes[keyPath: property] }
        func value(in notes: Configuration) -> Double { stored(in: notes) ?? defaultValue }
        func set(_ value: Double?, in notes: inout Configuration) {
            notes[keyPath: property] = value
        }
    }

    struct Configuration: Codable, Equatable {
        var count = 12
        var size: Float = 48
        var color = WSSFogConfiguration.Color(red: 1, green: 1, blue: 1)
        var opacity: Float = 0.85
        var direction: Float = 90
        var speed: Float = 24
        var hover = false
        var rotation = false
        var hoverStrength: Double?
        var hoverFrequency: Double?
        var rotationStrength: Double?
        var rotationFrequency: Double?
        var seed: UInt32 = 1
        var symbols: [WSSMusicNoteSymbol] = [.quarter, .eighth, .double]

        var hoverAmount: Float {
            hover ? Float(MotionParameter.hoverStrength.value(in: self) / 100) : 0
        }

        var rotationAmount: Float {
            rotation ? Float(MotionParameter.rotationStrength.value(in: self) / 100) : 0
        }

        var isAnimated: Bool {
            count > 0 && opacity > 0 && (speed > 0 || hoverAmount > 0 || rotationAmount > 0)
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case count, size, color, opacity, direction, speed, hover, rotation, seed, symbols
            case hoverStrength, hoverFrequency, rotationStrength, rotationFrequency
        }

        init() {}

        init(from decoder: Decoder) throws {
            try decoder.fields(CodingKeys.allCases.map(\.rawValue))
            let c = try decoder.container(keyedBy: CodingKeys.self)
            count = try c.decode(Int.self, forKey: .count)
            size = try c.decode(Float.self, forKey: .size)
            color = try c.decode(WSSFogConfiguration.Color.self, forKey: .color)
            opacity = try c.decode(Float.self, forKey: .opacity)
            direction = try c.decode(Float.self, forKey: .direction)
            speed = try c.decode(Float.self, forKey: .speed)
            hover = try c.decode(Bool.self, forKey: .hover)
            rotation = try c.decode(Bool.self, forKey: .rotation)
            hoverStrength = try c.decodeIfPresent(Double.self, forKey: .hoverStrength)
            hoverFrequency = try c.decodeIfPresent(Double.self, forKey: .hoverFrequency)
            rotationStrength = try c.decodeIfPresent(Double.self, forKey: .rotationStrength)
            rotationFrequency = try c.decodeIfPresent(Double.self, forKey: .rotationFrequency)
            seed = try c.decode(UInt32.self, forKey: .seed)
            symbols = try c.decode([WSSMusicNoteSymbol].self, forKey: .symbols)
            try validate()
        }

        func validate() throws {
            guard (0...WSSMusicNotesLayer.maximumCount).contains(count),
                WSSMusicNotesLayer.sizeRange.contains(size),
                WSSMusicNotesLayer.speedRange.contains(speed),
                (0...360).contains(direction),
                [opacity, color.red, color.green, color.blue].allSatisfy({ (0...1).contains($0) }),
                !symbols.isEmpty, symbols.count <= WSSMusicNoteSymbol.allCases.count,
                Set(symbols).count == symbols.count,
                MotionParameter.allCases.allSatisfy({ $0.range.contains($0.value(in: self)) })
            else { throw WSSSceneError.invalid("musicNotes parameters") }
        }
    }

    func validate() throws {
        try notes.validate()
        try staff?.validate()
        try validatePlacement()
        try depth?.validate()
        try perspective?.validate()
        if let path {
            _ = try path.prepare(in: region)
        } else {
            try Self.validateRegion(region)
        }
    }

    static func validateRegion(_ region: WSSSceneDocumentV1.Region) throws {
        guard abs(region.x) <= 1_000_000, abs(region.y) <= 1_000_000,
            (1...8192).contains(region.width), (1...8192).contains(region.height),
            Double(region.width) * Double(region.height) <= 32 * 1024 * 1024
        else { throw WSSSceneError.invalid("musicNotes region") }
    }

    var canvasTransform: WSSSceneDocumentV1.Transform {
        if placementMode == .freeSingle, let symbol = singleSymbol {
            return .init(
                center: [singleCenter.x, singleCenter.y],
                size: [symbol.size * (symbol.symbol == .trebleClef ? 0.5 : 1), symbol.size])
        }
        return .init(
            center: [regionCenter.x, regionCenter.y],
            size: [region.width, region.height])
    }

    var heading: SIMD2<Double> {
        let angle = Double(notes.direction.truncatingRemainder(dividingBy: 360)) * .pi / 180
        return SIMD2(cos(angle), sin(angle))
    }

    var hoverAxis: SIMD2<Float> {
        guard notes.speed > 0 else { return SIMD2(0, 1) }
        let heading = heading
        return SIMD2(Float(-heading.y), Float(heading.x))
    }

    func phases(at time: Double) -> SIMD4<Float> {
        let heading = heading
        let oscillation = oscillationPhases(at: time)
        return SIMD4(
            Self.phase(
                time,
                rate: abs(heading.x) < 1e-12
                    ? 0 : heading.x * Double(notes.speed) / Double(region.width)),
            Self.phase(
                time,
                rate: abs(heading.y) < 1e-12
                    ? 0 : heading.y * Double(notes.speed) / Double(region.height)),
            oscillation.x,
            oscillation.y)
    }

    func oscillationPhases(at time: Double, rockingAmount: Float? = nil) -> SIMD2<Float> {
        SIMD2(
            notes.hoverAmount > 0
                ? Self.phase(time, rate: MotionParameter.hoverFrequency.value(in: notes)) : 0,
            (rockingAmount ?? notes.rotationAmount) > 0
                ? Self.phase(time, rate: MotionParameter.rotationFrequency.value(in: notes)) : 0)
    }

    private static func phase(_ time: Double, rate: Double) -> Float {
        guard rate != 0, time.isFinite else { return 0 }
        return Float(time.truncatingRemainder(dividingBy: 1 / abs(rate)) * rate)
    }

    static func instances(seed: UInt32) -> [SIMD4<Float>] {
        var random = WSSRainRandom(seed: UInt64(seed) << 32 | 0x4E4F_5445)  // NOTE
        return (0..<maximumCount).map { _ in
            SIMD4(random.unit(), random.unit(), random.unit(), random.unit())
        }
    }
}
