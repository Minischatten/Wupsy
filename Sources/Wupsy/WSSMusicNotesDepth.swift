import Foundation

struct WSSMusicNotesDepth: Codable, Equatable {
    enum Side: String, Codable, CaseIterable {
        case behind, inFront
    }

    struct Change: Codable, Equatable {
        var position: Float
        var side: Side

        private enum CodingKeys: String, CodingKey, CaseIterable { case position, side }

        init(position: Float, side: Side) {
            self.position = position
            self.side = side
        }

        init(from decoder: Decoder) throws {
            try decoder.fields(CodingKeys.allCases.map(\.rawValue))
            let c = try decoder.container(keyedBy: CodingKeys.self)
            position = try c.decode(Float.self, forKey: .position)
            side = try c.decode(Side.self, forKey: .side)
        }
    }

    static let maximumChanges = 8
    var enabled = true
    var target: UUID
    var start: Side = .inFront
    var changes: [Change] = []
    var includesStaff: Bool?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case enabled, target, start, changes, includesStaff
    }

    init(target: UUID) { self.target = target }

    init(from decoder: Decoder) throws {
        try decoder.fields(CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        target = try c.decode(UUID.self, forKey: .target)
        start = try c.decode(Side.self, forKey: .start)
        includesStaff = try c.decodeIfPresent(Bool.self, forKey: .includesStaff)
        var points = try c.nestedUnkeyedContainer(forKey: .changes)
        while !points.isAtEnd {
            guard changes.count < Self.maximumChanges else {
                throw WSSSceneError.invalid("musicNotes depth change count")
            }
            changes.append(try points.decode(Change.self))
        }
        try validate()
    }

    func validate() throws {
        var previous: Float = 0
        guard changes.count <= Self.maximumChanges else {
            throw WSSSceneError.invalid("musicNotes depth change count")
        }
        for change in changes {
            guard change.position > previous, change.position < 100 else {
                throw WSSSceneError.invalid("musicNotes depth positions")
            }
            previous = change.position
        }
    }

    struct Uniforms {
        var first = SIMD4<Float>.zero
        var second = SIMD4<Float>.zero
        var section = SIMD4<UInt32>.zero

        init(_ depth: WSSMusicNotesDepth?, side: WSSMusicNotesDepth.Side?, closed: Bool) {
            guard let depth, let side else { return }
            section.w = closed ? 1 : 0
            section.x = UInt32(depth.changes.count)
            section.y = depth.start == .inFront ? 1 : 0
            section.z = side == .inFront ? 2 : 1
            for (index, change) in depth.changes.enumerated() {
                if index < 4 {
                    first[index] = change.position / 100
                } else {
                    second[index - 4] = change.position / 100
                }
                if change.side == .inFront {
                    section.y |= 1 << (index + 1)
                }
            }
        }
    }

    // Built once per resources snapshot, only for eligible visible targets.
    static func plan(for scene: WSSScene) -> [Int: [Int]] {
        var targets: [UUID: Int] = [:]
        for (index, node) in scene.layers.enumerated() {
            if case .image(let layer) = node, layer.visible, layer.composition == .sourceOver,
                let id = layer.depthID
            {
                targets[id] = index
            }
        }
        var result: [Int: [Int]] = [:]
        for (index, node) in scene.layers.enumerated() {
            if case .musicNotes(let layer) = node, layer.visible,
                layer.placementMode == .animatedPath, layer.usesActivePath,
                let depth = layer.depth, depth.enabled, let target = targets[depth.target]
            {
                result[target, default: []].append(index)
            }
        }
        return result
    }
}
