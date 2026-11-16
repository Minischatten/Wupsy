import MetalKit
import XCTest

@testable import Wupsy

final class WSSShootingStarRenderTests: XCTestCase {
    let cpu = WSSShootingStarTests()
    let helper = WSSStarfieldTests()
    func testHeadTailMotionClippingAndForegroundOrder() throws {
        var c = cpu.configuration()
        c.x = 12
        c.y = 12
        c.width = 40
        c.height = 40
        c.shootingStars.speed = 50
        let time = cpu.onset(c) + 0.3
        let r = try helper.resources(c)
        let pixels = try helper.render(r, time: time)
        XCTAssertTrue(pixels.enumerated().contains { $0.offset % 4 != 3 && $0.element > 0 })
        for y in 0..<64 {
            for x in 0..<64 where x < 12 || x >= 52 || y < 12 || y >= 52 {
                XCTAssertEqual(Array(pixels[(y * 64 + x) * 4..<(y * 64 + x) * 4 + 3]), [0, 0, 0])
            }
        }
        var noTail = c
        noTail.shootingStars.tailLength = 0
        let headOnly = try helper.render(helper.resources(noTail), time: time)
        XCTAssertNotEqual(pixels, headOnly)
        XCTAssertNotEqual(pixels, try helper.render(r, time: time + 0.1))
        let front = try helper.render(helper.resources(c, front: true), time: time)
        let reverse = try helper.render(
            helper.resources(c, front: true, reversed: true), time: time)
        XCTAssertEqual(reverse, pixels)
        for y in 0..<64 {
            for x in 12..<20 {
                XCTAssertEqual(Array(front[(y * 64 + x) * 4..<(y * 64 + x) * 4 + 3]), [0, 0, 0])
            }
        }
        for i in stride(from: 3, to: pixels.count, by: 4) { XCTAssertEqual(pixels[i], 255) }
    }
    func testDisabledLegacyIdentityAndNoPopulationRebuild() throws {
        let base = helper.configuration()
        let model = try helper.model(base)
        let r = try helper.resources(base)
        let buffer = r.starfield?.layers[0]?.buffer
        var c = base
        c.shootingStars.enabled = true
        var updated = model
        updated.layers[0].content = .starfield(.init(starfield: c))
        let reused = try XCTUnwrap(r.updatingTransforms(from: model, to: updated))
        XCTAssertTrue(reused.starfield === r.starfield)
        XCTAssertTrue(reused.starfield?.layers[0]?.buffer === buffer)
        XCTAssertEqual(r.textureBytes, 0)
        // Between events the optional extension must leave the original pixels bit exact.
        XCTAssertEqual(try helper.render(r), try helper.render(reused))
        c.shootingStars.enabled = false
        c.shootingStars.brightness = 4
        c.shootingStars.direction = 123
        XCTAssertEqual(
            try helper.render(r, time: 100), try helper.render(helper.resources(c), time: 100))
        XCTAssertEqual(
            try WSSStarfieldPopulation(count: c.count, seed: c.seed).instances,
            try WSSStarfieldPopulation(count: base.count, seed: base.seed).instances)
    }
    func testTinyRegionsMultipleLayersAndResourceRelease() throws {
        let device = try WSSStaticTests().device()
        var c = cpu.configuration()
        c.width = 1
        c.height = 1
        let time = cpu.onset(c) + 0.3
        weak var renderer: WSSStarfieldRenderer?
        try autoreleasepool {
            let nodes: [WSSSceneLayer] = (0..<8).map { i in
                var layer = c
                layer.x = Double(i * 4)
                layer.y = 32
                layer.seed = UInt32(i + 1)
                return .starfield(.init(starfield: layer))
            }
            let r = try WSSStaticResources(
                scene: .init(width: 64, height: 64, layers: nodes),
                assets: WSSStaticTests.Assets(values: [:]), device: device)
            renderer = r.starfield
            XCTAssertEqual(r.starfield?.bufferBytes, 0)
            XCTAssertEqual(r.textureBytes, 0)
            _ = try helper.render(r, time: time)
        }
        XCTAssertNil(renderer)
    }
    func testAssetFreeAcceptanceSceneLoadsViaNativeDocumentPath() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
                "Test-Wallpaper/WSS-Starfield-Shooting-Stars-v1")
        let doc = try WSSSceneDocumentV1.load(
            entry: root.appendingPathComponent("scene.wss.json"), root: root)
        let scene = try doc.scene()
        XCTAssertTrue(doc.referencedPaths.isEmpty)
        XCTAssertTrue(scene.isAnimated)
        let r = try WSSStaticResources(
            scene: scene, assets: doc.assetSource(root: root), device: WSSStaticTests().device())
        XCTAssertNotNil(r.starfield)
        XCTAssertEqual(r.starfield?.bufferBytes, 2000 * 32)
        XCTAssertEqual(r.textureBytes, 0)
    }
    func test4KMeteorHasNoSceneScratchAndFPSIndependentSamples() throws {
        var c = cpu.configuration()
        c.width = 3840
        c.height = 2160
        c.shootingStars.speed = 700
        let r = try WSSStaticResources(
            scene: .init(width: 3840, height: 2160, layers: [.starfield(.init(starfield: c))]),
            assets: WSSStaticTests.Assets(values: [:]), device: WSSStaticTests().device())
        let time = cpu.onset(c) + 0.4
        let a = try WSSStormLightingRenderTests().render(r, time: time, width: 3840, height: 2160).0
        XCTAssertTrue(a.enumerated().contains { $0.offset % 4 != 3 && $0.element > 0 })
        XCTAssertEqual(r.textureBytes, 0)
        XCTAssertEqual(r.starfield?.bufferBytes, 0)
        let frame = WSSShootingStarEvents.events(c, at: time)
        for fps in [24.0, 30, 60] {
            for i in 0..<Int(fps * 2) { _ = WSSShootingStarEvents.events(c, at: Double(i) / fps) }
            XCTAssertEqual(frame, WSSShootingStarEvents.events(c, at: time))
        }
    }
}
