import Foundation

enum WSSVectorPaintError: Error {
    case invalidGeometry, invalidBrush, budget, workLimit
}

struct WSSVectorPaintGeometry {
    let imageSize: SIMD2<Double>
    init(imageSize: SIMD2<Double>) throws {
        guard imageSize.x.isFinite, imageSize.y.isFinite, imageSize.x > 0, imageSize.y > 0,
            imageSize.x <= 8192, imageSize.y <= 8192
        else { throw WSSVectorPaintError.invalidGeometry }
        self.imageSize = imageSize
    }
    func localPoint(_ uv: SIMD2<Double>) throws -> SIMD2<Double> {
        guard uv.x.isFinite, uv.y.isFinite, (0...1).contains(uv.x), (0...1).contains(uv.y)
        else { throw WSSVectorPaintError.invalidGeometry }
        return uv * imageSize
    }
    func direction(from start: SIMD2<Double>, to end: SIMD2<Double>) throws -> SIMD2<Double>? {
        let delta = try localPoint(end) - localPoint(start)
        let length = hypot(delta.x, delta.y)
        return length > 0 ? delta / length : nil
    }
}

struct WSSVectorBrush {
    enum Operation { case direction, neutralize, erase }
    // Diameter in logical local image units, before layer scale/rotation.
    let diameter: Double
    let magnitude: Float
    let operation: Operation

    init(diameter: Double, magnitude: Float, operation: Operation) throws {
        guard diameter.isFinite, diameter > 0, magnitude.isFinite, (0...1).contains(magnitude)
        else { throw WSSVectorPaintError.invalidBrush }
        self.diameter = diameter
        self.magnitude = magnitude
        self.operation = operation
    }
    static func weight(distance: Double, radius: Double) -> Double {
        guard distance.isFinite, distance >= 0, radius.isFinite, radius > 0 else { return 0 }
        let t = min(1, max(0, (distance / radius - 0.5) * 2))
        return 1 - t * t * (3 - 2 * t)
    }
    static func blend(_ old: SIMD2<Float>, toward target: SIMD2<Float>, weight: Float) -> SIMD2<
        Float
    > {
        weight == 1 ? target : old + (target - old) * weight
    }
}

enum WSSVectorPaintResult {
    case unchanged
    case changed(WSSVectorFieldAsset)
}

// Pure, bounded polyline authoring. No session, clock, pointer, view or GPU state.
enum WSSVectorFieldPaint {
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

    static func paint(
        _ source: WSSVectorFieldAsset, imageSize: SIMD2<Double>, uvPoints: [SIMD2<Double>],
        brush: WSSVectorBrush, subpathStarts: [Int] = [],
        workingByteLimit: Int = WSSVectorFieldEditorBudget.workingDataLimit,
        visit: ((Int, Float) -> Void)? = nil
    ) throws -> WSSVectorPaintResult {
        _ = try WSSVectorPaintGeometry(imageSize: imageSize)
        guard brush.diameter <= 2 * max(imageSize.x, imageSize.y)
        else { throw WSSVectorPaintError.invalidGeometry }
        guard subpathStarts.count <= uvPoints.count,
            subpathStarts.enumerated().allSatisfy({ index, start in
                start > 0 && start < uvPoints.count
                    && (index == 0 || start > subpathStarts[index - 1])
            })
        else { throw WSSVectorPaintError.invalidGeometry }
        let bytes =
            try workingBytes(
                width: source.width, height: source.height,
                hasCoverage: source.coverage != nil, pointCount: uvPoints.count) + subpathStarts
            .count * MemoryLayout<Int>.stride
        try WSSVectorFieldEditorBudget.validateWorkingData(byteCount: bytes)
        guard bytes <= workingByteLimit else { throw WSSVectorPaintError.budget }
        try source.validate()
        var work = [SIMD2<Float>](repeating: .zero, count: source.width * source.height)
        var touched = [UInt8](repeating: 0, count: (work.count + 7) / 8)
        try source.vectors.withUnsafeBytes { raw in
            func original(_ index: Int) -> SIMD2<Float> {
                func component(_ axis: Int) -> Float {
                    Float(
                        Float16(
                            bitPattern: UInt16(
                                littleEndian:
                                    raw.loadUnaligned(
                                        fromByteOffset: index * 4 + axis * 2, as: UInt16.self))))
                }
                return SIMD2(component(0), component(1))
            }
            try support(
                width: source.width, height: source.height, imageSize: imageSize,
                uvPoints: uvPoints, brush: brush, subpathStarts: subpathStarts
            ) { index, weight, target in
                visit?(index, weight)
                let bit = UInt8(1 << (index % 8))
                let old = touched[index / 8] & bit == 0 ? original(index) : work[index]
                // Sequential Float32 blending; quantization still happens only once.
                work[index] =
                    brush.operation == .erase
                    ? .zero : WSSVectorBrush.blend(old, toward: target, weight: weight)
                touched[index / 8] |= bit
            }
        }
        var vectors = source.vectors
        vectors.withUnsafeMutableBytes { output in
            for index in work.indices where touched[index / 8] & UInt8(1 << (index % 8)) != 0 {
                for axis in 0..<2 {
                    let offset = index * 4 + axis * 2
                    let old = UInt16(
                        littleEndian: output.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                    let value = work[index][axis]
                    // Preserve the sign of an unchanged zero as well as all untouched
                    // half components. Quantize only final touched values, once.
                    guard value != Float(Float16(bitPattern: old)) else { continue }
                    output.storeBytes(
                        of: Float16(value).bitPattern.littleEndian, toByteOffset: offset,
                        as: UInt16.self)
                }
            }
        }
        guard vectors != source.vectors else { return .unchanged }
        let candidate = WSSVectorFieldAsset(
            width: source.width, height: source.height,
            vectors: vectors, coverage: source.coverage, isNeutral: false)
        let neutral = try candidate.validatedNeutrality()
        return .changed(
            WSSVectorFieldAsset(
                width: source.width, height: source.height,
                vectors: vectors, coverage: source.coverage, isNeutral: neutral))
    }
    // Canonical bounded stamp traversal shared by vector blending and binary support.
    // This path owns no field-sized vector workspace or encoded output.
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
