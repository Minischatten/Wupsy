import Foundation

enum WSSMusicNoteSymbol: String, Codable, CaseIterable {
    case quarter, eighth, double

    var atlasIndex: UInt32 {
        switch self {
        case .quarter: return 0
        case .eighth: return 1
        case .double: return 2
        }
    }
}

struct WSSMusicNotesLayer: Equatable {
    static let maximumCount = 128
    static let maximumLayers = 8
    static let maximumPerScene = 512
    static let sizeRange: ClosedRange<Float> = 4...192
    static let speedRange: ClosedRange<Float> = 0...256

    var visible = true
    var region: WSSSceneDocumentV1.Region
    var notes = Configuration()

    var isAnimated: Bool { visible && notes.isAnimated }

    struct Configuration: Codable, Equatable {
        var count = 12
        var size: Float = 48
        var color = WSSFogConfiguration.Color(red: 1, green: 1, blue: 1)
        var opacity: Float = 0.85
        var direction: Float = 90
        var speed: Float = 24
        var hover = false
        var rotation = false
        var seed: UInt32 = 1
        var symbols = WSSMusicNoteSymbol.allCases

        var isAnimated: Bool { count > 0 && opacity > 0 && (speed > 0 || hover || rotation) }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case count, size, color, opacity, direction, speed, hover, rotation, seed, symbols
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
                Set(symbols).count == symbols.count
            else { throw WSSSceneError.invalid("musicNotes parameters") }
        }
    }

    func validate() throws {
        try notes.validate()
        guard abs(region.x) <= 1_000_000, abs(region.y) <= 1_000_000,
            (1...8192).contains(region.width), (1...8192).contains(region.height),
            Double(region.width) * Double(region.height) <= 32 * 1024 * 1024
        else { throw WSSSceneError.invalid("musicNotes region") }
    }

    var canvasTransform: WSSSceneDocumentV1.Transform {
        .init(
            center: [region.x + region.width / 2, region.y + region.height / 2],
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
        return SIMD4(
            Self.phase(
                time,
                rate: abs(heading.x) < 1e-12
                    ? 0 : heading.x * Double(notes.speed) / Double(region.width)),
            Self.phase(
                time,
                rate: abs(heading.y) < 1e-12
                    ? 0 : heading.y * Double(notes.speed) / Double(region.height)),
            notes.hover ? Self.phase(time, rate: 0.23) : 0,
            notes.rotation ? Self.phase(time, rate: 0.13) : 0)
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
