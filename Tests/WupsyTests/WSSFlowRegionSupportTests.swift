import XCTest

@testable import Wupsy

final class WSSFlowRegionSupportTests: XCTestCase {
    func reference(
        _ source: WSSFlowRegion, size: SIMD2<Double>, points: [SIMD2<Double>],
        brush: WSSVectorBrush, subpaths: [Int] = []
    ) throws -> WSSFlowRegion {
        if brush.operation == .neutralize { return source }
        var result = source
        try result.pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            try WSSFlowRegionLegacyReference.support(
                width: source.width, height: source.height, imageSize: size,
                uvPoints: points, brush: brush, subpathStarts: subpaths
            ) { index, _, _ in bytes[index] = brush.operation == .erase ? 0 : 255 }
        }
        return result
    }
    func testFullWidth4K500MatchesLegacyUnionWithoutLegacyWorkOverflow() throws {
        let size = SIMD2<Double>(3840, 2160)
        let source = try WSSFlowRegion.empty(size: SIMD2<Float>(3840, 2160))
        for operation: WSSVectorBrush.Operation in [.direction, .erase] {
            let initial =
                operation == .erase
                ? WSSFlowRegion(
                    width: source.width, height: source.height,
                    pixels: Data(repeating: 255, count: source.pixels.count)) : source
            let brush = try WSSVectorBrush(diameter: 500, magnitude: 1, operation: operation)
            let actual = try initial.painted(
                imageSize: size, points: [SIMD2(0, 0.5), SIMD2(1, 0.5)], subpaths: [], brush: brush)
            // 1920 is exactly 1024 canonical region steps. Splitting here retains
            // every old stamp; its duplicate midpoint is idempotent for binary data.
            let left = try reference(
                initial, size: size,
                points: [SIMD2(0, 0.5), SIMD2(0.5, 0.5)], brush: brush)
            let expected = try reference(
                left, size: size,
                points: [SIMD2(0.5, 0.5), SIMD2(1, 0.5)], brush: brush)
            XCTAssertEqual(actual, expected)
            XCTAssertNotEqual(actual, initial)
        }
    }
    func testRepresentativePathsMatchFrozenLegacyBytes() throws {
        let paths: [([SIMD2<Double>], [Int])] = [
            ([], []), ([SIMD2(0.5, 0.5)], []),
            ([SIMD2(0.1, 0.5), SIMD2(0.12, 0.5)], []),
            ([SIMD2(0, 0.5), SIMD2(1, 0.5)], []),
            ([SIMD2(0, 0), SIMD2(1, 1)], []),
            ([SIMD2(0, 0.1), SIMD2(0.2, 0.8), SIMD2(0.7, 0.3), SIMD2(1, 0.9)], []),
            ([SIMD2(0, 0.5), SIMD2(1, 0.5), SIMD2(0, 0.5), SIMD2(1, 0.5)], []),
            ([SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)], []),
            ([SIMD2(0, 0.1), SIMD2(0.3, 0.1), SIMD2(0.7, 0.9), SIMD2(1, 0.9)], [2]),
        ]
        for size in [SIMD2<Double>(256, 192), SIMD2(400, 25), SIMD2(0.01, 192)] {
            let source = WSSFlowRegion(
                width: 64, height: 48,
                pixels: Data((0..<(64 * 48)).map { $0 % 7 == 0 ? 255 : 0 }))
            for diameter in [0.001, 1, 8, 17, 90, 300] {
                for operation: WSSVectorBrush.Operation in [.direction, .erase, .neutralize] {
                    let brush = try WSSVectorBrush(
                        diameter: diameter, magnitude: 0.73,
                        operation: operation)
                    for (points, subpaths) in paths {
                        // Tiny brushes on extremely anisotropic domains can exceed
                        // the existing stamp limit; require the same rejection.
                        let expected: WSSFlowRegion
                        do {
                            expected = try reference(
                                source, size: size, points: points,
                                brush: brush, subpaths: subpaths)
                        } catch {
                            XCTAssertThrowsError(
                                try source.painted(
                                    imageSize: size,
                                    points: points, subpaths: subpaths, brush: brush))
                            continue
                        }
                        XCTAssertEqual(
                            try source.painted(
                                imageSize: size, points: points,
                                subpaths: subpaths, brush: brush), expected,
                            "size=\(size) diameter=\(diameter) points=\(points)")
                    }
                }
            }
        }
    }
    func testRoundoffBoundariesAndDisjointSpanCacheMatchLegacy() throws {
        let source = WSSFlowRegion(width: 31, height: 19, pixels: Data(count: 31 * 19))
        for epsilon in [-1e-7, -1e-12, 0, 1e-12, 1e-7] {
            let brush = try WSSVectorBrush(diameter: 12 + epsilon, magnitude: 0, operation: .erase)
            let filled = WSSFlowRegion(
                width: 31, height: 19,
                pixels: Data(repeating: 255, count: 31 * 19))
            let points: [SIMD2<Double>] = [
                SIMD2(0.1, 0.5), SIMD2(0.2, 0.5),
                SIMD2(0.8, 0.5), SIMD2(0.9, 0.5), SIMD2(0.1, 0.5), SIMD2(0.2, 0.5),
            ]
            XCTAssertEqual(
                try filled.painted(
                    imageSize: SIMD2(62, 38), points: points,
                    subpaths: [2, 4], brush: brush),
                try reference(
                    filled, size: SIMD2(62, 38), points: points,
                    brush: brush, subpaths: [2, 4]))
        }
        XCTAssertEqual(source.pixels.count, 589)
    }
    func testSeededRasterAndFloatingBoundaryDifferentialCases() throws {
        var seed: UInt64 = 0xA531_6D28
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
        for _ in 0..<120 {
            let width = 1 + Int(next() * 60)
            let height = 1 + Int(next() * 40)
            let size = SIMD2(1 + next() * 400, 1 + next() * 250)
            let source = WSSFlowRegion(
                width: width, height: height,
                pixels: Data((0..<(width * height)).map { $0 % 3 == 0 ? 255 : 0 }))
            let diameter = max(0.1, next() * max(size.x, size.y))
            let brush = try WSSVectorBrush(
                diameter: diameter, magnitude: 1,
                operation: next() < 0.5 ? .direction : .erase)
            let points = (0..<6).map { _ in SIMD2(next(), next()) }
            XCTAssertEqual(
                try source.painted(
                    imageSize: size, points: points,
                    subpaths: [2, 4], brush: brush),
                try reference(
                    source, size: size, points: points,
                    brush: brush, subpaths: [2, 4]))
        }
        // Texel centers precisely at and very close to the circle's edge.
        for offset in [-1e-7, -1e-12, 0, 1e-12, 1e-7] {
            let source = WSSFlowRegion(width: 64, height: 64, pixels: Data(count: 4096))
            let brush = try WSSVectorBrush(
                diameter: 20 + offset, magnitude: 1,
                operation: .direction)
            let points = [SIMD2<Double>(0.5078125, 0.5078125), SIMD2(0.8, 0.5078125)]
            XCTAssertEqual(
                try source.painted(
                    imageSize: SIMD2(64, 64), points: points,
                    subpaths: [], brush: brush),
                try reference(source, size: SIMD2(64, 64), points: points, brush: brush))
        }
    }
    func testGeometryMemoryPointStampAndActualWorkLimitsRemainBounded() throws {
        let source = try WSSFlowRegion.empty(size: SIMD2<Float>(3840, 2160))
        let brush = try WSSVectorBrush(diameter: 500, magnitude: 1, operation: .direction)
        for points in [
            [SIMD2<Double>(-.infinity, 0), SIMD2(1, 1)],
            [SIMD2(-0.01, 0.5), SIMD2(1.01, 0.5)],
        ] {
            // Pointer clipping is upstream; out-of-domain raw UV remains invalid.
            XCTAssertThrowsError(
                try source.painted(
                    imageSize: SIMD2(3840, 2160),
                    points: points, subpaths: [], brush: brush))
        }
        XCTAssertThrowsError(
            try source.painted(
                imageSize: SIMD2(3840, 2160),
                points: [SIMD2(0, 0.5), SIMD2(1, 0.5)], subpaths: [0], brush: brush))
        XCTAssertThrowsError(
            try source.painted(
                imageSize: SIMD2(3840, 2160),
                points: [], subpaths: [], brush: brush,
                retainedBytes: WSSVectorFieldEditorBudget.workingDataLimit))
        XCTAssertThrowsError(
            try source.painted(
                imageSize: SIMD2(3840, 2160),
                points: Array(repeating: SIMD2(0.5, 0.5), count: 65_537), subpaths: [], brush: brush
            ))
        let tiny = try WSSVectorBrush(diameter: 0.00001, magnitude: 1, operation: .direction)
        XCTAssertThrowsError(
            try source.painted(
                imageSize: SIMD2(3840, 2160),
                points: [SIMD2(0, 0.5), SIMD2(1, 0.5)], subpaths: [], brush: tiny)
        ) {
            XCTAssertEqual($0 as? WSSVectorPaintError, .workLimit)
        }
        // Many overlapping traversals exhaust charged row searches even when the
        // binary output is already covered. Caching cannot bypass the work limit.
        let points = (0..<101).map { SIMD2<Double>($0 % 2 == 0 ? 0 : 1, 0.5) }
        XCTAssertThrowsError(
            try source.painted(
                imageSize: SIMD2(3840, 2160),
                points: points, subpaths: [], brush: brush)
        ) {
            XCTAssertEqual($0 as? WSSVectorPaintError, .workLimit)
        }
        XCTAssertTrue(source.pixels.allSatisfy { $0 == 0 })
    }
}
