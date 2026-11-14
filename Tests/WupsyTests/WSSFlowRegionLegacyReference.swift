import Foundation

@testable import Wupsy

// Frozen pre-Etappe-A CPU kernel from fc8871ed. Independent geometry oracle:
// intentionally do not call the production traversal or new interval algorithm.
enum WSSFlowRegionLegacyReference {
    static let maximumPoints = 65_536
    static let maximumStamps = 262_144
    static let maximumTexelVisits = 128 * 1024 * 1024

    // Conservative peak: source RG16F/R8, Float32 XY work, touched bits, final RG16F,
    // caller UVs plus canonical vertices/two arc-length tables, and fixed overhead.
    // Check before allocating any field-sized working representation. No encoded copy.
    static func workingBytes(width: Int, height: Int, hasCoverage: Bool, pointCount: Int) throws
        -> Int
    {
        guard (1...8192).contains(width), (1...8192).contains(height),
            pointCount >= 0, pointCount <= maximumPoints
        else { throw WSSVectorPaintError.invalidGeometry }
        func multiply(_ a: Int, _ b: Int) throws -> Int {
            let (value, overflow) = a.multipliedReportingOverflow(by: b)
            guard !overflow else { throw WSSVectorPaintError.budget }
            return value
        }
        func add(_ a: Int, _ b: Int) throws -> Int {
            let (value, overflow) = a.addingReportingOverflow(b)
            guard !overflow else { throw WSSVectorPaintError.budget }
            return value
        }
        let count = try multiply(width, height)
        guard count <= WSSVectorFieldAsset.byteLimit / 5 else {
            throw WSSVectorPaintError.invalidGeometry
        }
        let fields = try add(multiply(count, hasCoverage ? 17 : 16), (count + 7) / 8)
        return try add(add(fields, multiply(pointCount, 48)), 4096)
    }

