import ImageIO
import MetalKit
import UniformTypeIdentifiers
import XCTest

@testable import Wupsy

final class WSSRainTests: XCTestCase {
    var region: WSSRainRegion { .init(x: 0, y: 0, width: 1920, height: 1080) }
    var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Test-Wallpaper/WSS-Rain-v1")
    }
    func population(_ effect: WSSRainEffect = .init()) throws -> WSSRainPopulation {
        try WSSRainPopulation(.init(region: region, rain: effect))
    }
    func fixtureResources() async throws -> WSSStaticResources {
        try await WSSStaticPreparation.shared.prepare(WallpaperImporter.resolve(fixture))
    }
    func testParameterBoundsNonFiniteRegionAndBudget() throws {
        try WSSRainEffect().validate()
        let changes: [(inout WSSRainEffect) -> Void] = [
            { $0.direction = -1 }, { $0.direction = 360 }, { $0.speed = -1 }, { $0.speed = 6001 },
            { $0.density = -1 }, { $0.density = 2001 }, { $0.length = 0.49 }, { $0.length = 257 },
            { $0.width = 0.24 }, { $0.width = 8.01 }, { $0.opacity.min = -0.1 },
            { $0.opacity.max = 1.1 }, { $0.opacity.min = 0.9 },
        ]
        for change in changes {
            var e = WSSRainEffect()
            change(&e)
            XCTAssertThrowsError(try e.validate())
        }
        let keys: [WritableKeyPath<WSSRainEffect, Float>] = [
            \.direction, \.speed, \.density, \.length, \.width, \.opacity.min, \.opacity.max,
        ]
        for key in keys {
            for bad: Float in [.nan, .infinity, -.infinity] {
                var e = WSSRainEffect()
                e[keyPath: key] = bad
                XCTAssertThrowsError(try e.validate())
            }
        }
        for e in [
            WSSRainEffect(
                direction: 0, speed: 0, density: 0, length: 0.5, width: 0.25,
                opacity: .init(min: 0, max: 0), seed: 0),
            WSSRainEffect(
                direction: 359.99, speed: 6000, density: 2000, length: 256, width: 8,
                opacity: .init(min: 1, max: 1), seed: .max),
        ] {
            try e.validate()
        }
        XCTAssertTrue(try population(.init(density: 0)).instances.isEmpty)
        for bad in [
            WSSRainRegion(x: .nan, y: 0, width: 1, height: 1),
            .init(x: 0, y: 0, width: 0, height: 1), .init(x: 0, y: 0, width: 8193, height: 1),
            .init(x: 0, y: .infinity, width: 1, height: 1),
        ] {
            XCTAssertThrowsError(try bad.validate())
        }
        // Off-canvas rectangles are allowed and clipped at the canvas, not clamped/repositioned.
        try WSSRainRegion(x: -100, y: -100, width: 100, height: 100).validate()
        XCTAssertThrowsError(
            try WSSRainPopulation(
                .init(
                    region: .init(x: 0, y: 0, width: 6400, height: 3600), rain: .init(density: 2000)
                )))
        let node = WSSSceneLayer.rain(.init(region: region, rain: .init(density: 2000)))
        XCTAssertThrowsError(
            try WSSScene(width: 1920, height: 1080, layers: [node, node]).validate())
    }
    func testDirectionsDeterministicDepthMotionAndWrap() throws {
        for (angle, expected): (Float, SIMD2<Float>) in [
            (0, SIMD2(0, -1)), (90, SIMD2(1, 0)), (180, SIMD2(0, 1)), (270, SIMD2(-1, 0)),
            (45, SIMD2(sqrt(0.5), -sqrt(0.5))),
        ] {
            let e = WSSRainEffect(direction: angle, speed: 10)
            XCTAssertEqual(e.velocity.x, expected.x * 10, accuracy: 0.0001)
            XCTAssertEqual(e.velocity.y, expected.y * 10, accuracy: 0.0001)
        }
        let a = try population()
        let b = try population()
        XCTAssertEqual(a.instances, b.instances)
        XCTAssertNotEqual(a.instances, try population(.init(seed: 2)).instances)
        XCTAssertEqual(a.nominalCount, 207)
        XCTAssertGreaterThan(a.instances.count, a.nominalCount)
        XCTAssertEqual(MemoryLayout<WSSRainInstance>.stride, 32)
        XCTAssertEqual(Set(a.instances.map { Int($0.state.z) }), Set(0..<8))
        for instance in a.instances {
            let p = instance.state
            XCTAssertTrue((0..<1).contains(p.x) && (0..<1).contains(p.y))
            XCTAssertTrue((0.08...0.24).contains(p.w))
            let scale = WSSRainPopulation.depthScale(Int(p.z))
            XCTAssertTrue((0.65...1.35).contains(scale))
        }
        XCTAssertLessThan(WSSRainPopulation.depthScale(0), WSSRainPopulation.depthScale(7))
        for i in a.instances.indices {
            XCTAssertEqual(a.position(i, at: 1), b.position(i, at: 1))
            let dt = Float(0.00001)
            let diff = a.position(i, at: Double(dt)) - a.position(i, at: 0)
            XCTAssertEqual(diff.x, 0, accuracy: 0.001)
            XCTAssertEqual(
                diff.y, -900 * WSSRainPopulation.depthScale(Int(a.instances[i].state.z)) * dt,
                accuracy: 0.001)
        }
        for group in 0..<8 {
            let period = Double(a.travelSpan) / (900 * Double(WSSRainPopulation.depthScale(group)))
            XCTAssertLessThan(a.phase(at: period - 1e-6, group: group), 1)
            XCTAssertLessThan(a.phase(at: period + 1e-6, group: group), 0.0001)
            for time in [0.0, 60, 1e12, Double.greatestFiniteMagnitude] {
                let phase = a.phase(at: time, group: group)
                XCTAssertTrue(phase.isFinite && phase >= 0 && phase <= 1)
            }
        }
        let stopped = try population(.init(speed: 0))
        XCTAssertEqual(stopped.position(0, at: 0), stopped.position(0, at: 1e12))
        XCTAssertNotEqual(a.position(0, at: 0), a.position(0, at: 0.2))
        // Wrap points lie outside the region with enough clearance for the longest streak.
        XCTAssertGreaterThan(a.travelSpan - region.height, 32 * 1.35)
    }
    func testDensityAndAnimationPolicy() throws {
        for (w, h, n) in [(1920, 1080, 207), (3840, 2160, 829), (6400, 3600, 2304)] {
            let p = try WSSRainPopulation(
                .init(region: .init(x: 0, y: 0, width: Float(w), height: Float(h))))
            XCTAssertEqual(p.nominalCount, n)
        }
        var l = WSSRainLayer(region: region)
        func scene(_ l: WSSRainLayer) -> WSSScene {
            WSSScene(width: 1920, height: 1080, layers: [.rain(l)])
        }
        XCTAssertTrue(scene(l).isAnimated)
        l.visible = false
        XCTAssertFalse(scene(l).isAnimated)
        l.visible = true
        l.rain.speed = 0
        XCTAssertFalse(scene(l).isAnimated)
        l.rain.speed = 900
        l.rain.density = 0
        XCTAssertFalse(scene(l).isAnimated)
    }
    func testStrictDocumentAndBackwardCompatibility() throws {
        let bytes = try Data(contentsOf: fixture.appendingPathComponent("scene.wss.json"))
        let doc = try JSONDecoder().decode(WSSSceneDocumentV1.self, from: bytes)
        let scene = try doc.scene()
        guard case .image = scene.layers[0], case .rain = scene.layers[1],
            case .image = scene.layers[2]
        else { return XCTFail("ordered nodes") }
        let original = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        for change: (inout [String: Any]) -> Void in [
            { $0["type"] = "snow" }, { $0["unknown"] = 1 }, { $0["composition"] = "replace" },
            {
                var r = $0["rain"] as! [String: Any]
                r["wind"] = 1
                $0["rain"] = r
            },
            {
                var r = $0["region"] as! [String: Any]
                r["depth"] = 1
                $0["region"] = r
            },
            {
                var r = $0["rain"] as! [String: Any]
                r["opacity"] = ["min": 0, "max": 1, "curve": 2]
                $0["rain"] = r
            },
            { $0["type"] = NSNull() },
        ] {
            var json = original
            var layers = json["layers"] as! [[String: Any]]
            change(&layers[1])
            json["layers"] = layers
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    WSSSceneDocumentV1.self, from: JSONSerialization.data(withJSONObject: json)
                ).scene())
        }
        let old = WSSCloudsFixtureTests().fixture
        _ = try WSSSceneDocumentV1.load(
            entry: old.appendingPathComponent("scene.wss.json"), root: old
        ).scene()
    }
    func testGPUCompositionsOrderClippingCloudsAndLongTime() async throws {
        let r = try await fixtureResources()
        let helper = WSSCloudsTests()
        let a = try helper.render(r, time: 0, width: 960, height: 540).0
        XCTAssertNotEqual(a, try helper.render(r, time: 0.2, width: 960, height: 540).0)
        XCTAssertEqual(a, try helper.render(r, time: 0, width: 960, height: 540).0)
        var baseline = r.scene
        baseline.layers.remove(at: 1)
        let base = try WSSStaticResources(
            scene: baseline, assets: WSSNativeAssets(root: fixture), device: r.device)
        let b = try helper.render(base, width: 960, height: 540).0
        var changes = 0
        for y in 0..<540 {
            for x in 0..<960 {
                let p = (y * 960 + x) * 4
                XCTAssertEqual(a[p + 3], 255)
                if a[p..<p + 3] != b[p..<p + 3] { changes += 1 }
                if (220..<300).contains(x) && y > 120 { XCTAssertEqual(a[p..<p + 4], b[p..<p + 4]) }
            }
        }
        XCTAssertGreaterThan(changes, 100)
        // Native blend contract, tested over a partially transparent image and clear alpha=0.
        let rain = try XCTUnwrap(r.rain?.layers[1]?.population.layer)
        var only = WSSScene(width: 1920, height: 1080, layers: [.rain(rain)])
        let noAssets = WSSStaticTests.Assets(values: [:])
        _ = try helper.render(
            WSSStaticResources(scene: only, assets: noAssets, device: r.device), time: 1e12)
        for direction: Float in [0, 90, 180, 270, 35] {
            var l = rain
            l.rain.direction = direction
            l.rain.width = 8
            l.rain.length = 256
            l.rain.density = 500
            only.layers = [.rain(l)]
            _ = try helper.render(
                WSSStaticResources(scene: only, assets: noAssets, device: r.device), time: 3600)
        }
        var cloudy = r.scene
        if case .image(var image) = cloudy.layers[0] {
            image.effects = [.clouds(.init())]
            cloudy.layers[0] = .image(image)
        }
        _ = try helper.render(
            WSSStaticResources(
                scene: cloudy, assets: WSSNativeAssets(root: fixture), device: r.device))
        var additive = r.scene
        var add = rain
        add.composition = .additive
        additive.layers[1] = .rain(add)
        let addResources = try WSSStaticResources(
            scene: additive, assets: WSSNativeAssets(root: fixture), device: r.device)
        let c = try helper.render(addResources, width: 960, height: 540).0
        var brighter = 0
        for p in stride(from: 0, to: a.count, by: 4) {
            XCTAssertEqual(a[p + 3], c[p + 3])
            for channel in 0..<3 {
                XCTAssertGreaterThanOrEqual(c[p + channel], a[p + channel])
                if c[p + channel] > a[p + channel] { brighter += 1 }
            }
        }
        XCTAssertGreaterThan(brighter, 100)
        for t in [1e12, Double.greatestFiniteMagnitude] {
            _ = try helper.render(r, time: t, width: 320, height: 180)
        }
        for bad in [Double.nan, .infinity, -1] {
            XCTAssertThrowsError(try helper.render(r, time: bad))
        }
    }
    func testFixturePerformance() async throws {
        let original = try await fixtureResources()
        let helper = WSSCloudsTests()
        for density: Float in [100, 2000] {
            var scene = original.scene
            guard case .rain(var layer) = scene.layers[1] else { return XCTFail("rain") }
            layer.rain.density = density
            scene.layers[1] = .rain(layer)
            let r = try WSSStaticResources(
                scene: scene, assets: WSSNativeAssets(root: fixture), device: original.device)
            let p = try XCTUnwrap(r.rain?.layers[1]?.population)
            for width in [1920, 3840, 6400] {
                for fps in [30, 60] {
                    var ms = 0.0
                    for frame in 0..<8 {
                        let duration = try helper.render(
                            r, time: Double(frame) / Double(fps), width: width,
                            height: width * 9 / 16
                        ).1
                        if frame >= 2 { ms += duration }
                    }
                    print(
                        "Rain GPU: \(width)x\(width*9/16), \(fps)fps sample times, density \(density), nominal \(p.nominalCount), instances \(p.instances.count), buffer \(r.bufferBytes) bytes, 3 draws, mean \(ms/6) ms"
                    )
                }
            }
        }
    }
    @MainActor func testManagedImportPlaybackPauseResolutionAndFPS() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("Display required") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WSSRain-" + UUID().uuidString
        ).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source")
        try FileManager.default.copyItem(at: fixture, to: source)
        let suite = "WSSRain-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in ["conserve", "pauseOnBattery", "allDisplays"] {
            defaults.set(false, forKey: key)
        }
        let lib = Library(
            storage: root.appendingPathComponent("Support/library.json"), defaults: defaults)
        defer { lib.stop() }
        lib.importURLs([source])
        for _ in 0..<500 {
            if !lib.importing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(lib.message)
        let item = try XCTUnwrap(lib.items.first)
        XCTAssertEqual(item.ownership, .managed)
        XCTAssertEqual(item.sceneSource, .nativeWSS)
        try FileManager.default.removeItem(at: source)
        lib.apply(item)
        let helper = WSSNativeSceneTests()
        var player = try await helper.running(lib)
        XCTAssertGreaterThan(player.metrics.snapshot().frames, 0)
        let population = try XCTUnwrap(player.resources.rain?.layers[1]?.population)
        let buffer = try XCTUnwrap(player.resources.rain?.layers[1]?.buffer)
        let start = player.elapsed
        for mode in [SceneRenderResolution.standard, .hiDPI, .standard] {
            lib.sceneRenderResolution = mode
            XCTAssertTrue(player.resources.rain?.layers[1]?.buffer === buffer)
            XCTAssertEqual(
                player.resources.rain?.layers[1]?.population.instances, population.instances)
            XCTAssertGreaterThanOrEqual(player.elapsed, start)
        }
        let resources = player.resources
        player.view.frame.size = CGSize(width: 800, height: 450)
        player.setRenderResolution(.hiDPI)
        XCTAssertTrue(player.resources === resources)
        XCTAssertTrue(player.resources.rain?.layers[1]?.buffer === buffer)
        var frames: [Data] = []
        for fps in [30, 60] {
            lib.sceneFPS = fps
            player = try await helper.running(lib)
            XCTAssertEqual(player.view.preferredFramesPerSecond, fps)
            frames.append(
                try WSSCloudsTests().render(player.resources, time: 2, width: 320, height: 180).0)
        }
        XCTAssertEqual(frames[0], frames[1])
        lib.manuallyPaused = true
        let frozen = player.elapsed
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(player.elapsed, frozen)
        XCTAssertTrue(lib.renderers.allSatisfy { !$0.hasLiveResources })
        lib.manuallyPaused = false
        let resumed = try await helper.running(lib)
        XCTAssertGreaterThanOrEqual(resumed.elapsed, frozen - 0.02)
        XCTAssertLessThan(resumed.elapsed, frozen + 0.3)
        XCTAssertEqual(
            resumed.resources.rain?.layers[1]?.population.instances, population.instances)
        XCTAssertNil(lib.message)
        print(
            "Rain managed E2E: source removed; live frames; resize/Standard/HiDPI retain buffer; 30/60 FPS; pause excludes 400ms; deterministic resume"
        )
    }
    func testPhaseSeamHasNoVisibleJumpAndExportFrame() async throws {
        let r = try await fixtureResources()
        let p = try XCTUnwrap(r.rain?.layers[1]?.population)
        let helper = WSSCloudsTests()
        for group in 0..<8 {
            let period = Double(p.travelSpan) / (900 * Double(WSSRainPopulation.depthScale(group)))
            let a = try helper.render(r, time: period - 0.00001, width: 960, height: 540).0
            let b = try helper.render(r, time: period + 0.00001, width: 960, height: 540).0
            let mae =
                zip(a, b).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(a.count)
            XCTAssertLessThan(mae, 0.01)
        }
        if let path = ProcessInfo.processInfo.environment["AMBIENT_WSS_RAIN_QA"] {
            let bytes = try helper.render(r, time: 1, width: 1920, height: 1080).0
            let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
            let image = try XCTUnwrap(
                CGImage(
                    width: 1920, height: 1080, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: 1920 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                        .union(.byteOrder32Little), provider: provider, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent))
            let output = try XCTUnwrap(
                CGImageDestinationCreateWithURL(
                    URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(output, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(output))
        }
    }

    func testNativeAdditiveAlphaRemainsSourceOverOnTransparentTarget() throws {
        let device = try WSSStaticTests().device()
        let id = WSSAssetID(value: "own/solid")
        let assets = WSSStaticTests.Assets(values: [id: WSSStaticTests().solid([80, 40, 20, 128])])
        let image = WSSImageLayer(
            asset: id, transform: .init(center: SIMD2(128, 128), size: SIMD2(256, 256)))
        var rain = WSSRainLayer(
            region: .init(x: 0, y: 0, width: 256, height: 256),
            rain: .init(density: 1000, length: 64, width: 8, opacity: .init(min: 0.4, max: 0.4)))
        var scene = WSSScene(width: 256, height: 256, layers: [.image(image), .rain(rain)])
        let helper = WSSCloudsTests()
        let over = try helper.render(
            WSSStaticResources(scene: scene, assets: assets, device: device), width: 256,
            height: 256, clearAlpha: 0
        ).0
        rain.composition = .additive
        scene.layers[1] = .rain(rain)
        let add = try helper.render(
            WSSStaticResources(scene: scene, assets: assets, device: device), width: 256,
            height: 256, clearAlpha: 0
        ).0
        var affected = 0
        for p in stride(from: 0, to: over.count, by: 4) {
            XCTAssertEqual(over[p + 3], add[p + 3])
            if over[p + 3] > 140 && over[p + 3] < 250 {
                affected += 1
                XCTAssertGreaterThan(add[p + 2], over[p + 2])
            }
        }
        XCTAssertGreaterThan(affected, 100)
    }

}
