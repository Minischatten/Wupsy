import ImageIO
import MetalKit
import XCTest

@testable import Wupsy

final class WSSMilkyWayRenderTests: XCTestCase {
    let helper = WSSStarfieldTests()
    func render(_ c: WSSStarfieldConfiguration, time: Double = 0) throws -> Data {
        try helper.render(helper.resources(c), time: time)
    }
    func testDeterminismSeedsDustStructureAndOwnFreeRGB() throws {
        let c = WSSMilkyWayTests().configuration()
        let base = try render(c)
        XCTAssertTrue(base.enumerated().contains { $0.offset % 4 != 3 && $0.element > 0 })
        XCTAssertEqual(base, try render(c, time: 1e12))
        var changed = c
        changed.milkyWay.seed = 42
        XCTAssertNotEqual(base, try render(changed))
        changed = c
        changed.milkyWay.dust = 0
        let clear = try render(changed)
        XCTAssertNotEqual(base, clear)
        var darkened = 0
        for i in 0..<base.count where i % 4 != 3 {
            XCTAssertLessThanOrEqual(base[i], clear[i])
            if base[i] < clear[i] { darkened += 1 }
        }
        XCTAssertGreaterThan(darkened, 100)
        changed = c
        changed.milkyWay.structure = 0
        XCTAssertNotEqual(base, try render(changed))
        for color: SIMD3<Double> in [
            SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 1, 1), SIMD3(1, 0, 1),
        ] {
            changed = c
            changed.milkyWay.red = color.x
            changed.milkyWay.green = color.y
            changed.milkyWay.blue = color.z
            let pixels = try render(changed)
            for channel in 0..<3 {
                let values = stride(from: 2 - channel, to: pixels.count, by: 4).map { pixels[$0] }
                if color[channel] == 0 {
                    XCTAssertEqual(values.max(), 0)
                } else {
                    XCTAssertGreaterThan(values.max() ?? 0, 0)
                }
            }
        }
    }
    func testClippedRegionAnglesAspectAndForegroundOcclusion() throws {
        var c = WSSMilkyWayTests().configuration()
        for dimensions: SIMD2<Double> in [SIMD2(40, 16), SIMD2(16, 40)] {
            c.x = 12
            c.y = 12
            c.width = dimensions.x
            c.height = dimensions.y
            for angle in [0.0, 30, 90, 135, 359.9] {
                c.milkyWay.angle = angle
                let pixels = try render(c)
                XCTAssertTrue(pixels.enumerated().contains { $0.offset % 4 != 3 && $0.element > 0 })
                for y in 0..<64 {
                    for x in 0..<64
                    where x < 12 || x >= 12 + Int(c.width) || y < 64 - 12 - Int(c.height) || y >= 52
                    {
                        XCTAssertEqual(
                            Array(pixels[(y * 64 + x) * 4..<(y * 64 + x) * 4 + 3]), [0, 0, 0])
                    }
                }
            }
        }
        c = WSSMilkyWayTests().configuration()
        let plain = try render(c)
        let front = try helper.render(helper.resources(c, front: true))
        XCTAssertEqual(plain, try helper.render(helper.resources(c, front: true, reversed: true)))
        for y in 0..<64 {
            for x in 0..<12 {
                XCTAssertEqual(Array(front[(y * 64 + x) * 4..<(y * 64 + x) * 4 + 3]), [0, 0, 0])
            }
        }
        XCTAssertNotEqual(plain, front)
        for i in stride(from: 3, to: plain.count, by: 4) { XCTAssertEqual(plain[i], 255) }
    }
    func testSharedDriftWrapIsContinuousAndTranslatesAllPixels() throws {
        var c = WSSMilkyWayTests().configuration()
        c.driftX = 1
        c.driftY = -1
        let a = try render(c)
        let b = try render(c, time: 1)
        var difference = 0
        for y in 0..<64 {
            for x in 0..<64 {
                for channel in 0..<3 {
                    let source = (((y + 63) % 64) * 64 + (x + 63) % 64) * 4 + channel
                    difference = max(
                        difference, abs(Int(a[source]) - Int(b[(y * 64 + x) * 4 + channel])))
                }
            }
        }
        XCTAssertLessThanOrEqual(difference, 1)
        XCTAssertEqual(a, try render(c, time: 64))
        XCTAssertNotEqual(a, b)
    }
    func testLazyPipelineLegacyIdentityReuseAndRelease() throws {
        var c = helper.configuration()
        let old = try helper.model(c)
        let r = try helper.resources(c)
        XCTAssertNil(r.milkyWay)
        let pixels = try helper.render(r, time: 12)
        c.milkyWay.enabled = true
        var next = old
        next.layers[0].content = .starfield(.init(starfield: c))
        var reused: WSSStaticResources? = try XCTUnwrap(r.updatingTransforms(from: old, to: next))
        XCTAssertTrue(reused?.starfield === r.starfield)
        XCTAssertNotNil(reused?.milkyWay)
        XCTAssertEqual(reused?.textureBytes, 0)
        weak let galaxy = reused?.milkyWay
        reused = nil
        XCTAssertNil(galaxy)
        c.milkyWay.enabled = false
        c.milkyWay.seed = 42
        XCTAssertEqual(pixels, try render(c, time: 12))
        c.milkyWay.enabled = true
        c.milkyWay.intensity = 0
        XCTAssertEqual(pixels, try render(c, time: 12))
    }
    func testMultipleLayersRetainNoBuffersOrTextures() throws {
        let c = WSSMilkyWayTests().configuration()
        weak var galaxy: WSSMilkyWayRenderer?
        try autoreleasepool {
            let nodes: [WSSSceneLayer] = (0..<8).map { i in
                var next = c
                next.milkyWay.seed = UInt32(i + 1)
                return .starfield(.init(starfield: next))
            }
            let r = try WSSStaticResources(
                scene: .init(width: 64, height: 64, layers: nodes),
                assets: WSSStaticTests.Assets(values: [:]), device: WSSStaticTests().device())
            galaxy = r.milkyWay
            _ = try helper.render(r)
            XCTAssertEqual(r.textureBytes, 0)
            XCTAssertEqual(r.starfield?.bufferBytes, 0)
        }
        XCTAssertNil(galaxy)
    }
    func test4KFixturePerformanceAndOptionalVisualExport() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
                "Test-Wallpaper/WSS-Starfield-Milky-Way-v1")
        let doc = try WSSSceneDocumentV1.load(
            entry: root.appendingPathComponent("scene.wss.json"), root: root)
        let r = try WSSStaticResources(
            scene: doc.scene(), assets: doc.assetSource(root: root),
            device: WSSStaticTests().device())
        let result = try WSSStormLightingRenderTests().render(r, time: 0, width: 3840, height: 2160)
        print(
            "Milky Way 4K GPU: \(result.1) ms; image textures \(r.textureBytes) bytes; stars \(r.starfield?.bufferBytes ?? 0) bytes; zero galaxy textures/buffers"
        )
        XCTAssertEqual(result.0.count, 3840 * 2160 * 4)
        if let folder = ProcessInfo.processInfo.environment["WUPSY_MILKY_WAY_QA"] {
            let data = try WSSStormLightingRenderTests().render(r, time: 0, width: 960, height: 540)
                .0
            let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
            let image = try XCTUnwrap(
                CGImage(
                    width: 960, height: 540, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: 960 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                        .union(.byteOrder32Little), provider: provider, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent))
            let path = URL(fileURLWithPath: folder).appendingPathComponent("milky-way.png")
            let output = try XCTUnwrap(
                CGImageDestinationCreateWithURL(path as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(output, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(output))
        }
    }
}
