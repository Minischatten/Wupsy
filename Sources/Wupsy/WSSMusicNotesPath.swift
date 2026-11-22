import Foundation
import simd

struct WSSMusicNotesPath: Codable, Equatable {
    static let minimumAnchors = 2
    static let maximumAnchors = 16
    static let maximumSubdivisionDepth = 16
    static let maximumFlattenedEdges = 4096
    static let minimumAnchorDistance = 0.01
    static let standardSampleCount = 257
    static let maximumSampleCount = 513
    static let maximumClosedSampleCount = 2049

    enum Direction: String, Codable { case forward, reverse }

    struct Anchor: Codable, Equatable {
        var position: SIMD2<Double>
        var incoming: SIMD2<Double>
        var outgoing: SIMD2<Double>

        enum CodingKeys: String, CodingKey, CaseIterable { case position, incoming, outgoing }

        init(position: SIMD2<Double>, incoming: SIMD2<Double>, outgoing: SIMD2<Double>) {
            self.position = position
            self.incoming = incoming
            self.outgoing = outgoing
        }

        init(from decoder: Decoder) throws {
            try decoder.fields(CodingKeys.allCases.map(\.rawValue))
            let c = try decoder.container(keyedBy: CodingKeys.self)
            position = try c.decode(SIMD2<Double>.self, forKey: .position)
            incoming = try c.decode(SIMD2<Double>.self, forKey: .incoming)
            outgoing = try c.decode(SIMD2<Double>.self, forKey: .outgoing)
        }
    }

    var enabled: Bool
    var closed: Bool
    var direction: Direction
    var anchors: [Anchor]

