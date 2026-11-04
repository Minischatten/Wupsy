import ImageIO
import MetalKit
import UniformTypeIdentifiers
import XCTest

@testable import Wupsy

final class WSSRippleTests: XCTestCase {
    let image = WSSAssetID(value: "image")
    let mask = WSSAssetID(value: "mask")
    func resources(
        _ effect: WSSRippleEffect?, maskValues: [UInt8]? = nil,
        opacity: Float = 1, over: Bool = false, alpha: UInt8 = 255
    ) throws -> WSSStaticResources {
        var bytes = Data()
        for y in 0..<64 {
            for x in 0..<64 { bytes.append(contentsOf: [UInt8(x * 3), UInt8(y * 3), 60, alpha]) }
        }
        var values = [image: WSSImageAsset(width: 64, height: 64, payload: .rgba8(bytes))]
        if let maskValues {
            values[mask] = WSSImageAsset(
                width: 64, height: 64,
                payload: .rgba8(Data(maskValues.flatMap { [$0, 0, 0, 255] })))
        }
        return try WSSStaticResources(
            scene: WSSScene(
                width: 64, height: 64,
                layers: [
                    WSSImageLayer(
                        asset: image,
                        transform: WSSImageTransform(center: SIMD2(32, 32), size: SIMD2(64, 64)),
                        opacity: opacity, composition: over ? .sourceOver : .replace,
                        effects: effect.map { [.ripple($0)] } ?? [])
                ]), assets: WSSStaticTests.Assets(values: values), device: WSSStaticTests().device()
        )
    }
    func render(_ r: WSSStaticResources, time: Double = 0, size: Int = 64) throws -> Data {
        try WSSCloudsTests().render(r, time: time, width: size, height: size, clearAlpha: 0).0
    }
    func testBoundsAndNonfiniteValues() throws {
        for change: (inout WSSRippleEffect) -> Void in [
            { $0.amplitude = -1 }, { $0.amplitude = 257 }, { $0.wavelength = 0 },
            { $0.wavelength = 8193 }, { $0.stretch = 0 }, { $0.stretch = 9 },
            { $0.direction = -1 }, { $0.direction = 360 }, { $0.travelSpeed = -1 },
            { $0.travelSpeed = 4097 }, { $0.evolutionRate = -1 }, { $0.evolutionRate = 9 },
            { $0.amplitude = .nan }, { $0.wavelength = .infinity }, { $0.stretch = .nan },
            { $0.direction = .infinity }, { $0.travelSpeed = .nan },
            { $0.evolutionRate = .infinity },
            { $0.mask = WSSImageMask(asset: WSSAssetID(value: "")) },
        ] {
            var effect = WSSRippleEffect()
            change(&effect)
            XCTAssertThrowsError(try effect.validate())
        }
        let e = WSSRippleEffect()
        for t in [-1, Double.nan, .infinity] {
            XCTAssertThrowsError(try e.displacement(at: .zero, time: t))
        }
    }
    func testDeterminismDriftEvolutionAndAmplitudeBound() throws {
        let p = SIMD2<Double>(26, 19)
        var e = WSSRippleEffect(
            amplitude: 4, wavelength: 24, direction: 90, travelSpeed: 8, evolutionRate: 0)
        let initial = try e.displacement(at: p, time: 0)
        XCTAssertEqual(initial, try e.displacement(at: p, time: 0))
        XCTAssertNotEqual(initial, try e.displacement(at: p, time: 1))
        e.seed = 2
        XCTAssertNotEqual(initial, try e.displacement(at: p, time: 0))
        e.travelSpeed = 0
        e.evolutionRate = 1
        XCTAssertNotEqual(try e.displacement(at: p, time: 0), try e.displacement(at: p, time: 1))
        e.travelSpeed = 8
        XCTAssertNotEqual(try e.displacement(at: p, time: 0), try e.displacement(at: p, time: 1))
        e.evolutionRate = 0
        e.travelSpeed = 0
        XCTAssertEqual(
            try e.displacement(at: p, time: 0), try e.displacement(at: p, time: 100_000_000))
        for time in [0.0, 1, 8, 1e9] {
            let d = try e.displacement(at: p, time: time)
            XCTAssertLessThanOrEqual(simd_length(d), e.amplitude + 0.0001)
        }
    }
    func testCardinalVisibleFieldTranslationCPUAndGPU() throws {
        for (direction, dx, dy): (Float, Int, Int) in [
            (0, 0, -8), (90, 8, 0), (180, 0, 8), (270, -8, 0),
        ] {
            let e = WSSRippleEffect(
                amplitude: 5, wavelength: 24, direction: direction, travelSpeed: 8, evolutionRate: 0
            )
            let p = SIMD2<Double>(24.5, 24.5)
            let a = try e.displacement(at: p, time: 0)
            let b = try e.displacement(at: p + SIMD2(Double(dx), Double(dy)), time: 1)
            XCTAssertEqual(a.x, b.x, accuracy: 0.00001)
            XCTAssertEqual(a.y, b.y, accuracy: 0.00001)
            let r = try resources(e)
            let start = try render(r)
            let moved = try render(r, time: 1)
            // Coordinate-colored image reveals the GPU displacement field. Compare
            // translated locations after subtracting their unwarped image coordinate.
            for y in stride(from: 16, to: 40, by: 4) {
                for x in stride(from: 16, to: 40, by: 4) {
                    let i = (y * 64 + x) * 4
                    let j = ((y + dy) * 64 + x + dx) * 4
                    XCTAssertEqual(
                        Double(Int(moved[j + 2]) - dx * 3), Double(start[i + 2]), accuracy: 1)
                    XCTAssertEqual(
                        Double(Int(moved[j + 1]) - dy * 3), Double(start[i + 1]), accuracy: 1)
                }
            }
        }
    }
    func testGPUTimeModesSeedAndLongRun() throws {
        for (speed, evolution): (Float, Float) in [(8, 0), (0, 1), (8, 1), (0, 0)] {
            let e = WSSRippleEffect(
                amplitude: 8, wavelength: 24, travelSpeed: speed, evolutionRate: evolution)
            let r = try resources(e)
            let a = try render(r)
            let b = try render(r, time: 2)
            XCTAssertEqual(a, try render(r))
            if speed == 0 && evolution == 0 {
                XCTAssertEqual(a, b)
            } else {
                XCTAssertNotEqual(a, b)
            }
            _ = try render(r, time: 1e9)
            var other = e
            other.seed += 1
            XCTAssertNotEqual(a, try render(resources(other)))
            let waves = e.waves
            for wave in waves { XCTAssertTrue(try e.phase(wave, at: 1e9).isFinite) }
            // Continuity at a long-running clock and across each component wrap.
            for wave in waves {
                let frequency =
                    -simd_dot(wave.k, e.velocity)
                    + wave.evolution * Double(e.evolutionRate)
                let phase0 = try e.phase(wave, at: 1e9)
                let phase1 = try e.phase(wave, at: 1e9 + 1.0 / 60)
                XCTAssertEqual(
                    sin(Double(phase1)),
                    sin(Double(phase0) + frequency * 2 * .pi / 60), accuracy: 0.00001)
                if frequency != 0 {
                    let wrap = 1 / abs(frequency)
                    let before = try e.phase(wave, at: wrap - 0.000001)
                    let after = try e.phase(wave, at: wrap + 0.000001)
                    XCTAssertEqual(sin(before), sin(after), accuracy: 0.0001)
                }
            }
        }
    }
    func testNullAmplitudeNullMaskMissingAndAbsentMask() throws {
        let base = try render(resources(nil))
        XCTAssertEqual(base, try render(resources(WSSRippleEffect(amplitude: 0)), time: 8))
        var e = WSSRippleEffect()
        e.mask = WSSImageMask(asset: mask)
        XCTAssertEqual(
            base, try render(resources(e, maskValues: [UInt8](repeating: 0, count: 4096)), time: 4))
        XCTAssertThrowsError(try resources(e))
        e.mask = nil
        XCTAssertNotEqual(base, try render(resources(e), time: 4))
    }
    func testHardSoftMasksAndOutsideStability() throws {
        let e = WSSRippleEffect(amplitude: 8, wavelength: 24, mask: WSSImageMask(asset: mask))
        let levels: [UInt8] = [0, 64, 128, 255]
        let masks = levels.map { [UInt8](repeating: $0, count: 4096) }
        let frames = try masks.map { try render(resources(e, maskValues: $0), time: 1) }
        let base = try render(resources(nil))
        XCTAssertEqual(base, frames[0])
        for y in 16..<48 {
            for x in 16..<48 {
                for c in [1, 2] {
                    let i = (y * 64 + x) * 4 + c
                    let full = Double(Int(frames[3][i]) - Int(base[i]))
                    for j in [1, 2] {
                        XCTAssertEqual(
                            Double(Int(frames[j][i]) - Int(base[i])),
                            full * Double(levels[j]) / 255, accuracy: 1.5)
                    }
                }
            }
        }
        let hard = (0..<4096).map { UInt8($0 % 64 < 32 ? 0 : 255) }
        let soft = (0..<4096).map { UInt8(max(0, min(255, ($0 % 64 - 16) * 8))) }
        for values in [hard, soft] {
            let r = try resources(e, maskValues: values)
            for time in [0.0, 1, 2, 4, 8] {
                let frame = try render(r, time: time)
                for y in 0..<64 {
                    for x in 0..<15 {
                        let i = (y * 64 + x) * 4
                        XCTAssertEqual(frame[i..<i + 4], base[i..<i + 4])
                    }
                }
            }
        }
    }
    func testDensityOpacityAlphaAndClock() throws {
        let e = WSSRippleEffect(amplitude: 5, wavelength: 24)
        let r = try resources(e)
        let standard = try render(r, time: 2)
        let hidpi = try render(r, time: 2, size: 128)
        // Compare spatially corresponding interior samples (half-pixel offset bounded).
        for y in 12..<52 {
            for x in 12..<52 {
                for c in [1, 2] {
                    XCTAssertEqual(
                        Double(standard[(y * 64 + x) * 4 + c]),
                        Double(hidpi[((y * 2) * 128 + x * 2) * 4 + c]), accuracy: 4)
                }
            }
        }
        for over in [true, false] {
            let alpha = try render(resources(e, opacity: 0.5, over: over, alpha: 128))
            for i in stride(from: 3, to: alpha.count, by: 4) {
                XCTAssertEqual(Double(alpha[i]), 64, accuracy: 1)
            }
        }
        var clock = WSSPlaybackClock()
        clock.play(now: 100)
        clock.stop(now: 102)
        let before = try render(r, time: clock.time(now: 200))
        clock.play(now: 200)
        XCTAssertEqual(before, try render(r, time: clock.time(now: 200)))
        XCTAssertNotEqual(before, try render(r, time: clock.time(now: 201)))
        XCTAssertEqual(
            SceneRenderResolution.standard.drawableSize(
                bounds: CGSize(width: 64, height: 64), backing: CGSize(width: 128, height: 128),
                maxDimension: 8192
            ).width, 64)
        XCTAssertEqual(
            SceneRenderResolution.hiDPI.drawableSize(
                bounds: CGSize(width: 64, height: 64), backing: CGSize(width: 128, height: 128),
                maxDimension: 8192
            ).width, 128)
    }
    func effectJSON() -> [String: Any] {
        [
            "type": "ripple", "amplitude": 6, "wavelength": 120, "stretch": 1, "direction": 180,
            "travelSpeed": 20, "evolutionRate": 0.2, "seed": 1,
        ]
    }
    func testDocumentStrictFieldsNumbersAndPaths() throws {
        let helper = WSSNativeSceneTests()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        func document(_ effect: [String: Any]) -> [String: Any] {
            var d = helper.document()
            var layers = d["layers"] as! [[String: Any]]
            layers[0]["effects"] = [effect]
            d["layers"] = layers
            return d
        }
        let folder = try helper.fixture(document(effectJSON()))
        let entry = folder.appendingPathComponent("scene.wss.json")
        func load(_ e: [String: Any]) throws -> WSSScene {
            try JSONSerialization.data(withJSONObject: document(e)).write(to: entry)
            return try WSSSceneDocumentV1.load(entry: entry, root: folder).scene()
        }
        guard case .ripple = try load(effectJSON()).testImages[0].effects.first else {
            return XCTFail("ripple")
        }
        for (key, value): (String, Any) in [
            ("unknown", 1), ("velocity", [1, 2]), ("amplitude", -1), ("wavelength", 0),
            ("seed", -1), ("stretch", NSNull()), ("direction", 360), ("travelSpeed", true),
            ("evolutionRate", "NaN"), ("amplitude", "Infinity"),
        ] {
            var e = effectJSON()
            e[key] = value
            XCTAssertThrowsError(try load(e))
        }
        for key in [
            "amplitude", "wavelength", "stretch", "direction", "travelSpeed", "evolutionRate",
            "seed",
        ] {
            var e = effectJSON()
            e.removeValue(forKey: key)
            XCTAssertThrowsError(try load(e))
        }
        for path in ["../mask.png", "/mask.png", "assets/../mask.png", "assets\\mask.png"] {
            var e = effectJSON()
            e["mask"] = path
            XCTAssertThrowsError(try load(e))
        }
        var e = effectJSON()
        e["mask"] = "assets/missing.png"
        let scene = try load(e)
        XCTAssertThrowsError(
            try WSSStaticResources(
                scene: scene, assets: WSSNativeAssets(root: folder),
                device: WSSStaticTests().device()))
        let link = folder.appendingPathComponent("assets/link.png")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: folder.appendingPathComponent("assets/mask.png"))
        e["mask"] = "assets/link.png"
        XCTAssertThrowsError(
            try WSSStaticResources(
                scene: load(e), assets: WSSNativeAssets(root: folder),
                device: WSSStaticTests().device()))
    }
    func writePNG(_ data: Data, width: Int, height: Int, to url: URL) throws {
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                    .union(.byteOrder32Little), provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent))
        let out = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(out, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(out))
    }
    func testFixtureDiagnosticsPerformanceAndShore() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
                "Test-Wallpaper/WSS-Ripple-v1")
        var scene = try WSSSceneDocumentV1.load(
            entry: root.appendingPathComponent("scene.wss.json"), root: root
        ).scene()
        let assets = WSSNativeAssets(root: root)
        let device = try WSSStaticTests().device()
        let r = try WSSStaticResources(scene: scene, assets: assets, device: device)
        let output = ProcessInfo.processInfo.environment["AMBIENT_RIPPLE_QA"].map {
            URL(fileURLWithPath: $0)
        }
        if let output {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        }
        var baseScene = scene
        baseScene.testImages[0].effects = []
        let base = try WSSStaticResources(scene: baseScene, assets: assets, device: device)
        let reference = try WSSCloudsTests().render(base, width: 960, height: 540).0
        let maskAsset = try assets.mask(for: WSSAssetID(value: "assets/mask.png"))
        var changes = 0
        var shoreEdges: [Int] = []
        for t in [0.0, 1, 2, 4, 8] {
            let frame = try WSSCloudsTests().render(r, time: t, width: 960, height: 540).0
            for y in 0..<540 {
                for x in 0..<960 {
                    let pixel = y * 960 + x
                    let i = pixel * 4
                    // Pixel centers align with authored mask texels.
                    if maskAsset.pixels[pixel] == 0 {
                        XCTAssertEqual(frame[i..<i + 4], reference[i..<i + 4])
                    }
                    if frame[i..<i + 4] != reference[i..<i + 4] { changes += 1 }
                }
            }
            let edge = (225..<265).first { y in
                let i = (y * 960 + 680) * 4
                return frame[i + 2] > 180 && frame[i + 1] > 160 && frame[i] < 190
            }
            if let edge { shoreEdges.append(edge) }
            if let output {
                try writePNG(
                    frame, width: 960, height: 540,
                    to: output.appendingPathComponent("t\(Int(t)).png"))
                var crop = Data()
                for y in 210..<490 { crop.append(frame[(y * 960 + 490) * 4..<(y * 960 + 875) * 4]) }
                try writePNG(
                    crop, width: 385, height: 280,
                    to: output.appendingPathComponent("shore-t\(Int(t)).png"))
            }
        }
        XCTAssertGreaterThan(changes, 0)
        XCTAssertGreaterThan(Set(shoreEdges).count, 1)
        print("RIPPLE SHORE upper rim y at t0/1/2/4/8: \(shoreEdges)")
        guard let output else { return }
        var effect: WSSRippleEffect
        guard case .ripple(let e) = scene.testImages[0].effects[0] else { return XCTFail() }
        effect = e
        for (label, speed, evolution): (String, Float, Float) in [
            ("drift-only", 35, 0), ("evolution-only", 0, 0.35), ("static", 0, 0),
        ] {
            effect.travelSpeed = speed
            effect.evolutionRate = evolution
            scene.testImages[0].effects = [.ripple(effect)]
            let variant = try WSSStaticResources(scene: scene, assets: assets, device: device)
            for t in [0.0, 2, 8] {
                try writePNG(
                    WSSCloudsTests().render(variant, time: t, width: 960, height: 540).0,
                    width: 960, height: 540,
                    to: output.appendingPathComponent("\(label)-t\(Int(t)).png"))
            }
        }
        effect = e
        for direction: Float in [0, 90, 180, 270] {
            effect.direction = direction
            effect.evolutionRate = 0
            scene.testImages[0].effects = [.ripple(effect)]
            let variant = try WSSStaticResources(scene: scene, assets: assets, device: device)
            try writePNG(
                WSSCloudsTests().render(variant, time: 2, width: 960, height: 540).0, width: 960,
                height: 540, to: output.appendingPathComponent("direction-\(Int(direction))-t2.png")
            )
        }
        try writePNG(
            reference, width: 960, height: 540,
            to: output.appendingPathComponent("zero-amplitude.png"))
        try writePNG(
            Data(maskAsset.pixels.flatMap { [$0, $0, $0, 255] }), width: 960, height: 540,
            to: output.appendingPathComponent("mask.png"))
        print("RIPPLE DEVICE \(device.name)")
        for (w, h) in [(3840, 2160), (6400, 3600)] {
            var timings: [Double] = []
            for i in 0..<12 {
                let ms = try WSSCloudsTests().render(r, time: Double(i) / 30, width: w, height: h).1
                if i >= 2 { timings.append(ms) }
            }
            print(
                "RIPPLE PERF \(w)x\(h): GPU mean \(timings.reduce(0,+)/Double(timings.count)) ms; min \(timings.min()!) max \(timings.max()!); 1 draw, 2 samples, zero intermediates; total texture bytes \(r.textureBytes); ripple bytes \(r.ripple!.textureBytes)"
            )
        }
    }
}
