import MetalKit
import XCTest

@testable import Wupsy

final class WSSRainProfilesTests: XCTestCase {
    func population(_ effect: WSSRainEffect) throws -> WSSRainPopulation {
        try WSSRainPopulation(
            .init(region: .init(x: 0, y: 0, width: 1920, height: 1080), rain: effect))
    }
    func testProfilesKeepPrimaryRandomStreamAndPairShapeAtEveryDepth() throws {
        let legacy = try population(.init())
        let authored = try population(.init(profiles: WSSRainEffect.authoredProfiles))
        let rebuilt = try population(.init(profiles: WSSRainEffect.authoredProfiles))
        XCTAssertEqual(authored.instances, rebuilt.instances)
        for (old, new) in zip(legacy.instances, authored.instances) {
            XCTAssertEqual(old.state, new.state)
        }
        XCTAssertEqual(Set(authored.instances.map { Int($0.variation.z) }), Set(0..<3))
        for i in authored.instances.indices {
            let instance = authored.instances[i]
            let profile = WSSRainEffect.authoredProfiles[Int(instance.variation.z)]
            XCTAssertEqual(instance.variation.x, profile.length)
            XCTAssertEqual(instance.variation.y, profile.width)
            XCTAssertEqual(
                authored.geometricLength(i),
                profile.length * WSSRainPopulation.depthScale(Int(instance.state.z)))
            XCTAssertEqual(authored.position(i, at: 12), rebuilt.position(i, at: 12))
        }
        var changed = authored.layer.rain
        changed.speed = 2000
        XCTAssertEqual(try population(changed).instances, authored.instances)
        changed.seed = 99
        XCTAssertNotEqual(try population(changed).instances, authored.instances)
    }
    func testProfilePaddingUsesMaximumAndLegacyPaddingIsFrozen() throws {
        let legacy = try population(.init())
        XCTAssertEqual(legacy.crossSpan, 1920 + max(Float(32), 1.2) * 1.35 + 2)
        XCTAssertEqual(legacy.travelSpan, 1080 + 48 * 1.35 + 2)
        let e = WSSRainEffect(profiles: [
            .init(length: 256, width: 1), .init(length: 2, width: 8), .init(length: 1, width: 1),
        ])
        let p = try population(e)
        XCTAssertEqual(p.crossSpan, 1920 + 256 * 1.35 + 2)
        XCTAssertEqual(p.travelSpan, 1080 + 256 * 1.35 + 2)
        for profiles: [WSSRainEffect.Profile] in [
            [], [.init(length: 1, width: 1)],
            Array(repeating: .init(length: .nan, width: 1), count: 3),
        ] {
            XCTAssertThrowsError(try population(.init(profiles: profiles)))
        }
        var large = WSSRainLayer(
            region: .init(x: 0, y: 0, width: 8192, height: 4096),
            rain: .init(profiles: WSSRainEffect.authoredProfiles, direction: 45, density: 2000))
        XCTAssertThrowsError(try WSSRainPopulation(large))
        large.rain.density = 100
        let count = try WSSRainPopulation(large).instances.count
        XCTAssertGreaterThan(count, 0)
        let scene = WSSScene(
            width: 8192, height: 4096, layers: Array(repeating: .rain(large), count: 4))
        XCTAssertThrowsError(try scene.validate())
    }
    func testLegacyCodecNeverMaterializesProfilesAndAuthoredRoundtripIsStrict() throws {
        let fixture = WSSRainTests().fixture
        let legacy = try WSSSceneDocumentV1.load(
            entry: fixture.appendingPathComponent("scene.wss.json"), root: fixture)
        let encoded = try legacy.encoded()
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("profiles"))
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: encoded), legacy)
        var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var layers = json["layers"] as! [[String: Any]]
        var rain = layers[1]["rain"] as! [String: Any]
        rain["profiles"] = WSSRainEffect.authoredProfiles.map {
            ["length": $0.length, "width": $0.width]
        }
        layers[1]["rain"] = rain
        json["layers"] = layers
        let authored = try WSSSceneDocumentV1.decode(
            data: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: authored.encoded()), authored)
        rain["profiles"] = [["length": 1, "width": 1, "jitter": 1]]
        layers[1]["rain"] = rain
        json["layers"] = layers
        XCTAssertThrowsError(
            try WSSSceneDocumentV1.decode(data: JSONSerialization.data(withJSONObject: json)))
    }
    struct Assets: WSSImageAssetSource {
        let maskPixels: Data
        func image(for id: WSSAssetID) throws -> WSSImageAsset {
            if id.value == "foreground" {
                return WSSImageAsset(
                    width: 2, height: 1, payload: .rgba8(Data([20, 0, 0, 255, 0, 0, 0, 0])))
            }
            throw WSSMaskError.invalid
        }
        func mask(for id: WSSAssetID) throws -> WSSMaskAsset {
            WSSMaskAsset(width: 1, height: 2, pixels: maskPixels, uvScale: SIMD2(1, 1))
        }
    }
    func testMaskGPUUsesTopLeftUVFullWhiteMatchesNilAndBlackSuppresses() throws {
        let device = try WSSStaticTests().device()
        let effect = WSSRainEffect(
            profiles: Array(repeating: .init(length: 32, width: 4), count: 3), speed: 0,
            density: 2000, opacity: .init(min: 1, max: 1))
        var rain = WSSRainLayer(region: .init(x: 32, y: 64, width: 128, height: 128), rain: effect)
        let helper = WSSCloudsTests()
        func frame(_ pixels: Data) throws -> Data {
            let scene = WSSScene(width: 256, height: 256, layers: [.rain(rain)])
            return try helper.render(
                WSSStaticResources(
                    scene: scene, assets: Assets(maskPixels: pixels), device: device), width: 256,
                height: 256
            ).0
        }
        let unmasked = try frame(Data([255, 255]))
        rain.mask = .init(asset: .init(value: "mask"))
        XCTAssertEqual(try frame(Data([255, 255])), unmasked)
        let black = try frame(Data([0, 0]))
        XCTAssertTrue(stride(from: 0, to: black.count, by: 4).allSatisfy { black[$0] == 0 })
        let half = try frame(Data([255, 0]))
        var top = 0
        var bottom = 0
        for y in 64..<192 {
            for x in 32..<160 {
                let v = Int(half[(y * 256 + x) * 4])
                if y < 96 { top += v }
                if y >= 160 { bottom += v }
            }
        }
        XCTAssertGreaterThan(top, 0)
        XCTAssertEqual(bottom, 0)
    }
    func testAuthoredRainLayerOrderControlsForegroundOcclusion() throws {
        let device = try WSSStaticTests().device()
        let rain = WSSSceneLayer.rain(
            .init(
                region: .init(x: 0, y: 0, width: 256, height: 256),
                rain: .init(
                    profiles: WSSRainEffect.authoredProfiles, density: 2000,
                    opacity: .init(min: 1, max: 1))))
        let foreground = WSSSceneLayer.image(
            .init(
                asset: .init(value: "foreground"),
                transform: .init(center: SIMD2(128, 128), size: SIMD2(256, 256))))
        let assets = Assets(maskPixels: Data([255, 255]))
        let helper = WSSCloudsTests()
        func frame(_ layers: [WSSSceneLayer]) throws -> Data {
            try helper.render(
                WSSStaticResources(
                    scene: .init(width: 256, height: 256, layers: layers), assets: assets,
                    device: device), width: 256, height: 256
            ).0
        }
        let behind = try frame([rain, foreground])
        let front = try frame([foreground, rain])
        XCTAssertNotEqual(behind, front)
        var changes = 0
        for y in 0..<256 {
            for x in 0..<60 {
                let p = (y * 256 + x) * 4
                XCTAssertEqual(behind[p], 0)
                if front[p] > 0 { changes += 1 }
            }
        }
        XCTAssertGreaterThan(changes, 0)
    }
    func testRainStringsHaveEnglishGermanAndFallback() {
        for text: EditorText in [
            .addRain, .addSceneContent, .rainAmount, .rainSpeed, .rainSlant, .rainDropLength,
            .rainDropWidth, .rainArea, .rainFullArea, .rainLayerHelp, .rainEraseHelp,
        ] {
            XCTAssertNotEqual(text.localized(language: "de"), text.rawValue)
            XCTAssertNotEqual(text.localized(language: "en"), text.rawValue)
            XCTAssertEqual(text.localized(language: "zz"), text.localized(language: "en"))
        }
    }
    func testGPUProfilesControlLengthAndWidthTogether() throws {
        let profiles: [WSSRainEffect.Profile] = [
            .init(length: 32, width: 2), .init(length: 64, width: 4), .init(length: 128, width: 8),
        ]
        let rain = WSSRainLayer(
            region: .init(x: 0, y: 0, width: 512, height: 512),
            rain: .init(profiles: profiles, speed: 0, density: 4, opacity: .init(min: 1, max: 1)))
        let resources = try WSSStaticResources(
            scene: .init(width: 512, height: 512, layers: [.rain(rain)]),
            assets: WSSStaticTests.Assets(values: [:]), device: WSSStaticTests().device())
        let prepared = try XCTUnwrap(resources.rain?.layers[0])
        let buffer = try XCTUnwrap(prepared.buffer)
        var extents: [(Int, Int)] = []
        for (profileIndex, profile) in profiles.enumerated() {
            let instances = prepared.population.instances.indices.map { index in
                WSSRainInstance(
                    state: SIMD4(0.5, 0.5, 3, index == 0 ? 1 : 0),
                    variation: SIMD4(profile.length, profile.width, Float(profileIndex), 0))
            }
            _ = instances.withUnsafeBytes { memcpy(buffer.contents(), $0.baseAddress!, $0.count) }
            let pixels = try WSSCloudsTests().render(
                resources, width: 512, height: 512, clearAlpha: 0
            ).0
            var xs = Set<Int>()
            var ys = Set<Int>()
            for y in 0..<512 {
                for x in 0..<512 {
                    if pixels[(y * 512 + x) * 4 + 3] > 1 {
                        xs.insert(x)
                        ys.insert(y)
                    }
                }
            }
            extents.append((xs.count, ys.count))
        }
        XCTAssertLessThan(extents[0].0, extents[1].0)
        XCTAssertLessThan(extents[1].0, extents[2].0)
        XCTAssertLessThan(extents[0].1, extents[1].1)
        XCTAssertLessThan(extents[1].1, extents[2].1)
    }

    func testExplicitLegacyProfileEditPreservesExtremeClassLengths() throws {
        for length: Float in [0.5, 256] {
            var rain = WSSRainEffect(length: length)
            try WSSRainParameter.width(0).apply(2, to: &rain)
            XCTAssertEqual(rain.profiles?.map(\.length), [0.5, 1, 1.5].map { $0 * length })
            try rain.validate()
            XCTAssertThrowsError(try WSSRainParameter.width(3).apply(1, to: &rain))
        }
    }

}
