import XCTest

@testable import Wupsy

final class WSSDirectionGlyphPresentationTests: XCTestCase {
    func field() throws -> WSSVectorFieldAsset {
        var bytes = Data()
        for component: Float in [0, 0, 1, 0, 0, 0, -1, 0] {
            var word = Float16(component).bitPattern.littleEndian
            withUnsafeBytes(of: &word) { bytes.append(contentsOf: $0) }
        }
        let field = WSSVectorFieldAsset(
            width: 4, height: 1, vectors: bytes,
            coverage: Data([255, 255, 0, 0]), isNeutral: false)
        try field.validate()
        return field
    }
    let queries: [SIMD2<Double>] = [
        SIMD2(0.125, 0.5), SIMD2(0.375, 0.5), SIMD2(0.625, 0.5), SIMD2(0.875, 0.5),
    ]

    func testNoRegionShowsDirectionsWithoutTurningNeutralRawSamplesIntoGlyphs() throws {
        // Image-bound Flow has no explicit Flow region.
        let field = try field()
        let bytes = field.vectors
        let coverage = field.coverage
        let raw = WSSDirectionSampling.samples(field, at: queries)
        XCTAssertEqual(raw.map(\.vector), [.zero, SIMD2(1, 0), .zero, SIMD2(-1, 0)])
        let glyphs = WSSDirectionOverlayGeometry.glyphSamples(raw, hasRegion: false)
        XCTAssertEqual(glyphs.map(\.uv), [queries[1], queries[3]])
        XCTAssertEqual(glyphs.map(\.vector), [SIMD2(1, 0), SIMD2(-1, 0)])
        // Coverage must not become paint-history gating: hidden nonzero vectors
        // remain authorable/presented with their existing coverage-based opacity.
        XCTAssertEqual(glyphs.last?.coverage, 0)
        XCTAssertEqual(WSSDirectionSampling.samples(field, at: queries), raw)
        XCTAssertEqual(field.vectors, bytes)
        XCTAssertEqual(field.coverage, coverage)
    }

    func testExplicitRegionKeepsItsGateAndNeutralActiveCells() throws {
        let field = try field()
        let region = WSSFlowRegion(width: 4, height: 1, pixels: Data([255, 255, 0, 0]))
        try region.validate()
        let regionBytes = region.pixels
        let raw = WSSDirectionSampling.samples(field, at: queries, region: region)
        XCTAssertEqual(raw.map(\.uv), [queries[0], queries[1]])
        let glyphs = WSSDirectionOverlayGeometry.glyphSamples(raw, hasRegion: true)
        XCTAssertEqual(glyphs, raw)
        XCTAssertEqual(glyphs.first?.vector, .zero)  // Active neutral region remains visible.
        XCTAssertEqual(glyphs.last?.vector, SIMD2(1, 0))
        XCTAssertFalse(glyphs.contains { $0.uv == queries[2] || $0.uv == queries[3] })
        XCTAssertEqual(region.pixels, regionBytes)
    }

    func testExistingNeutralThresholdIsOnlyAGlyphPresentationBoundary() {
        let samples: [WSSDirectionSample] = [
            .init(uv: queries[0], vector: SIMD2(0.0001, 0), coverage: 1),
            .init(uv: queries[1], vector: SIMD2(0.002, 0), coverage: 1),
        ]
        XCTAssertEqual(
            WSSDirectionOverlayGeometry.glyphSamples(samples, hasRegion: false), [samples[1]])
        XCTAssertEqual(WSSDirectionOverlayGeometry.glyphSamples(samples, hasRegion: true), samples)
        XCTAssertEqual(samples[0].vector, SIMD2(0.0001, 0))
    }
}
