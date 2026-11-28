import AppKit
import XCTest

@testable import Wupsy

final class WSSSlimeDirectDropTests: XCTestCase {
    func testGrowthReleaseAndFallAcrossSizesDirectionsAndDistances() {
        let anchor = WSSSlimePrototype.anchor
        let release = WSSSlimePrototype.directRelease
        let transform = WSSImageTransform(center: [80, 120], size: [32, 32], rotation: 0.35)
        for direction: Float in [0, 90, 180, 270] {
            for distance: Float in [24, 800, WSSSlimeLayer.maximumDistance] {
                for diameter: Float in [9.5, 38] {
                    var c = WSSSlimeConfiguration()
                    c.mode = .directDrop
                    c.direction = direction
                    c.distance = distance
                    c.dropSize = diameter
                    let drawing = WSSSlimePrototype.Placement(transform, direction: direction)
                    func frame(_ time: Double) -> WSSSlimePrototype.Frame {
                        WSSSlimePrototype.directDropFrame(
                            at: time, configuration: c, drawing: drawing)
                    }
                    let start = frame(0)
                    let early = frame(release / 3)
                    let pre = frame(release - 0.0001)
                    let detached = frame(release)
                    let post = frame(release + 0.0001)
                    XCTAssertTrue(start.stem.isEmpty)
                    XCTAssertEqual(start.neck.z, 0)
                    XCTAssertEqual(start.visibility, 0)
                    XCTAssertGreaterThan(early.visibility, 0)
                    XCTAssertLessThan(early.drop.z, detached.drop.z)
                    XCTAssertEqual(detached.drop.z * 2, diameter, accuracy: 0.0001)
                    for index in 0..<4 {
                        XCTAssertEqual(pre.drop[index], post.drop[index], accuracy: 0.001)
                    }
                    XCTAssertEqual(pre.visibility, post.visibility, accuracy: 0.0001)
                    let travel = distance - (detached.drop.y - anchor.y)
                    let endTime = release + sqrt(Double(travel / (96 * drawing.longitudinalScale)))
                    let fadeDistance = min(42 * drawing.longitudinalScale, travel * (42.0 / 147.0))
                    let fading = frame(
                        release
                            + sqrt(
                                Double(
                                    (travel - fadeDistance / 2) / (96 * drawing.longitudinalScale)))
                    )
                    let end = frame(endTime + 0.005)
                    XCTAssertGreaterThan(fading.visibility, 0)
                    XCTAssertLessThan(fading.visibility, 1)
                    XCTAssertEqual(end.visibility, 0)
                    let offset =
                        drawing.axisX * (end.drop.x - anchor.x)
                        + drawing.axisY * (end.drop.y - anchor.y)
                    let headings: [Float: SIMD2<Float>] = [
                        0: [0, 1], 90: [1, 0], 180: [0, -1], 270: [-1, 0],
                    ]
                    let expected = headings[direction]! * distance
                    XCTAssertEqual(offset.x, expected.x, accuracy: 0.003)
                    XCTAssertEqual(offset.y, expected.y, accuracy: 0.003)
                }
            }
        }
    }

    func testMetalMaterialAndSizeChangeDirectDropPixels() throws {
        let device = try WSSStaticTests().device()
        var config = WSSSlimeConfiguration()
        config.mode = .directDrop
        func pixels(_ value: WSSSlimeConfiguration) throws -> Data {
            let scene = WSSScene(
                width: 128, height: 128, background: [0.2, 0.2, 0.2],
                layers: [
                    .slime(
                        .init(
                            transform: .init(center: [64, 95], size: [32, 32]),
                            configuration: value))
                ])
            let resources = try WSSStaticResources(
                scene: scene, assets: WSSStaticTests.Assets(values: [:]), device: device)
            return try WSSCloudsTests().render(resources, time: 1.25, width: 128, height: 128).0
        }
        let reference = try pixels(config)
        var changed = config
        changed.dropSize = 30
        let larger = try pixels(changed)
        XCTAssertNotEqual(reference, larger)
        changed = config
        changed.color = .init(red: 0.7, green: 0.15, blue: 0.3)
        XCTAssertNotEqual(reference, try pixels(changed))
        changed = config
        changed.reflectionColor = .init(red: 1, green: 0, blue: 0)
        changed.gloss = 2
        changed.opacity = 0.55
        XCTAssertNotEqual(reference, try pixels(changed))
    }

