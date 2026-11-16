import XCTest

@testable import Wupsy

final class WSSShootingStarTests: XCTestCase {
    func configuration() -> WSSStarfieldConfiguration {
        var c = WSSStarfieldTests().configuration()
        c.count = 0
        c.shootingStars.enabled = true
        c.shootingStars.frequency = 12
        c.shootingStars.speed = 50
        c.shootingStars.tailLength = 20
        c.shootingStars.direction = 0
        c.shootingStars.directionVariation = 0
        return c
    }
    func onset(_ c: WSSStarfieldConfiguration, slot: UInt64 = 0) -> Double {
        let s = WSSShootingStarEvents.samples(seed: c.seed, slot: slot)
        return (Double(slot) + 0.1 + 0.8 * s[0]) * 60 / c.shootingStars.frequency
    }
    func testDeterministicIrregularScheduleIndependentOfPopulationColorAndDrift() throws {
        let c = configuration()
        let onsets = (0..<30).map { onset(c, slot: UInt64($0)) }
        let intervals = zip(onsets.dropFirst(), onsets).map { $0 - $1 }
        XCTAssertGreaterThan(Set(intervals.map { Int($0 * 1000) }).count, 20)
        XCTAssertTrue(intervals.allSatisfy { $0 > 0.99 && $0 < 9.01 })
        let t = onsets[2] + 0.3
        let a = WSSShootingStarEvents.events(c, at: t)
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(a, WSSShootingStarEvents.events(c, at: t))
        var changed = c
        changed.count = 9000
        changed.red = 0.3
        changed.colorVariation = 1
        changed.driftX = 5
        changed.driftY = -5
        changed.brightness = 0
        XCTAssertEqual(a, WSSShootingStarEvents.events(changed, at: t))
        changed.seed = 42
        XCTAssertNotEqual(a, WSSShootingStarEvents.events(changed, at: t))
        for event in a {
            XCTAssertTrue((0.1...0.9).contains(event.origin.x))
            XCTAssertTrue((0.15...0.85).contains(event.origin.y))
            XCTAssertEqual(event.heading.x, 1, accuracy: 1e-12)
            XCTAssertEqual(event.heading.y, 0, accuracy: 1e-12)
        }
    }
    func testBoundedSeeksCycleAndPauseResume() {
        var c = configuration()
        let t = onset(c) + 0.4
        let event = WSSShootingStarEvents.events(c, at: t)
        var clock = WSSPlaybackClock(offset: t)
        clock.play(now: 100)
        clock.stop(now: 100)
        XCTAssertEqual(WSSShootingStarEvents.events(c, at: clock.time(now: 1000)), event)
        clock.play(now: 1000)
        XCTAssertEqual(WSSShootingStarEvents.events(c, at: clock.time(now: 1000)), event)
        XCTAssertNotEqual(WSSShootingStarEvents.events(c, at: clock.time(now: 1010)), event)
        for time in [-1, Double.nan, .infinity] {
            XCTAssertTrue(WSSShootingStarEvents.events(c, at: time).isEmpty)
        }
        for frequency in [0.0, 0.1, 2, 12] {
            c.shootingStars.frequency = frequency
            for time in [0.0, 1, 1e6, 1e12, 1e100, Double.greatestFiniteMagnitude] {
                let a = WSSShootingStarEvents.events(c, at: time)
                XCTAssertEqual(a, WSSShootingStarEvents.events(c, at: time))
                XCTAssertLessThanOrEqual(a.count, 2)
                XCTAssertTrue(a.allSatisfy { $0.age.isFinite && $0.duration <= 2 })
            }
        }
    }
    func testOverlapLimitAndCycleBoundaryDoNotCreateStartupGhosts() {
        let c = configuration()
        XCTAssertTrue(WSSShootingStarEvents.events(c, at: 0).isEmpty)
        var foundOverlap = false
        for slot in 1..<1000 {
            let t = onset(c, slot: UInt64(slot)) + 0.1
            let events = WSSShootingStarEvents.events(c, at: t)
            XCTAssertLessThanOrEqual(events.count, 2)
            if events.count == 2 {
                foundOverlap = true
                break
            }
        }
        XCTAssertTrue(foundOverlap)
        let cycle = Double(WSSShootingStarEvents.cycleSlots) * 5
        var foundCrossing = false
        for seed: UInt32 in 0..<100 {
            var c = c
            c.seed = seed
            let lastSlot = WSSShootingStarEvents.cycleSlots - 1
            let a = WSSShootingStarEvents.events(c, at: cycle - 0.01).first { $0.slot == lastSlot }
            let b = WSSShootingStarEvents.events(c, at: cycle + 0.01).first { $0.slot == lastSlot }
            if let a, let b {
                XCTAssertEqual(b.age - a.age, 0.02, accuracy: 0.00001)
                foundCrossing = true
                break
            }
        }
        XCTAssertTrue(foundCrossing)
    }
    func testBoundsStrictOptionalEncodingAndLegacyDefault() throws {
        for p in WSSShootingStarParameter.allCases {
            for v in [
                Double.nan, .infinity, -.infinity, p.range.lowerBound - 1, p.range.upperBound + 1,
            ] {
                var m = WSSStarfieldShootingStars()
                XCTAssertThrowsError(try p.apply(v, to: &m))
            }
        }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
                "Test-Wallpaper/WSS-Starfield-v1/scene.wss.json")
        let old = try WSSSceneDocumentV1.decode(data: Data(contentsOf: fixture))
        XCTAssertFalse(String(decoding: try old.encoded(), as: UTF8.self).contains("shootingStars"))
        var c = configuration()
        let encoded = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(WSSStarfieldConfiguration.self, from: encoded), c)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for invalid: Any in [NSNull(), true, ["enabled": true], ["unknown": 1]] {
            json["shootingStars"] = invalid
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    WSSStarfieldConfiguration.self,
                    from: JSONSerialization.data(withJSONObject: json)))
        }
        c.shootingStars.enabled = false
        c.shootingStars.speed = .nan
        XCTAssertThrowsError(try c.validate())
    }
    func testStaticAndMeteorOnlyLayer() throws {
        var c = configuration()
        XCTAssertTrue(c.isAnimated)  // Count zero must not suppress independent meteors.
        c.shootingStars.enabled = false
        XCTAssertFalse(c.isAnimated)
        c.shootingStars.enabled = true
        c.shootingStars.frequency = 0
        XCTAssertFalse(c.isAnimated)
        c.shootingStars.frequency = 2
        c.shootingStars.brightness = 0
        XCTAssertFalse(c.isAnimated)
        c.shootingStars.brightness = 1
        c.red = 0
        c.green = 0
        c.blue = 0
        XCTAssertFalse(c.isAnimated)
    }
    func testEnvelopesDirectionsAndIndependentLayers() {
        var c = configuration()
        c.shootingStars.direction = 315
        c.shootingStars.directionVariation = 20
        for i in 0..<100 {
            let t = onset(c, slot: UInt64(i))
            let early = WSSShootingStarEvents.events(c, at: t + 0.0001).first {
                $0.slot == UInt64(i)
            }
            XCTAssertLessThan(early?.envelope ?? 1, 0.001)
            let a = WSSShootingStarEvents.events(c, at: t + 0.5).first { $0.slot == UInt64(i) }
            XCTAssertGreaterThan(a?.envelope ?? 0, 0.5)
            if let a {
                let degrees = atan2(a.heading.y, a.heading.x) * 180 / .pi
                XCTAssertTrue((-65 ... -25).contains(degrees))
                XCTAssertTrue(
                    WSSShootingStarEvents.events(c, at: t + a.duration + 0.01).allSatisfy {
                        $0.slot != a.slot
                    })
            }
        }
        var second = c
        second.seed = 2
        XCTAssertNotEqual(onset(c), onset(second))
    }
}
