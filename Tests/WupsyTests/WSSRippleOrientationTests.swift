import MetalKit
import XCTest
import simd

@testable import Wupsy

final class WSSRippleOrientationTests: XCTestCase {
    func decode(_ json: [String: Any]) throws -> WSSRippleEffect {
        let effect = try JSONDecoder().decode(
            WSSSceneDocumentV1.Effect.self,
            from: JSONSerialization.data(withJSONObject: json))
        guard case .ripple(let ripple) = effect.native else {
            throw WSSSceneError.invalid("expected ripple")
        }
        return ripple
    }

    func testOptionalRotationAndStrictDocumentValidation() throws {
        let original = WSSRippleTests().effectJSON()
        let absent = try decode(original)
        XCTAssertEqual(absent, WSSRippleEffect())
        var json = original
        json["structureRotation"] = 0
        XCTAssertEqual(try decode(json), absent)
        json["structureRotation"] = 90
        XCTAssertEqual(try decode(json).structureRotation, 90)
        json["structureRotation"] = 359.5
        XCTAssertEqual(try decode(json).structureRotation, 359.5)
        for value: Any in [-1, 360, NSNull(), true, "90", "NaN"] {
            json["structureRotation"] = value
            XCTAssertThrowsError(try decode(json), "\(value)")
        }
        for key in ["structureDirection", "experimentalStructureRotation", "unknown"] {
            json = original
            json[key] = 90
            XCTAssertThrowsError(try decode(json), key)
        }
        for value: Float in [-1, 360, .nan, .infinity, -.infinity] {
            var effect = absent
            effect.structureRotation = value
            XCTAssertThrowsError(try effect.validate())
        }
        // The additive field belongs only to Ripple, not to other effect schemas.
        let clouds: [String: Any] = [
            "type": "clouds", "velocity": [1, 0], "scale": 120,
            "intensity": 0.5, "density": 0.5, "seed": 1, "structureRotation": 90,
        ]
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                WSSSceneDocumentV1.Effect.self, from: JSONSerialization.data(withJSONObject: clouds)
            ))
    }

    func testMissingAndExplicitZeroAreByteIdenticalOnGPU() throws {
        let json = WSSRippleTests().effectJSON()
        let absent = try decode(json)
        var explicit = json
        explicit["structureRotation"] = 0
        let zero = try decode(explicit)
        let helper = WSSRippleTests()
        let original = try helper.resources(absent)
        let defaulted = try helper.resources(zero)
        for time in [0.0, 0.25, 1, 8, 1e6] {
            XCTAssertEqual(
                try helper.render(original, time: time),
                try helper.render(defaulted, time: time), "time \(time)")
        }
    }

    func testRotationPreservesComponentsAndIsIndependentOfMovement() throws {
        let original = WSSRippleEffect(
            amplitude: 10, wavelength: 48, stretch: 2, direction: 130,
            travelSpeed: 30, evolutionRate: 0, seed: 7319)
        var rotated = original
        rotated.structureRotation = 90
        XCTAssertEqual(rotated.velocity, original.velocity)
        XCTAssertEqual(rotated.waves.count, 6)
        for (a, b) in zip(original.waves, rotated.waves) {
            XCTAssertEqual(b.k.x, -a.k.y, accuracy: 1e-15)
            XCTAssertEqual(b.k.y, a.k.x, accuracy: 1e-15)
            XCTAssertEqual(simd_length(a.k), simd_length(b.k), accuracy: 1e-15)
            XCTAssertEqual(b.offset, a.offset)
            XCTAssertEqual(b.evolution, a.evolution)
            XCTAssertEqual(b.displacement, a.displacement)
        }
        let p = SIMD2<Double>(37, 91)
        let actual = try rotated.displacement(at: p, time: 0)
        let expected = try original.displacement(at: SIMD2(p.y, -p.x), time: 0)
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.00001)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.00001)
        for direction: Float in [0, 90, 180, 270] {
            var moved = rotated
            moved.direction = direction
            for (a, b) in zip(rotated.waves, moved.waves) { XCTAssertEqual(a.k, b.k) }
            let transported = try moved.displacement(at: p + moved.velocity * 0.5, time: 0.5)
            XCTAssertEqual(transported.x, actual.x, accuracy: 0.00001)
            XCTAssertEqual(transported.y, actual.y, accuracy: 0.00001)
        }
    }

    func testRotatedGPUOutputIsDeterministicAndUsesRotation() throws {
        var effect = WSSRippleEffect(
            amplitude: 8, wavelength: 24, stretch: 2, direction: 180,
            travelSpeed: 12, evolutionRate: 0.2, seed: 17)
        let helper = WSSRippleTests()
        let original = try helper.resources(effect)
        effect.structureRotation = 90
        let rotated = try helper.resources(effect)
        let duplicate = try helper.resources(effect)
        for time in [0.0, 0.25, 2] {
            let frame = try helper.render(rotated, time: time)
            XCTAssertEqual(frame, try helper.render(duplicate, time: time))
            XCTAssertNotEqual(frame, try helper.render(original, time: time))
        }
        effect.seed += 1
        XCTAssertNotEqual(
            try helper.render(rotated, time: 1),
            try helper.render(helper.resources(effect), time: 1))
    }
}
