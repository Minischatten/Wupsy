import MetalKit
import XCTest

@testable import Wupsy

final class WSSCloudsExtensionTests: XCTestCase {
    func resources(_ effect: WSSCloudsEffect, size: Int = 256, mask: UInt8 = 255) throws
        -> WSSStaticResources
    {
        let image = WSSAssetID(value: "own/black")
        let maskID = WSSAssetID(value: "own/mask")
        var e = effect
        if effect.mask != nil { e.mask = .init(asset: maskID) }
        let scene = WSSScene(
            width: size, height: size,
            layers: [
                WSSImageLayer(
                    asset: image,
                    transform: .init(
                        center: SIMD2(Float(size) / 2, Float(size) / 2),
                        size: SIMD2(repeating: Float(size))), effects: [.clouds(e)])
            ])
        return try WSSStaticResources(
            scene: scene,
            assets: WSSStaticTests.Assets(values: [
                image: WSSStaticTests().solid([0, 0, 0, 255]),
                maskID: WSSStaticTests().solid([mask, 0, 0, 255]),
            ]), device: WSSStaticTests().device())
    }
    func render(_ e: WSSCloudsEffect, time: Double = 0, size: Int = 256) throws -> Data {
        try WSSCloudsTests().render(resources(e), time: time, width: size, height: size).0
    }
    func testModelDirectionsRangesAndNeutralDefaults() throws {
        let base = WSSCloudsEffect()
        XCTAssertFalse(base.isExtended)
        XCTAssertEqual(base.primaryField, .init(velocity: SIMD2(12, 0), scale: 256))
        for (angle, expected): (Float, SIMD2<Float>) in [
            (0, SIMD2(0, -1)), (90, SIMD2(1, 0)), (180, SIMD2(0, 1)), (270, SIMD2(-1, 0)),
        ] {
            var e = base
            e.shadingDirection = angle
            XCTAssertEqual(e.shadingVector.x, expected.x, accuracy: 0.0001)
            XCTAssertEqual(e.shadingVector.y, expected.y, accuracy: 0.0001)
        }
        for key: WritableKeyPath<WSSCloudsEffect, Float> in [
            \.brightness, \.secondaryInfluence, \.shadingAmount, \.shadingDirection,
        ] {
            for bad: Float in [.nan, .infinity, -.infinity, -1] {
                var e = base
                e[keyPath: key] = bad
                XCTAssertThrowsError(try e.validate())
            }
        }
        for change: (inout WSSCloudsEffect) -> Void in [
            { $0.brightness = 2.01 }, { $0.secondaryInfluence = 1.01 }, { $0.shadingAmount = 1.01 },
            { $0.shadingDirection = 360 },
            { $0.secondaryField = .init(velocity: SIMD2(.nan, 0), scale: 10) },
            { $0.secondaryField = .init(velocity: SIMD2(0, 4097), scale: 10) },
            { $0.secondaryField = .init(velocity: .zero, scale: 0) },
            { $0.secondaryField = .init(velocity: .zero, scale: 8193) },
        ] {
            var e = base
            change(&e)
            XCTAssertThrowsError(try e.validate())
        }
        for amount: Float in [0, 1] {
            for brightness: Float in [0, 1, 2] {
                var e = base
                e.shadingAmount = amount
                e.brightness = brightness
                e.secondaryField = .init(velocity: SIMD2(-4096, 4096), scale: 8192)
                e.secondaryInfluence = amount
                try e.validate()
            }
        }
    }
    func testV1NeutralExactAndIndependentMotion() throws {
        let base = WSSCloudsEffect(
            velocity: .zero, scale: 180, intensity: 0.8, density: 0.5, seed: 7)
        let old = try render(base)
        var e = base
        e.secondaryField = .init(velocity: SIMD2(-35, 14), scale: 320)
        e.secondaryInfluence = 0
        e.shadingAmount = 0
        e.shadingDirection = 270
        e.brightness = 1
        XCTAssertFalse(e.isExtended)
        XCTAssertEqual(old, try render(e, time: 12))
        e.secondaryInfluence = 0.7
        let a = try render(e)
        let b = try render(e, time: 2)
        XCTAssertNotEqual(old, a)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, try render(e))
        e.secondaryField?.scale = 700
        XCTAssertNotEqual(a, try render(e))
        // Long-time reduction is independently bounded for both motions.
        for t in [1e12, Double.greatestFiniteMagnitude] {
            let phase = try e.secondaryPhase(at: t)
            XCTAssertTrue(phase.x.isFinite && phase.y.isFinite)
            XCTAssertEqual(try render(e, time: t), try render(e, time: t))
        }
    }
    func testToneCoverageMaskAndDirectionalShading() throws {
        var e = WSSCloudsEffect(
            velocity: .zero, scale: 180, intensity: 0.8, density: 0.5, seed: 7,
            secondaryField: .init(velocity: SIMD2(-10, 20), scale: 350), secondaryInfluence: 0.5)
        let full = try render(e)
        e.brightness = 0.5
        let half = try render(e)
        for i in stride(from: 0, to: full.count, by: 4) {
            XCTAssertEqual(full[i + 3], half[i + 3])
            XCTAssertLessThanOrEqual(abs(Int(half[i]) * 2 - Int(full[i])), 2)
        }
        e.brightness = 0
        let black = try render(e)
        XCTAssertTrue(stride(from: 0, to: black.count, by: 4).allSatisfy { black[$0] == 0 })
        e.brightness = 1
        e.shadingAmount = 0.6
        let up = try render(e)
        e.shadingDirection = 180
        let down = try render(e)
        XCTAssertNotEqual(full, up)
        XCTAssertNotEqual(up, down)
        e.brightness = 2
        let bright = try render(e)
        for i in stride(from: 0, to: down.count, by: 4) {
            XCTAssertGreaterThanOrEqual(bright[i], down[i])
        }
        e.mask = .init(asset: .init(value: "mask"))
        let masked = try WSSCloudsTests().render(resources(e, mask: 0), width: 256, height: 256).0
        XCTAssertTrue(stride(from: 0, to: masked.count, by: 4).allSatisfy { masked[$0] == 0 })
        e.mask = nil
        e.density = 0
        let clear = try render(e)
        XCTAssertTrue(stride(from: 0, to: clear.count, by: 4).allSatisfy { clear[$0] == 0 })
    }
    func testScaleDoublesSpatialFeaturesAndSecondaryWrapIsContinuous() throws {
        var e = WSSCloudsEffect(velocity: .zero, scale: 180, intensity: 1, density: 0.5, seed: 7)
        let small = try render(e)
        e.scale = 360
        let large = try render(e)
        var error = 0.0
        for y in 0..<128 {
            for x in 0..<128 {
                let average = (0..<2).reduce(0) { sum, dy in
                    sum
                        + (0..<2).reduce(0) { sum, dx in
                            sum + Int(large[((y * 2 + dy) * 256 + x * 2 + dx) * 4])
                        }
                }
                error += abs(Double(average) / 4 - Double(small[(y * 256 + x) * 4]))
            }
        }
        // Same logical features occupy twice the width/height, allowing raster filtering.
        XCTAssertLessThan(error / (128 * 128), 2)
        e.secondaryField = .init(velocity: SIMD2(-35, 14), scale: 320)
        e.secondaryInfluence = 0.7
        e.shadingAmount = 1
        let field = e.secondaryField!
        let axisSpeed =
            WSSCloudsNoise.secondaryOrientation.x * field.velocity.x
            - WSSCloudsNoise.secondaryOrientation.y * field.velocity.y
        let period = Double(field.scale) / abs(Double(axisSpeed))
        let before = try render(e, time: period - 0.00001)
        let after = try render(e, time: period + 0.00001)
        let delta = zip(before, after).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
        XCTAssertLessThan(delta / Double(before.count), 0.1)
    }
    func testNativeDocumentCompatibilityAndStrictExtensions() throws {
        let oldURL = WSSCloudsFixtureTests().fixture.appendingPathComponent("scene.wss.json")
        let old = try Data(contentsOf: oldURL)
        let original = try JSONSerialization.jsonObject(with: old) as! [String: Any]
        func decode(_ effect: [String: Any]) throws -> WSSCloudsEffect {
            var root = original
            var layers = root["layers"] as! [[String: Any]]
            layers[0]["effects"] = [effect]
            root["layers"] = layers
            let scene = try JSONDecoder().decode(
                WSSSceneDocumentV1.self, from: JSONSerialization.data(withJSONObject: root)
            ).scene()
            guard case .image(let l) = scene.layers[0], case .clouds(let e) = l.effects[0] else {
                throw WSSSceneError.invalid("test")
            }
            return e
        }
        let oldEffect =
            ((original["layers"] as! [[String: Any]])[0]["effects"] as! [[String: Any]])[0]
        let oldNative = try decode(oldEffect)
        XCTAssertFalse(oldNative.isExtended)
        var native = oldEffect
        native.removeValue(forKey: "velocity")
        native.removeValue(forKey: "scale")
        native["primaryField"] = ["velocity": [24, -3], "scale": 600]
        XCTAssertEqual(oldNative, try decode(native))
        native["secondaryField"] = ["velocity": [-10, 20], "scale": 900]
        native["shadingAmount"] = 0.5
        native["shadingDirection"] = 90
        native["brightness"] = 0.9
        XCTAssertTrue(try decode(native).isExtended)
        for (key, value): (String, Any) in [
            ("velocity", [1, 2]), ("unknown", 1), ("shadingAmount", 2),
            ("secondaryField", ["velocity": [0, 0], "scale": 300, "frequency": 2]),
            ("secondaryField", NSNull()),
        ] {
            var bad = native
            bad[key] = value
            XCTAssertThrowsError(try decode(bad))
        }
    }
    func testV2FixtureAndLogicalRasterParity() async throws {
        let root = WSSCloudsFixtureTests().fixture.deletingLastPathComponent()
            .appendingPathComponent("WSS-Clouds-v2")
        let item = try WallpaperImporter.resolve(root)
        let r = try await WSSStaticPreparation.shared.prepare(item)
        let helper = WSSCloudsTests()
        let a = try helper.render(r, time: 4, width: 960, height: 540).0
        let b = try helper.render(r, time: 4, width: 1920, height: 1080).0
        var sum = 0.0
        var count = 0.0
        for y in stride(from: 8, to: 532, by: 8) {
            for x in stride(from: 8, to: 952, by: 8) {
                for c in 0..<3 {
                    let high = (0..<2).reduce(0) { s, dy in
                        s
                            + (0..<2).reduce(0) { v, dx in
                                v + Int(b[((2 * y + dy) * 1920 + 2 * x + dx) * 4 + c])
                            }
                    }
                    sum += abs(Double(high) / 4 - Double(a[(y * 960 + x) * 4 + c]))
                    count += 1
                }
            }
        }
        XCTAssertLessThan(sum / count, 2)
        for time in [0.0, 4, 10, 1e12] {
            let bytes = try helper.render(r, time: time, width: 1920, height: 1080).0
            if time < 100, let path = ProcessInfo.processInfo.environment["AMBIENT_CLOUDS_V2_QA"] {
                let folder = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true)
                try NativeImageTestWriter().save(
                    bytes, width: 1920, height: 1080,
                    to: folder.appendingPathComponent("clouds-v2-t\(Int(time)).png"))
            }
        }
        print(
            "Clouds v2 fixture: logical raster MAE \(sum/count), own noise/resources, masked native PNGs"
        )
    }

}