    func testModeCodecAndLocalizedInspectorOptions() throws {
        let original = WSSSlimeConfiguration()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["mode"])
        XCTAssertEqual(try decoder.decode(WSSSlimeConfiguration.self, from: data), original)
        json["mode"] = "hangingThread"
        XCTAssertEqual(
            try decoder.decode(
                WSSSlimeConfiguration.self, from: JSONSerialization.data(withJSONObject: json)),
            original)
        json["mode"] = "directDrop"
        let direct = try decoder.decode(
            WSSSlimeConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(direct.mode, .directDrop)
        XCTAssertEqual(
            try decoder.decode(WSSSlimeConfiguration.self, from: encoder.encode(direct)), direct)
        XCTAssertFalse(direct.inspectorParameters.contains(.width))
        XCTAssertFalse(direct.inspectorParameters.contains(.length))
        XCTAssertTrue(original.inspectorParameters.contains(.width))
        XCTAssertTrue(original.inspectorParameters.contains(.length))
        for invalid: Any in ["unknown", NSNull()] {
            json["mode"] = invalid
            XCTAssertThrowsError(
                try decoder.decode(
                    WSSSlimeConfiguration.self, from: JSONSerialization.data(withJSONObject: json)))
        }
        XCTAssertEqual(
            Localization.string(key: "editor.slime.hangingThread", language: "de"),
            "Hängender Faden")
        XCTAssertEqual(
            Localization.string(key: "editor.slime.hangingThread", language: "en"), "Hanging Thread"
        )
        XCTAssertEqual(
            Localization.string(key: "editor.slime.directDrop", language: "de"), "Direkter Tropfen")
        XCTAssertEqual(
            Localization.string(key: "editor.slime.directDrop", language: "en"), "Direct Drop")
    }

    func testInspectorUnitsInBothLanguages() {
        for (key, de, en) in [
            ("anchorX", "Ansatz X (px)", "Anchor X (px)"),
            ("anchorY", "Ansatz Y (px)", "Anchor Y (px)"),
            ("sizeX", "Horizontale Größe (px)", "Horizontal Size (px)"),
            ("sizeY", "Vertikale Größe (px)", "Vertical Size (px)"),
            ("opacity", "Deckkraft (0–1)", "Opacity (0–1)"),
            ("gloss", "Glanz (Faktor)", "Gloss (Factor)"),
            ("speed", "Zyklusgeschwindigkeit (Faktor)", "Cycle Speed (Factor)"),
        ] {
            XCTAssertEqual(Localization.string(key: "editor.slime." + key, language: "de"), de)
            XCTAssertEqual(Localization.string(key: "editor.slime." + key, language: "en"), en)
        }
    }

    @MainActor func testInspectorModeChangeUndoDuplicateAndReopen() async throws {
        let helper = WSSMaskEditingTests()
        try await helper.setUp()
        do {
            let doc = try XCTUnwrap(helper.doc)
            try doc.addSlime()
            let id = try XCTUnwrap(doc.selection?.layer)
            try doc.changeSlime(id, name: "Filament dimensions") {
                $0.configuration.width = 23
                $0.configuration.length = 143
            }
            let thread = try XCTUnwrap(doc.slimeLayer(id)?.configuration)
            try doc.changeSlimeMode(id, to: .directDrop)
            let direct = try XCTUnwrap(doc.slimeLayer(id)?.configuration)
            XCTAssertEqual(direct.mode, .directDrop)
            doc.undoManager.undo()
            XCTAssertEqual(doc.slimeLayer(id)?.configuration, thread)
            doc.undoManager.redo()
            XCTAssertEqual(doc.slimeLayer(id)?.configuration, direct)
            try await doc.duplicateLayer(id)
            let copy = try XCTUnwrap(doc.selection?.layer)
            XCTAssertEqual(doc.slimeLayer(copy)?.configuration, direct)
            try doc.changeSlimeMode(id, to: .hangingThread)
            XCTAssertEqual(doc.slimeLayer(id)?.configuration, thread)
            XCTAssertEqual(doc.slimeLayer(copy)?.configuration, direct)
            await doc.waitForPreview()
            let model = doc.state.workingModel
            let saved = await doc.save()
            XCTAssertTrue(saved)
            let loaded = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
            XCTAssertEqual(loaded.document, model)
        } catch {
            try await helper.tearDown()
            throw error
        }
        try await helper.tearDown()
    }
}
