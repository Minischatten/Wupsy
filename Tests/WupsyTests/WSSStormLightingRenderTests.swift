import ImageIO
import MetalKit
import XCTest

@testable import Wupsy

final class WSSStormLightingRenderTests: XCTestCase {
    func configuration() -> WSSStormConfiguration {
        var c = WSSStormIlluminationTests().configuration()
        c.x = 32
        c.y = 60
        c.length = 54
        c.spread = 6
        c.glow = 4
        return c
    }
    func resources(_ c: WSSStormConfiguration, image: [UInt8]? = nil) throws -> WSSStaticResources {
        var layers: [WSSSceneLayer] = []
        if image != nil {
            layers.append(
                .image(
                    .init(
                        asset: .init(value: "base"),
                        transform: .init(center: SIMD2(32, 32), size: SIMD2(64, 64)))))
        }
        layers.append(.storm(.init(storm: c)))
        return try WSSStaticResources(
            scene: WSSScene(
                width: 64, height: 64, background: SIMD3(repeating: 0.05), layers: layers),
            assets: WSSStaticTests.Assets(values: [
                .init(value: "base"): WSSStaticTests().solid(image ?? [0, 0, 0, 255])
            ]), device: WSSStaticTests().device())
    }
    func render(
        _ r: WSSStaticResources, time: Double, context: WSSStormLightingRenderContext? = nil,
        trail: WSSTrailRenderContext? = nil, pointer: SIMD2<Float>? = nil,
        width: Int = 64, height: Int = 64
    ) throws -> (Data, Double) {
        let target = try WSSRippleChainTests().target(r.device, width: width, height: height)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let b = r.scene.background
        pass.colorAttachments[0].clearColor = MTLClearColorMake(
            Double(b.x), Double(b.y), Double(b.z), 1)
        let command = try XCTUnwrap(r.queue.makeCommandBuffer())
        try r.encode(
            command: command, descriptor: pass, size: CGSize(width: width, height: height),
            time: time,
            rippleContext: WSSRippleRenderContext(device: r.device), trailContext: trail,
            pointer: pointer,
            lightingContext: context)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes {
            target.getBytes(
                $0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0)
        }
        return (data, max(0, command.gpuEndTime - command.gpuStartTime) * 1000)
    }
    func testLegacyAndInactiveLightingRemainBitExactWithoutAllocations() throws {
        var c = configuration()
        c.illumination.enabled = false
        let time = WSSStormTests().onset(c) + 0.01
        let legacy = try resources(c, image: [20, 30, 40, 255])
        var allocations = 0
        let context = WSSStormLightingRenderContext(
            device: legacy.device,
            allocate: { _ in
                allocations += 1
                return nil
            })
        let original = try render(legacy, time: time, context: context).0
        XCTAssertEqual(allocations, 0)
        c.illumination.enabled = true
        c.illumination.intensity = 0
        c.illumination.shadowLift = 0
        let neutral = try resources(c, image: [20, 30, 40, 255])
        XCTAssertEqual(try render(neutral, time: time, context: context).0, original)
        XCTAssertEqual(context.textureBytes, 0)
        XCTAssertEqual(allocations, 0)
        c.illumination.intensity = 2
        let active = try resources(c, image: [20, 30, 40, 255])
        XCTAssertNotNil(active.stormLighting)
        XCTAssertEqual(
            try render(active, time: 0, context: context).0, try render(legacy, time: 0).0)
        XCTAssertEqual(allocations, 0)
    }
    func testLightingOnlyLinearExposureShadowLiftColorAndHighlightShoulder() throws {
        var c = configuration()
        c.boltEnabled = false
        c.illumination.intensity = 1
        c.illumination.shadowLift = 0
        let time = WSSStormTests().onset(c) + 0.01
        let middle = try render(resources(c, image: [128, 128, 128, 255]), time: time).0
        // sRGB 128 -> linear 0.21586; one EV and anchored shoulder -> sRGB ~161.
        XCTAssertEqual(Double(middle[0]), 161, accuracy: 1)
        let white = try render(resources(c, image: [255, 255, 255, 255]), time: time).0
        XCTAssertEqual(Array(white.prefix(4)), [255, 255, 255, 255])
        let black = try render(resources(c, image: [0, 0, 0, 255]), time: time).0
        XCTAssertEqual(Array(black.prefix(4)), [0, 0, 0, 255])
        c.illumination.shadowLift = 0.1
        let lifted = try render(resources(c, image: [0, 0, 0, 255]), time: time).0
        XCTAssertEqual(Double(lifted[0]), 85, accuracy: 1)
        c.illumination.red = 0
        c.illumination.green = 0
        c.illumination.blue = 1
        let blue = try render(resources(c, image: [96, 96, 96, 255]), time: time).0
        XCTAssertGreaterThan(blue[0], blue[1])
        XCTAssertEqual(blue[1], 96)
        XCTAssertEqual(blue[2], 96)
        XCTAssertEqual(blue[3], 255)
    }
    func testAllocationFailureBudgetAndAliasFallBackToOriginalComposition() throws {
        var c = configuration()
        c.illumination.enabled = false
        let time = WSSStormTests().onset(c) + 0.01
        let original = try render(resources(c, image: [30, 40, 50, 255]), time: time).0
        c.illumination.enabled = true
        let r = try resources(c, image: [30, 40, 50, 255])
        var attempts = 0
        var clock = 100.0
        let failure = WSSStormLightingRenderContext(
            device: r.device,
            allocate: { _ in
                attempts += 1
                return nil
            }, now: { clock })
        XCTAssertEqual(try render(r, time: time, context: failure).0, original)
        XCTAssertEqual(try render(r, time: time, context: failure).0, original)
        XCTAssertEqual(attempts, 1)  // No repeated makeTexture failure every frame.
        clock += 1.1
        _ = try render(r, time: time, context: failure)
        XCTAssertEqual(attempts, 2)
        let limited = WSSStormLightingRenderContext(device: r.device, byteLimit: 64)
        XCTAssertEqual(try render(r, time: time, context: limited).0, original)
        XCTAssertEqual(limited.textureBytes, 0)
        let output = try WSSRippleChainTests().target(r.device)
        let alias = WSSStormLightingRenderContext(device: r.device, allocate: { _ in output })
        XCTAssertNil(alias.acquire(output: output, inputs: []))
        XCTAssertEqual(alias.textureBytes, 0)
        let image = try WSSRippleChainTests().target(r.device)
        let sourceAlias = WSSStormLightingRenderContext(device: r.device, allocate: { _ in image })
        XCTAssertNil(sourceAlias.acquire(output: output, inputs: [image]))
    }
    func testTwoInFlightSlotsReuseRetirementAndStaleLeaseProtection() throws {
        let device = try WSSStaticTests().device()
        let output = try WSSRippleChainTests().target(device)
        var allocations = 0
        let context = WSSStormLightingRenderContext(
            device: device,
            allocate: { d in
                allocations += 1
                return device.makeTexture(descriptor: d)
            })
        XCTAssertEqual(context.textureBytes, 0)
        let a = try XCTUnwrap(context.acquire(output: output, inputs: []))
        let b = try XCTUnwrap(context.acquire(output: output, inputs: []))
        XCTAssertFalse(a.texture === b.texture)
        XCTAssertNil(context.acquire(output: output, inputs: []))
        context.release(a)
        let reused = try XCTUnwrap(context.acquire(output: output, inputs: []))
        XCTAssertTrue(a.texture === reused.texture)
        XCTAssertEqual(allocations, 2)
        context.release(a)  // Old token cannot release the newer frame's slot.
        XCTAssertNil(context.acquire(output: output, inputs: []))
        context.discardResources()
        XCTAssertGreaterThan(context.textureBytes, 0)
        context.release(reused)
        context.release(b)
        XCTAssertEqual(context.textureBytes, 0)
    }
    func testCompletionOwnsLightingLeaseEvenIfPlayerDisablesOrStops() throws {
        let c = configuration()
        let r = try resources(configuration(), image: [30, 40, 50, 255])
        let context = WSSStormLightingRenderContext(device: r.device)
        let target = try WSSRippleChainTests().target(r.device)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(r.queue.makeCommandBuffer())
        try r.encode(
            command: command, descriptor: pass, size: CGSize(width: 64, height: 64),
            time: WSSStormTests().onset(c) + 0.01, lightingContext: context)
        context.discardResources()
        XCTAssertGreaterThan(context.textureBytes, 0)
        // Completion handlers may finish just after waitUntilCompleted returns.
        let drained = expectation(description: "completion drained")
        command.addCompletedHandler { _ in drained.fulfill() }
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(context.textureBytes, 0)
    }
    func reference(_ sample: [UInt8], frame: WSSStormLightingFrame) -> [Int] {
        let linear = sample.prefix(3).map { v -> Double in
            let x = Double(v) / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let luminance = linear[2] * 0.2126 + linear[1] * 0.7152 + linear[0] * 0.0722
        return (0..<3).map { index in
            let channel = 2 - index
            let gain = pow(2, Double(frame.exposure[channel]))
            let lift = Double(frame.shadowLift[channel]) * pow(1 - luminance, 2)
            let x = (linear[index] * gain + lift) / (1 + linear[index] * (gain - 1) + lift)
            let srgb = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
            return Int((srgb * 255).rounded())
        }
    }
    func testFinalPassIncludesBackgroundForegroundRainTrailAndBolt() throws {
        let device = try WSSStaticTests().device()
        let c = configuration()
        let time = WSSStormTests().onset(configuration()) + 0.01
        let back = WSSAssetID(value: "back")
        let front = WSSAssetID(value: "front")
        var background = Data()
        var foreground = Data()
        for y in 0..<64 {
            for x in 0..<64 {
                let grey = UInt8(15 + x * 3)
                background.append(contentsOf: [grey, grey, grey, 255])
                foreground.append(contentsOf: [40, 55, 70, (x > 24 && y > 20 && y < 52) ? 220 : 0])
            }
        }
        let assets = WSSStaticTests.Assets(values: [
            back: .init(width: 64, height: 64, payload: .rgba8(background)),
            front: .init(width: 64, height: 64, payload: .rgba8(foreground)),
        ])
        var trail = WSSTrailConfiguration(colors: [.init(r: 0.1, g: 0.2, b: 0.3)])
        trail.width = 3
        trail.fadeIn = 0
        trail.fadeOut = 0.1
        let image: (WSSAssetID) -> WSSSceneLayer = {
            .image(.init(asset: $0, transform: .init(center: SIMD2(32, 32), size: SIMD2(64, 64))))
        }
        let nodes: [WSSSceneLayer] = [
            image(back), .storm(.init(storm: c)),
            .rain(
                .init(region: .init(x: 0, y: 0, width: 64, height: 64), rain: .init(density: 2000))),
            .trail(.init(configuration: trail)), image(front),
        ]
        let s = WSSScene(width: 64, height: 64, background: SIMD3(repeating: 0.02), layers: nodes)
        let lit = try WSSStaticResources(scene: s, assets: assets, device: device)
        var off = s
        if case .storm(var layer) = off.layers[1] {
            layer.storm.illumination.enabled = false
            off.layers[1] = .storm(layer)
        }
        let base = try WSSStaticResources(scene: off, assets: assets, device: device)
        let contexts = [WSSTrailRenderContext(), WSSTrailRenderContext()]
        for (index, r) in [base, lit].enumerated() {
            for i in 0..<16 {
                _ = try render(
                    r, time: time - 0.25 + Double(i) * 0.015, trail: contexts[index],
                    pointer: SIMD2(Float(8 + i * 2), 30))
            }
        }
        let original = try render(base, time: time, trail: contexts[0], pointer: SIMD2(44, 30)).0
        let result = try render(lit, time: time, trail: contexts[1], pointer: SIMD2(44, 30)).0
        XCTAssertGreaterThan(contexts[0].sampleCount(index: 3), 1)
        XCTAssertEqual(contexts[0].sampleCount(index: 3), contexts[1].sampleCount(index: 3))
        let frame = WSSStormLightingFrame.illumination(scene: s, at: time)
        for i in stride(from: 0, to: result.count, by: 4) {
            let expected = reference(Array(original[i..<i + 4]), frame: frame)
            for channel in 0..<3 {
                XCTAssertEqual(Double(result[i + channel]), Double(expected[channel]), accuracy: 2)
            }
            XCTAssertEqual(result[i + 3], original[i + 3])
        }
    }
    func testImageEffectStackCompletesBeforeIllumination() throws {
        let helper = WSSRippleChainTests()
        var scene = helper.scene([.ripple(.init(amplitude: 2)), .ripple(.init(amplitude: 3))])
        var c = configuration()
        c.boltEnabled = false
        scene.layers.append(.storm(.init(storm: c)))
        let time = WSSStormTests().onset(c) + 0.01
        let device = try WSSStaticTests().device()
        let lit = try WSSStaticResources(scene: scene, assets: helper.assets(), device: device)
        var off = scene
        c.illumination.enabled = false
        off.layers[1] = .storm(.init(storm: c))
        let base = try WSSStaticResources(scene: off, assets: helper.assets(), device: device)
        let original = try render(base, time: time).0
        let result = try render(lit, time: time).0
        let light = WSSStormLightingFrame.illumination(scene: scene, at: time)
        for i in stride(from: 0, to: result.count, by: 4) {
            let expected = reference(Array(original[i..<i + 4]), frame: light)
            for channel in 0..<3 {
                XCTAssertEqual(Double(result[i + channel]), Double(expected[channel]), accuracy: 2)
            }
        }
    }

    func testMultipleLightsAggregateBeforeSingleBoundedPass() throws {
        var c = configuration()
        c.boltEnabled = false
        c.illumination.intensity = 3
        c.illumination.shadowLift = 0
        let time = WSSStormTests().onset(c) + 0.01
        let device = try WSSStaticTests().device()
        let scene = WSSScene(
            width: 64, height: 64, background: SIMD3(repeating: 0.1),
            layers: [.storm(.init(storm: c)), .storm(.init(storm: c))])
        let multiple = try WSSStaticResources(
            scene: scene, assets: WSSStaticTests.Assets(values: [:]), device: device)
        c.illumination.intensity = 4
        let single = try WSSStaticResources(
            scene: WSSScene(
                width: 64, height: 64, background: scene.background,
                layers: [.storm(.init(storm: c))]), assets: WSSStaticTests.Assets(values: [:]),
            device: device)
        var allocations = 0
        let context = WSSStormLightingRenderContext(
            device: device,
            allocate: { d in
                allocations += 1
                return device.makeTexture(descriptor: d)
            })
        XCTAssertEqual(
            try render(multiple, time: time, context: context).0, try render(single, time: time).0)
        XCTAssertEqual(allocations, 1)
    }
    func testEncodeFailureReleasesReservedSlot() throws {
        let helper = WSSRippleChainTests()
        var scene = helper.scene([.ripple(.init(amplitude: 2)), .ripple(.init(amplitude: 3))])
        let c = configuration()
        scene.layers.append(.storm(.init(storm: c)))
        let r = try WSSStaticResources(
            scene: scene, assets: helper.assets(), device: WSSStaticTests().device())
        let target = try helper.target(r.device)
        let context = WSSStormLightingRenderContext(device: r.device)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        let command = try XCTUnwrap(r.queue.makeCommandBuffer())
        // Deliberately omit the required image-effect context. Caller must not commit a failed encode.
        XCTAssertThrowsError(
            try r.encode(
                command: command, descriptor: pass, size: CGSize(width: 64, height: 64),
                time: WSSStormTests().onset(c) + 0.01, lightingContext: context))
        let a = try XCTUnwrap(context.acquire(output: target, inputs: []))
        let b = try XCTUnwrap(context.acquire(output: target, inputs: []))
        context.release(a)
        context.release(b)
        context.discardResources()
        XCTAssertEqual(context.textureBytes, 0)
    }

    func test4KReusableTargetsAndFPSDeterminism() throws {
        var c = configuration()
        c.boltEnabled = false
        let s = WSSScene(
            width: 3840, height: 2160, background: SIMD3(repeating: 0.05),
            layers: [.storm(.init(storm: c))])
        let device = try WSSStaticTests().device()
        let r = try WSSStaticResources(
            scene: s, assets: WSSStaticTests.Assets(values: [:]), device: device)
        let context = WSSStormLightingRenderContext(device: device)
        let time = WSSStormTests().onset(c) + 0.01
        var previous: Data?
        for fps in [24, 30, 60] {
            let frame = try render(r, time: time, context: context, width: 3840, height: 2160)
            if let previous { XCTAssertEqual(frame.0, previous) }
            previous = frame.0
            print(
                "Storm illumination GPU: 3840x2160, \(fps) fps policy, \(frame.1) ms, \(context.textureBytes) intermediate bytes"
            )
        }
        XCTAssertGreaterThanOrEqual(context.textureBytes, 3840 * 2160 * 4)
        XCTAssertLessThanOrEqual(context.textureBytes, 2 * 3840 * 2160 * 4)
        context.discardResources()
        XCTAssertEqual(context.textureBytes, 0)
    }
    @MainActor func testPlayerMetricsHiDPIAndDisablingReleasesTargets() throws {
        let c = configuration()
        let r = try resources(configuration())
        let player = WSSStaticPlayer(
            resources: r, size: CGSize(width: 1920, height: 1080), scale: 2, maxDimension: 4096,
            fps: 24, resolution: .hiDPI, offset: WSSStormTests().onset(c), onError: { XCTFail($0) })
        defer { player.stop() }
        XCTAssertEqual(player.view.drawableSize, CGSize(width: 3840, height: 2160))
        XCTAssertTrue(player.view.framebufferOnly)
        let target = try WSSRippleChainTests().target(r.device)
        let lease = try XCTUnwrap(player.lightingContext.acquire(output: target, inputs: []))
        player.lightingContext.release(lease)
        XCTAssertGreaterThan(player.diagnostics.intermediateTextureBytes, 0)
        let old = try WSSStormTests().model(c)
        var updated = old
        if case .storm(var layer) = updated.layers[0].content {
            layer.storm.illumination.enabled = false
            updated.layers[0].content = .storm(layer)
        }
        let reused = try XCTUnwrap(r.updatingTransforms(from: old, to: updated))
        XCTAssertTrue(player.updateTransforms(reused))
        XCTAssertEqual(player.diagnostics.intermediateTextureBytes, 0)
    }
    func testNative4KFixtureAndOptionalVisualExport() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
                "Test-Wallpaper/WSS-Storm-Lighting-v1")
        let doc = try WSSSceneDocumentV1.load(
            entry: root.appendingPathComponent("scene.wss.json"), root: root)
        let scene = try doc.scene()
        let device = try WSSStaticTests().device()
        let lit = try WSSStaticResources(
            scene: scene, assets: doc.assetSource(root: root), device: device)
        guard case .storm(let layer) = scene.layers[1] else { return XCTFail("fixture storm") }
        let time = WSSStormTests().onset(layer.storm) + 0.01
        let illuminated = try render(lit, time: time, width: 960, height: 540).0
        var off = scene
        var bolt = layer
        bolt.storm.illumination.enabled = false
        off.layers[1] = .storm(bolt)
        let base = try WSSStaticResources(
            scene: off, assets: doc.assetSource(root: root), device: device)
        let original = try render(base, time: time, width: 960, height: 540).0
        XCTAssertNotEqual(illuminated, original)
        let person = (270 * 960 + 635) * 4
        XCTAssertGreaterThan(illuminated[person], original[person])
        if let folder = ProcessInfo.processInfo.environment["WUPSY_STORM_LIGHTING_QA"] {
            for (name, data) in [("original", original), ("illuminated", illuminated)] {
                let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
                let image = try XCTUnwrap(
                    CGImage(
                        width: 960, height: 540, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: 960 * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(
                            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                        ).union(.byteOrder32Little), provider: provider, decode: nil,
                        shouldInterpolate: false, intent: .defaultIntent))
                let path = URL(fileURLWithPath: folder).appendingPathComponent(name + ".png")
                let output = try XCTUnwrap(
                    CGImageDestinationCreateWithURL(path as CFURL, "public.png" as CFString, 1, nil)
                )
                CGImageDestinationAddImage(output, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(output))
            }
        }
    }

}
