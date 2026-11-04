import ImageIO
import MetalKit
import XCTest

@testable import Wupsy

final class WSSRippleChainTests: XCTestCase {
    let image = WSSAssetID(value: "base")
    let maskA = WSSAssetID(value: "a")
    let maskB = WSSAssetID(value: "b")
    var a: WSSRippleEffect {
        WSSRippleEffect(
            amplitude: 10, wavelength: 20, stretch: 2,
            direction: 180, travelSpeed: 10, evolutionRate: 0.2, seed: 17)
    }
    var b: WSSRippleEffect {
        WSSRippleEffect(
            amplitude: 7, wavelength: 32, stretch: 1,
            direction: 90, travelSpeed: 3, evolutionRate: 0.4, seed: 981)
    }
    func scene(_ effects: [WSSImageEffect]) -> WSSScene {
        WSSScene(
            width: 64, height: 64,
            layers: [
                WSSImageLayer(
                    asset: image,
                    transform: WSSImageTransform(center: SIMD2(32, 32), size: SIMD2(64, 64)),
                    composition: .replace, effects: effects)
            ])
    }
    func assets(_ pixels: Data? = nil, alpha: UInt8 = 255) -> WSSStaticTests.Assets {
        var base = Data()
        var ma = Data()
        var mb = Data()
        for y in 0..<64 {
            for x in 0..<64 {
                let value: UInt8 = (x / 4 + y / 5) % 2 == 0 ? 40 : 210
                base.append(contentsOf: [value, UInt8(x * 3), UInt8(y * 3), alpha])
                ma.append(contentsOf: [x < 38 ? 255 : 0, 0, 0, 255])
                mb.append(contentsOf: [y > 24 ? 255 : 0, 0, 0, 255])
            }
        }
        return WSSStaticTests.Assets(values: [
            image: WSSImageAsset(width: 64, height: 64, payload: .rgba8(pixels ?? base)),
            maskA: WSSImageAsset(width: 64, height: 64, payload: .rgba8(ma)),
            maskB: WSSImageAsset(width: 64, height: 64, payload: .rgba8(mb)),
        ])
    }
    func resources(
        _ effects: [WSSRippleEffect], pixels: Data? = nil, alpha: UInt8 = 255,
        opacity: Float = 1, over: Bool = false
    ) throws -> WSSStaticResources {
        var s = scene(effects.map { .ripple($0) })
        s.testImages[0].opacity = opacity
        s.testImages[0].composition = over ? .sourceOver : .replace
        return try WSSStaticResources(
            scene: s, assets: assets(pixels, alpha: alpha), device: WSSStaticTests().device())
    }
    func target(_ device: MTLDevice, width: Int = 64, height: Int = 64) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.storageMode = .shared
        d.usage = [.renderTarget, .shaderRead]
        return try XCTUnwrap(device.makeTexture(descriptor: d))
    }
    func render(
        _ r: WSSStaticResources, context: WSSRippleRenderContext? = nil,
        time: Double = 2, width: Int = 64, height: Int = 64
    ) throws -> (Data, Double) {
        let t = try target(r.device, width: width, height: height)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = t
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let cmd = try XCTUnwrap(r.queue.makeCommandBuffer())
        let c = context ?? WSSRippleRenderContext(device: r.device)
        try r.encode(
            command: cmd, descriptor: pass, size: CGSize(width: width, height: height), time: time,
            rippleContext: c)
        cmd.commit()
        cmd.waitUntilCompleted()
        XCTAssertEqual(cmd.status, .completed)
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes {
            t.getBytes(
                $0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0)
        }
        return (data, max(0, cmd.gpuEndTime - cmd.gpuStartTime) * 1000)
    }
    func rgba(_ bgra: Data) -> Data {
        var result = bgra
        for i in stride(from: 0, to: result.count, by: 4) {
            result[i] = bgra[i + 2]
            result[i + 2] = bgra[i]
        }
        return result
    }
    func testStrictModelDocumentOrderAndCombinations() throws {
        try scene([.ripple(a)]).validate()
        try scene([.ripple(a), .ripple(b)]).validate()
        for list: [WSSImageEffect] in [
            [.ripple(a), .ripple(b), .ripple(a)],
            [.clouds(WSSCloudsEffect()), .ripple(a)], [.ripple(a), .clouds(WSSCloudsEffect())],
        ] {
            XCTAssertNoThrow(try scene(list).validate())
        }
        let root = fixtureRoot
        let entry = root.appendingPathComponent("scene.wss.json")
        let loaded = try WSSSceneDocumentV1.load(entry: entry, root: root).scene()
        guard case .ripple(let first) = loaded.testImages[0].effects[0],
            case .ripple(let second) = loaded.testImages[0].effects[1]
        else { return XCTFail() }
        XCTAssertEqual(first.seed, 17)
        XCTAssertEqual(second.seed, 981)
        var doc = try JSONSerialization.jsonObject(with: Data(contentsOf: entry)) as! [String: Any]
        var layers = doc["layers"] as! [[String: Any]]
        let list = layers[0]["effects"] as! [[String: Any]]
        for effectList in [
            list + [["type": "flow"]], [["type": "rain"]],
            [list[0].merging(["unknown": 1]) { _, new in new }],
        ] {
            layers[0]["effects"] = effectList
            doc["layers"] = layers
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    WSSSceneDocumentV1.self, from: JSONSerialization.data(withJSONObject: doc)
                ).scene())
        }
    }
    func testActualSequentialInputAllMaskCombinations() throws {
        // Independent execution reference: render A, read its pixels, construct a
        // new immutable input image, render B. No chain encoder in the reference.
        for (ma, mb): (WSSAssetID?, WSSAssetID?) in [
            (nil, nil), (maskA, nil), (nil, maskB), (maskA, maskA), (maskA, maskB),
        ] {
            var first = a
            var second = b
            first.mask = ma.map { WSSImageMask(asset: $0) }
            second.mask = mb.map { WSSImageMask(asset: $0) }
            let firstFrame = try render(resources([first])).0
            let expected = try render(resources([second], pixels: rgba(firstFrame))).0
            let actual = try render(resources([first, second])).0
            XCTAssertEqual(actual, expected)
        }
    }
    func testNeutralStagesAreByteExactAndAllocateNothing() throws {
        var zeroA = a
        var zeroB = b
        zeroA.amplitude = 0
        zeroB.amplitude = 0
        for (chain, single) in [([zeroA, b], [b]), ([a, zeroB], [a]), ([zeroA, zeroB], [])] {
            let r = try resources(chain)
            let c = WSSRippleRenderContext(device: r.device)
            XCTAssertEqual(try render(r, context: c).0, try render(resources(single)).0)
            XCTAssertEqual(c.textureBytes, 0)
        }
    }
    func testMaskRegionsOverlapOrderAndSeedIndependence() throws {
        var first = a
        var second = b
        first.mask = WSSImageMask(asset: maskA)
        second.mask = WSSImageMask(asset: maskB)
        let chain = try render(resources([first, second])).0
        let aOnly = try render(resources([first])).0
        let bOnly = try render(resources([second])).0
        let base = try render(resources([])).0
        let reversed = try render(resources([second, first])).0
        var overlapChanges = 0
        for y in 0..<64 {
            for x in 0..<64 {
                let i = (y * 64 + x) * 4
                if y < 22 { XCTAssertEqual(chain[i..<i + 4], aOnly[i..<i + 4]) }
                if x > 50 && y < 22 { XCTAssertEqual(chain[i..<i + 4], base[i..<i + 4]) }
                if x > 50 && y > 30 { XCTAssertEqual(chain[i..<i + 4], bOnly[i..<i + 4]) }
                if x < 35 && y > 30 && chain[i..<i + 4] != reversed[i..<i + 4] {
                    overlapChanges += 1
                }
            }
        }
        XCTAssertGreaterThan(overlapChanges, 100)
        XCTAssertNotEqual(chain, aOnly)
        XCTAssertNotEqual(chain, bOnly)
        first.seed += 1
        XCTAssertNotEqual(chain, try render(resources([first, second])).0)
        second.seed += 1
        XCTAssertNotEqual(chain, try render(resources([a, second])).0)
    }
    func testContextSlotsReuseResizeBudgetAndControlledFailures() throws {
        let d = try WSSStaticTests().device()
        let output = try target(d)
        let c = WSSRippleRenderContext(device: d)
        let sizes = [0: SIMD2(64, 64)]
        let one = try c.acquire(sizes: sizes, output: output)
        let two = try c.acquire(sizes: sizes, output: output)
        XCTAssertFalse(one.targets[0]! === two.targets[0]!)
        XCTAssertFalse(one.targets[0]! === output)
        XCTAssertThrowsError(try c.acquire(sizes: sizes, output: output))
        c.release(one)
        let again = try c.acquire(sizes: sizes, output: output)
        XCTAssertTrue(again.targets[0]! === one.targets[0]!)
        c.release(again)
        c.release(two)
        let resized = try c.acquire(sizes: [0: SIMD2(128, 64)], output: output)
        XCTAssertFalse(resized.targets[0]! === one.targets[0]!)
        c.release(resized)
        XCTAssertThrowsError(try c.acquire(sizes: [0: SIMD2(9000, 64)], output: output))
        XCTAssertThrowsError(
            try WSSRippleRenderContext(device: d, byteLimit: 1).acquire(
                sizes: sizes, output: output))
        XCTAssertThrowsError(
            try WSSRippleRenderContext(device: d, allocate: { _ in nil }).acquire(
                sizes: sizes, output: output))
        XCTAssertThrowsError(
            try WSSRippleRenderContext(device: d, allocate: { _ in output }).acquire(
                sizes: sizes, output: output))
        let other = WSSRippleRenderContext(device: d)
        let different = try other.acquire(sizes: sizes, output: output)
        XCTAssertFalse(different.targets[0]! === one.targets[0]!)
        other.release(different)
        // A missing context must fail, never silently execute just the first stage.
        let r = try resources([a, b])
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        XCTAssertThrowsError(
            try r.encode(
                command: XCTUnwrap(r.queue.makeCommandBuffer()), descriptor: pass,
                size: CGSize(width: 64, height: 64)))
    }
    func testTwoPendingCommandBuffersKeepSeparateTargets() throws {
        let r = try resources([a, b])
        let context = WSSRippleRenderContext(device: r.device)
        var commands: [MTLCommandBuffer] = []
        var outputs: [MTLTexture] = []
        for time in [2.0, 4] {
            let output = try target(r.device)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let cmd = try XCTUnwrap(r.queue.makeCommandBuffer())
            try r.encode(
                command: cmd, descriptor: pass, size: CGSize(width: 64, height: 64), time: time,
                rippleContext: context)
            commands.append(cmd)
            outputs.append(output)
        }
        XCTAssertFalse(context.targets[0][0]! === context.targets[1][0]!)
        for cmd in commands { cmd.commit() }
        for (index, cmd) in commands.enumerated() {
            cmd.waitUntilCompleted()
            XCTAssertEqual(cmd.status, .completed)
            var bytes = Data(count: 64 * 64 * 4)
            bytes.withUnsafeMutableBytes {
                outputs[index].getBytes(
                    $0.baseAddress!, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 64),
                    mipmapLevel: 0)
            }
            XCTAssertEqual(bytes, try render(r, time: index == 0 ? 2 : 4).0)
        }
    }
    func testPremultipliedAlphaOpacityAndComposition() throws {
        for over in [false, true] {
            let frame = try render(resources([a, b], alpha: 128, opacity: 0.5, over: over)).0
            for i in stride(from: 3, to: frame.count, by: 4) {
                XCTAssertEqual(Double(frame[i]), 64, accuracy: 1)
            }
        }
    }
    func testClockLongRunAndDensity() throws {
        let r = try resources([a, b])
        let c = WSSRippleRenderContext(device: r.device)
        var clock = WSSPlaybackClock()
        clock.play(now: 100)
        clock.stop(now: 102)
        let paused = try render(r, context: c, time: clock.time(now: 200)).0
        clock.play(now: 200)
        XCTAssertEqual(paused, try render(r, context: c, time: clock.time(now: 200)).0)
        XCTAssertNotEqual(paused, try render(r, context: c, time: clock.time(now: 201)).0)
        _ = try render(r, context: c, time: 1e9)
        let high = try render(r, context: c, time: 2, width: 128, height: 128).0
        XCTAssertEqual(c.targets[0][0]?.width, 128)
        // Density increases sampling, not the wave's logical units.
        for y in 8..<56 {
            for x in 8..<56 {
                let i = (y * 64 + x) * 4
                // Red is deliberately discontinuous; coordinate channels provide a stable comparison.
                for channel in [0, 1] {
                    XCTAssertEqual(
                        Double(paused[i + channel]),
                        Double(high[((y * 2) * 128 + x * 2) * 4 + channel]), accuracy: 12)
                }
            }
        }
    }
    var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(
                "Test-Wallpaper/WSS-Ripple-Chain-v1")
    }
    func testFrozenSingleRippleFrames() throws {
        guard let path = ProcessInfo.processInfo.environment["AMBIENT_RIPPLE_FROZEN"] else {
            throw XCTSkip("Set AMBIENT_RIPPLE_FROZEN to compare 7B frames")
        }
        let root = fixtureRoot.deletingLastPathComponent().appendingPathComponent("WSS-Ripple-v1")
        let scene = try WSSSceneDocumentV1.load(
            entry: root.appendingPathComponent("scene.wss.json"), root: root
        ).scene()
        let r = try WSSStaticResources(
            scene: scene, assets: WSSNativeAssets(root: root), device: WSSStaticTests().device())
        let out = URL(fileURLWithPath: path)
        for t in [0, 1, 2, 4, 8] {
            let old = try Data(contentsOf: out.appendingPathComponent("t\(t).png"))
            let png = CGImageSourceCreateWithData(old as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(png, 0, nil)!
            let oldPixels = image.dataProvider!.data! as Data
            let new = try render(r, time: Double(t), width: 960, height: 540).0
            // Saved diagnostics use BGRA premultiplied provider bytes; ImageIO may
            // expose RGBA. Decode layout explicitly before exact comparison.
            let bytes = Array(oldPixels)
            var expected = Data(count: new.count)
            let alphaFirst = [CGImageAlphaInfo.first, .premultipliedFirst, .noneSkipFirst].contains(
                image.alphaInfo)
            for y in 0..<540 {
                for x in 0..<960 {
                    let p = y * image.bytesPerRow + x * 4
                    let i = (y * 960 + x) * 4
                    if image.bitmapInfo.contains(.byteOrder32Little) {
                        expected.replaceSubrange(i..<i + 4, with: bytes[p..<p + 4])
                    } else if alphaFirst {
                        expected.replaceSubrange(
                            i..<i + 4, with: [bytes[p + 3], bytes[p + 2], bytes[p + 1], bytes[p]])
                    } else {
                        expected.replaceSubrange(
                            i..<i + 4, with: [bytes[p + 2], bytes[p + 1], bytes[p], bytes[p + 3]])
                    }
                }
            }
            XCTAssertEqual(new, expected, "Frozen 7B t\(t)")
        }
    }
    func testFixtureDiagnosticsAndPerformance() throws {
        guard let path = ProcessInfo.processInfo.environment["AMBIENT_RIPPLE_CHAIN_QA"] else {
            throw XCTSkip("Set AMBIENT_RIPPLE_CHAIN_QA for diagnostics/performance")
        }
        let out = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let root = fixtureRoot
        let scene = try WSSSceneDocumentV1.load(
            entry: root.appendingPathComponent("scene.wss.json"), root: root
        ).scene()
        let assets = WSSNativeAssets(root: root)
        let device = try WSSStaticTests().device()
        let chain = try WSSStaticResources(scene: scene, assets: assets, device: device)
        let context = WSSRippleRenderContext(device: device)
        let writer = WSSRippleTests()
        for t in [0, 1, 2, 4, 8] {
            let data = try render(chain, context: context, time: Double(t), width: 960, height: 540)
                .0
            try writer.writePNG(
                data, width: 960, height: 540, to: out.appendingPathComponent("chain-t\(t).png"))
        }
        let effects = scene.testImages[0].effects
        var variants: [String: [WSSImageEffect]] = [
            "A-only": [effects[0]], "B-only": [effects[1]], "A-to-B": effects,
            "B-to-A": effects.reversed(),
        ]
        variants["original"] = []
        var pictures: [String: Data] = [:]
        for (name, list) in variants {
            var s = scene
            s.testImages[0].effects = list
            let r = try WSSStaticResources(scene: s, assets: assets, device: device)
            let data = try render(r, time: 2, width: 960, height: 540).0
            pictures[name] = data
            try writer.writePNG(
                data, width: 960, height: 540, to: out.appendingPathComponent(name + ".png"))
            var crop = Data()
            for y in 270..<345 { crop.append(data[(y * 960 + 300) * 4..<(y * 960 + 500) * 4]) }
            try writer.writePNG(
                crop, width: 200, height: 75, to: out.appendingPathComponent(name + "-overlap.png"))
        }
        for name in ["mask-a", "mask-b"] {
            let m = try assets.mask(for: WSSAssetID(value: "assets/\(name).png"))
            try writer.writePNG(
                Data(m.pixels.flatMap { [$0, $0, $0, 255] }), width: 960, height: 540,
                to: out.appendingPathComponent(name + ".png"))
        }
        let ma = try assets.mask(for: WSSAssetID(value: "assets/mask-a.png")).pixels
        let mb = try assets.mask(for: WSSAssetID(value: "assets/mask-b.png")).pixels
        var changed = 0
        for i in 0..<ma.count where ma[i] > 0 && mb[i] > 0 {
            if pictures["A-to-B"]![i * 4..<i * 4 + 4] != pictures["B-to-A"]![i * 4..<i * 4 + 4] {
                changed += 1
            }
        }
        XCTAssertGreaterThan(changed, 100)
        print("CHAIN overlap order-sensitive pixels: \(changed); device \(device.name)")
        var singleScene = scene
        singleScene.testImages[0].effects = [effects[0]]
        let single = try WSSStaticResources(scene: singleScene, assets: assets, device: device)
        for (w, h) in [(3840, 2160), (6400, 3600)] {
            for (name, r) in [("single", single), ("chain", chain)] {
                let c = WSSRippleRenderContext(device: device)
                var times: [Double] = []
                for i in 0..<12 {
                    let ms = try render(r, context: c, time: Double(i) / 30, width: w, height: h).1
                    if i >= 2 { times.append(ms) }
                }
                // Reserve both slots concurrently to verify real per-display peak storage.
                if name == "chain" {
                    let output = try target(device, width: w, height: h)
                    let first = try c.acquire(sizes: [0: SIMD2(w, h)], output: output)
                    let second = try c.acquire(sizes: [0: SIMD2(w, h)], output: output)
                    XCTAssertFalse(first.targets[0]! === second.targets[0]!)
                    c.release(first)
                    c.release(second)
                }
                print(
                    "CHAIN PERF \(name) \(w)x\(h) mean \(times.reduce(0,+)/Double(times.count)) ms; min \(times.min()!) max \(times.max()!); scratch \(c.textureBytes) bytes; immutable \(r.textureBytes); mask bytes \(r.ripple!.textureBytes)"
                )
            }
        }
    }
}
