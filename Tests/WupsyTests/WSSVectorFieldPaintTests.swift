import Foundation
import XCTest

@testable import Wupsy

final class WSSVectorFieldPaintTests: XCTestCase {
    func testDisconnectedPathsShareStampBudgetAndValidateBreaks() throws {
        let source = try field(width: 1, height: 1)
        let points: [SIMD2<Double>] = [
            SIMD2(0.2, 0.5), SIMD2(0.35, 0.5), SIMD2(0.2, 0.5), SIMD2(0.35, 0.5),
        ]
        let brush = try WSSVectorBrush(diameter: 0.001, magnitude: 1, operation: .neutralize)
        XCTAssertThrowsError(
            try WSSVectorFieldPaint.paint(
                source, imageSize: SIMD2(128, 128), uvPoints: points, brush: brush,
                subpathStarts: [2])
        ) { error in
            guard case WSSVectorPaintError.workLimit = error else {
                return XCTFail("Expected shared stamp limit, got \(error)")
            }
        }
        for breaks in [[0], [4], [2, 2], [3, 1]] {
            XCTAssertThrowsError(
                try WSSVectorFieldPaint.paint(
                    source, imageSize: SIMD2(128, 128), uvPoints: points, brush: brush,
                    subpathStarts: breaks))
        }
    }
    func field(
        width: Int = 64, height: Int = 64, vector: SIMD2<Float> = .zero,
        coverage: Bool = false
    ) throws -> WSSVectorFieldAsset {
        var pixel = Data()
        for component in [vector.x, vector.y] {
            var word = Float16(component).bitPattern.littleEndian
            withUnsafeBytes(of: &word) { pixel.append(contentsOf: $0) }
        }
        var vectors = Data()
        for _ in 0..<(width * height) { vectors.append(pixel) }
        let value = WSSVectorFieldAsset(
            width: width, height: height, vectors: vectors,
            coverage: coverage ? Data((0..<(width * height)).map { UInt8($0 % 256) }) : nil,
            isNeutral: vector == .zero)
        try value.validate()
        return value
    }
    func result(_ result: WSSVectorPaintResult, original: WSSVectorFieldAsset)
        -> WSSVectorFieldAsset
    {
        if case .changed(let field) = result { return field }
        return original
    }
    func vector(_ field: WSSVectorFieldAsset, x: Int, y: Int) -> SIMD2<Float> {
        field.vectors.withUnsafeBytes { raw in
            func component(_ axis: Int) -> Float {
                Float(
                    Float16(
                        bitPattern: UInt16(
                            littleEndian: raw.loadUnaligned(
                                fromByteOffset: (y * field.width + x) * 4 + axis * 2,
                                as: UInt16.self))))
            }
            return SIMD2(component(0), component(1))
        }
    }
    func paint(
        _ field: WSSVectorFieldAsset, points: [SIMD2<Double>], size: SIMD2<Double> = SIMD2(64, 64),
        diameter: Double = 8, magnitude: Float = 1, operation: WSSVectorBrush.Operation = .direction
    ) throws -> WSSVectorFieldAsset {
        result(
            try WSSVectorFieldPaint.paint(
                field, imageSize: size, uvPoints: points.map { $0 / size },
                brush: WSSVectorBrush(
                    diameter: diameter, magnitude: magnitude, operation: operation)),
            original: field)
    }
    func assertVector(
        _ actual: SIMD2<Float>, _ expected: SIMD2<Float>, accuracy: Float = 0.0006,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
    }

