import XCTest

@testable import Wupsy

final class WSSStormTests: XCTestCase {
    func onset(_ c: WSSStormConfiguration) -> Double {
        c.interval * (0.1 + 0.1 * WSSStormRandom.unit(UInt64(c.seed) ^ 0x5343_4845_4455_4c45))
    }
    func model(_ configuration: WSSStormConfiguration = .init()) throws -> WSSSceneDocumentV1 {
        let config = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration))
        let json: [String: Any] = [
            "format": "wss-scene", "version": 1, "title": "Synthetic storm",
            "canvas": ["width": 1920, "height": 1080],
            "layers": [["type": "storm", "storm": config]],
        ]
        return try WSSSceneDocumentV1.decode(data: JSONSerialization.data(withJSONObject: json))
    }
    func testDeterministicScheduleGeometryAndSeparateStreams() throws {
        let c = WSSStormConfiguration()
        let time = onset(.init()) + 0.01
        let a = try XCTUnwrap(WSSStormEvents.event(c, at: time))
        XCTAssertEqual(a, WSSStormEvents.event(c, at: time))
        let geometry = try WSSStormGeometry.segments(c, event: a.identity)
        XCTAssertEqual(geometry, try WSSStormGeometry.segments(c, event: a.identity))
        XCTAssertEqual(geometry.count, 192)
        XCTAssertEqual(geometry[0].a, .zero)
        XCTAssertEqual(geometry[63].b, SIMD2(0, -800))
        var other = c
        other.seed = 2
        XCTAssertNotEqual(geometry, try WSSStormGeometry.segments(other, event: a.identity))
        other = c
        other.branchDepth = 0
        other.spread = 0
        XCTAssertEqual(a, WSSStormEvents.event(other, at: time))
        let straight = try WSSStormGeometry.segments(other, event: a.identity)
        XCTAssertTrue(straight.allSatisfy { $0.a.x == 0 && $0.b.x == 0 })
        XCTAssertNotEqual(geometry, try WSSStormGeometry.segments(c, event: 123))
    }
    func testCadenceFlickerAndBoundedLargeSeeks() throws {
        let c = WSSStormConfiguration()
        let start = onset(.init())
        XCTAssertNil(WSSStormEvents.event(c, at: 0))
        let first = try XCTUnwrap(WSSStormEvents.event(c, at: start + 0.01))
        let second = try XCTUnwrap(
            WSSStormEvents.event(c, at: start + c.presentationDuration + c.flashGap + 0.01))
        XCTAssertEqual(first.identity, second.identity)
        XCTAssertGreaterThan(first.intensity, second.intensity)
        XCTAssertGreaterThan(second.intensity, 0)
        let gap = try XCTUnwrap(
            WSSStormEvents.event(c, at: start + c.presentationDuration + c.flashGap / 2))
        XCTAssertEqual(gap.intensity, 0)
        XCTAssertNil(WSSStormEvents.event(c, at: start + c.eventDuration + 0.001))
        let next = try XCTUnwrap(WSSStormEvents.event(c, at: start + c.interval + 0.01))
        XCTAssertNotEqual(next.identity, first.identity)
        for time in [1e6, 1e12, 1e100, Double.greatestFiniteMagnitude] {
            XCTAssertEqual(WSSStormEvents.event(c, at: time), WSSStormEvents.event(c, at: time))
        }
        for time in [-1, Double.nan, .infinity] { XCTAssertNil(WSSStormEvents.event(c, at: time)) }
    }
    func testShortPulsesSurviveEvery24FPSPhaseAndPauseClock() throws {
        var c = WSSStormConfiguration()
        c.duration = 0.01
        c.flashes = 1
        let start = onset(c)
        for phase in 0..<100 {
            let offset = Double(phase) / 100 / 24
            let samples = (0..<100).map { Double($0) / 24 + offset }
            XCTAssertTrue(
                samples.contains { (WSSStormEvents.event(c, at: $0)?.intensity ?? 0) > 0 })
        }
        var clock = WSSPlaybackClock(offset: start + 0.01)
        let frozen = WSSStormEvents.event(c, at: clock.time(now: 100))
        clock.play(now: 100)
        clock.stop(now: 100.01)
        let paused = WSSStormEvents.event(c, at: clock.time(now: 1000))
        XCTAssertEqual(paused, WSSStormEvents.event(c, at: clock.time(now: 2000)))
        clock.play(now: 2000)
        XCTAssertEqual(paused, WSSStormEvents.event(c, at: clock.time(now: 2000)))
        XCTAssertNotNil(frozen)
        XCTAssertNil(WSSStormEvents.event(c, at: clock.time(now: 2001)))
    }
    func testAllNumericBoundsNonFiniteAndIntegerRejection() throws {
        for parameter in WSSStormParameter.allCases {
            for invalid in [
                Double.nan, .infinity, -.infinity, parameter.range.lowerBound - 1,
                parameter.range.upperBound + 1,
            ] {
                var c = WSSStormConfiguration()
                XCTAssertThrowsError(try parameter.apply(invalid, to: &c), parameter.rawValue)
            }
            if parameter.integral {
                var c = WSSStormConfiguration()
                XCTAssertThrowsError(try parameter.apply(0.5, to: &c))
            }
        }
        var c = WSSStormConfiguration()
        c.interval = 0.5
        c.duration = 0.5
        XCTAssertThrowsError(try c.validate())
        c = .init()
        c.seed = .max
        c.branchDepth = 3
        XCTAssertEqual(try WSSStormGeometry.segments(c, event: .max).count, 256)
        let scene = WSSScene(
            width: 1920, height: 1080,
            layers: Array(repeating: .storm(.init(visible: false, storm: c)), count: 8))
        try scene.validate()
        XCTAssertLessThanOrEqual(c.segmentCount * 8, WSSStormGeometry.maximumSegmentsPerScene)
        var excessive = scene
        excessive.layers.append(.storm(.init()))
        XCTAssertThrowsError(try excessive.validate())
        c.branchDepth = 4
        excessive.layers = [.storm(.init(visible: false, storm: c))]
        XCTAssertThrowsError(try excessive.validate())
    }
    func testStrictV1RoundtripAndNoResourceReferences() throws {
        var c = WSSStormConfiguration()
        c.seed = .max
        c.x = 12.123456789
        let document = try model(c)
        let encoded = try document.encoded()
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: encoded), document)
        XCTAssertTrue(document.referencedPaths.isEmpty)
        XCTAssertTrue(try document.scene().isAnimated)
        var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var layers = json["layers"] as! [[String: Any]]
        var storm = layers[0]["storm"] as! [String: Any]
        for (key, value): (String, Any) in [
            ("unknown", 1), ("duration", NSNull()), ("seed", -1), ("flashes", 1.5),
        ] {
            var badStorm = storm
            badStorm[key] = value
            var badLayers = layers
            badLayers[0]["storm"] = badStorm
            var bad = json
            bad["layers"] = badLayers
            XCTAssertThrowsError(
                try WSSSceneDocumentV1.decode(data: JSONSerialization.data(withJSONObject: bad))
                    .scene())
        }
        storm.removeValue(forKey: "length")
        layers[0]["storm"] = storm
        json["layers"] = layers
        XCTAssertThrowsError(
            try WSSSceneDocumentV1.decode(data: JSONSerialization.data(withJSONObject: json)))
        let legacy = Data(
            """
            {"format":"wss-scene","version":1,"title":"Old","canvas":{"width":64,"height":64},"layers":[{"image":"assets/a.png","transform":{"center":[32,32],"size":[64,64]}}]}
            """.utf8)
        let old = try WSSSceneDocumentV1.decode(data: legacy)
        XCTAssertEqual(old, try WSSSceneDocumentV1.decode(data: old.encoded()))
        XCTAssertNil(
            try old.scene().layers.compactMap {
                if case .storm(let s) = $0 { return s }
                return nil
            }.first)
    }
}
