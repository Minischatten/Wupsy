import XCTest

@testable import Wupsy

final class WSSFlowPaintLatencyTests: XCTestCase {
    func timed<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        let value = try body()
        print("FLOW LATENCY", label, start.duration(to: .now))
        return value
    }
    func fingerprint(_ data: Data) -> UInt64 {
        data.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
    func testDeterministicPaintMatchesPreOptimizationBytes() throws {
        let source = try WSSVectorFieldPaintTests().field(
            width: 32, height: 24, vector: SIMD2(0.2, -0.4), coverage: true)
        let region = WSSFlowRegion(
            width: 128, height: 96, pixels: Data((0..<(128 * 96)).map { $0 % 7 == 0 ? 255 : 0 }))
        let points: [SIMD2<Double>] = [
            SIMD2(0.12, 0.2), SIMD2(0.4, 0.2), SIMD2(0.8, 0.6), SIMD2(0.4, 0.2), SIMD2(0.4, 0.85),
            SIMD2(0.6, 0.8), SIMD2(0.7, 0.3),
        ]
        let expected: [(UInt64, UInt64)] = [
            (9_975_835_524_947_332_858, 4_064_314_840_983_827_061),
            (17_570_258_855_173_751_858, 10_029_769_382_778_370_372),
            (10_123_105_924_507_865_843, 2_136_664_687_753_486_220),
            (12_585_801_717_982_905_441, 12_432_784_539_166_228_601),
            (15_201_066_025_849_872_339, 12_432_784_539_166_228_601),
            (6_255_592_886_318_728_597, 12_432_784_539_166_228_601),
            (5_767_944_313_702_379_465, 11_557_994_667_765_036_189),
            (14_919_523_395_953_481_125, 974_219_289_396_833_599),
            (12_791_330_561_871_029_029, 15_219_089_856_751_976_572),
        ]
        var caseIndex = 0
        for operation: WSSVectorBrush.Operation in [.direction, .neutralize, .erase] {
            for diameter in [1.0, 17.0, 90.0] {
                let brush = try WSSVectorBrush(
                    diameter: diameter, magnitude: 0.73, operation: operation)
                let value = WSSVectorFieldPaintTests().result(
                    try WSSVectorFieldPaint.paint(
                        source, imageSize: SIMD2(256, 192), uvPoints: points, brush: brush,
                        subpathStarts: [5]), original: source)
                let area = try region.painted(
                    imageSize: SIMD2(256, 192), points: points, subpaths: [5], brush: brush)
                XCTAssertEqual(value.coverage, source.coverage)
                XCTAssertEqual(fingerprint(value.vectors), expected[caseIndex].0)
                XCTAssertEqual(fingerprint(area.pixels), expected[caseIndex].1)
                caseIndex += 1
            }
        }
    }
    func testRegionOverlayIsIndependentOfVectorMagnitudeAndKeepsTouchAlpha() throws {
        let empty = try WSSVectorFieldPaintTests().field(width: 32, height: 24)
        let active = try WSSVectorFieldPaintTests().field(
            width: 32, height: 24, vector: SIMD2(0.8, -0.6))
        let region = WSSFlowRegion(
            width: 128, height: 96, pixels: Data((0..<(128 * 96)).map { $0 % 7 == 0 ? 255 : 0 }))
        let touches = (0..<(32 * 24)).map { UInt8($0 % 256) }
        let a = try WSSDirectionArea.make(empty, region: region, touches: touches)
        let b = try WSSDirectionArea.make(active, region: region, touches: touches)
        XCTAssertEqual(a.image.dataProvider?.data as Data?, b.image.dataProvider?.data as Data?)
        let withoutTouches = try WSSDirectionArea.make(active, region: region)
        XCTAssertNotEqual(
            b.image.dataProvider?.data as Data?, withoutTouches.image.dataProvider?.data as Data?)
    }
    @MainActor func testCPUFeedbackKeepsLastCompletePreviewUntilReplacement() async throws {
        let input = WSSNewFlowCanvasInputTests()
        try await input.setUp()
        addTeardownBlock { @MainActor in try await input.tearDown() }
        try input.doc.addEffect(.flow)
        let session = input.doc.directionCanvas
        await session.waitForLoad()
        await input.doc.waitForPreview()
        try input.downAndDrag()
        await session.waitForFeedback()
        let previousPreview = try XCTUnwrap(session.liveResources)
        let previousVectors = try XCTUnwrap(session.transientState?.field.vectors)
        let previousChange = session.onChange
        var retainedPreviewDuringNewAuthoring = false
        session.onChange = {
            if let state = session.transientState, state.field.vectors != previousVectors,
                session.liveResources === previousPreview
            {
                retainedPreviewDuringNewAuthoring = true
            }
            previousChange?()
        }
        input.canvas.surface.mouseDragged(
            with: try input.event(.leftMouseDragged, uv: SIMD2(0.45, 0.65)))
        await session.waitForFeedback()
        session.onChange = previousChange
        XCTAssertTrue(retainedPreviewDuringNewAuthoring)
        XCTAssertNotNil(session.liveResources)
        XCTAssertFalse(session.liveResources === previousPreview)
        XCTAssertNil(session.error)
        session.cancelStroke()
    }
    func testRepresentativeFeedbackCostsWithoutTimingThreshold() throws {
        let size = SIMD2<Double>(3840, 2160)
        let field = try WSSVectorFieldPaintTests().field(width: 512, height: 288)
        let region = try WSSFlowRegion.empty(size: SIMD2(3840, 2160))
        let brush = try WSSVectorBrush(diameter: 100, magnitude: 1, operation: .direction)
        for count in [8, 64, 256] {
            let points = (0..<count).map { i in
                SIMD2<Double>(
                    0.2 + Double(i) * 0.6 / Double(count - 1), 0.5 + sin(Double(i) * 0.2) * 0.05)
            }
            let result = try timed("field \(count)") {
                WSSVectorFieldPaintTests().result(
                    try WSSVectorFieldPaint.paint(
                        field, imageSize: size, uvPoints: points, brush: brush), original: field)
            }
            let painted = try timed("region \(count)") {
                try region.painted(imageSize: size, points: points, subpaths: [], brush: brush)
            }
            let area = try timed("area \(count)") {
                try WSSDirectionArea.make(result, region: painted, flowGlyphs: true)
            }
            let layout = WSSFlowGlyphLayout(
                visible: CGRect(x: 0, y: 0, width: 960, height: 540), origin: .zero, zoom: 0.25,
                sceneHeight: 2160,
                geometry: WSSDirectionCanvasGeometry(
                    transform: WSSImageTransform(center: SIMD2(1920, 1080), size: SIMD2(3840, 2160))
                ))
            _ = timed("Flow glyph selection \(count)") {
                WSSFlowGlyphSelection.select(result, region: painted, area: area, layout: layout)
            }
            _ = timed("glyphs \(count)") {
                WSSDirectionSampling.samples(result, at: points, region: painted)
            }
            let mask = try WSSMaskStrokeTests().bitmap(width: region.width, height: region.height)
            var transaction = try WSSMaskStrokeTests().stroke(
                mask, diameter: 100 * 2048 / 3840,
                start: points[0] * SIMD2(Double(region.width), Double(region.height)))
            try timed("mask append all \(count)") {
                for p in points.dropFirst() {
                    try transaction.append(p * SIMD2(Double(region.width), Double(region.height)))
                }
            }
        }
    }
}
