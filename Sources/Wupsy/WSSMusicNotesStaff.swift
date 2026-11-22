import Foundation
import simd

struct WSSMusicNotesStaff: Codable, Equatable {
    static let spacingRange: ClosedRange<Float> = 1...256
    static let widthRange: ClosedRange<Float> = 0.25...64

    var enabled = false
    var spacing: Float = 12
    var width: Float = 1.5
    var color = WSSFogConfiguration.Color(red: 1, green: 1, blue: 1)
    var opacity: Float = 0.45

    enum CodingKeys: String, CodingKey, CaseIterable {
        case enabled, spacing, width, color, opacity
    }

    init() {}

    init(from decoder: Decoder) throws {
        try decoder.fields(CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        spacing = try c.decode(Float.self, forKey: .spacing)
        width = try c.decode(Float.self, forKey: .width)
        color = try c.decode(WSSFogConfiguration.Color.self, forKey: .color)
        opacity = try c.decode(Float.self, forKey: .opacity)
        try validate()
    }

    func validate() throws {
        guard Self.spacingRange.contains(spacing), Self.widthRange.contains(width),
            width < spacing,
            [color.red, color.green, color.blue, opacity].allSatisfy({ (0...1).contains($0) })
        else { throw WSSSceneError.invalid("musicNotes staff parameters") }
    }

    // Each edge emits one quad and its following join at most one more.
    static let maximumVertices = 5 * WSSMusicNotesPath.maximumFlattenedEdges * 12

    struct Geometry: Equatable {
        // Triangle list relative to origin, ordered by line in logical units.
        let origin: SIMD2<Double>
        let vertices: [SIMD2<Float>]
        let progress: [Float]
        let lineRanges: [Range<Int>]
        let closed: Bool
        // Local folds and near reversals can cause crowding. Distant
        // intersections are left as authored.
        let hasTightTurns: Bool
    }

    struct GeometryKey: Equatable {
        let path: WSSMusicNotesPath?
        let size: SIMD2<Double>
        let heading: SIMD2<Double>?
        let perspective: WSSMusicNotesPerspective?
        let spacing: Float
        let width: Float

        init(layer: WSSMusicNotesLayer, staff: WSSMusicNotesStaff) {
            path = layer.path.flatMap { $0.enabled ? $0 : nil }
            size = SIMD2(Double(layer.region.width), Double(layer.region.height))
            heading = path == nil ? layer.heading : nil
            perspective = layer.activePerspective
            spacing = staff.spacing
            width = staff.width
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            let samePath =
                lhs.path.map { path in rhs.path.map { path.sameCurve(as: $0) } ?? false }
                ?? (rhs.path == nil)
            return samePath && lhs.size == rhs.size && lhs.heading == rhs.heading
                && lhs.spacing == rhs.spacing && lhs.width == rhs.width
                && lhs.perspective == rhs.perspective
        }
    }

    final class Preparation {
        private let lock = NSLock()
        private var entry: (GeometryKey, Geometry)?

        func geometry(for layer: WSSMusicNotesLayer) throws -> Geometry? {
            guard let staff = layer.staff, staff.enabled else { return nil }
            try staff.validate()
            try WSSMusicNotesLayer.validateRegion(layer.region)
            let key = GeometryKey(layer: layer, staff: staff)

            lock.lock()
            defer { lock.unlock() }
            if let entry, entry.0 == key { return entry.1 }
            let centerline: (origin: Point, points: [Point], progress: [Float])
            if let path = key.path {
                centerline = try path.staffCenterline(scale: key.size)
            } else if let heading = key.heading {
                guard heading.x.isFinite, heading.y.isFinite else {
                    throw WSSSceneError.invalid("musicNotes staff heading")
                }
                let half = key.size / 2
                let extent = min(half.x / abs(heading.x), half.y / abs(heading.y))
                centerline = (half, [-extent * heading, extent * heading], [])
            } else {
                return nil
            }
            let geometry = staff.stroke(
                centerline.points, progress: centerline.progress, origin: centerline.origin,
                closed: key.path?.closed == true, perspective: key.perspective)
            entry = (key, geometry)
            return geometry
        }
    }

    private typealias Point = SIMD2<Double>

    private struct Section {
        let position: Point
        let normal: Point

        func at(_ distance: Double) -> Point { position + normal * distance }
    }

    private struct Join {
        let incoming: Section
        let outgoing: Section
        let bevel: Bool
        let reversal: Bool

        init(incoming: Section, outgoing: Section, bevel: Bool = false, reversal: Bool = false) {
            self.incoming = incoming
            self.outgoing = outgoing
            self.bevel = bevel
            self.reversal = reversal
        }
    }

    private func stroke(
        _ points: [Point], progress: [Float], origin: Point, closed: Bool,
        perspective: WSSMusicNotesPerspective?
    )
        -> Geometry
    {
        let normals = zip(points, points.dropFirst()).map { a, b -> Point in
            let delta = b - a
            return Point(-delta.y, delta.x) / simd_length(delta)
        }
        let edgeCount = normals.count
        let joins = (0..<(closed ? edgeCount : points.count)).map { index -> Join in
            let before = normals[(index + edgeCount - 1) % edgeCount]
            let after = normals[index % edgeCount]
            let position = points[index]
            if !closed && (index == 0 || index == edgeCount) {
                let section = Section(position: position, normal: index == 0 ? after : before)
                return Join(incoming: section, outgoing: section)
            }
            // (before + after) / (1 + dot) intersects the two offset edge lines.
            let denominator = 1 + simd_dot(before, after)
            if denominator >= 0.5 {
                let section = Section(position: position, normal: (before + after) / denominator)
                return Join(incoming: section, outgoing: section)
            }
            let reversal = denominator < 0.01
            return Join(
                incoming: Section(position: position, normal: before),
                outgoing: Section(position: position, normal: after),
                bevel: !reversal, reversal: reversal)
        }

        var vertices: [SIMD2<Float>] = []
        vertices.reserveCapacity(5 * edgeCount * 6)
        var vertexProgress: [Float] = []
        if !progress.isEmpty { vertexProgress.reserveCapacity(5 * edgeCount * 6) }
        var ranges: [Range<Int>] = []
        var tight = joins.contains { $0.bevel || $0.reversal }
        let halfWidth = Double(width) / 2
        let scales = perspective.map { perspective in
            progress.map { Double(perspective.factor(at: $0)) }
        }

        func triangle(_ a: Point, _ b: Point, _ c: Point, _ phases: SIMD3<Float>) {
            // Fixed winding, including strips that fold back at tight inside offsets.
            let ab = b - a
            let ac = c - a
            let cross = ab.x * ac.y - ab.y * ac.x
            vertices.append(SIMD2<Float>(a))
            vertices.append(SIMD2<Float>(cross < 0 ? c : b))
            vertices.append(SIMD2<Float>(cross < 0 ? b : c))
            if !progress.isEmpty {
                vertexProgress.append(phases.x)
                vertexProgress.append(cross < 0 ? phases.z : phases.y)
                vertexProgress.append(cross < 0 ? phases.y : phases.z)
            }
        }

        for line in -2...2 {
            let start = vertices.count
            let offset = Double(line) * Double(spacing)
            let low = offset - halfWidth
            let high = offset + halfWidth
            for index in 0..<edgeCount {
                let a = joins[index].outgoing
                let next = joins[(index + 1) % joins.count]
                let b = next.incoming
                let direction = points[index + 1] - points[index]

                let from = progress.isEmpty ? 0 : progress[index]
                let to = progress.isEmpty ? 0 : progress[index + 1]
                let aScale = scales?[index] ?? 1
                let bScale = scales?[index + 1] ?? 1
                if simd_dot(b.at(offset * bScale) - a.at(offset * aScale), direction) <= 0 {
                    tight = true
                }
                let aLow = a.at(low * aScale)
                let aHigh = a.at(high * aScale)
                let bLow = b.at(low * bScale)
                let bHigh = b.at(high * bScale)
                triangle(aLow, bLow, aHigh, SIMD3(from, to, from))
                triangle(aHigh, bLow, bHigh, SIMD3(from, to, to))
                guard next.bevel else { continue }
                let c = next.outgoing
                if line == 0 {
                    // A centered stroke's inner halves already overlap. Fill
                    // only the outer wedge to avoid a bow-tie at its center.
                    let turn = b.normal.x * c.normal.y - b.normal.y * c.normal.x
                    let outside = turn > 0 ? low : high
                    triangle(
                        b.position, b.at(outside * bScale), c.at(outside * bScale),
                        SIMD3(repeating: to))
                } else {
                    triangle(bLow, c.at(low * bScale), bHigh, SIMD3(repeating: to))
                    triangle(bHigh, c.at(low * bScale), c.at(high * bScale), SIMD3(repeating: to))
                }
            }
            ranges.append(start..<vertices.count)
        }
        return Geometry(
            origin: origin, vertices: vertices, progress: vertexProgress, lineRanges: ranges,
            closed: closed,
            hasTightTurns: tight)
    }
}
