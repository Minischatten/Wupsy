import MetalKit
import XCTest

@testable import Wupsy

final class ScenePlaybackModeTests: XCTestCase {
    func record(kind: String = "scene", managed: Bool = false) -> [String: Any] {
        var value: [String: Any] = [
            "id": "01234567-89AB-CDEF-0123-456789ABCDEF", "title": "Example",
            "kind": kind,
        ]
        if managed {
            value["ownership"] = "managed"
            value["managed"] = ["directory": "Loose/Example", "entry": "nested/scene.json"]
        } else {
            value["path"] = "/example/scene.pkg"
            value["root"] = "/example"
        }
        return value
    }
    func decode(_ value: [String: Any]) throws -> Wallpaper {
        try JSONDecoder().decode(
            Wallpaper.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testHistoricalSceneRecordsAreRejected() throws {
        for managed in [false, true] {
            for value: Any in [NSNull(), "compatibility", "wss"] {
                var old = record(managed: managed)
                old["scenePlaybackMode"] = value
                XCTAssertThrowsError(try decode(old))
            }
            var old = record(managed: managed)
            old["sceneSource"] = "wallpaperEngine"
            XCTAssertThrowsError(try decode(old))
        }
    }
    func testUnknownModesAndInvalidTypesAreRejected() throws {
        for value: Any in ["future-backend", 1, true, ["mode": "wss"]] {
            var json = record()
            json["scenePlaybackMode"] = value
            XCTAssertThrowsError(try decode(json))
        }
        for kind in ["image", "video", "web"] {
            let item = try decode(record(kind: kind))
            XCTAssertNil(item.scenePlaybackMode)
            let data = try JSONEncoder().encode(item)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(json["scenePlaybackMode"])
            var invalid = record(kind: kind)
            invalid["scenePlaybackMode"] = "wss"
            XCTAssertThrowsError(try decode(invalid))
        }
    }

}