    func testLocalDirectionsAllAxesDiagonalsAndImageAspectRatios() throws {
        for size: SIMD2<Double> in [
            SIMD2(160, 90), SIMD2(90, 160), SIMD2(128, 128), SIMD2(4096, 16), SIMD2(16, 4096),
        ] {
            let geometry = try WSSVectorPaintGeometry(imageSize: size)
            for delta: SIMD2<Double> in [
                SIMD2(1, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1),
                SIMD2(1, 1), SIMD2(1, -1), SIMD2(-1, 1), SIMD2(-1, -1),
            ] {
                let start = SIMD2<Double>(0.5, 0.5)
                let end = start + delta / size
                let value = try XCTUnwrap(geometry.direction(from: start, to: end))
                let length = hypot(delta.x, delta.y)
                XCTAssertEqual(value.x, delta.x / length, accuracy: 1e-10)
                XCTAssertEqual(value.y, delta.y / length, accuracy: 1e-10)
            }
        }
    }
    func testPaintDirectionIndependentOfRectangularFieldAndImage() throws {
        for (size, width, height): (SIMD2<Double>, Int, Int) in [
            (SIMD2(160, 90), 64, 36), (SIMD2(90, 160), 36, 64),
            (SIMD2(128, 128), 64, 16), (SIMD2(128, 128), 16, 64),
            (SIMD2(4096, 16), 512, 16), (SIMD2(16, 4096), 16, 512),
        ] {
            let source = try field(width: width, height: height)
            let center =
                (SIMD2(Double(width / 2), Double(height / 2)) + SIMD2(repeating: 0.5))
                / SIMD2(Double(width), Double(height)) * size
            let distance = min(size.x, size.y) / 8
            for direction: SIMD2<Double> in [
                SIMD2(1, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1),
                SIMD2(1, 1), SIMD2(1, -1), SIMD2(-1, 1), SIMD2(-1, -1),
            ] {
                let result = try paint(
                    source, points: [center - direction * distance, center + direction * distance],
                    size: size, diameter: 16, magnitude: 0.35)
                let norm = direction / hypot(direction.x, direction.y)
                assertVector(
                    vector(result, x: width / 2, y: height / 2),
                    SIMD2(Float(norm.x), Float(norm.y)) * 0.35)
            }
        }
    }
    func testMagnitudeZeroPoint35AndOneAndExistingLongVectorsOutsideBrush() throws {
        let source = try field(vector: SIMD2(1, 1))
        for magnitude: Float in [0, 0.35, 1] {
            let result = try paint(
                source, points: [SIMD2(16.5, 32.5), SIMD2(48.5, 32.5)], magnitude: magnitude)
            assertVector(vector(result, x: 32, y: 32), SIMD2(magnitude, 0))
            XCTAssertEqual(vector(result, x: 0, y: 0), SIMD2(1, 1))
            XCTAssertEqual(result.vectors.prefix(4), source.vectors.prefix(4))
        }
    }
    func testFalloffAndNeutralizeCenterCoreTransitionEdgeOutside() throws {
        XCTAssertEqual(WSSVectorBrush.weight(distance: 0, radius: 4), 1)
        XCTAssertEqual(WSSVectorBrush.weight(distance: 2, radius: 4), 1)
        XCTAssertEqual(WSSVectorBrush.weight(distance: 3, radius: 4), 0.5)
        XCTAssertEqual(WSSVectorBrush.weight(distance: 4, radius: 4), 0)
        XCTAssertEqual(WSSVectorBrush.weight(distance: 5, radius: 4), 0)
        XCTAssertEqual(WSSVectorBrush.weight(distance: .nan, radius: 4), 0)
        let source = try field(vector: SIMD2(1, -1), coverage: true)
        let output = try paint(source, points: [SIMD2(32.5, 32.5)], operation: .neutralize)
        assertVector(vector(output, x: 32, y: 32), .zero)
        assertVector(vector(output, x: 34, y: 32), .zero)
        assertVector(vector(output, x: 35, y: 32), SIMD2(0.5, -0.5))
        XCTAssertEqual(vector(output, x: 36, y: 32), SIMD2(1, -1))
        XCTAssertEqual(vector(output, x: 37, y: 32), SIMD2(1, -1))
        XCTAssertEqual(output.coverage, source.coverage)
    }
    func testOppositeVectorBlendPassesThroughZeroWithoutRenormalization() throws {
        XCTAssertEqual(WSSVectorBrush.blend(SIMD2(-1, 0), toward: SIMD2(1, 0), weight: 0.5), .zero)
        XCTAssertEqual(
            WSSVectorBrush.blend(SIMD2(-1, 0), toward: SIMD2(0, 1), weight: 0.5), SIMD2(-0.5, 0.5))
        let source = try field(vector: SIMD2(-1, 0))
        let output = try paint(
            source, points: [SIMD2(8.5, 32.5), SIMD2(56.5, 32.5)], magnitude: 0.35)
        assertVector(vector(output, x: 32, y: 32), SIMD2(0.35, 0))
    }
    func testEquivalentStraightPolylinesTwoAndHundredPointsAreByteIdentical() throws {
        let source = try field(coverage: true)
        for (start, end) in [
            (SIMD2<Double>(8.5, 32.5), SIMD2<Double>(56.5, 32.5)),
            (SIMD2(8.5, 8.5), SIMD2(56.5, 56.5)), (SIMD2(55.3, 10.7), SIMD2(11.7, 51.3)),
        ] {
            let dense = (0..<100).map { start + (end - start) * (Double($0) / 99) }
            let fast = try paint(source, points: [start, end], magnitude: 0.35)
            let slow = try paint(source, points: dense, magnitude: 0.35)
            XCTAssertEqual(try fast.encodedNative(), try slow.encodedNative())
        }
    }
    func testEquivalentSubdividedCurveDeterminismAndTangentSmoothing() throws {
        let source = try field()
        let path: [SIMD2<Double>] = [
            SIMD2(8.5, 16.5), SIMD2(32.5, 16.5), SIMD2(32.5, 40.5), SIMD2(48.5, 40.5),
        ]
        var dense: [SIMD2<Double>] = []
        for index in 1..<path.count {
            for part in 0..<100 {
                dense.append(
                    path[index - 1] + (path[index] - path[index - 1]) * (Double(part) / 100))
            }
        }
        dense.append(path.last!)
        let output = try paint(source, points: path)
        let bytes = try output.encodedNative()
        XCTAssertEqual(try paint(source, points: dense).encodedNative(), bytes)
        for _ in 0..<8 { XCTAssertEqual(try paint(source, points: path).encodedNative(), bytes) }
        // Beside the corner both axes survive. At the exact crossing later core
        // stamps intentionally replace the initial tangent with the vertical leg.
        let corner = vector(output, x: 29, y: 16)
        XCTAssertGreaterThan(corner.x, 0)
        XCTAssertGreaterThan(corner.y, 0)
        assertVector(vector(output, x: 32, y: 28), SIMD2(0, 1))
        assertVector(vector(output, x: 48, y: 40), SIMD2(1, 0))
    }
    func testClickSmallJitterStartAndFinalEndpoint() throws {
        let source = try field()
        let click = try paint(source, points: [SIMD2(16.5, 32.5)])
        XCTAssertEqual(click.vectors, source.vectors)
        let jitter = try paint(
            source, points: [SIMD2(16.5, 32.5), SIMD2(16.50001, 32.5), SIMD2(16.5, 32.5)])
        XCTAssertEqual(jitter.vectors, source.vectors)
        let output = try paint(source, points: [SIMD2(16.5, 32.5), SIMD2(47.8, 32.5)], diameter: 1)
        XCTAssertGreaterThan(vector(output, x: 16, y: 32).x, 0)
        XCTAssertGreaterThan(vector(output, x: 47, y: 32).x, 0)
        for x in 17..<47 { XCTAssertGreaterThan(vector(output, x: x, y: 32).x, 0) }
    }
    func testSmallBrushHalfTexelFastStrokeDoesNotHaveGaps() throws {
        let source = try field()
        let output = try paint(source, points: [SIMD2(1.5, 32), SIMD2(61.5, 32)], diameter: 1)
        for x in 2..<61 {
            XCTAssertGreaterThan(vector(output, x: x, y: 31).x, 0)
            XCTAssertGreaterThan(vector(output, x: x, y: 32).x, 0)
        }
    }
    func testLaterSelfCrossingAndReversedSegmentTakeOver() throws {
        let source = try field()
        let crossing = try paint(
            source,
            points: [
                SIMD2(8.5, 32.5), SIMD2(56.5, 32.5),
                SIMD2(56.5, 56.5), SIMD2(32.5, 56.5), SIMD2(32.5, 8.5),
            ])
        assertVector(vector(crossing, x: 32, y: 32), SIMD2(0, -1))
        let reversal = try paint(
            source, points: [SIMD2(8.5, 32.5), SIMD2(56.5, 32.5), SIMD2(8.5, 32.5)])
        assertVector(vector(reversal, x: 32, y: 32), SIMD2(-1, 0))
    }
    func testTightCurveRetainsBothLegsAndFiniteBoundedValues() throws {
        let source = try field()
        let output = try paint(
            source,
            points: [
                SIMD2(16.5, 16.5), SIMD2(24.5, 16.5),
                SIMD2(24.5, 20.5), SIMD2(16.5, 20.5),
            ], diameter: 2)
        assertVector(vector(output, x: 20, y: 16), SIMD2(1, 0))
        assertVector(vector(output, x: 20, y: 20), SIMD2(-1, 0))
        XCTAssertNoThrow(try output.validate())
    }
    func testCoverageAbsentPresentAndZeroNeverGatesVectorEditing() throws {
        for coverage in [false, true] {
            let source = try field(coverage: coverage)
            let output = try paint(source, points: [SIMD2(0.5, 32.5), SIMD2(48.5, 32.5)])
            XCTAssertEqual(output.coverage, source.coverage)
            if coverage { XCTAssertEqual(source.coverage?[32 * 64], 0) }
            XCTAssertGreaterThan(vector(output, x: 0, y: 32).x, 0)
        }
    }
    func testUntouchedHalfBitsSignedZeroSubnormalsAndBelowHalfNoOp() throws {
        let original = try field()
        var bytes = original.vectors
        bytes[0] = 0
        bytes[1] = 0x80
        bytes[2] = 1
        bytes[3] = 0
        let source = WSSVectorFieldAsset(
            width: 64, height: 64, vectors: bytes, coverage: nil, isNeutral: false)
        let output = try paint(source, points: [SIMD2(16.5, 32.5), SIMD2(48.5, 32.5)])
        XCTAssertEqual(output.vectors.prefix(4), source.vectors.prefix(4))
        XCTAssertEqual(source.vectors, bytes)
        let right = try field(vector: SIMD2(1, 0))
        let result = try WSSVectorFieldPaint.paint(
            right, imageSize: SIMD2(64, 64),
            uvPoints: [SIMD2(0.25, 0.5), SIMD2(0.75, 0.5)],
            brush: WSSVectorBrush(diameter: 8, magnitude: Float(1).nextDown, operation: .direction))
        if case .changed = result { XCTFail("sub-half change created an edit") }
    }
    func testLocalRoundBrushHasEllipticalTexelFootprint() throws {
        let source = try field(width: 128, height: 32, vector: SIMD2(1, 0))
        let size = SIMD2<Double>(128, 128)
        let output = try paint(
            source, points: [SIMD2(64.5, 66)], size: size, diameter: 16, operation: .neutralize)
        assertVector(vector(output, x: 64, y: 16), .zero)
        // Five local X units and four local Y units are both inside the round brush.
        XCTAssertLessThan(vector(output, x: 69, y: 16).x, 1)
        XCTAssertEqual(vector(output, x: 64, y: 19).x, 1)
        XCTAssertEqual(vector(output, x: 74, y: 16).x, 1)
    }
    func testWorkBudgetCheckedBeforeRepresentationAndFullFormatDimensionsSupported() throws {
        let bytes = try WSSVectorFieldPaint.workingBytes(
            width: 8192, height: 819, hasCoverage: true,
            pointCount: WSSVectorFieldPaint.maximumPoints)
        XCTAssertLessThanOrEqual(bytes, WSSVectorFieldEditorBudget.workingDataLimit)
        for (w, h, count) in [(Int.max, 1, 1), (8192, 8192, 1), (1, 1, Int.max), (0, 1, 0)] {
            XCTAssertThrowsError(
                try WSSVectorFieldPaint.workingBytes(
                    width: w, height: h,
                    hasCoverage: false, pointCount: count))
        }
        let source = try field()
        let brush = try WSSVectorBrush(diameter: 8, magnitude: 1, operation: .direction)
        XCTAssertThrowsError(
            try WSSVectorFieldPaint.paint(
                source, imageSize: SIMD2(64, 64),
                uvPoints: [SIMD2(0.25, 0.5), SIMD2(0.75, 0.5)], brush: brush, workingByteLimit: 1))
        let large = try field(width: 1024, height: 1)
        let output = try paint(
            large, points: [SIMD2(64, 0.5), SIMD2(960, 0.5)],
            size: SIMD2(1024, 1), diameter: 1)
        XCTAssertEqual(output.width, 1024)
        XCTAssertEqual(output.height, 1)
        XCTAssertTrue(output.vectors != large.vectors)
    }
    func testInvalidSettingsGeometryAssetAndUnboundedStrokeFailClosed() throws {
        for diameter in [0.0, -1, .nan, .infinity] {
            XCTAssertThrowsError(
                try WSSVectorBrush(diameter: diameter, magnitude: 1, operation: .direction))
        }
        for magnitude: Float in [-1, 1.1, .nan, .infinity] {
            XCTAssertThrowsError(
                try WSSVectorBrush(diameter: 8, magnitude: magnitude, operation: .neutralize))
        }
        let source = try field()
        let bytes = source.vectors
        let brush = try WSSVectorBrush(diameter: 8, magnitude: 1, operation: .direction)
        for size: SIMD2<Double> in [
            SIMD2(0, 64), SIMD2(.nan, 64), SIMD2(64, .infinity), SIMD2(8193, 64),
        ] {
            XCTAssertThrowsError(
                try WSSVectorFieldPaint.paint(source, imageSize: size, uvPoints: [], brush: brush))
        }
        for point: SIMD2<Double> in [
            SIMD2(.nan, 0), SIMD2(.infinity, 0), SIMD2(-1, 0), SIMD2(1.1, 0),
        ] {
            XCTAssertThrowsError(
                try WSSVectorFieldPaint.paint(
                    source, imageSize: SIMD2(64, 64), uvPoints: [point], brush: brush))
        }
        XCTAssertThrowsError(
            try WSSVectorFieldPaint.paint(
                source, imageSize: SIMD2(64, 64),
                uvPoints: Array(
                    repeating: SIMD2(0.5, 0.5), count: WSSVectorFieldPaint.maximumPoints + 1),
                brush: brush))
        let malformed = WSSVectorFieldAsset(
            width: 64, height: 64, vectors: Data(), coverage: nil, isNeutral: true)
        XCTAssertThrowsError(
            try WSSVectorFieldPaint.paint(
                malformed, imageSize: SIMD2(64, 64), uvPoints: [], brush: brush))
        let tiny = try WSSVectorBrush(diameter: 1e-9, magnitude: 1, operation: .direction)
        XCTAssertThrowsError(
            try WSSVectorFieldPaint.paint(
                source, imageSize: SIMD2(64, 64),
                uvPoints: [SIMD2(0, 0), SIMD2(1, 1)], brush: tiny))
        XCTAssertEqual(source.vectors, bytes)
    }
    func testInverseCanvasTransformsRecoverSameLocalDirection() throws {
        for rotation: Float in [0, 0.7, 1.57, -.pi] {
            let transform = WSSImageTransform(
                center: SIMD2(300, 200), size: SIMD2(160, 90),
                scale: SIMD2(2, 0.5), rotation: rotation)
            let p = SIMD2<Float>(0.3, 0.3)
            let q = p + SIMD2(16.0 / 160, 16.0 / 90)
            let a = transform.point(SIMD2(p.x - 0.5, 0.5 - p.y))
            let b = transform.point(SIMD2(q.x - 0.5, 0.5 - q.y))
            let u = try XCTUnwrap(WSSCanvasGeometry.uv(a, transform: transform))
            let v = try XCTUnwrap(WSSCanvasGeometry.uv(b, transform: transform))
            let direction = try XCTUnwrap(
                WSSVectorPaintGeometry(imageSize: SIMD2(160, 90)).direction(
                    from: SIMD2(Double(u.x), Double(u.y)), to: SIMD2(Double(v.x), Double(v.y))))
            XCTAssertEqual(direction.x, 1 / sqrt(2), accuracy: 0.00001)
            XCTAssertEqual(direction.y, 1 / sqrt(2), accuracy: 0.00001)
        }
    }
}

