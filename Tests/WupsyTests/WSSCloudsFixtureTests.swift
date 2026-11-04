import ImageIO
import MetalKit
import UniformTypeIdentifiers
import XCTest

@testable import Wupsy

final class WSSCloudsFixtureTests: XCTestCase {
    var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Test-Wallpaper/WSS-Clouds-v1")
    }
    func resources(_ folder: URL) async throws -> WSSStaticResources {
        let item = try WallpaperImporter.resolve(folder)
        guard case .wss = item.playbackMode else { throw WSSDocumentError.invalid("not native") }
        return try await WSSStaticPreparation.shared.prepare(item)
    }
    func testRealFixtureDocumentAssetsAndMask() throws {
        let item = try WallpaperImporter.resolve(fixture)
        XCTAssertEqual(item.sceneSource, .nativeWSS)
        XCTAssertNil(item.scenePlaybackMode)
        let doc = try WSSSceneDocumentV1.load(entry: item.url, root: fixture)
        let scene = try doc.scene()
        XCTAssertEqual(scene.width, 1920)
        XCTAssertEqual(scene.height, 1080)
        XCTAssertEqual(scene.testImages.count, 1)
        guard case .clouds(let effect) = scene.testImages[0].effects.first else {
            return XCTFail("clouds")
        }
        XCTAssertEqual(effect.velocity, SIMD2(24, -3))
        XCTAssertEqual(effect.scale, 600)
        XCTAssertEqual(effect.intensity, 0.45)
        XCTAssertEqual(effect.density, 0.5)
        XCTAssertEqual(effect.seed, 7)
        let maskID = try XCTUnwrap(effect.mask?.asset)
        let assets = WSSNativeAssets(root: fixture)
        let image = try assets.image(for: scene.testImages[0].asset)
        XCTAssertEqual(image.width, 1920)
        XCTAssertEqual(image.height, 1080)
        let mask = try assets.mask(for: maskID)
        XCTAssertEqual(mask.width, 1920)
        XCTAssertEqual(mask.height, 1080)
        XCTAssertEqual(mask.pixels[430 * 1920], 255)
        XCTAssertEqual(mask.pixels[820 * 1920], 0)
        for y in 1..<1080 {
            let a = Int(mask.pixels[y * 1920])
            let b = Int(mask.pixels[(y - 1) * 1920])
            XCTAssertLessThanOrEqual(a, b)
            XCTAssertLessThanOrEqual(b - a, 1)
        }
        let paths = try FileManager.default.subpathsOfDirectory(atPath: fixture.path)
        XCTAssertEqual(
            Set(
                paths.filter {
                    !$0.hasSuffix("assets")
                        && URL(fileURLWithPath: $0).lastPathComponent != ".DS_Store"
                }),
            Set([
                "scene.wss.json", "assets/background.png", "assets/clouds-mask.png", "README.md",
            ]))
        print("Visual fixture: native DTO, two own PNG assets, smooth top-to-bottom scalar mask")
    }
    func testRealFixtureFramesMaskDirectionAndRasterDensity() async throws {
        let r = try await resources(fixture)
        var staticScene = r.scene
        staticScene.testImages[0].effects = []
        let baseline = try WSSStaticResources(
            scene: staticScene, assets: WSSNativeAssets(root: fixture), device: r.device)
        let helper = WSSCloudsTests()
        let base = try helper.render(baseline, width: 960, height: 540).0
        let a = try helper.render(r, width: 960, height: 540).0
        let b = try helper.render(r, time: 4, width: 960, height: 540).0
        XCTAssertNotEqual(a, b)
        var changed = 0
        for y in 0..<540 {
            for x in 0..<960 {
                let p = (y * 960 + x) * 4
                XCTAssertEqual(a[p + 3], 255)
                XCTAssertEqual(b[p + 3], 255)
                for c in 0..<3 {
                    // All source RGB is positive: this also catches black/invalid
                    // converted output. Float phases are checked independently below.
                    XCTAssertGreaterThanOrEqual(Int(a[p + c]), Int(base[p + c]) - 1)
                    XCTAssertGreaterThanOrEqual(Int(b[p + c]), Int(base[p + c]) - 1)
                }
                if y >= 420 {
                    XCTAssertEqual(a[p..<p + 4], base[p..<p + 4])
                    XCTAssertEqual(b[p..<p + 4], base[p..<p + 4])
                }
                if y < 200 && a[p] > base[p] { changed += 1 }
            }
        }
        XCTAssertGreaterThan(changed, 40_000)
        // Normalize out the static sky. At half resolution four seconds moves
        // the scalar fog 48 pixels right and six pixels up (top-left UV origin).
        func fog(_ bytes: Data, _ x: Int, _ y: Int) -> Double {
            let p = (y * 960 + x) * 4
            return Double(Int(bytes[p]) - Int(base[p])) / Double(255 - Int(base[p]))
        }
        var expected = 0.0
        var opposite = 0.0
        var count = 0.0
        for y in stride(from: 20, to: 190, by: 8) {
            for x in stride(from: 60, to: 900, by: 8) {
                expected += abs(fog(a, x, y) - fog(b, x + 48, y - 6))
                opposite += abs(fog(a, x, y) - fog(b, x - 48, y + 6))
                count += 1
            }
        }
        XCTAssertLessThan(expected / count, 0.006)
        XCTAssertLessThan(expected, opposite * 0.5)
        guard case .clouds(let effect) = r.scene.testImages[0].effects.first else {
            return XCTFail("clouds")
        }
        for time in [0.0, 4, 1e12] {
            let phase = try effect.phase(at: time)
            XCTAssertTrue(phase.x.isFinite && phase.y.isFinite)
        }
        let high = try helper.render(r, time: 4, width: 1920, height: 1080).0
        var error = 0.0
        var samples = 0.0
        // Average the four high-density pixel centres covering each standard pixel.
        for y in stride(from: 8, to: 532, by: 8) {
            for x in stride(from: 8, to: 952, by: 8) {
                for c in 0..<3 {
                    let sum = (0..<2).reduce(0) { row, dy in
                        row
                            + (0..<2).reduce(0) { value, dx in
                                value + Int(high[((y * 2 + dy) * 1920 + x * 2 + dx) * 4 + c])
                            }
                    }
                    error += abs(Double(sum) / 4 - Double(b[(y * 960 + x) * 4 + c]))
                    samples += 1
                }
            }
        }
        XCTAssertLessThan(error / samples, 1)
        print(
            "Visual fixture: mask null area unchanged; full area affected; motion right/up verified; raster MAE \(error/samples), direction error \(expected/count)"
        )
        if let folder = ProcessInfo.processInfo.environment["AMBIENT_WSS_FIXTURE_QA"] {
            for (name, bytes) in [
                ("clouds-fixture-0", a), ("clouds-fixture-4", b), ("clouds-fixture-base", base),
            ] {
                let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
                let image = try XCTUnwrap(
                    CGImage(
                        width: 960, height: 540, bitsPerComponent: 8,
                        bitsPerPixel: 32, bytesPerRow: 960 * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(
                            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                        ).union(.byteOrder32Little),
                        provider: provider, decode: nil, shouldInterpolate: false,
                        intent: .defaultIntent))
                let output = try XCTUnwrap(
                    CGImageDestinationCreateWithURL(
                        URL(fileURLWithPath: folder).appendingPathComponent(name + ".png") as CFURL,
                        UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(output, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(output))
            }
        }
    }
    @MainActor func testRealFixtureNormalImportManagedPlaybackFPSAndPause() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("Display required") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source")
        try FileManager.default.copyItem(at: fixture, to: source)
        let suite = "WSSFixture-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in ["conserve", "pauseOnBattery", "allDisplays"] {
            defaults.set(false, forKey: key)
        }
        let storage = root.appendingPathComponent("Support/library.json")
        let lib = Library(storage: storage, defaults: defaults)
        defer { lib.stop() }
        lib.importURLs([source])
        for _ in 0..<500 {
            if !lib.importing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(lib.message)
        let item = try XCTUnwrap(lib.items.first)
        XCTAssertEqual(item.sceneSource, .nativeWSS)
        XCTAssertEqual(item.ownership, .managed)
        XCTAssertEqual(lib.selected, item.id)
        XCTAssertNil(item.scenePlaybackMode)
        let saved =
            try JSONSerialization.jsonObject(with: Data(contentsOf: storage)) as! [[String: Any]]
        XCTAssertNil(saved[0]["scenePlaybackMode"])
        for name in ["scene.wss.json", "assets/background.png", "assets/clouds-mask.png"] {
            XCTAssertEqual(
                try Data(contentsOf: source.appendingPathComponent(name)),
                try Data(contentsOf: URL(fileURLWithPath: item.root).appendingPathComponent(name)))
        }
        try FileManager.default.removeItem(at: source)
        let support = await ScenePlayback.wssSupport(for: item)
        XCTAssertEqual(support, .supported)
        lib.apply(item)
        let helper = WSSNativeSceneTests()
        var p = try await helper.running(lib)
        XCTAssertEqual(p.resources.images.count, 1)
        XCTAssertEqual(p.resources.scene.testImages[0].effects.count, 1)
        let assets = WSSNativeAssets(root: URL(fileURLWithPath: item.root))
        guard case .clouds(let effect) = p.resources.scene.testImages[0].effects.first else {
            return XCTFail("clouds")
        }
        let mask = try assets.mask(for: XCTUnwrap(effect.mask?.asset))
        XCTAssertEqual(mask.pixels[0], 255)
        for mode in [SceneRenderResolution.standard, .hiDPI] {
            let time = p.elapsed
            let resources = p.resources
            lib.sceneRenderResolution = mode
            XCTAssertEqual(p.resolution, mode)
            XCTAssertTrue(p.resources === resources)
            XCTAssertGreaterThanOrEqual(p.elapsed, time)
        }
        var frames: [Data] = []
        for fps in [24, 60] {
            lib.sceneFPS = fps
            p = try await helper.running(lib)
            XCTAssertEqual(p.view.preferredFramesPerSecond, fps)
            frames.append(
                try WSSCloudsTests().render(p.resources, time: 4, width: 320, height: 180).0)
            XCTAssertFalse(p.view.isPaused)
        }
        XCTAssertEqual(frames[0], frames[1])
        lib.manuallyPaused = true
        let frozen = p.elapsed
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(p.elapsed, frozen)
        XCTAssertTrue(lib.renderers.allSatisfy { !$0.hasLiveResources })
        lib.manuallyPaused = false
        let resumed = try await helper.running(lib)
        XCTAssertGreaterThanOrEqual(resumed.elapsed, frozen - 0.02)
        XCTAssertLessThan(resumed.elapsed, frozen + 0.3)
        XCTAssertGreaterThan(resumed.metrics.snapshot().frames, 0)
        lib.remove(item)
        for _ in 0..<500 {
            if !lib.importing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(lib.items.isEmpty)
        XCTAssertNil(lib.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
        print(
            "Visual fixture E2E: normal Library import, source removed, managed playback, 24/60 FPS, resolution, pause/resume and removal passed"
        )
    }
}
