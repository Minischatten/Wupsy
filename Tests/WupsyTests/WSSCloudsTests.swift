import ImageIO
import MetalKit
import UniformTypeIdentifiers
import XCTest

@testable import Wupsy

final class WSSCloudsTests: XCTestCase {
    let image = WSSAssetID(value: "native/base")
    let mask = WSSAssetID(value: "native/mask")
    func scene(_ effect: WSSCloudsEffect? = WSSCloudsEffect()) -> WSSScene {
        WSSScene(
            width: 64, height: 64,
            layers: [
                WSSImageLayer(
                    asset: image,
                    transform: WSSImageTransform(center: SIMD2(32, 32), size: SIMD2(64, 64)),
                    composition: .replace, effects: effect.map { [.clouds($0)] } ?? [])
            ])
    }
    func resources(
        _ effect: WSSCloudsEffect? = WSSCloudsEffect(), maskValue: UInt8 = 255,
        alpha: UInt8 = 255, composition: WSSImageLayer.Composition = .replace,
        opacity: Float = 1
    ) throws -> WSSStaticResources {
        var s = scene(effect)
        s.testImages[0].composition = composition
        s.testImages[0].opacity = opacity
        return try WSSStaticResources(
            scene: s,
            assets: WSSStaticTests.Assets(values: [
                image: WSSImageAsset(
                    width: 1, height: 1, payload: .rgba8(Data([40, 80, 120, alpha]))),
                mask: WSSImageAsset(
                    width: 1, height: 1, payload: .rgba8(Data([maskValue, 0, 0, 0]))),
            ]), device: WSSStaticTests().device())
    }
    func render(
        _ r: WSSStaticResources, time: Double = 0, width: Int = 64, height: Int = 64,
        clearAlpha: Double = 1
    ) throws
        -> (Data, Double)
    {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        d.storageMode = .shared
        d.usage = .renderTarget
        let texture = try XCTUnwrap(r.device.makeTexture(descriptor: d))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, clearAlpha)
        let cmd = try XCTUnwrap(r.queue.makeCommandBuffer())
        try r.encode(
            command: cmd, descriptor: pass, size: CGSize(width: width, height: height), time: time)
        cmd.commit()
        cmd.waitUntilCompleted()
        XCTAssertEqual(cmd.status, .completed)
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return (pixels, max(0, cmd.gpuEndTime - cmd.gpuStartTime) * 1000)
    }
    func testNativeValuesAndBoundaries() throws {
        try scene().validate()
        for change: (inout WSSCloudsEffect) -> Void in [
            { $0.scale = 0 }, { $0.scale = 8193 }, { $0.scale = .nan },
            { $0.intensity = -.infinity }, { $0.intensity = 1.1 },
            { $0.density = -0.1 }, { $0.density = .nan },
            { $0.velocity.x = .infinity }, { $0.velocity.y = 4097 },
            { $0.mask = WSSImageMask(asset: WSSAssetID(value: "")) },
        ] {
            var e = WSSCloudsEffect()
            change(&e)
            XCTAssertThrowsError(try scene(e).validate())
        }
        for scale: Float in [1, 8192] {
            for value: Float in [0, 1] {
                try scene(
                    WSSCloudsEffect(
                        velocity: SIMD2(-4096, 4096), scale: scale,
                        intensity: value, density: value, seed: .max)
                ).validate()
            }
        }
        var s = scene()
        s.testImages[0].effects.append(.clouds(WSSCloudsEffect()))
        XCTAssertNoThrow(try s.validate())
    }
    func testNoiseDeterminismAndPeriodicSeam() {
        let a = WSSCloudsNoise.pixels(seed: 1)
        XCTAssertEqual(a.count, 128 * 128)
        XCTAssertEqual(a, WSSCloudsNoise.pixels(seed: 1))
        XCTAssertNotEqual(a, WSSCloudsNoise.pixels(seed: 2))
        XCTAssertGreaterThan(Int(a.max()!) - Int(a.min()!), 40)
        // A periodic sampled field need not duplicate edge texels. Adjacent wrapped
        // texels must be as smooth as ordinary neighbours, without a discontinuity.
        for i in 0..<128 {
            XCTAssertLessThan(abs(Int(a[i * 128]) - Int(a[i * 128 + 127])), 20)
            XCTAssertLessThan(abs(Int(a[i]) - Int(a[127 * 128 + i])), 20)
        }
    }
    func testClockAndLongRunningPhase() throws {
        var c = WSSPlaybackClock()
        XCTAssertEqual(c.time(now: 100), 0)
        c.play(now: 100)
        XCTAssertEqual(c.time(now: 102), 2)
        c.stop(now: 103)
        XCTAssertEqual(c.time(now: 999), 3)
        c.play(now: 1000)
        XCTAssertEqual(c.time(now: 1001), 4)
        let resumed = WSSPlaybackClock(offset: c.time(now: 1001))
        XCTAssertEqual(resumed.time(now: 9000), 4)
        let e = WSSCloudsEffect(velocity: SIMD2(16, -8), scale: 128)
        XCTAssertEqual(try e.phase(at: 1), try e.phase(at: 1_000_000_000_001))
        for t in [0.0, 1e12, Double.greatestFiniteMagnitude] {
            let p = try e.phase(at: t)
            XCTAssertTrue(p.x.isFinite && p.y.isFinite)
            XCTAssertLessThan(abs(p.x), 1)
            XCTAssertLessThan(abs(p.y), 1)
        }
        XCTAssertThrowsError(try e.phase(at: .nan))
        XCTAssertThrowsError(try e.phase(at: -1))
    }
    func testGPUAppearanceMotionMaskAlphaAndComposition() throws {
        let e = WSSCloudsEffect(velocity: SIMD2(9, 3), scale: 32, intensity: 0.8, density: 0.6)
        let r = try resources(e)
        let a = try render(r).0
        XCTAssertEqual(a, try render(r).0)
        XCTAssertNotEqual(a, try render(r, time: 2).0)
        XCTAssertEqual(r.textureBytes, try resources(e).textureBytes)
        var still = e
        still.velocity = .zero
        let stationary = try resources(still)
        XCTAssertEqual(try render(stationary).0, try render(stationary, time: 1000).0)
        var empty = e
        empty.density = 0
        XCTAssertEqual(try render(resources(empty)).0, try render(resources(nil)).0)
        var zero = e
        zero.intensity = 0
        XCTAssertEqual(try render(resources(zero)).0, try render(resources(nil)).0)
        var masked = e
        masked.mask = WSSImageMask(asset: mask)
        XCTAssertEqual(try render(resources(masked, maskValue: 0)).0, try render(resources(nil)).0)
        XCTAssertEqual(try render(resources(masked)).0, a)
        for composition: WSSImageLayer.Composition in [.replace, .sourceOver] {
            let transparent = try render(resources(e, alpha: 0, composition: composition)).0
            XCTAssertTrue(
                stride(from: 0, to: transparent.count, by: 4).allSatisfy {
                    transparent[$0] == 0 && transparent[$0 + 1] == 0 && transparent[$0 + 2] == 0
                })
            let half = try render(resources(e, alpha: 128, composition: composition, opacity: 0.5))
                .0
            if composition == .replace {
                XCTAssertEqual(half[3], 64)
            } else {
                XCTAssertEqual(half[3], 255)
            }
        }
        var bad = e
        bad.mask = WSSImageMask(asset: WSSAssetID(value: "missing"))
        XCTAssertThrowsError(try resources(bad))
        XCTAssertThrowsError(try render(r, time: .infinity))
    }
    @MainActor func testPlayerClockAnimationAndResolution() throws {
        for effect in [nil, WSSCloudsEffect()] {
            let r = try resources(effect)
            let p = WSSStaticPlayer(
                resources: r, size: CGSize(width: 64, height: 64), scale: 2,
                maxDimension: 1000, fps: 24, resolution: .standard, offset: 7,
                onError: { XCTFail($0) })
            XCTAssertEqual(p.elapsed, 7)
            p.play()
            XCTAssertEqual(p.view.isPaused, effect == nil)
            XCTAssertEqual(p.view.enableSetNeedsDisplay, effect == nil)
            let before = p.elapsed
            p.setRenderResolution(.hiDPI)
            XCTAssertEqual(p.view.drawableSize.width, 128)
            XCTAssertGreaterThanOrEqual(p.elapsed, before)
            p.setRenderResolution(.standard)
            XCTAssertEqual(p.view.drawableSize.width, 64)
            p.stop()
            let frozen = p.elapsed
            XCTAssertEqual(p.elapsed, frozen)
            XCTAssertTrue(p.view.isPaused)
        }
    }
    func testPerformanceStandardAndHiDPI() throws {
        for (label, r, size) in [
            ("static", try resources(nil), 1920),
            ("clouds standard", try resources(), 1920), ("clouds HiDPI", try resources(), 3840),
        ] {
            var times: [Double] = []
            for _ in 0..<6 {
                times.append(try render(r, time: 1, width: size, height: size * 9 / 16).1)
            }
            print(
                "WSS benchmark \(label): mean GPU ms \(times.dropFirst().reduce(0,+)/5), texture bytes \(r.textureBytes), one draw, zero intermediates"
            )
        }
    }
    @MainActor func testLiveCloudsFramesAndStop() async throws {
        let p = WSSStaticPlayer(
            resources: try resources(), size: CGSize(width: 128, height: 72),
            scale: 2, maxDimension: 1000, fps: 30, resolution: .standard, offset: 0,
            onError: { XCTFail($0) })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 128, height: 72),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = p.view
        defer {
            p.stop()
            window.close()
        }
        window.orderFront(nil)
        p.play()
        for _ in 0..<100 {
            if p.metrics.snapshot().frames >= 3 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(p.metrics.snapshot().frames, 3)
        let before = p.elapsed
        p.setRenderResolution(.hiDPI)
        XCTAssertGreaterThanOrEqual(p.elapsed, before)
        p.stop()
        let time = p.elapsed
        try await Task.sleep(for: .milliseconds(150))
        let frames = p.metrics.snapshot().frames
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(p.elapsed, time)
        XCTAssertEqual(p.metrics.snapshot().frames, frames)
    }
    func testMaskDecodeOrientationAndLayerOrder() throws {
        let rgba = Data([0, 71, 91, 255, 255, 81, 101, 255])
        let provider = try XCTUnwrap(CGDataProvider(data: rgba as CFData))
        let image = try XCTUnwrap(
            CGImage(
                width: 1, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let decoded = try WSSMaskAsset.decode(
            encoded as Data, width: 1, height: 2, uvScale: SIMD2(repeating: 1))
        XCTAssertEqual(decoded.pixels, Data([0, 255]))
        let r = try resources(WSSCloudsEffect(intensity: 1, density: 1))
        var scene = r.scene
        var foreground = scene.testImages[0]
        foreground.effects = []
        foreground.opacity = 1
        foreground.composition = .replace
        scene.testImages.append(foreground)
        let assets = WSSStaticTests.Assets(values: [
            self.image: WSSImageAsset(
                width: 1, height: 1,
                payload: .rgba8(Data([40, 80, 120, 255])))
        ])
        let ordered = try WSSStaticResources(scene: scene, assets: assets, device: r.device)
        XCTAssertEqual(try render(ordered).0, try render(resources(nil)).0)
        scene.testImages.reverse()
        let reversed = try WSSStaticResources(scene: scene, assets: assets, device: r.device)
        XCTAssertNotEqual(try render(reversed).0, try render(resources(nil)).0)
    }

}