@MainActor final class WSSVectorFieldPaintIntegrationTests: XCTestCase {
    var helper: WSSVectorFieldEditingTests!
    override func setUp() async throws {
        helper = WSSVectorFieldEditingTests()
        try await helper.setUp()
    }
    override func tearDown() async throws {
        try await helper.tearDown()
        helper = nil
    }
    func testCPUStrokeThroughGenerationSelectedStageUndoRedoAndPreview() async throws {
        let doc = helper.doc!
        let edit = try await helper.edit()
        let before = doc.state.workingModel
        let original = try helper.helper.helper.snapshot()
        let painted = try WSSVectorFieldPaint.paint(
            edit.field, imageSize: SIMD2(128, 128),
            uvPoints: [SIMD2(0.05, 0.5), SIMD2(0.4, 0.5)],
            brush: WSSVectorBrush(diameter: 128, magnitude: 0.35, operation: .direction))
        guard case .changed(let field) = painted else { return XCTFail("stroke unchanged") }
        XCTAssertEqual(field.coverage, edit.field.coverage)
        XCTAssertEqual(
            try WSSVectorFieldAsset.decodeNative(field.encodedNative()).vectors, field.vectors)
        try await doc.replaceVectorField(edit, vectors: field.vectors)
        let paths = try helper.fields(doc.state.workingModel)
        XCTAssertEqual(Array(paths.prefix(2)), ["assets/a.wssvf", "assets/b.wssvf"])
        XCTAssertNotEqual(paths[2], "assets/a.wssvf")
        XCTAssertEqual(try helper.helper.helper.snapshot(), original)
        let generation = try XCTUnwrap(doc.state.sessionAssets[paths[2]])
        XCTAssertEqual(
            try WSSVectorFieldAsset.decodeNative(generation.read()).coverage, edit.field.coverage)
        let after = doc.state.workingModel
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, after)
        XCTAssertTrue(doc.state.sessionAssets[paths[2]] === generation)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        XCTAssertNotNil(doc.previewResources.vectorFields?.fields[.init(value: paths[2])])
    }
}
