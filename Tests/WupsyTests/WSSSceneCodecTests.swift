import MetalKit
import XCTest

@testable import Wupsy

final class WSSSceneCodecTests: XCTestCase {
    let helper = WSSNativeSceneTests()
    func roundtrip(_ json: [String: Any]) throws -> WSSSceneDocumentV1 {
        let first = try WSSSceneDocumentV1.decode(
            data: JSONSerialization.data(withJSONObject: json))
        let bytes = try first.encoded()
        let second = try WSSSceneDocumentV1.decode(data: bytes)
        XCTAssertEqual(first, second)
        XCTAssertEqual(bytes, try second.encoded())
        XCTAssertEqual(first.referencedPaths, second.referencedPaths)
        let a = try first.scene()
        let b = try second.scene()
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
        XCTAssertEqual(a.background, b.background)
        XCTAssertEqual(a.imageLayers.map(\.effects), b.imageLayers.map(\.effects))
        for (a, b) in zip(a.imageLayers, b.imageLayers) {
            XCTAssertEqual(a.asset, b.asset)
            XCTAssertEqual(a.transform.center, b.transform.center)
            XCTAssertEqual(a.transform.axisX, b.transform.axisX)
            XCTAssertEqual(a.transform.axisY, b.transform.axisY)
            XCTAssertEqual(a.opacity, b.opacity)
            XCTAssertEqual(a.visible, b.visible)
            XCTAssertEqual(a.composition, b.composition)
        }
        return second
    }
    func testCanonicalDefaultsNullCloudSpellingsAndOriginalTransforms() throws {
        var document = helper.document(clouds: true)
        let canonical = try roundtrip(document).encoded()
        var layer = (document["layers"] as! [[String: Any]])[0]
        var cloud = (layer["effects"] as! [[String: Any]])[0]
        cloud["mask"] = NSNull()
        cloud["primaryField"] = [
            "velocity": cloud.removeValue(forKey: "velocity")!,
            "scale": cloud.removeValue(forKey: "scale")!,
        ]
        cloud["secondaryInfluence"] = 0.35
        cloud["softness"] = 0
        cloud["brightness"] = 1
        cloud["shadingAmount"] = 0
        cloud["shadingDirection"] = 0
        layer["effects"] = [cloud]
        layer["type"] = "image"
        layer["visible"] = true
        layer["opacity"] = 1
        layer["transform"] = [
            "center": [32, 32], "size": [64, 64], "scale": [1, 1], "rotation": 0,
        ]
        document["layers"] = [layer]
        document["background"] = [0, 0, 0]
        XCTAssertEqual(canonical, try roundtrip(document).encoded())
        layer["transform"] = [
            "center": [-42.125, 17.5], "size": [64, 32], "scale": [2.25, 0.75],
            "rotation": Float.pi * 6 + 0.375,
        ]
        layer["visible"] = false
        layer["opacity"] = 0.375
        document["layers"] = [layer, layer]
        let result = try roundtrip(document)
        XCTAssertEqual(result.layers[0].imageTransform?.rotation, Float.pi * 6 + 0.375)
        XCTAssertEqual(result.layers[0].imageTransform?.scale, [2.25, 0.75])
    }
    func ripple(mask: Any? = nil) -> [String: Any] {
        var value: [String: Any] = [
            "type": "ripple", "amplitude": 6, "wavelength": 120,
            "stretch": 1.25, "direction": 180, "travelSpeed": 20, "evolutionRate": 0.2,
            "seed": UInt32.max,
        ]
        if let mask { value["mask"] = mask }
        return value
    }
    func field(_ native: Bool) -> [String: Any] {
        [
            "format": native ? "wss-vector-field-f16" : "wss-flow-rgba8", "version": 1,
            "asset": native ? "assets/directions.wssvf" : "assets/flow.png",
        ]
    }
    func descriptor(
        _ path: String = "assets/image.rgba8", encoding: String = "rgba8",
        filter: String = "linear", edge: String = "clamp", mips: Bool = false
    ) -> [String: Any] {
        [
            "asset": path, "encoding": encoding, "width": 2, "height": 1, "uvScale": [0.75, 0.5],
            "filter": filter, "edge": edge, "mipmapped": mips,
        ]
    }
    func testEveryEffectChainMaskAndFieldRepresentation() throws {
        for native in [false, true] {
            let flow: [String: Any] = ["type": "flow", "flowMap": field(native)]
            for mask: Any? in [nil, NSNull(), "assets/mask.png", descriptor("assets/mask.rgba8")] {
                let ripple = ripple(mask: mask)
                for effects in [
                    [ripple], [flow], [ripple, ripple],
                    [flow, ripple],
                ] {
                    var doc = helper.document()
                    var layer = (doc["layers"] as! [[String: Any]])[0]
                    layer["effects"] = effects
                    doc["layers"] = [layer]
                    let decoded = try roundtrip(doc)
                    if effects.count == 2 {
                        XCTAssertEqual(try decoded.scene().imageLayers[0].effects.count, 2)
                    }
                }
            }
        }
    }
    func testDescriptorSamplingCloudExtensionsAndBothCompositions() throws {
        for encoding in ["image", "rgba8"] {
            for filter in ["linear", "nearest"] {
                for edge in ["clamp", "repeat"] {
                    for mips in [false, true] {
                        for composition in ["replace", "sourceOver"] {
                            var doc = helper.document(clouds: true)
                            var layer = (doc["layers"] as! [[String: Any]])[0]
                            layer["image"] = descriptor(
                                encoding: encoding, filter: filter, edge: edge, mips: mips)
                            layer["composition"] = composition
                            var cloud = (layer["effects"] as! [[String: Any]])[0]
                            cloud["secondaryField"] = ["velocity": [-4.25, 8.125], "scale": 123.5]
                            cloud["secondaryInfluence"] = 0.75
                            cloud["softness"] = 0.5
                            cloud["brightness"] = 1.5
                            cloud["shadingAmount"] = 0.625
                            cloud["shadingDirection"] = 275.125
                            cloud["mask"] = descriptor("assets/mask.rgba8")
                            layer["effects"] = [cloud]
                            doc["layers"] = [layer]
                            _ = try roundtrip(doc)
                        }
                    }
                }
            }
        }
    }
    func testRainTrailPrecisionAndOrderedMixedLayers() throws {
        var doc = helper.document()
        let trail: [String: Any] = [
            "type": "cursorTrail", "visible": false,
            "trail": [
                "colors": [["r": 0.125, "g": 0.25, "b": 0.75], ["r": 1, "g": 0, "b": 0]],
                "colorMode": "ageGradient", "width": 12.125, "lifetime": 1.1234567890123,
                "emissionRate": 32.123456789, "fadeIn": 0.0123456789, "fadeOut": 0.5,
                "opacity": 0.875, "edgeSoftness": 0.625, "seed": UInt32.max,
            ],
        ]
        let rain: [String: Any] = [
            "type": "rain", "composition": "additive", "visible": false,
            "region": ["x": -2.25, "y": 3.5, "width": 64, "height": 32],
            "rain": [
                "direction": 12.125, "speed": 700.5, "density": 100.25, "length": 32.5,
                "width": 1.25, "opacity": ["min": 0.125, "max": 0.375], "seed": UInt32.max,
            ],
        ]
        doc["layers"] = [(doc["layers"] as! [[String: Any]])[0], rain, trail]
        let result = try roundtrip(doc)
        guard case .trail(let configuration, _) = result.layers[2].content else {
            return XCTFail("order")
        }
        XCTAssertEqual(configuration.lifetime, 1.1234567890123)
        XCTAssertEqual(configuration.emissionRate, 32.123456789)
        XCTAssertEqual(configuration.seed, UInt32.max)
    }
    func testInvalidStructuresAndEncodingBudgetStayClosed() throws {
        var doc = helper.document()
        for bad: Any in [NSNull(), "unknown"] {
            doc["background"] = bad
            XCTAssertThrowsError(
                try WSSSceneDocumentV1.decode(data: JSONSerialization.data(withJSONObject: doc)))
        }
        doc = helper.document()
        doc["editorID"] = "forbidden"
        XCTAssertThrowsError(
            try WSSSceneDocumentV1.decode(data: JSONSerialization.data(withJSONObject: doc)))
        XCTAssertThrowsError(
            try WSSSceneDocumentV1.decode(
                data: Data(repeating: 32, count: WSSSceneDocumentV1.byteLimit + 1)))
        var model = try WSSSceneDocumentV1.decode(
            data: JSONSerialization.data(withJSONObject: helper.document()))
        model.background = [.nan, 0, 0]
        XCTAssertThrowsError(try model.encoded())
        model = try WSSSceneDocumentV1.decode(
            data: JSONSerialization.data(withJSONObject: helper.document()))
        guard case .image(var image) = model.layers[0].content else { return XCTFail("image") }
        image.asset = String(repeating: "a", count: WSSSceneDocumentV1.byteLimit) + ".png"
        model.layers[0].content = .image(image)
        XCTAssertThrowsError(try model.encoded())
        image.asset = "assets/base.png"
        image.effects = try [ripple(), ripple(), ripple()].map {
            try JSONDecoder().decode(
                WSSSceneDocumentV1.Effect.self, from: JSONSerialization.data(withJSONObject: $0))
        }
        model.layers[0].content = .image(image)
        XCTAssertNoThrow(try model.encoded())
    }
    func testOwnFixtureRoundtripsKeepNativeFramesAndAllAssetBytes() async throws {
        let helper = WSSEditorProjectTests()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for name in [
            "WSS-Ripple-v1", "WSS-Ripple-Chain-v1", "WSS-Flow-v1", "WSS-Flow-Ripple-v1",
            "WSS-Clouds-v2",
            "WSS-Rain-v1",
        ] {
            let source = repo.appendingPathComponent("Test-Wallpaper/" + name)
            let original = try ManagedLibraryTests().snapshot(source)
            let document = try WSSSceneDocumentV1.load(
                entry: source.appendingPathComponent("scene.wss.json"), root: source)
            let roundtripped = try WSSSceneDocumentV1.decode(data: document.encoded())
            let device = try WSSStaticTests().device()
            let a = try WSSStaticResources(
                scene: document.scene(), assets: document.assetSource(root: source), device: device)
            let b = try WSSStaticResources(
                scene: roundtripped.scene(), assets: roundtripped.assetSource(root: source),
                device: device)
            let renderer = WSSRippleChainTests()
            XCTAssertEqual(
                try renderer.render(a, time: 0.75).0, try renderer.render(b, time: 0.75).0, name)
            XCTAssertEqual(try ManagedLibraryTests().snapshot(source), original)
        }
    }
}
