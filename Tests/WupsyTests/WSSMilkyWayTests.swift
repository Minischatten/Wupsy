import XCTest

@testable import Wupsy

final class WSSMilkyWayTests: XCTestCase {
    func configuration() -> WSSStarfieldConfiguration {
        var c = WSSStarfieldTests().configuration()
        c.count = 0
        c.milkyWay.enabled = true
        return c
    }
    func testAllBoundsStrictOptionalDecodingAndLegacyDefaults() throws {
        for p in WSSMilkyWayParameter.allCases {
            for invalid in [
                Double.nan, .infinity, -.infinity, p.range.lowerBound - 1, p.range.upperBound + 1,
            ] {
                var m = WSSMilkyWay()
                XCTAssertThrowsError(try p.apply(invalid, to: &m))
            }
        }
        var m = WSSMilkyWay()
        XCTAssertThrowsError(try WSSMilkyWayParameter.seed.apply(1.5, to: &m))
        m.red = .nan
        XCTAssertThrowsError(try m.validate())
        var c = configuration()
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(WSSStarfieldConfiguration.self, from: data), c)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for invalid: Any in [NSNull(), true, [:], ["enabled": true], ["unsupported": 0]] {
            json["milkyWay"] = invalid
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    WSSStarfieldConfiguration.self,
                    from: JSONSerialization.data(withJSONObject: json)))
        }
        c.milkyWay = .init()
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("milkyWay"))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for name in ["WSS-Starfield-v1", "WSS-Starfield-Shooting-Stars-v1"] {
            let d = try WSSSceneDocumentV1.decode(
                data: Data(
                    contentsOf: root.appendingPathComponent(
                        "Test-Wallpaper/" + name + "/scene.wss.json")))
            XCTAssertFalse(String(decoding: try d.encoded(), as: UTF8.self).contains("milkyWay"))
            XCTAssertEqual(try WSSSceneDocumentV1.decode(data: d.encoded()), d)
        }
    }
    func testMilkyWayOnlyStaticAndSharedDriftAnimation() throws {
        var c = configuration()
        c.red = 0
        c.green = 0
        c.blue = 0
        XCTAssertFalse(c.isAnimated)
        c.driftX = 0.1
        XCTAssertTrue(c.isAnimated)
        c.milkyWay.intensity = 0
        XCTAssertFalse(c.isAnimated)
        c.milkyWay.intensity = 1
        c.milkyWay.enabled = false
        XCTAssertFalse(c.isAnimated)
        c.milkyWay.enabled = true
        c.driftX = 0
        c.driftY = -0.1
        XCTAssertTrue(c.isAnimated)
        c.milkyWay.red = 0
        c.milkyWay.green = 0
        c.milkyWay.blue = 0
        XCTAssertFalse(c.isAnimated)
        c.milkyWay.width = -1
        XCTAssertThrowsError(
            try WSSScene(
                width: 64, height: 64, layers: [.starfield(.init(visible: false, starfield: c))]
            ).validate())
    }
    func testIndependentSeedsDoNotRedistributeStarsOrShootingStars() throws {
        var c = configuration()
        c.count = 1500
        c.shootingStars.enabled = true
        let population = try WSSStarfieldPopulation(count: c.count, seed: c.seed).instances
        let time = WSSShootingStarTests().onset(c) + 0.4
        let events = WSSShootingStarEvents.events(c, at: time)
        for p in WSSMilkyWayParameter.allCases {
            var next = c
            let value = p == .seed ? 1234 : p.range.upperBound
            try p.apply(value, to: &next.milkyWay)
            XCTAssertEqual(
                population, try WSSStarfieldPopulation(count: next.count, seed: next.seed).instances
            )
            XCTAssertEqual(events, WSSShootingStarEvents.events(next, at: time))
        }
    }
}
