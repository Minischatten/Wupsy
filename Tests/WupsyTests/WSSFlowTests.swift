import MetalKit
import XCTest

@testable import Wupsy

final class WSSFlowTests: XCTestCase {
    let image = WSSAssetID(value: "image")
    let map = WSSAssetID(value: "map")
    struct Assets: WSSImageAssetSource {
        let base: WSSImageAsset
        let field: WSSFlowMapAsset
        func image(for id: WSSAssetID) throws -> WSSImageAsset {
            guard id.value == "image" else {
                throw WSSSceneError.invalid("unexpected image request")
            }
            return base
        }
        func flowMap(for id: WSSAssetID) throws -> WSSFlowMapAsset {
            guard id.value == "map" else { throw WSSSceneError.invalid("unexpected flow request") }
            return field
        }
    }
    func pixels(size: Int = 128, constant: Bool = false, alpha: UInt8 = 255) -> Data {
        var data = Data()
        for y in 0..<size {
            for x in 0..<size {
                let hash = UInt32(
                    truncatingIfNeeded: (x * 73_856_093) ^ (y * 19_349_663)
                        ^ ((x * y + 17) * 83_492_791))
                let value = constant ? 120 : Int(((hash ^ (hash >> 13)) &* 1_274_126_177) >> 24)
                data.append(contentsOf: [UInt8(value), UInt8(value), UInt8(value), alpha])
            }
        }
        return data
    }
    func field(_ rgba: [UInt8] = [255, 128, 0, 255]) throws -> WSSFlowMapAsset {
        try WSSFlowMapAsset.rgba(width: 1, height: 1, pixels: Data(rgba))
    }
    func resources(
        _ effects: [WSSImageEffect], field: WSSFlowMapAsset? = nil,
        base: Data? = nil, opacity: Float = 1
    ) throws -> WSSStaticResources {
        let scene = WSSScene(
            width: 128, height: 128,
            layers: [
                WSSImageLayer(
                    asset: image,
                    transform: WSSImageTransform(center: SIMD2(64, 64), size: SIMD2(128, 128)),
                    opacity: opacity, composition: .sourceOver, effects: effects)
            ])
        return try WSSStaticResources(
            scene: scene,
            assets: Assets(
                base: WSSImageAsset(width: 128, height: 128, payload: .rgba8(base ?? pixels())),
                field: try field ?? self.field()), device: WSSStaticTests().device())
    }
    var effect: WSSFlowEffect { WSSFlowEffect(flowMap: map, speed: 30, strength: 24) }
    func render(
        _ r: WSSStaticResources, time: Double = 0, size: Int = 128,
        context: WSSRippleRenderContext? = nil
    ) throws -> Data {
        try WSSRippleChainTests().render(r, context: context, time: time, width: size, height: size)
            .0
    }
    func testOwnPNGDataFormatPreservesNeutralMagnitudeAndTransparentRG() throws {
        XCTAssertEqual(WSSFlowMapAsset.component(128), 0)
        XCTAssertEqual(WSSFlowMapAsset.component(0), -1)
        XCTAssertEqual(WSSFlowMapAsset.component(255), 1)
        let bytes: [UInt8] = [128, 128, 0, 255, 255, 0, 0, 0, 160, 96, 0, 127]
        let png = try WSSNativeSceneTests().png(bytes, width: 3, height: 1)
        let asset = try WSSFlowMapAsset.decode(png)
        XCTAssertEqual(asset.coverage, Data([255, 0, 127]))
        try asset.validate()
        asset.vectors.withUnsafeBytes { raw in
            for (i, byte) in [128, 128, 255, 0, 160, 96].enumerated() {
                let word = raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)
                XCTAssertEqual(
                    Float(Float16(bitPattern: UInt16(littleEndian: word))),
                    WSSFlowMapAsset.component(UInt8(byte)), accuracy: 0.00025)
            }
        }
        XCTAssertThrowsError(
            try WSSFlowMapAsset.rgba(width: 1, height: 1, pixels: Data([128, 128, 1, 255])))
        XCTAssertThrowsError(try WSSFlowMapAsset.rgba(width: 8192, height: 8192, pixels: Data()))
        XCTAssertThrowsError(try WSSFlowMapAsset.decode(Data([1, 2, 3])))
        var invalid = png
        invalid[24] = 16
        XCTAssertThrowsError(try WSSFlowMapAsset.decode(invalid))
        let bad = WSSFlowMapAsset(
            width: 1, height: 1, vectors: Data([0, 124, 0, 0]), coverage: nil, isNeutral: false)
        XCTAssertThrowsError(try bad.validate())  // Float16 infinity
    }
    func testStrictDocumentVersionDefaultsAndOrderedStacks() throws {
        let mapJSON: [String: Any] = [
            "format": "wss-flow-rgba8", "version": 1, "asset": "assets/flow.png",
        ]
        func decode(_ value: [String: Any]) throws -> WSSImageEffect {
            try JSONDecoder().decode(
                WSSSceneDocumentV1.Effect.self,
                from: JSONSerialization.data(withJSONObject: value)
            ).native
        }
        let value: [String: Any] = ["type": "flow", "flowMap": mapJSON]
        XCTAssertEqual(
            try decode(value), .flow(WSSFlowEffect(flowMap: WSSAssetID(value: "assets/flow.png"))))
        for key in ["phase", "noise", "direction", "lateralDetail", "seed"] {
            var invalid = value
            invalid[key] = 1
            XCTAssertThrowsError(try decode(invalid))
        }
        for (key, items) in [("speed", [-1.0, 1025]), ("strength", [-1.0, 129])] {
            for number in items {
                var invalid = value
                invalid[key] = number
                XCTAssertThrowsError(try decode(invalid))
            }
        }
        var invalid = value
        invalid["speed"] = NSNull()
        XCTAssertThrowsError(try decode(invalid))
        for change: [String: Any] in [
            ["version": 2], ["format": "other"], ["asset": "../flow.png"], ["unknown": 1],
        ] {
            var ref = mapJSON
            for (k, v) in change { ref[k] = v }
            invalid = value
            invalid["flowMap"] = ref
            XCTAssertThrowsError(try decode(invalid))
        }
        let ripple = WSSRippleEffect(amplitude: 5, wavelength: 32)
        XCTAssertNoThrow(try resources([.flow(effect), .ripple(ripple)]))
        XCTAssertNoThrow(try resources([.ripple(ripple), .flow(effect)]))
        XCTAssertNoThrow(try resources([.flow(effect), .flow(effect)]))
        XCTAssertNoThrow(try resources([.flow(effect), .clouds(WSSCloudsEffect())]))
        XCTAssertNoThrow(try resources([.flow(effect), .ripple(ripple), .ripple(ripple)]))
        var bad = effect
        bad.speed = .nan
        XCTAssertThrowsError(try bad.validate())
        XCTAssertThrowsError(try effect.phase(at: .infinity))
        XCTAssertThrowsError(try effect.phase(at: -1))
    }
    func testNeutralStrengthZeroSpeedZeroAndIdentityChainAreByteExact() throws {
        let staticImage = try resources([])
        let original = try render(staticImage, time: 2)
        let neutral = try resources([.flow(effect)], field: field([128, 128, 0, 255]))
        var zeroStrength = effect
        zeroStrength.strength = 0
        var zeroSpeed = effect
        zeroSpeed.speed = 0
        for r in [
            neutral, try resources([.flow(zeroStrength)]), try resources([.flow(zeroSpeed)]),
            try resources([.flow(effect)], field: field([255, 128, 0, 0])),
        ] {
            XCTAssertEqual(try render(r, time: 2), original)
            XCTAssertTrue(r.stages(for: r.scene.imageLayers[0]).isEmpty)
        }
        let ripple = WSSRippleEffect(amplitude: 6, wavelength: 32, seed: 19)
        let single = try resources([.ripple(ripple)])
        let chain = try resources(
            [.flow(effect), .ripple(ripple)], field: field([128, 128, 0, 255]))
        let ctx = WSSRippleRenderContext(device: chain.device)
        XCTAssertEqual(try render(single, time: 2), try render(chain, time: 2, context: ctx))
        XCTAssertEqual(ctx.textureBytes, 0)
        let flowOnly = try resources([.flow(effect)])
        var zero = ripple
        zero.amplitude = 0
        XCTAssertEqual(
            try render(flowOnly, time: 2),
            try render(resources([.flow(effect), .ripple(zero)]), time: 2))
    }
    // Correlate actual rendered source details, not vector signs or UV offsets.
    func shift(_ a: Data, _ b: Data, size: Int, axis: Int) -> Int {
        let scale = size / 128
        var best = Double.infinity
        var answer = 0
        for step in (-6 * scale)...(6 * scale) {
            var error = 0.0
            for y in (40 * scale)..<(88 * scale) {
                for x in (40 * scale)..<(88 * scale) {
                    let xx = x + (axis == 0 ? step : 0)
                    let yy = y + (axis == 1 ? step : 0)
                    let d = Double(a[(y * size + x) * 4]) - Double(b[(yy * size + xx) * 4])
                    error += d * d
                }
            }
            if error < best {
                best = error
                answer = step
            }
        }
        return answer
    }
    func testRenderedVisibleDirectionsAndLogicalSpeedAtBothDensities() throws {
        var report: [[String: Any]] = []
        for (label, rgba, axis, sign): (String, [UInt8], Int, Int) in [
            ("right", [255, 128, 0, 255], 0, 1), ("left", [0, 128, 0, 255], 0, -1),
            ("down", [128, 255, 0, 255], 1, 1), ("up", [128, 0, 0, 255], 1, -1),
        ] {
            let r = try resources([.flow(effect)], field: field(rgba))
            for size in [128, 256] {
                let a = try render(r, time: 0.22, size: size)
                let b = try render(r, time: 0.30, size: size)
                let delta = shift(a, b, size: size, axis: axis)
                XCTAssertEqual(delta.signum(), sign, label)
                XCTAssertEqual(
                    Double(delta), Double(sign) * 30 * 0.08 * Double(size) / 128, accuracy: 0.8)
                report.append([
                    "direction": label, "raster": size, "observedPixels": delta,
                    "expectedLogical": Double(sign) * 2.4,
                ])
                for start in [0.0, 0.08, 0.35, 0.48, 0.61, 0.9] {
                    let earlier = try render(r, time: start, size: size)
                    let later = try render(r, time: start + 0.04, size: size)
                    let motion = shift(earlier, later, size: size, axis: axis)
                    XCTAssertEqual(
                        motion.signum(), sign, "\(label), phase \(start), raster \(size)")
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["AMBIENT_WSS_FLOW_QA"] {
            let folder = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys]
            ).write(to: folder.appendingPathComponent("directions.json"))
        }
        print("Flow rendered-direction evidence: \(report)")
    }
    func testTimeSeamsDeterminismConstantColorAndAlpha() throws {
        let r = try resources([.flow(effect)])
        for t in [0.0, 0.25, 0.5, 1, 2, 4, 8, 1e6] {
            XCTAssertEqual(try render(r, time: t), try render(r, time: t))
        }
        let period = 2 * Double(effect.strength) / Double(effect.speed)
        for seam in [period / 3, 2 * period / 3, period, 10 * period] {
            let a = try render(r, time: seam - 1e-5)
            let b = try render(r, time: seam + 1e-5)
            let difference = zip(a, b).map { abs(Int($0) - Int($1)) }
            // At exact symmetric sample positions the BGRA8 half-level rounding
            // can switch by one level even for arbitrarily small time deltas.
            XCTAssertLessThan(Double(difference.reduce(0, +)) / Double(difference.count), 0.5)
            print(
                "Flow seam \(seam): mean \(Double(difference.reduce(0,+))/Double(difference.count)), max \(difference.max()!) byte levels"
            )
            XCTAssertLessThanOrEqual(difference.max()!, 2)
        }
        let flat = try resources(
            [.flow(effect)], base: pixels(constant: true, alpha: 128), opacity: 0.5)
        let reference = try render(
            resources([], base: pixels(constant: true, alpha: 128), opacity: 0.5))
        for t in [0.0, 0.25, 1, 8] { XCTAssertEqual(try render(flat, time: t), reference) }
    }
    func testChainUsesFlowOutputAndOrderChangesResult() throws {
        let ripple = WSSRippleEffect(amplitude: 8, wavelength: 35, stretch: 1.2, seed: 17)
        let chain = try resources([.flow(effect), .ripple(ripple)])
        let actual = try render(chain, time: 0.37)
        func rgba(_ bgra: Data) -> Data {
            var data = Data()
            for i in stride(from: 0, to: bgra.count, by: 4) {
                data.append(contentsOf: [bgra[i + 2], bgra[i + 1], bgra[i], bgra[i + 3]])
            }
            return data
        }
        let first = try render(resources([.flow(effect)]), time: 0.37)
        let expected = try render(resources([.ripple(ripple)], base: rgba(first)), time: 0.37)
        XCTAssertEqual(actual, expected)
        let reverseFirst = try render(resources([.ripple(ripple)]), time: 0.37)
        let reverse = try render(resources([.flow(effect)], base: rgba(reverseFirst)), time: 0.37)
        XCTAssertNotEqual(actual, reverse)
        let context = WSSRippleRenderContext(device: chain.device)
        _ = try render(chain, time: 0.37, context: context)
        let before = context.textureBytes
        _ = try render(chain, time: 1, context: context)
        XCTAssertEqual(context.textureBytes, before)
        let tiny = WSSRippleRenderContext(device: chain.device, byteLimit: 1)
        XCTAssertThrowsError(try render(chain, time: 1, context: tiny))
        XCTAssertThrowsError(
            try context.acquire(
                sizes: [0: SIMD2(6400, 3600), 1: SIMD2(6400, 3600)],
                output: WSSRippleChainTests().target(chain.device)))
    }
    @MainActor func testPlayerPauseResumeAndResolution() async throws {
        let r = try resources([.flow(effect)])
        func player(_ offset: Double) -> WSSStaticPlayer {
            WSSStaticPlayer(
                resources: r, size: CGSize(width: 64, height: 64), scale: 2, maxDimension: 8192,
                fps: 30, resolution: .standard, offset: offset, onError: { XCTFail($0) })
        }
        let p = player(0)
        p.play()
        XCTAssertTrue(r.scene.isAnimated)
        XCTAssertEqual(p.view.drawableSize, CGSize(width: 64, height: 64))
        p.setRenderResolution(.hiDPI)
        XCTAssertEqual(p.view.drawableSize, CGSize(width: 128, height: 128))
        try await Task.sleep(for: .milliseconds(30))
        p.stop()
        let frozen = p.elapsed
        let a = try render(r, time: p.elapsed)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(p.elapsed, frozen)
        XCTAssertEqual(a, try render(r, time: p.elapsed))
        let resumed = player(frozen)
        resumed.play()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertGreaterThan(resumed.elapsed, frozen)
        resumed.stop()
    }
}