    static func support(
        width: Int, height: Int, imageSize: SIMD2<Double>, uvPoints: [SIMD2<Double>],
        brush: WSSVectorBrush, subpathStarts: [Int] = [],
        visit: (Int, Float, SIMD2<Float>) -> Void
    ) throws {
        let geometry = try WSSVectorPaintGeometry(imageSize: imageSize)
        guard brush.diameter <= 2 * max(imageSize.x, imageSize.y),
            subpathStarts.count <= uvPoints.count,
            subpathStarts.enumerated().allSatisfy({ index, start in
                start > 0 && start < uvPoints.count
                    && (index == 0 || start > subpathStarts[index - 1])
            })
        else { throw WSSVectorPaintError.invalidGeometry }
        // Retain the original conservative budget and dimension guards even though
        // the support-only consumer no longer allocates the charged vector buffers.
        let bytes =
            try workingBytes(
                width: width, height: height, hasCoverage: false, pointCount: uvPoints.count)
            + subpathStarts.count * MemoryLayout<Int>.stride
        try WSSVectorFieldEditorBudget.validateWorkingData(byteCount: bytes)
        let texel = imageSize / SIMD2(Double(width), Double(height))
        var visits = 0
        var stamps = 0
        func stamp(_ point: SIMD2<Double>, target: SIMD2<Float>) throws {
            let radius = brush.diameter / 2
            let integrate = radius < max(texel.x, texel.y)
            let extent = SIMD2(repeating: radius) + (integrate ? texel / 2 : .zero)
            let low = (point - extent) / texel - SIMD2(repeating: 0.5)
            let high = (point + extent) / texel - SIMD2(repeating: 0.5)
            let x0 = max(
                0, min(width, Int(ceil(max(-1, min(Double(width), low.x))))))
            let y0 = max(
                0, min(height, Int(ceil(max(-1, min(Double(height), low.y))))))
            let x1 = min(
                width - 1, Int(floor(max(-1, min(Double(width), high.x)))))
            let y1 = min(
                height - 1, Int(floor(max(-1, min(Double(height), high.y)))))
            guard x0 <= x1, y0 <= y1 else { return }
            let area = (x1 - x0 + 1) * (y1 - y0 + 1)
            guard area <= maximumTexelVisits - visits else {
                throw WSSVectorPaintError.workLimit
            }
            visits += area
            for y in y0...y1 {
                for x in x0...x1 {
                    let center = (SIMD2(Double(x), Double(y)) + SIMD2(repeating: 0.5)) * texel
                    var amount = 0.0
                    if integrate {
                        // Fixed 4x4 texel-footprint integration for subtexel brushes,
                        // in local units on both axes, just as for the scalar brush.
                        for sy in 0..<4 {
                            for sx in 0..<4 {
                                let sample =
                                    center
                                    + (SIMD2(Double(sx), Double(sy)) / 4
                                        - SIMD2(repeating: 0.375)) * texel
                                amount +=
                                    WSSVectorBrush.weight(
                                        distance: hypot(sample.x - point.x, sample.y - point.y),
                                        radius: radius) / 16
                            }
                        }
                    } else {
                        amount = WSSVectorBrush.weight(
                            distance: hypot(center.x - point.x, center.y - point.y),
                            radius: radius)
                    }
                    let weight = Float(amount)
                    guard weight > 0 else { continue }
                    let index = y * width + x
                    visit(index, weight, target)
                }
            }
        }
        func paintPath(_ uvPoints: ArraySlice<SIMD2<Double>>) throws {
            // Canonicalize only forward collinear subdivisions, with a tiny local-space
            // tolerance for Double roundoff. Reversals and genuine corners survive.
            var points: [SIMD2<Double>] = []
            points.reserveCapacity(uvPoints.count)
            let tolerance = max(imageSize.x, imageSize.y) * 1e-10
            for uv in uvPoints {
                let point = try geometry.localPoint(uv)
                if point == points.last { continue }
                while points.count >= 2 {
                    let a = points[points.count - 2]
                    let b = points[points.count - 1]
                    let ab = b - a
                    let bc = point - b
                    let ac = point - a
                    let length = hypot(ac.x, ac.y)
                    guard length > 0, ab.x * bc.x + ab.y * bc.y >= 0,
                        abs(ab.x * ac.y - ab.y * ac.x) <= tolerance * length
                    else { break }
                    points.removeLast()
                }
                points.append(point)
            }
            guard let start = points.first else { return }
            let step = SIMD2(min(brush.diameter / 8, texel.x), min(brush.diameter / 8, texel.y))
            guard step.x > 0, step.y > 0 else { throw WSSVectorPaintError.invalidGeometry }
            let minimumMovement = max(1e-6, min(texel.x, texel.y) * 0.001)
            let firstDirection = points.dropFirst().first {
                hypot($0.x - start.x, $0.y - start.y) >= minimumMovement
            }
            if brush.operation == .direction, firstDirection == nil { return }
            var distances = [Double](repeating: 0, count: points.count)
            var metric = [Double](repeating: 0, count: points.count)
            for index in points.indices.dropFirst() {
                let delta = points[index] - points[index - 1]
                distances[index] = distances[index - 1] + hypot(delta.x, delta.y)
                metric[index] = metric[index - 1] + hypot(delta.x / step.x, delta.y / step.y)
                guard distances[index].isFinite, metric[index].isFinite,
                    distances[index] > distances[index - 1], metric[index] > metric[index - 1]
                else { throw WSSVectorPaintError.invalidGeometry }
            }
            let total = distances.last!
            let stampDistance = metric.last!
            guard stampDistance.isFinite, stampDistance < Double(maximumStamps - 1) else {
                throw WSSVectorPaintError.workLimit
            }
            // A maximum of three monotone cursors walks the bounded polyline. Stamps
            // are consumed immediately; there is no event/stamp history per texel.
            var positionCursor = 0
            var leftCursor = 0
            var rightCursor = 0
            var lastDirection = SIMD2<Double>(1, 0)
            if let firstDirection {
                let delta = firstDirection - start
                lastDirection = delta / hypot(delta.x, delta.y)
            }
            func sample(_ distance: Double, table: [Double], cursor: inout Int) -> (
                SIMD2<Double>, Double
            ) {
                guard points.count > 1 else { return (start, 0) }
                while cursor + 1 < points.count - 1, table[cursor + 1] <= distance {
                    cursor += 1
                }
                let fraction = min(
                    1, max(0, (distance - table[cursor]) / (table[cursor + 1] - table[cursor])))
                return (
                    points[cursor] + (points[cursor + 1] - points[cursor]) * fraction,
                    distances[cursor] + (distances[cursor + 1] - distances[cursor]) * fraction
                )
            }
            // Centered local arc-length secant, window +/- diameter/8. It smooths only
            // the stroke tangent, never the field. A cancelling cusp uses the forward
            // segment tangent; an endpoint retains its last valid tangent if necessary.
            func target(at distance: Double) -> SIMD2<Float> {
                guard brush.operation == .direction else { return .zero }
                if distance == 0 {
                    return SIMD2(Float(lastDirection.x), Float(lastDirection.y))
                        * brush.magnitude
                }
                let left = sample(
                    max(0, distance - brush.diameter / 8), table: distances, cursor: &leftCursor
                ).0
                let right = sample(
                    min(total, distance + brush.diameter / 8), table: distances,
                    cursor: &rightCursor
                ).0
                var delta = right - left
                var length = hypot(delta.x, delta.y)
                if length < minimumMovement, positionCursor + 1 < points.count {
                    delta = points[positionCursor + 1] - points[positionCursor]
                    length = hypot(delta.x, delta.y)
                }
                if length >= minimumMovement { lastDirection = delta / length }
                return SIMD2(Float(lastDirection.x), Float(lastDirection.y)) * brush.magnitude
            }
            let count = Int(ceil(stampDistance)) + 1
            guard count <= maximumStamps - stamps else { throw WSSVectorPaintError.workLimit }
            stamps += count
            for index in 0...Int(floor(stampDistance)) {
                let (point, distance) = sample(
                    Double(index), table: metric, cursor: &positionCursor)
                try stamp(point, target: target(at: distance))
            }
            if stampDistance.rounded(.down) != stampDistance {
                try stamp(points.last!, target: target(at: total))
            }
        }
        // Disconnected clipped paths share the same stamp and texel-visit budgets.
        var start = 0
        for end in subpathStarts {
            try paintPath(uvPoints[start..<end])
            start = end
        }
        try paintPath(uvPoints[start..<uvPoints.count])
    }
}
