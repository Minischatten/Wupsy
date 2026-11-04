import MetalKit
import XCTest

@testable import Wupsy

final class WSSVectorFieldTests: XCTestCase {
    func field() throws -> WSSVectorFieldAsset {
        try WSSVectorFieldAsset.rgba(
            width: 3, height: 1,
            pixels: Data([128, 128, 0, 255, 255, 0, 0, 0, 160, 96, 0, 127]))
    }
    func replaceWord(_ data: Data, offset: Int, value: UInt32) -> Data {
        var result = data
        var word = value.littleEndian
        withUnsafeBytes(of: &word) { result.replaceSubrange(offset..<offset + 4, with: $0) }
        return result
    }
    func testLosslessDeterministicNativeRoundTripAndOpaqueCoverage() throws {
        let original = try field()
        let bytes = try original.encodedNative()
        XCTAssertEqual(bytes, try original.encodedNative())
        XCTAssertEqual(bytes.count, 32 + 3 * 4 + 3)
        let result = try WSSVectorFieldAsset.decodeNative(bytes)
        XCTAssertEqual(result.vectors, original.vectors)
        XCTAssertEqual(result.coverage, original.coverage)
        XCTAssertEqual(result.isNeutral, original.isNeutral)
        XCTAssertEqual(try result.encodedNative(), bytes)
        // Inputs whose Data startIndex is not zero must not crash indexed decoding.
        let prefixed = Data([99]) + bytes
        XCTAssertEqual(
            try WSSVectorFieldAsset.decodeNative(prefixed.dropFirst()).vectors, original.vectors)
        for coverage in [Data?.none, Data([255]), Data([0])] {
            // Preserve the signed-zero bit pattern rather than canonicalizing it.
            let value = WSSVectorFieldAsset(
                width: 1, height: 1,
                vectors: Data([0, 0, 0, 128]), coverage: coverage, isNeutral: true)
            let decoded = try WSSVectorFieldAsset.decodeNative(value.encodedNative())
            XCTAssertEqual(decoded.vectors, value.vectors)
            XCTAssertEqual(decoded.coverage, coverage)
            XCTAssertTrue(decoded.isNeutral)
        }
    }
    func testMalformedVersionDimensionsHalfPayloadAndCoverageReject() throws {
        let data = try field().encodedNative()
        for (offset, value) in [
            (8, 2), (12, 0), (12, 8193), (12, Int(UInt32.max)),
            (16, 0), (20, 2), (24, 0), (28, 1),
        ] {
            XCTAssertThrowsError(
                try WSSVectorFieldAsset.decodeNative(
                    replaceWord(data, offset: offset, value: UInt32(value))))
        }
        for length in [0, 7, 8, 31, 32, data.count - 1] {
            XCTAssertThrowsError(try WSSVectorFieldAsset.decodeNative(Data(data.prefix(length))))
        }
        XCTAssertThrowsError(try WSSVectorFieldAsset.decodeNative(data + Data([0])))
        for half: UInt16 in [0x7c00, 0xfc00, 0x7e00, 0x4000] {  // ±inf, NaN, 2
            var bad = data
            bad[32] = UInt8(half & 255)
            bad[33] = UInt8(half >> 8)
            XCTAssertThrowsError(try WSSVectorFieldAsset.decodeNative(bad))
        }
        let wrong = WSSVectorFieldAsset(
            width: 1, height: 1,
            vectors: Data(repeating: 0, count: 4), coverage: Data([0, 0]), isNeutral: true)
        XCTAssertThrowsError(try wrong.encodedNative())
    }
    func project() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("assets"),
            withIntermediateDirectories: true)
        return root
    }
    func testNativeProjectReadWriteStrictDescriptorAndPaths() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = WSSNativeAssets(root: root)
        let value = try field()
        try assets.writeVectorField(value, to: "assets/field.wssvf")
        let first = try Data(contentsOf: root.appendingPathComponent("assets/field.wssvf"))
        try assets.writeVectorField(value, to: "assets/field.wssvf")
        XCTAssertEqual(
            first, try Data(contentsOf: root.appendingPathComponent("assets/field.wssvf")))
        XCTAssertEqual(
            try assets.vectorField(for: WSSAssetID(value: "assets/field.wssvf")).vectors,
            value.vectors)
        let descriptor: [String: Any] = [
            "type": "flow",
            "flowMap": [
                "format": WSSVectorFieldAsset.fileFormat, "version": 1,
                "asset": "assets/field.wssvf",
            ],
        ]
        let native = try JSONDecoder().decode(
            WSSSceneDocumentV1.Effect.self,
            from: JSONSerialization.data(withJSONObject: descriptor)
        ).native
        guard case .flow(let flow) = native else { return XCTFail("flow") }
        XCTAssertEqual(flow.flowMap.value, "assets/field.wssvf")
        for version in [0, 2] {
            var bad = descriptor
            bad["flowMap"] = [
                "format": WSSVectorFieldAsset.fileFormat, "version": version,
                "asset": "assets/field.wssvf",
            ]
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    WSSSceneDocumentV1.Effect.self,
                    from: JSONSerialization.data(withJSONObject: bad)))
        }
        for path in [
            "../escape.wssvf", "/tmp/escape.wssvf", "assets/../../escape.wssvf",
            "assets/./field.wssvf", "~/.field.wssvf", "C:/field.wssvf", "assets\\field.wssvf",
        ] {
            XCTAssertThrowsError(try assets.writeVectorField(value, to: path))
            XCTAssertThrowsError(try assets.vectorField(for: WSSAssetID(value: path)))
        }
        let outside = try project()
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try assets.writeVectorField(value, to: "link/escape.wssvf"))
        XCTAssertThrowsError(try assets.vectorField(for: WSSAssetID(value: "link/missing.wssvf")))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("assets/alias.wssvf"),
            withDestinationURL: root.appendingPathComponent("assets/field.wssvf"))
        XCTAssertThrowsError(try assets.writeVectorField(value, to: "assets/alias.wssvf"))
        XCTAssertThrowsError(try assets.vectorField(for: WSSAssetID(value: "assets/alias.wssvf")))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("escape.wssvf").path))
    }
    func testNativeSceneWithLosslessFieldSurvivesSourceRemoval() throws {
        let fixture = WSSFlowFixtureTests().root.appendingPathComponent("WSS-Flow-v1")
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let saved = root.appendingPathComponent("saved")
        try FileManager.default.copyItem(at: fixture, to: source)
        let assets = WSSNativeAssets(root: source)
        let field = try assets.flowMap(for: WSSAssetID(value: "assets/flow.png"))
        try assets.writeVectorField(field, to: "assets/flow.wssvf")
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: source.appendingPathComponent("scene.wss.json")))
                as? [String: Any])
        var layers = try XCTUnwrap(document["layers"] as? [[String: Any]])
        var effects = try XCTUnwrap(layers[0]["effects"] as? [[String: Any]])
        effects[0]["flowMap"] = [
            "format": WSSVectorFieldAsset.fileFormat,
            "version": 1, "asset": "assets/flow.wssvf",
        ]
        layers[0]["effects"] = effects
        document["layers"] = layers
        try JSONSerialization.data(withJSONObject: document).write(
            to: source.appendingPathComponent("scene.wss.json"))
        try FileManager.default.removeItem(at: source.appendingPathComponent("assets/flow.png"))
        try FileManager.default.copyItem(at: source, to: saved)
        try FileManager.default.removeItem(at: source)
        let scene = try WSSSceneDocumentV1.load(
            entry: saved.appendingPathComponent("scene.wss.json"), root: saved
        ).scene()
        let originalScene = try WSSSceneDocumentV1.load(
            entry: fixture.appendingPathComponent("scene.wss.json"), root: fixture
        ).scene()
        let device = try WSSStaticTests().device()
        let a = try WSSStaticResources(
            scene: scene, assets: WSSNativeAssets(root: saved), device: device)
        let b = try WSSStaticResources(
            scene: originalScene, assets: WSSNativeAssets(root: fixture), device: device)
        for time in [0.0, 2, 8] {
            XCTAssertEqual(
                try WSSRippleChainTests().render(a, time: time, width: 960, height: 540).0,
                try WSSRippleChainTests().render(b, time: time, width: 960, height: 540).0)
        }
    }

    func testSharedProviderUploadAndCachedFieldAreGPUIdentical() throws {
        let helper = WSSFlowTests()
        let original = try field()
        let decoded = try WSSVectorFieldAsset.decodeNative(original.encodedNative())
        let a = try helper.resources([.flow(helper.effect)], field: original)
        let b = try helper.resources([.flow(helper.effect)], field: decoded)
        for time in [0.0, 0.3, 1, 8] {
            XCTAssertEqual(try helper.render(a, time: time), try helper.render(b, time: time))
        }
        var loads = 0
        let fields = try WSSVectorFieldResources(ids: [helper.map, helper.map], device: a.device) {
            _ in
            loads += 1
            return original
        }
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(fields.fields.count, 1)
        XCTAssertEqual(fields.fields[helper.map]?.vectors.pixelFormat, .rg16Float)
        XCTAssertEqual(fields.fields[helper.map]?.coverage?.pixelFormat, .r8Unorm)
        XCTAssertEqual(fields.textureBytes, a.flow?.textureBytes)
    }
}
