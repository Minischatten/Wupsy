import XCTest

@testable import Wupsy

final class WSSStormIlluminationTests: XCTestCase {
    func configuration() -> WSSStormConfiguration {
        var c = WSSStormConfiguration()
        c.illumination.enabled = true
        return c
    }
    func scene(_ c: WSSStormConfiguration) -> WSSScene {
        WSSScene(width: 64, height: 64, layers: [.storm(.init(storm: c))])
    }
    func testThreeModesUseSameEventAndLeaveSeededGeometryUnchanged() throws {
        let original = WSSStormConfiguration()
        let geometry = try WSSStormGeometry.segments(original, event: 17)
        let time = WSSStormTests().onset(original) + 0.01
        let legacy = WSSStormLightingFrame.illumination(scene: scene(original), at: time)
        XCTAssertFalse(legacy.isEffective)
        for bolt in [true, false] {
            var c = configuration()
            c.boltEnabled = bolt
            XCTAssertTrue(scene(c).isAnimated)
            XCTAssertEqual(
                WSSStormEvents.event(c, at: time), WSSStormEvents.event(original, at: time))
            XCTAssertEqual(try WSSStormGeometry.segments(c, event: 17), geometry)
            XCTAssertTrue(WSSStormLightingFrame.illumination(scene: scene(c), at: time).isEffective)
        }
        var off = configuration()
        off.boltEnabled = false
        off.illumination.enabled = false
        XCTAssertFalse(scene(off).isAnimated)
        off.illumination.enabled = true
        off.brightness = 0
        XCTAssertTrue(scene(off).isAnimated)
    }
    func testPulseSynchronizationSmoothFalloffAndDeterministicSeeks() throws {
        let c = configuration()
        let start = WSSStormTests().onset(configuration())
        let early = WSSStormLightingFrame.illumination(scene: scene(c), at: start + 0.02)
        let late = WSSStormLightingFrame.illumination(scene: scene(c), at: start + 0.10)
        XCTAssertGreaterThan(early.exposure.x, late.exposure.x)
        XCTAssertGreaterThan(late.exposure.x, 0)
        XCTAssertFalse(
            WSSStormLightingFrame.illumination(
                scene: scene(c), at: start + c.presentationDuration + 0.04
            ).isEffective)
        XCTAssertTrue(
            WSSStormLightingFrame.illumination(
                scene: scene(c), at: start + c.presentationDuration + c.flashGap + 0.01
            ).isEffective)
        for time in [0, 1.0, 1e12, Double.greatestFiniteMagnitude] {
            XCTAssertEqual(
                WSSStormLightingFrame.illumination(scene: scene(c), at: time),
                WSSStormLightingFrame.illumination(scene: scene(c), at: time))
        }
        for fps in [24, 30, 60] {
            XCTAssertTrue(
                (0..<fps * 2).contains {
                    WSSStormLightingFrame.illumination(
                        scene: scene(c), at: Double($0) / Double(fps)
                    ).isEffective
                })
        }
        var clock = WSSPlaybackClock(offset: start + 0.02)
        clock.play(now: 100)
        clock.stop(now: 100)
        let frozen = WSSStormLightingFrame.illumination(scene: scene(c), at: clock.time(now: 1000))
        clock.play(now: 1000)
        XCTAssertEqual(
            frozen, WSSStormLightingFrame.illumination(scene: scene(c), at: clock.time(now: 1000)))
    }
    func testAggregationLimitsHiddenAndZeroEnergyLights() throws {
        var c = configuration()
        c.illumination.intensity = 4
        c.illumination.shadowLift = 0.25
        let time = WSSStormTests().onset(c) + 0.01
        var s = scene(c)
        s.layers = Array(repeating: .storm(.init(storm: c)), count: 8)
        try s.validate()
        let f = WSSStormLightingFrame.illumination(scene: s, at: time)
        XCTAssertEqual(f.exposure, SIMD3(repeating: 4))
        XCTAssertEqual(f.shadowLift, SIMD3(repeating: 0.25))
        s.layers = [.storm(.init(visible: false, storm: c))]
        XCTAssertFalse(s.hasEffectiveStormIllumination)
        XCTAssertFalse(WSSStormLightingFrame.illumination(scene: s, at: time).isEffective)
        c.illumination.red = 0
        c.illumination.green = 0
        c.illumination.blue = 0
        XCTAssertFalse(scene(c).hasEffectiveStormIllumination)
        c = configuration()
        c.illumination.intensity = 0
        c.illumination.shadowLift = 0
        XCTAssertFalse(scene(c).hasEffectiveStormIllumination)
    }
    func testLegacyEncodingAndStrictOptionalExtension() throws {
        let old = try WSSStormTests().model()
        let oldBytes = try old.encoded()
        let oldJSON = try JSONSerialization.jsonObject(with: oldBytes) as! [String: Any]
        let oldConfig = ((oldJSON["layers"] as! [[String: Any]])[0]["storm"] as! [String: Any])
        XCTAssertNil(oldConfig["illumination"])
        XCTAssertNil(oldConfig["boltEnabled"])
        let decoded = try WSSSceneDocumentV1.decode(data: oldBytes)
        XCTAssertEqual(try decoded.encoded(), oldBytes)
        var c = configuration()
        c.boltEnabled = false
        let modern = try WSSStormTests().model(c)
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: modern.encoded()), modern)
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
        for (key, value): (String, Any) in [
            ("illumination", NSNull()), ("boltEnabled", NSNull()), ("boltEnabled", 1),
        ] {
            var bad = raw
            bad[key] = value
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    WSSStormConfiguration.self, from: JSONSerialization.data(withJSONObject: bad)))
        }
        for (key, value): (String, Any) in [
            ("unknown", 0), ("intensity", 5), ("shadowLift", -1), ("enabled", NSNull()), ("red", 2),
        ] {
            var bad = raw
            var light = raw["illumination"] as! [String: Any]
            light[key] = value
            bad["illumination"] = light
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    WSSStormConfiguration.self, from: JSONSerialization.data(withJSONObject: bad)))
        }
        var bad = raw
        var incomplete = raw["illumination"] as! [String: Any]
        incomplete.removeValue(forKey: "green")
        bad["illumination"] = incomplete
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                WSSStormConfiguration.self, from: JSONSerialization.data(withJSONObject: bad)))
    }
    func testDisabledAndHiddenLightingStillValidatesAllNumbers() throws {
        for key: WritableKeyPath<WSSStormIllumination, Double> in [
            \.intensity, \.shadowLift, \.red, \.green, \.blue,
        ] {
            for bad in [Double.nan, .infinity, -.infinity, -1] {
                var c = configuration()
                c.illumination.enabled = false
                c.illumination[keyPath: key] = bad
                let s = WSSScene(
                    width: 64, height: 64, layers: [.storm(.init(visible: false, storm: c))])
                XCTAssertThrowsError(try s.validate())
            }
        }
    }
}
