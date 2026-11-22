import Foundation

struct WSSMusicNotesPerspective: Codable, Equatable {
    static let percentRange: ClosedRange<Float> = 10...200

    var enabled = false
    var start: Float = 100
    var end: Float = 30

    private enum CodingKeys: String, CodingKey, CaseIterable { case enabled, start, end }

    init() {}

    init(from decoder: Decoder) throws {
        try decoder.fields(CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        start = try c.decode(Float.self, forKey: .start)
        end = try c.decode(Float.self, forKey: .end)
        try validate()
    }

    var factors: SIMD2<Float> { SIMD2(start, end) / 100 }

    func factor(at progress: Float) -> Float {
        let limits = factors
        return limits.x + (limits.y - limits.x) * progress
    }

    func validate() throws {
        guard Self.percentRange.contains(start), Self.percentRange.contains(end) else {
            throw WSSSceneError.invalid("musicNotes perspective")
        }
    }
}

extension WSSMusicNotesLayer {
    var supportsPerspective: Bool {
        placementMode == .animatedPath && path?.enabled == true && path?.closed == false
    }

    var activePerspective: WSSMusicNotesPerspective? {
        guard supportsPerspective, let perspective, perspective.enabled,
            perspective.start != 100 || perspective.end != 100
        else { return nil }
        return perspective
    }
}