    private let preparation = Preparation()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.enabled == rhs.enabled && lhs.direction == rhs.direction && lhs.sameCurve(as: rhs)
    }

    func sameCurve(as other: Self) -> Bool {
        closed == other.closed && anchors == other.anchors
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case enabled, closed, direction, anchors }

    init(enabled: Bool, closed: Bool, direction: Direction, anchors: [Anchor]) {
        self.enabled = enabled
        self.closed = closed
        self.direction = direction
        self.anchors = anchors
    }

    init(from decoder: Decoder) throws {
        try decoder.fields(CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        closed = try c.decode(Bool.self, forKey: .closed)
        direction = try c.decode(Direction.self, forKey: .direction)
        var input = try c.nestedUnkeyedContainer(forKey: .anchors)
        anchors = []
        while !input.isAtEnd {
            guard anchors.count < Self.maximumAnchors else {
                throw WSSSceneError.invalid("musicNotes path anchor count")
            }
            anchors.append(try input.decode(Anchor.self))
        }
        try validateAnchors()
    }

    private func validateAnchors() throws {
        guard (Self.minimumAnchors...Self.maximumAnchors).contains(anchors.count) else {
            throw WSSSceneError.invalid("musicNotes path anchor count")
        }
        for anchor in anchors {
            for point in [anchor.position, anchor.incoming, anchor.outgoing] {
                guard (0...1).contains(point.x), (0...1).contains(point.y) else {
                    throw WSSSceneError.invalid("musicNotes path coordinates")
                }
            }
        }
    }

    // Positions are in logical canvas units relative to the first anchor.
    // Keeping the offset separate preserves precision for short paths.
    struct Table: Equatable {
        struct Sample: Equatable {
            let position: SIMD2<Float>
            let tangent: SIMD2<Float>
        }

        let origin: SIMD2<Double>  // First anchor relative to the region origin.
        let length: Double
        let samples: [Sample]
    }

    private struct Vertex {
        let position: SIMD2<Double>
        let distance: Double
    }

    private struct Cubic {
        let start, outgoing, incoming, end: SIMD2<Double>

        var polygonLength: Double {
            simd_distance(start, outgoing) + simd_distance(outgoing, incoming)
                + simd_distance(incoming, end)
        }

        func split() -> (Cubic, Cubic) {
            let a = (start + outgoing) / 2
            let b = (outgoing + incoming) / 2
            let c = (incoming + end) / 2
            let d = (a + b) / 2
            let e = (b + c) / 2
            let middle = (d + e) / 2
            return (
                Cubic(start: start, outgoing: a, incoming: d, end: middle),
                Cubic(start: middle, outgoing: e, incoming: c, end: end)
            )
        }

        func isFlat(chord: Double, tolerance: Double) -> Bool {
            guard polygonLength - chord <= tolerance else { return false }
            guard chord > 0 else { return true }
            let direction = (end - start) / chord
            return [outgoing, incoming].allSatisfy {
                let offset = $0 - start
                let projection = min(chord, max(0, simd_dot(offset, direction)))
                return simd_length(offset - direction * projection) <= tolerance
            }
        }
    }

    // Copies of a document path share one bounded, synchronized preparation.
    // The key excludes placement, direction and enablement.
    private final class Preparation {
        struct Key: Equatable {
            let closed: Bool
            let anchors: [Anchor]
            let scale: SIMD2<Double>
        }

        private let lock = NSLock()
        private var entry: (Key, Table)?

        func table(for key: Key, build: () throws -> Table) rethrows -> Table {
            lock.lock()
            defer { lock.unlock() }
            if let entry, entry.0 == key { return entry.1 }
            let table = try build()
            entry = (key, table)
            return table
        }
    }

    func prepare(in region: WSSSceneDocumentV1.Region) throws -> Table {
        try WSSMusicNotesLayer.validateRegion(region)
        let scale = SIMD2(Double(region.width), Double(region.height))
        let key = Preparation.Key(closed: closed, anchors: anchors, scale: scale)
        return try preparation.table(for: key) { try makeTable(scale: scale) }
    }

    private func flattened(scale: SIMD2<Double>) throws -> (
        origin: SIMD2<Double>, vertices: [Vertex], joins: [Double]
    ) {
        try validateAnchors()
        let origin = anchors[0].position * scale
        var vertices = [Vertex(position: .zero, distance: 0)]
        var joins: [Double] = []
        let segmentCount = closed ? anchors.count : anchors.count - 1
        for index in 0..<segmentCount {
            let a = anchors[index]
            let b = anchors[(index + 1) % anchors.count]
            let curve = Cubic(
                start: a.position * scale - origin, outgoing: a.outgoing * scale - origin,
                incoming: b.incoming * scale - origin, end: b.position * scale - origin)
            guard simd_distance(curve.start, curve.end) >= Self.minimumAnchorDistance else {
                throw WSSSceneError.invalid("musicNotes path anchors too close")
            }
            // Scale tolerance down for short curves so their shape is preserved.
            let tolerance = min(0.01, curve.polygonLength * 0.0001)
            try Self.flatten(curve, tolerance: tolerance, depth: 0, into: &vertices)
            if index < segmentCount - 1 { joins.append(vertices[vertices.count - 1].distance) }
        }
        return (origin, vertices, joins)
    }

    // Same adaptive subdivision and exact segment boundaries as playback.
    func staffCenterline(scale: SIMD2<Double>) throws -> (
        origin: SIMD2<Double>, points: [SIMD2<Double>], progress: [Float]
    ) {
        let geometry = try flattened(scale: scale)
        let length = geometry.vertices.last!.distance
        return (
            geometry.origin, geometry.vertices.map(\.position),
            geometry.vertices.map { Float($0.distance / length) }
        )
    }

    private func makeTable(scale: SIMD2<Double>) throws -> Table {
        let (origin, vertices, joins) = try flattened(scale: scale)
        let length = vertices[vertices.count - 1].distance
        let standard = Self.resample(vertices, length: length, count: Self.standardSampleCount)
        let fine: [SIMD2<Double>]
        if Self.fits(standard, vertices: vertices, length: length, joins: nil) {
            fine = standard
        } else {
            let regular = Self.resample(vertices, length: length, count: Self.maximumSampleCount)
            if Self.fits(regular, vertices: vertices, length: length, joins: joins) {
                fine = regular
            } else if closed,
                let refined = [1025, Self.maximumClosedSampleCount].lazy.map({
                    Self.resample(vertices, length: length, count: $0)
                }).first(where: {
                    Self.fits(
                        $0, vertices: vertices, length: length, joins: joins,
                        closingStart: joins.last
                    )
                })
            {
                // Refine only closures the old tables cannot describe. Existing
                // valid tables keep their original positions and tangents.
                fine = refined
            } else {
                throw WSSSceneError.invalid("musicNotes path sampling budget")
            }
        }
        let samples = fine.indices.map { index in
            Table.Sample(position: SIMD2<Float>(fine[index]), tangent: tangent(at: index, in: fine))
        }
        return Table(origin: origin, length: length, samples: samples)
    }

    private static func flatten(
        _ curve: Cubic, tolerance: Double, depth: Int, into vertices: inout [Vertex]
    ) throws {
        let chord = simd_distance(curve.start, curve.end)
        if curve.isFlat(chord: chord, tolerance: tolerance) {
            let previous = vertices[vertices.count - 1]
            let distance = previous.distance + simd_distance(previous.position, curve.end)
            guard distance > previous.distance else { return }
            guard vertices.count <= maximumFlattenedEdges else {
                throw WSSSceneError.invalid("musicNotes path subdivision budget")
            }
            vertices.append(Vertex(position: curve.end, distance: distance))
            return
        }
        guard depth < maximumSubdivisionDepth else {
            throw WSSSceneError.invalid("musicNotes path subdivision depth")
        }
        let (first, second) = curve.split()
        try flatten(first, tolerance: tolerance, depth: depth + 1, into: &vertices)
        try flatten(second, tolerance: tolerance, depth: depth + 1, into: &vertices)
    }

    private static func resample(
        _ vertices: [Vertex], length: Double, count: Int
    ) -> [SIMD2<Double>] {
        let last = vertices.count - 1
        var upper = 1
        return (0..<count).map { index in
            if index == count - 1 { return vertices[last].position }
            let distance = length * Double(index) / Double(count - 1)
            while upper < last && vertices[upper].distance < distance { upper += 1 }
            let a = vertices[upper - 1]
            let b = vertices[upper]
            let fraction = (distance - a.distance) / (b.distance - a.distance)
            return a.position + (b.position - a.position) * fraction
        }
    }

    private static func fits(
        _ points: [SIMD2<Double>], vertices: [Vertex], length: Double, joins: [Double]?,
        closingStart: Double? = nil
    ) -> Bool {
        let intervals = points.count - 1
        let step = length / Double(intervals)
        let joinIntervals = Set(
            (joins ?? []).map { min(intervals - 1, Int($0 / length * Double(intervals))) })
        let closingIndex = closingStart.map { Int($0 / length * Double(intervals)) }
        func canTurnSharply(_ index: Int) -> Bool {
            joinIntervals.contains(index) || index >= (closingIndex ?? intervals)
        }
        let minimumChord = (joins == nil ? 0.96 : 0.90) * step
        for index in 0..<intervals where !canTurnSharply(index) {
            guard simd_distance(points[index], points[index + 1]) >= minimumChord else {
                return false
            }
        }

        // Both interpolants are linear between the union of their knots.
        // At table knots they agree, so flattened vertices bound the error.
        let tolerance = joins == nil ? min(0.25, step * 0.08) : min(1, step * 0.12)
        // Arc-length interpolation across a reversal can deviate by half
        // a sample interval. The fallback still caps error at two units.
        let joinTolerance = min(2, step * (closingStart == nil ? 0.49 : 0.500001))
        return vertices.allSatisfy { vertex in
            let index = vertex.distance / length * Double(intervals)
            let lower = min(intervals - 1, Int(index))
            let position =
                points[lower] + (points[lower + 1] - points[lower]) * (index - Double(lower))
            let limit = canTurnSharply(lower) ? joinTolerance : tolerance
            return simd_distance(vertex.position, position) <= limit
        }
    }

    private func tangent(at index: Int, in points: [SIMD2<Double>]) -> SIMD2<Float> {
        let last = points.count - 1
        let seam = closed && (index == 0 || index == last)
        let before = points[seam ? last - 1 : max(0, index - 1)]
        let after = points[seam ? 1 : min(last, index + 1)]
        let center = points[index]
        for vector in [after - before, after - center, center - before] {
            let length = simd_length(vector)
            if length > 1e-12 { return SIMD2<Float>(vector / length) }
        }
        return SIMD2(1, 0)
    }
}
