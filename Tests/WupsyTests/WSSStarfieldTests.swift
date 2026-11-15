import MetalKit
import XCTest

@testable import Wupsy

final class WSSStarfieldTests: XCTestCase {
    func configuration() -> WSSStarfieldConfiguration {
        var c = WSSStarfieldConfiguration()
        c.width = 64
        c.height = 64
        c.count = 100
        c.size = 1.5
        return c
    }
    func model(_ c: WSSStarfieldConfiguration) throws -> WSSSceneDocumentV1 {
        let config = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c))
        return try WSSSceneDocumentV1.decode(
            data: JSONSerialization.data(withJSONObject: [
                "format": "wss-scene", "version": 1, "title": "Synthetic starfield",
                "canvas": ["width": 64, "height": 64],
                "layers": [["type": "starfield", "starfield": config]],
            ]))
    }
    func resources(_ c: WSSStarfieldConfiguration, front: Bool = false, reversed: Bool = false)
        throws -> WSSStaticResources
    {
        let stars = WSSSceneLayer.starfield(.init(starfield: c))
        let image = WSSSceneLayer.image(
            .init(
                asset: .init(value: "foreground"),
                transform: .init(center: SIMD2(32, 32), size: SIMD2(64, 64))))
        let layers = front ? (reversed ? [image, stars] : [stars, image]) : [stars]
        // Left half opaque; right half transparent. Synthetic data, no personal assets.
        let bytes: [UInt8] = [0, 0, 0, 255, 0, 0, 0, 0]
        return try WSSStaticResources(
            scene: WSSScene(width: 64, height: 64, layers: layers),
            assets: WSSStaticTests.Assets(values: [
                .init(value: "foreground"): WSSImageAsset(
                    width: 2, height: 1, payload: .rgba8(Data(bytes)))
            ]), device: WSSStaticTests().device())
    }
    func render(_ r: WSSStaticResources, time: Double = 0) throws -> Data {
        try WSSStormLightingRenderTests().render(r, time: time).0
    }
    func testStrictRoundTripAndLegacyCompatibility() throws {
        let c = configuration()
        let m = try model(c)
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: m.encoded()), m)
        XCTAssertTrue(m.referencedPaths.isEmpty)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: m.encoded()) as? [String: Any])
        var layers = try XCTUnwrap(json["layers"] as? [[String: Any]])
        var config = try XCTUnwrap(layers[0]["starfield"] as? [String: Any])
        for invalid: Any in [NSNull(), "yes", 1] {
            config["twinkleEnabled"] = invalid
            layers[0]["starfield"] = config
            json["layers"] = layers
            XCTAssertThrowsError(
                try WSSSceneDocumentV1.decode(data: JSONSerialization.data(withJSONObject: json)))
        }
        config["twinkleEnabled"] = false
        config["shootingStars"] = true
        layers[0]["starfield"] = config
        json["layers"] = layers
        XCTAssertThrowsError(
            try WSSSceneDocumentV1.decode(data: JSONSerialization.data(withJSONObject: json)))
        let legacy = try WSSStormTests().model()
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: legacy.encoded()), legacy)
    }
    func testValidationAndSceneBudgetsIncludeHiddenLayers() throws {
        for parameter in WSSStarfieldParameter.allCases {
            for invalid in [
                Double.nan, .infinity, -.infinity, parameter.range.lowerBound - 1,
                parameter.range.upperBound + 1,
            ] {
                var c = configuration()
                XCTAssertThrowsError(try parameter.apply(invalid, to: &c), parameter.rawValue)
            }
            if parameter.integral {
                var c = configuration()
                XCTAssertThrowsError(try parameter.apply(0.5, to: &c))
            }
        }
        var c = configuration()
        c.red = .nan
        XCTAssertThrowsError(try c.validate())
        c = configuration()
        c.width = 8192
        c.height = 8192
        XCTAssertThrowsError(try c.validate())
        c = configuration()
        c.count = 16_384
        let node = WSSSceneLayer.starfield(.init(visible: false, starfield: c))
        try WSSScene(width: 64, height: 64, layers: Array(repeating: node, count: 4)).validate()
        XCTAssertThrowsError(
            try WSSScene(width: 64, height: 64, layers: Array(repeating: node, count: 5)).validate()
        )
        c.count = 1
        XCTAssertThrowsError(
            try WSSScene(
                width: 64, height: 64,
                layers: Array(repeating: .starfield(.init(starfield: c)), count: 9)
            ).validate())
    }
    func testPopulationSeedPrefixBoundsAndColor() throws {
        let a = try WSSStarfieldPopulation(count: 100, seed: 42).instances
        XCTAssertEqual(a, try WSSStarfieldPopulation(count: 100, seed: 42).instances)
        XCTAssertNotEqual(a, try WSSStarfieldPopulation(count: 100, seed: 43).instances)
        XCTAssertEqual(
            Array(a.prefix(50)), try WSSStarfieldPopulation(count: 50, seed: 42).instances)
        XCTAssertEqual(MemoryLayout<WSSStarfieldPopulation.Instance>.stride, 32)
        XCTAssertTrue(a.allSatisfy { (0..<1).contains($0.state.x) && (0..<1).contains($0.state.y) })
        for base: SIMD3<Float> in [
            SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 1), SIMD3(1, 0, 1),
            SIMD3(repeating: 1),
        ] {
            for star in a {
                XCTAssertEqual(
                    WSSStarfieldPopulation.color(
                        base, variation: 0, warm: star.variation.z, tint: star.variation.w), base)
                let color = WSSStarfieldPopulation.color(
                    base, variation: 1, warm: star.variation.z, tint: star.variation.w)
                for i in 0..<3 {
                    XCTAssertLessThanOrEqual(abs(color[i] - base[i]), 0.151)
                }
            }
        }
    }
    func testStaticAnimationAndLongTimePhases() throws {
        var c = configuration()
        func animated() throws -> Bool { try model(c).scene().isAnimated }
        XCTAssertFalse(try animated())
        c.twinkleEnabled = true
        XCTAssertTrue(try animated())
        c.twinkleIntensity = 0
        XCTAssertFalse(try animated())
        c.driftX = -0.5
        XCTAssertTrue(try animated())
        c.brightness = 0
        XCTAssertFalse(try animated())
        for time in [0.0, 1, 1e6, 1e12, 1e100] {
            let phase = WSSStarfieldConfiguration.phase(time: time, speed: -0.25, period: 64)
            XCTAssertTrue(phase.isFinite && phase >= 0 && phase < 64)
        }
        XCTAssertEqual(
            WSSStarfieldConfiguration.phase(time: 123, speed: -0.25, period: 64),
            WSSStarfieldConfiguration.phase(time: 379, speed: -0.25, period: 64))
    }
    func testGPUColorForegroundOrderingAndAlpha() throws {
        var c = configuration()
        c.red = 0
        c.green = 1
        c.blue = 0
        c.colorVariation = 0
        let baseline = try render(resources(c))
        XCTAssertTrue(baseline.enumerated().contains { $0.offset % 4 == 1 && $0.element > 0 })
        for i in stride(from: 0, to: baseline.count, by: 4) {
            XCTAssertEqual(baseline[i], 0)
            XCTAssertEqual(baseline[i + 2], 0)
            XCTAssertEqual(baseline[i + 3], 255)
        }
        let covered = try render(resources(c, front: true))
        let before = try render(resources(c, front: true, reversed: true))
        XCTAssertEqual(before, baseline)
        var visibleRight = false
        for y in 0..<64 {
            for x in 0..<64 {
                let i = (y * 64 + x) * 4
                if x < 12 { XCTAssertEqual(covered[i + 1], 0) }
                if x > 50 && covered[i + 1] > 0 { visibleRight = true }
            }
        }
        XCTAssertTrue(visibleRight)
    }
    func testGPUClippingWrappingDeterminismAndTwinkle() throws {
        var c = configuration()
        c.x = 16
        c.y = 16
        c.width = 32
        c.height = 32
        c.driftX = 0.5
        c.driftY = -0.25
        let r = try resources(c)
        let first = try render(r)
        XCTAssertEqual(first, try render(r, time: 128))
        XCTAssertNotEqual(first, try render(r, time: 10))
        for y in 0..<64 {
            for x in 0..<64 where x < 16 || x >= 48 || y < 16 || y >= 48 {
                let i = (y * 64 + x) * 4
                XCTAssertEqual(Array(first[i..<i + 3]), [0, 0, 0])
            }
        }
        c.twinkleEnabled = true
        c.twinkleIntensity = 1
        let twinkling = try resources(c)
        XCTAssertNotEqual(try render(twinkling), try render(twinkling, time: 0.5))
        // With zero drift an unanimated layer is identical at all playback times.
        c.twinkleEnabled = false
        c.driftX = 0
        c.driftY = 0
        let still = try resources(c)
        XCTAssertEqual(try render(still), try render(still, time: 1e12))
    }
    func testImmutableBufferReuseBudgetsAndRelease() throws {
        let c = configuration()
        let m = try model(c)
        var r: WSSStaticResources? = try resources(c)
        let renderer = try XCTUnwrap(r?.starfield)
        let buffer = renderer.layers[0]?.buffer
        XCTAssertEqual(renderer.bufferBytes, c.count * 32)
        var changed = m
        var updated = c
        updated.brightness = 2
        updated.driftX = 0.5
        changed.layers[0].content = .starfield(.init(starfield: updated))
        let reuse = try XCTUnwrap(r?.updatingTransforms(from: m, to: changed))
        XCTAssertTrue(reuse.starfield === renderer)
        updated.seed = 2
        changed.layers[0].content = .starfield(.init(starfield: updated))
        XCTAssertNil(try r?.updatingTransforms(from: m, to: changed))
        XCTAssertEqual(r?.textureBytes, 0)
        r = nil
        XCTAssertNotNil(buffer)  // Shared snapshot still owns it.
    }
    func testGPUWrappingConservesHalosAcrossAllEdges() throws {
        var c = configuration()
        c.driftX = 1
        c.driftY = -1
        let r = try resources(c)
        let a = try render(r)
        let b = try render(r, time: 1)
        var maximumDifference = 0
        for y in 0..<64 {
            for x in 0..<64 {
                let source = (((y + 63) % 64) * 64 + (x + 63) % 64) * 4
                let destination = (y * 64 + x) * 4
                for channel in 0..<3 {
                    maximumDifference = max(
                        maximumDifference,
                        abs(Int(a[source + channel]) - Int(b[destination + channel])))
                }
            }
        }
        XCTAssertLessThanOrEqual(
            maximumDifference, 1,
            "Wrapping must translate the complete halo without losing edge fragments")
    }
    func testGPUIndependentLayersAndFreeRGBColors() throws {
        for base: SIMD3<Double> in [
            SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 1), SIMD3(1, 0, 1),
            SIMD3(repeating: 1),
        ] {
            var c = configuration()
            c.red = base.x
            c.green = base.y
            c.blue = base.z
            c.colorVariation = 0
            let image = try render(resources(c))
            for channel in 0..<3 {
                let values = stride(from: 2 - channel, to: image.count, by: 4).map { image[$0] }
                if base[channel] == 0 {
                    XCTAssertEqual(values.max(), 0)
                } else {
                    XCTAssertGreaterThan(values.max() ?? 0, 0)
                }
            }
        }
        var a = configuration()
        a.width = 32
        a.red = 1
        a.green = 0
        a.blue = 0
        var b = a
        b.x = 32
        b.red = 0
        b.blue = 1
        b.seed = 2
        let r = try WSSStaticResources(
            scene: WSSScene(
                width: 64, height: 64,
                layers: [
                    .starfield(.init(starfield: a)), .starfield(.init(starfield: b)),
                ]), assets: WSSStaticTests.Assets(values: [:]), device: WSSStaticTests().device())
        XCTAssertEqual(r.starfield?.layers.count, 2)
        let image = try render(r)
        var red = 0
        var blue = 0
        for y in 0..<64 {
            for x in 0..<64 {
                let i = (y * 64 + x) * 4
                if x < 32 {
                    XCTAssertEqual(image[i], 0)
                    red += Int(image[i + 2])
                } else {
                    XCTAssertEqual(image[i + 2], 0)
                    blue += Int(image[i])
                }
            }
        }
        XCTAssertGreaterThan(red, 0)
        XCTAssertGreaterThan(blue, 0)
    }
    func test4KMaxPopulationAndStaticPlayer() async throws {
        var c = configuration()
        c.width = 3840
        c.height = 2160
        c.count = 16_384
        let r = try WSSStaticResources(
            scene: WSSScene(width: 3840, height: 2160, layers: [.starfield(.init(starfield: c))]),
            assets: WSSStaticTests.Assets(values: [:]), device: WSSStaticTests().device())
        XCTAssertEqual(r.starfield?.bufferBytes, 512 * 1024)
        XCTAssertEqual(r.textureBytes, 0)
        let result = try WSSStormLightingRenderTests().render(
            r, time: 123, width: 3840, height: 2160)
        XCTAssertEqual(result.0.count, 3840 * 2160 * 4)
        await MainActor.run {
            let player = WSSStaticPlayer(
                resources: r, size: CGSize(width: 64, height: 64), scale: 1, maxDimension: 8192,
                fps: 60, resolution: .standard, offset: 0,
                onError: { _ in XCTFail("Unexpected render failure") })
            player.play()
            XCTAssertTrue(player.view.isPaused)
            XCTAssertTrue(player.view.enableSetNeedsDisplay)
            player.stop()
        }
    }
    func testResourcesReleaseAfterCompletedFrames() throws {
        weak var buffer: MTLBuffer?
        weak var renderer: WSSStarfieldRenderer?
        try autoreleasepool {
            let r = try resources(configuration())
            buffer = r.starfield?.layers[0]?.buffer
            renderer = r.starfield
            _ = try render(r)
            XCTAssertNotNil(buffer)
        }
        XCTAssertNil(renderer)
        XCTAssertNil(buffer)
    }
}
