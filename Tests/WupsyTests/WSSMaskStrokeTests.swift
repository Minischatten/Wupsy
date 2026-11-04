import XCTest

@testable import Wupsy

final class WSSMaskStrokeTests: XCTestCase {
    func bitmap(_ value: UInt8 = 0, width: Int = 64, height: Int = 16) throws -> WSSMaskBitmap {
        try WSSMaskBitmap(
            width: width, height: height, uvScale: SIMD2(0.75, 1),
            pixels: Data(repeating: value, count: width * height))
    }
    func stroke(
        _ bitmap: WSSMaskBitmap, diameter: Double = 8, opacity: Double = 1,
        mode: WSSMaskBrushSettings.Mode = .paint, start: SIMD2<Double> = SIMD2(8, 8)
    ) throws -> WSSMaskStrokeTransaction {
        try WSSMaskStrokeTransaction(
            resolved: WSSResolvedMaskTarget(
                target: WSSMaskTarget(
                    sessionID: UUID(), layerID: WSSLayerID(), effectID: WSSEffectID(), slot: .ripple
                ),
                path: "assets/mask.png", fingerprint: WSSContentFingerprint(Data()), definition: nil
            ),
            revision: 0, bitmap: bitmap,
            settings: WSSMaskBrushSettings(diameter: diameter, opacity: opacity, mode: mode),
            start: start)
    }
    func testScalarCodecPreservesEveryByteAndUVWithoutColorConversion() throws {
        let pixels = Data((0..<1024).map { UInt8($0 % 256) })
        let bitmap = try WSSMaskBitmap(
            width: 256, height: 4, uvScale: SIMD2(0.5, 0.75), pixels: pixels)
        let decoded = try WSSMaskBitmap(
            WSSMaskAsset.decode(
                bitmap.encoded(), width: 256, height: 4, uvScale: bitmap.uvScale))
        XCTAssertEqual(decoded, bitmap)
        let definition = bitmap.definition(path: "assets/new.png")
        XCTAssertEqual(definition.uvScale, [0.5, 0.75])
        XCTAssertEqual(definition.filter, "linear")
        XCTAssertEqual(definition.edge, "clamp")
        XCTAssertFalse(definition.mipmapped)
    }
    func testRGBAUsesRedNotLuminanceOrOtherChannels() throws {
        let png = try WSSNativeSceneTests().png(
            [0, 255, 100, 255, 128, 0, 255, 255, 255, 0, 0, 255], width: 3, height: 1)
        let bitmap = try WSSMaskBitmap(
            WSSMaskAsset.decode(png, width: 3, height: 1, uvScale: SIMD2(1, 1)))
        XCTAssertEqual(bitmap.pixels, Data([0, 128, 255]))
        XCTAssertEqual(
            try WSSMaskAsset.decode(bitmap.encoded(), width: 3, height: 1, uvScale: SIMD2(1, 1))
                .pixels, bitmap.pixels)
    }
    func testScalarAndBrushLimitsRejectInvalidInputs() throws {
        for size in [(0, 1), (8193, 1), (8192, 8192)] {
            XCTAssertThrowsError(
                try WSSMaskBitmap(
                    width: size.0, height: size.1, uvScale: SIMD2(1, 1), pixels: Data()))
        }
        XCTAssertThrowsError(
            try WSSMaskBitmap(
                width: 1, height: 1, uvScale: SIMD2(.nan, 1), pixels: Data([0])))
        XCTAssertThrowsError(try WSSMaskBrushSettings(diameter: 0, opacity: 1, mode: .paint))
        XCTAssertThrowsError(try WSSMaskBrushSettings(diameter: .nan, opacity: 1, mode: .paint))
        XCTAssertThrowsError(try WSSMaskBrushSettings(diameter: 1, opacity: 1.1, mode: .paint))
        XCTAssertThrowsError(try stroke(bitmap(), diameter: 129))
    }
    func testAbsolutePaintTargetsEveryStartingValueExactly() throws {
        for old: UInt8 in [0, 51, 128, 204, 255] {
            var value = try stroke(
                bitmap(old, width: 1, height: 1), diameter: 2, opacity: 0.5, start: .zero)
            let result = try value.finish()?.result.pixels ?? value.before.pixels
            XCTAssertEqual(result, Data([128]))
        }
        XCTAssertEqual(WSSMaskBrushSettings.quantized(0.5), 128)
        XCTAssertEqual(WSSMaskBrushSettings.quantized(0), 0)
        XCTAssertEqual(WSSMaskBrushSettings.quantized(1), 255)
    }
    func testRepeatedAbsolutePaintCoreIsNoOpAndTargetCanIncreaseOrDecrease() throws {
        var first = try stroke(
            bitmap(0, width: 1, height: 1), diameter: 2, opacity: 0.5, start: .zero)
        let half = try XCTUnwrap(first.finish()).result
        var repeated = try stroke(half, diameter: 2, opacity: 0.5, start: .zero)
        XCTAssertNil(try repeated.finish())
        var up = try stroke(half, diameter: 2, opacity: 0.7, start: .zero)
        let high = try XCTUnwrap(up.finish()).result
        XCTAssertEqual(high.pixels, Data([179]))
        var down = try stroke(high, diameter: 2, opacity: 0.3, start: .zero)
        XCTAssertEqual(try down.finish()?.result.pixels, Data([77]))
        var zero = try stroke(high, diameter: 2, opacity: 0, start: .zero)
        XCTAssertEqual(try zero.finish()?.result.pixels, Data([0]))
    }
    func testRelativeEraseStillBuildsDownAcrossSeparateStrokes() throws {
        var first = try stroke(
            bitmap(255, width: 1, height: 1), diameter: 2, opacity: 0.5, mode: .erase, start: .zero)
        let half = try XCTUnwrap(first.finish()).result
        XCTAssertEqual(half.pixels, Data([128]))
        var second = try stroke(half, diameter: 2, opacity: 0.5, mode: .erase, start: .zero)
        XCTAssertEqual(try second.finish()?.result.pixels, Data([64]))
        var none = try stroke(half, diameter: 2, opacity: 0, mode: .erase, start: .zero)
        XCTAssertNil(try none.finish())
        var full = try stroke(half, diameter: 2, opacity: 1, mode: .erase, start: .zero)
        XCTAssertEqual(try full.finish()?.result.pixels, Data([0]))
    }
    func testSoftEdgeInterpolatesFromPreStrokeWithoutStampAccumulation() throws {
        for old: UInt8 in [0, 51, 128, 204, 255] {
            var once = try stroke(bitmap(old), opacity: 0.5)
            let first = try once.finish()?.result ?? once.before
            // Radius 4, distance 3: coverage exactly 0.5.
            let expected = WSSMaskBrushSettings.quantized(Double(old) / 255 * 0.5 + 0.5 * 0.5)
            XCTAssertEqual(first.pixels[8 * 64 + 11], expected)
            var repeated = try stroke(bitmap(old), opacity: 0.5)
            for _ in 0..<100 { try repeated.append(SIMD2(8, 8)) }
            XCTAssertEqual(try repeated.finish()?.result ?? repeated.before, first)
        }
        XCTAssertEqual(WSSMaskBrushSettings.coverage(distance: 2, radius: 4), 1)
        XCTAssertEqual(WSSMaskBrushSettings.coverage(distance: 3, radius: 4), 0.5)
        XCTAssertEqual(WSSMaskBrushSettings.coverage(distance: 4, radius: 4), 0)
    }
    func testSamplingIsIndependentOfEventFrequencyForSmallAndLargeBrushes() throws {
        for diameter in [1.0, 8.0, 64.0] {
            var fast = try stroke(bitmap(), diameter: diameter, start: SIMD2(1, 8))
            try fast.append(SIMD2(62, 8))
            var slow = try stroke(bitmap(), diameter: diameter, start: SIMD2(1, 8))
            for x in 2...62 { try slow.append(SIMD2(Double(x), 8)) }
            let a = try XCTUnwrap(fast.finish())
            XCTAssertEqual(try slow.finish()?.result, a.result)
            for x in 1...62 { XCTAssertGreaterThan(a.result.pixels[8 * 64 + x], 0) }
        }
    }
    func testFinalPositionAndExplicitSegmentBreak() throws {
        var value = try stroke(bitmap(), diameter: 1, start: SIMD2(1, 8))
        try value.breakSegment()
        try value.append(SIMD2(60, 8))
        let result = try XCTUnwrap(value.finish(at: SIMD2(62, 8))).result
        XCTAssertEqual(result.pixels[8 * 64 + 30], 0)
        XCTAssertGreaterThan(result.pixels[8 * 64 + 62], 0)
    }
    func testCancelAndNoOpProduceNoCandidateAndCannotBeReused() throws {
        let source = try bitmap()
        var value = try stroke(source)
        XCTAssertNotEqual(value.pixels, source.pixels)
        value.cancel()
        XCTAssertEqual(value.pixels, source.pixels)
        XCTAssertThrowsError(try value.finish())
        XCTAssertThrowsError(try value.append(SIMD2(1, 1)))
        var white = try stroke(bitmap(255))
        XCTAssertNil(try white.finish())
        XCTAssertThrowsError(try white.finish())
    }
    func testOnePixelBrushHasNoGapsOnHalfTexelPath() throws {
        var value = try stroke(bitmap(), diameter: 1, start: SIMD2(1.5, 8.5))
        try value.append(SIMD2(61.5, 8.5))
        let result = try XCTUnwrap(value.finish()).result
        for x in 2...61 {
            XCTAssertGreaterThan(result.pixels[8 * 64 + x], 0)
            XCTAssertGreaterThan(result.pixels[9 * 64 + x], 0)
        }
    }
    func testNonFiniteOrUnboundedPointsFailWithoutMutation() throws {
        var value = try stroke(bitmap())
        let before = value.pixels
        for point in [SIMD2<Double>(.nan, 1), SIMD2(.infinity, 1), SIMD2(1e20, 1)] {
            XCTAssertThrowsError(try value.append(point))
            XCTAssertEqual(value.pixels, before)
        }
    }
}
