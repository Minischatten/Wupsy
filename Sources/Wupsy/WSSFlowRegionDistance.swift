import Foundation

// Exact Euclidean distances at cell centers to the union's axis-aligned cell edges.
// Boundary endpoints AND edge midpoints lie on a doubled lattice. The closest
// projection from a cell center to any boundary segment is one of these seeds.
// Weighted separable squared EDT therefore handles corners and anisotropy exactly.
enum WSSFlowRegionDistance {
    static let workingLimit = 128 * 1024 * 1024
    static func make(
        _ region: WSSFlowRegion, size: SIMD2<Float>, workingByteLimit: Int = workingLimit
    ) throws -> [Float] {
        try region.validate()
        guard size.x.isFinite, size.y.isFinite, size.x > 0, size.y > 0,
            size.x <= 8192, size.y <= 8192
        else { throw WSSVectorFieldEditError.invalid }
        let width = region.width * 2 + 1
        let height = region.height * 2 + 1
        let bytes = width * height * 4 + region.pixels.count * 5 + max(width, height) * 40
        guard bytes <= min(workingLimit, workingByteLimit) else {
            throw WSSVectorFieldEditError.budget
        }
        if !region.pixels.contains(255) { return [Float](repeating: 0, count: region.pixels.count) }
        let infinity = Float(1e20)
        var grid = [Float](repeating: infinity, count: width * height)
        func active(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < region.width && y < region.height
                && region.pixels[y * region.width + x] == 255
        }
        for y in 0..<region.height {
            try Task.checkCancellation()
            for x in 0..<region.width where active(x, y) {
                for side in 0..<4 {
                    let xx = x + (side == 0 ? -1 : side == 1 ? 1 : 0)
                    let yy = y + (side == 2 ? -1 : side == 3 ? 1 : 0)
                    guard !active(xx, yy) else { continue }
                    for offset in 0...2 {
                        let sx = side < 2 ? 2 * x + (side == 1 ? 2 : 0) : 2 * x + offset
                        let sy = side < 2 ? 2 * y + offset : 2 * y + (side == 3 ? 2 : 0)
                        grid[sy * width + sx] = 0
                    }
                }
            }
        }
        func transform(_ input: [Float], spacing: Double) -> [Float] {
            let n = input.count
            let a = spacing * spacing
            var sites = [Int](repeating: 0, count: n)
            var cuts = [Double](repeating: 0, count: n + 1)
            var k = -1
            for q in 0..<n where input[q] < infinity {
                var cut = -Double.infinity
                while k >= 0 {
                    let p = sites[k]
                    cut =
                        (Double(input[q]) - Double(input[p]) + a * Double(q * q - p * p))
                        / (2 * a * Double(q - p))
                    if cut > cuts[k] { break }
                    k -= 1
                }
                k += 1
                sites[k] = q
                cuts[k] = k == 0 ? -.infinity : cut
                cuts[k + 1] = .infinity
            }
            guard k >= 0 else { return input }
            let last = k
            k = 0
            return (0..<n).map { q in
                while k < last && cuts[k + 1] < Double(q) { k += 1 }
                let delta = Double(q - sites[k])
                return Float(a * delta * delta + Double(input[sites[k]]))
            }
        }
        let dx = Double(size.x) / Double(region.width) / 2
        let dy = Double(size.y) / Double(region.height) / 2
        for y in 0..<height {
            try Task.checkCancellation()
            let row = transform(Array(grid[y * width..<(y + 1) * width]), spacing: dx)
            grid.replaceSubrange(y * width..<(y + 1) * width, with: row)
        }
        for x in 0..<width {
            try Task.checkCancellation()
            let column = transform((0..<height).map { grid[$0 * width + x] }, spacing: dy)
            for y in 0..<height { grid[y * width + x] = column[y] }
        }
        return (0..<region.pixels.count).map { index in
            let value = sqrt(
                grid[(index / region.width * 2 + 1) * width + index % region.width * 2 + 1])
            return region.pixels[index] == 255 ? value : -value
        }
    }
}

// Bounded content-addressed cache. Geometry, not transport controls or viewport,
// is part of the key. Serial calculation limits peak working memory across scenes.
final class WSSFlowRegionDistanceCache: @unchecked Sendable {
    static let shared = WSSFlowRegionDistanceCache()
    private let lock = NSLock()
    private var entries: [(WSSContentFingerprint, SIMD2<Float>, [Float])] = []
    private(set) var computations = 0
    static let byteLimit = 32 * 1024 * 1024
    func distance(_ region: WSSFlowRegion, size: SIMD2<Float>) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let fingerprint = WSSContentFingerprint(try region.encoded())
        if let entry = entries.first(where: { $0.0 == fingerprint && $0.1 == size }) {
            return entry.2
        }
        // Retained cache (32 MiB) plus the bounded transform stays below 128 MiB.
        while entries.reduce(0, { $0 + $1.2.count * 4 }) + region.pixels.count * 4 > Self.byteLimit
        { entries.removeFirst() }
        let result = try WSSFlowRegionDistance.make(region, size: size)
        guard result.count * 4 <= Self.byteLimit else { throw WSSVectorFieldEditError.budget }
        computations += 1
        entries.append((fingerprint, size, result))
        return result
    }
}
