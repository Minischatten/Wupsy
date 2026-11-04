import MetalKit
import XCTest

@testable import Wupsy

final class WSSFlowGlyphSelectionTests: XCTestCase {
    let size = SIMD2<Double>(1280, 640)
    func layout(rotation: Float = 0, scale: SIMD2<Float> = SIMD2(1, 1), zoom: CGFloat = 0.5)
        -> WSSFlowGlyphLayout
    {
        WSSFlowGlyphLayout(
            visible: CGRect(x: 0, y: 0, width: 640, height: 320), origin: .zero, zoom: zoom,
            sceneHeight: 640,
            geometry: WSSDirectionCanvasGeometry(
                transform: WSSImageTransform(
                    center: SIMD2(640, 320), size: SIMD2(1280, 640), scale: scale,
                    rotation: rotation)))
    }
    func region(_ contains: (Double, Double) -> Bool) -> WSSFlowRegion {
        var pixels = Data(count: 1280 * 640)
        pixels.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for y in 0..<640 {
                for x in 0..<1280 {
                    raw[y * 1280 + x] =
                        contains((Double(x) + 0.5) / 1280, (Double(y) + 0.5) / 640) ? 255 : 0
                }
            }
        }
        return WSSFlowRegion(width: 1280, height: 640, pixels: pixels)
    }
    func select(
        _ field: WSSVectorFieldAsset, _ region: WSSFlowRegion?, _ layout: WSSFlowGlyphLayout? = nil
    ) throws -> WSSFlowGlyphSelectionResult {
        let area = try WSSDirectionArea.make(field, region: region, flowGlyphs: true)
        return WSSFlowGlyphSelection.select(
            field, region: region, area: area, layout: layout ?? self.layout())
    }
    func point(_ sample: WSSDirectionSample, _ layout: WSSFlowGlyphLayout) -> CGPoint {
        WSSCanvasGeometry.viewportPoint(
            layout.geometry.scene(sample.uv), origin: layout.origin, zoom: layout.zoom,
            height: layout.sceneHeight)
    }
    func assertRegion(
        _ samples: [WSSDirectionSample], _ region: WSSFlowRegion, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for sample in samples {
            let index =
                Int(sample.uv.y * Double(region.height)) * region.width
                + Int(sample.uv.x * Double(region.width))
            XCTAssertEqual(region.pixels[index], 255, file: file, line: line)
            XCTAssertGreaterThanOrEqual(
                hypot(sample.vector.x, sample.vector.y),
                Float(WSSDirectionOverlayGeometry.minimumDirectionalMagnitude), file: file,
                line: line)
        }
    }
    func testThreeThinHorizontalRegionsBetweenOldGridRowsHaveEvenGlyphs() throws {
        let field = try WSSVectorFieldPaintTests().field(
            width: 128, height: 64, vector: SIMD2(0.35, 0))
        let rows = [0.123, 0.427, 0.731]
        let region = region { x, y in
            (0.04...0.96).contains(x) && rows.contains { abs(y - $0) < 0.003 }
        }
        let l = layout()
        let oldQueries = WSSDirectionOverlayGeometry.queries(
            visible: l.visible, origin: l.origin, zoom: l.zoom, height: l.sceneHeight,
            geometry: l.geometry)
        XCTAssertTrue(
            WSSDirectionSampling.samples(field, at: oldQueries, region: region).isEmpty,
            "Reproduces point-grid miss despite continuous region")
        let selection = try select(field, region)
        assertRegion(selection.samples, region)
        for row in rows {
            let line = selection.samples.filter { abs($0.uv.y - row) < 0.003 }.map {
                point($0, l).x
            }.sorted()
            XCTAssertGreaterThanOrEqual(line.count, 10)
            for pair in zip(line, line.dropFirst()) {
                XCTAssertGreaterThanOrEqual(pair.1 - pair.0, l.spacing * 0.65 - 0.01)
                XCTAssertLessThanOrEqual(pair.1 - pair.0, l.spacing * 1.6)
            }
        }
        XCTAssertTrue(selection.samples.allSatisfy { $0.vector.x > 0 && abs($0.vector.y) < 0.001 })
        XCTAssertLessThanOrEqual(selection.fieldProbes, 4 * 13 * 7)
        XCTAssertEqual(selection.samples, try select(field, region).samples)
    }
    func testActualPaintedLongStrokesHaveContinuousVectorsDespiteOldGridMissingThem() throws {
        let helper = WSSVectorFieldPaintTests()
        var field = try helper.field(width: 512, height: 256)
        var region = try WSSFlowRegion.empty(size: SIMD2(3840, 1920))
        let brush = try WSSVectorBrush(diameter: 80, magnitude: 1, operation: .direction)
        let ys = [0.125, 0.375, 0.625]
        for y in ys {
            let points = [SIMD2<Double>(0.05, y), SIMD2(0.95, y)]
            field = helper.result(
                try WSSVectorFieldPaint.paint(
                    field, imageSize: SIMD2(3840, 1920), uvPoints: points, brush: brush),
                original: field)
            region = try region.painted(
                imageSize: SIMD2(3840, 1920), points: points, subpaths: [], brush: brush)
            let centerline = WSSDirectionSampling.samples(
                field, at: (1...80).map { SIMD2(0.1 + Double($0) / 100, y) }, region: region)
            XCTAssertEqual(centerline.count, 80)
            XCTAssertTrue(centerline.allSatisfy { $0.vector.x > 0.95 && abs($0.vector.y) < 0.001 })
        }
        let l = WSSFlowGlyphLayout(
            visible: CGRect(x: 0, y: 0, width: 1200, height: 600), origin: .zero, zoom: 0.3125,
            sceneHeight: 1920,
            geometry: WSSDirectionCanvasGeometry(
                transform: WSSImageTransform(center: SIMD2(1920, 960), size: SIMD2(3840, 1920))))
        let queries = WSSDirectionOverlayGeometry.queries(
            visible: l.visible, origin: l.origin, zoom: l.zoom, height: l.sceneHeight,
            geometry: l.geometry)
        XCTAssertTrue(WSSDirectionSampling.samples(field, at: queries, region: region).isEmpty)
        let area = try WSSDirectionArea.make(field, region: region, flowGlyphs: true)
        let result = WSSFlowGlyphSelection.select(field, region: region, area: area, layout: l)
        for y in ys {
            XCTAssertGreaterThanOrEqual(
                result.samples.filter { abs($0.uv.y - y) < 0.025 }.count, 20)
        }
        assertRegion(result.samples, region)
        print(
            "FLOW GLYPH ROOT CAUSE: 240 continuous centerline vectors >0.95; old grid 0 glyphs; region-aware",
            result.samples.count, "probes", result.fieldProbes)
    }
    func testThinVerticalRegionAndWeakVectorsHaveVisibleCorrectDirection() throws {
        let field = try WSSVectorFieldPaintTests().field(
            width: 128, height: 64, vector: SIMD2(0, 0.002))
        let region = region { x, y in abs(x - 0.437) < 0.002 && (0.05...0.95).contains(y) }
        let l = layout()
        let samples = try select(field, region).samples
        XCTAssertGreaterThanOrEqual(samples.count, 5)
        assertRegion(samples, region)
        for sample in samples {
            let arrow = WSSDirectionOverlayGeometry.arrow(
                sample, geometry: l.geometry, origin: l.origin, zoom: l.zoom, height: l.sceneHeight,
                minimumLength: WSSFlowGlyphSelection.minimumLength)
            XCTAssertEqual(arrow.tip.x, arrow.center.x, accuracy: 0.001)
            XCTAssertGreaterThan(arrow.tip.y, arrow.center.y)
            XCTAssertEqual(
                hypot(arrow.tip.x - arrow.center.x, arrow.tip.y - arrow.center.y), 14,
                accuracy: 0.001)
            XCTAssertEqual(sample.vector.y, Float(Float16(0.002)), accuracy: 0.000001)
            // The raw overlay helper retains magnitude-proportional display size.
            let transport = WSSDirectionOverlayGeometry.arrow(
                sample, geometry: l.geometry, origin: l.origin, zoom: l.zoom, height: l.sceneHeight)
            XCTAssertLessThan(
                hypot(transport.tip.x - transport.center.x, transport.tip.y - transport.center.y), 1
            )
        }
    }
    func testNeutralAndBelowThresholdRegionsNeverProduceFakeGlyphs() throws {
        let region = region { _, _ in true }
        for magnitude: Float in [0, 0.0001] {
            let field = try WSSVectorFieldPaintTests().field(
                width: 128, height: 64, vector: SIMD2(magnitude, 0))
            XCTAssertTrue(try select(field, region).samples.isEmpty)
            XCTAssertTrue(try select(field, nil).samples.isEmpty)
        }
    }
    func testCurvedFieldPreservesLocalDirectionsAndDoesNotMutateData() throws {
        var vectors = Data()
        for _ in 0..<64 {
            for x in 0..<128 {
                let angle = sin((Double(x) + 0.5) / 128 * 2 * .pi) * 1.1
                for component in [Float(cos(angle) * 0.4), Float(sin(angle) * 0.4)] {
                    var word = Float16(component).bitPattern.littleEndian
                    withUnsafeBytes(of: &word) { vectors.append(contentsOf: $0) }
                }
            }
        }
        let coverage = Data((0..<(128 * 64)).map { UInt8($0 % 256) })
        let field = WSSVectorFieldAsset(
            width: 128, height: 64, vectors: vectors, coverage: coverage, isNeutral: false)
        try field.validate()
        let region = region { x, y in abs(y - (0.5 + 0.2 * sin(x * 2 * .pi))) < 0.025 }
        let original = region.pixels
        let samples = try select(field, region).samples
        XCTAssertGreaterThan(samples.count, 10)
        XCTAssertTrue(samples.contains { $0.vector.y > 0.15 })
        XCTAssertTrue(samples.contains { $0.vector.y < -0.15 })
        XCTAssertEqual(
            samples, WSSDirectionSampling.samples(field, at: samples.map(\.uv), region: region))
        assertRegion(samples, region)
        XCTAssertEqual(field.vectors, vectors)
        XCTAssertEqual(field.coverage, coverage)
        XCTAssertEqual(region.pixels, original)
    }
    func testLegacyW1RegionlessFieldCoverageAndViewTransformsRemainDeterministic() throws {
        let bytes = Data((0..<(128 * 64)).flatMap { _ in [UInt8(200), 128, 0, 0] })
        let field = try WSSVectorFieldAsset.rgba(width: 128, height: 64, pixels: bytes)
        let l = layout(rotation: 0.23, scale: SIMD2(0.85, 1.15))
        let samples = try select(field, nil, l).samples
        XCTAssertGreaterThan(samples.count, 20)
        XCTAssertTrue(samples.allSatisfy { $0.vector.x > 0 && $0.coverage == 0 })
        XCTAssertEqual(samples, try select(field, nil, l).samples)
        let before = field.vectors
        _ = try select(field, nil, layout(zoom: 1))
        XCTAssertEqual(field.vectors, before)
        XCTAssertEqual(field.coverage, Data(count: 128 * 64))
    }
    @MainActor func testLiveFlowGlyphsTrackProvisionalAndUndoStatesWithoutPaintReplayForLayout()
        async throws
    {
        let input = WSSNewFlowCanvasInputTests()
        try await input.setUp()
        addTeardownBlock { @MainActor in try await input.tearDown() }
        try input.doc.addEffect(.flow)
        let session = input.doc.directionCanvas
        await session.waitForLoad()
        await input.doc.waitForPreview()
        let geometry = try XCTUnwrap(session.geometry)
        let frame = try XCTUnwrap(input.canvas.surface.subviews.compactMap { $0 as? MTKView }.first)
            .frame
        let l = WSSFlowGlyphLayout(
            visible: input.canvas.surface.visibleRect, origin: frame.origin,
            zoom: frame.width / input.canvas.surface.sceneSize.width,
            sceneHeight: input.canvas.surface.sceneSize.height, geometry: geometry)
        session.updateFlowGlyphLayout(l)
        XCTAssertTrue(session.flowGlyphs.isEmpty)
        try input.downAndDrag()
        await session.waitForFeedback()
        let state = try XCTUnwrap(session.transientState)
        XCTAssertFalse(session.flowGlyphs.isEmpty)
        assertRegion(session.flowGlyphs, try XCTUnwrap(state.region))
        let passes = session.feedbackPaintPassCount
        let shifted = WSSFlowGlyphLayout(
            visible: l.visible.insetBy(dx: 1, dy: 1), origin: l.origin, zoom: l.zoom,
            sceneHeight: l.sceneHeight, geometry: l.geometry)
        session.updateFlowGlyphLayout(shifted)
        await session.waitForFeedback()
        XCTAssertEqual(session.feedbackPaintPassCount, passes)
        XCTAssertEqual(session.transientState?.field.vectors, state.field.vectors)
        XCTAssertEqual(session.transientState?.region, state.region)
        input.canvas.surface.mouseUp(with: try input.event(.leftMouseUp, uv: SIMD2(0.45, 0.6)))
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertFalse(session.flowGlyphs.isEmpty)
        input.doc.undoManager.undo()
        await session.waitForLoad()
        XCTAssertTrue(session.flowGlyphs.isEmpty)
        input.doc.undoManager.redo()
        await session.waitForLoad()
        XCTAssertFalse(session.flowGlyphs.isEmpty)
    }
    func testSelectionUsesVisibleCachedSupportAndFourLocalProbesPerCell() throws {
        let field = try WSSVectorFieldPaintTests().field(
            width: 128, height: 64, vector: SIMD2(1, 0))
        let area = try WSSDirectionArea.make(field, region: nil, flowGlyphs: true)
        let base = layout(zoom: 2)
        let l = WSSFlowGlyphLayout(
            visible: CGRect(x: 600, y: 200, width: 100, height: 100), origin: .zero, zoom: 2,
            sceneHeight: 640, geometry: base.geometry)
        let result = WSSFlowGlyphSelection.select(field, region: nil, area: area, layout: l)
        XCTAssertLessThan(result.inspectedSupportCells, field.width * field.height / 10)
        XCTAssertLessThanOrEqual(result.fieldProbes, 16)
        XCTAssertLessThanOrEqual(result.samples.count, 4)
        XCTAssertTrue(result.samples.allSatisfy { l.visible.contains(point($0, l)) })
        XCTAssertNil(
            try WSSDirectionArea.make(field).glyphSupport,
            "Raw overlay path allocates no Flow index")
    }
}
