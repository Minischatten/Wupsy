import ImageIO
import MetalKit
import UniformTypeIdentifiers
import XCTest

@testable import Wupsy

final class WSSStormRenderTests: XCTestCase {
    func configuration() -> WSSStormConfiguration {
        var c = WSSStormConfiguration()
        c.x = 32
        c.y = 60
        c.length = 54
        c.spread = 9
        c.glow = 5
        return c
    }
    func resources(_ nodes: [WSSSceneLayer]) throws -> WSSStaticResources {
        try WSSStaticResources(
            scene: WSSScene(width: 64, height: 64, layers: nodes),
            assets: WSSStaticTests.Assets(values: [
                WSSAssetID(value: "black"): WSSStaticTests().solid([0, 0, 0, 255])
            ]), device: WSSStaticTests().device())
    }
    func testGPUVisibleDarkFlickerDeterminismAndPainterOcclusion() throws {
        let c = configuration()
        let time = WSSStormTests().onset(configuration()) + 0.01
        let node = WSSSceneLayer.storm(.init(storm: c))
        let r = try resources([node])
        let lit = try WSSRippleChainTests().render(r, time: time).0
        XCTAssertEqual(lit, try WSSRippleChainTests().render(r, time: time).0)
        XCTAssertTrue(stride(from: 0, to: lit.count, by: 4).contains { lit[$0] > 30 })
        let dark = try WSSRippleChainTests().render(r, time: 0).0
        XCTAssertTrue(dark.allSatisfy { $0 == 0 })
        let foreground = WSSSceneLayer.image(
            .init(
                asset: WSSAssetID(value: "black"),
                transform: .init(center: SIMD2(32, 32), size: SIMD2(64, 64))))
        let covered = try WSSRippleChainTests().render(resources([node, foreground]), time: time).0
        XCTAssertTrue(
            stride(from: 0, to: covered.count, by: 4).allSatisfy {
                covered[$0] == 0 && covered[$0 + 1] == 0 && covered[$0 + 2] == 0
                    && covered[$0 + 3] == 255
            })
        let above = try WSSRippleChainTests().render(resources([foreground, node]), time: time).0
        XCTAssertNotEqual(covered, above)
        let hidden = try WSSRippleChainTests().render(
            resources([.storm(.init(visible: false, storm: c))]), time: time
        ).0
        XCTAssertEqual(hidden, dark)
    }
    func testCacheOnlyRegeneratesGeometryWhenNeededAndSurvivesResetInFlight() throws {
        let device = try WSSStaticTests().device()
        let context = WSSStormRenderContext()
        let c = configuration()
        let first = try context.entry(index: 0, configuration: c, event: 0, device: device)
        var changed = c
        changed.x = 5
        changed.direction = 20
        changed.red = 0.2
        changed.interval = 5
        changed.width = 4
        changed.glow = 32
        let same = try context.entry(index: 0, configuration: changed, event: 0, device: device)
        XCTAssertTrue(first.buffer === same.buffer)
        XCTAssertEqual(context.generationCount, 1)
        changed.spread += 1
        XCTAssertFalse(
            first.buffer
                === (try context.entry(index: 0, configuration: changed, event: 0, device: device))
                .buffer)
        XCTAssertEqual(context.generationCount, 2)
        XCTAssertLessThanOrEqual(context.bufferBytes, 256 * 48)
        let r = try resources([.storm(.init(storm: c))])
        var commands: [MTLCommandBuffer] = []
        var targets: [MTLTexture] = []
        for cycle in 0..<2 {
            let target = try WSSRippleChainTests().target(r.device)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let command = try XCTUnwrap(r.queue.makeCommandBuffer())
            try r.encode(
                command: command, descriptor: pass, size: CGSize(width: 64, height: 64),
                time: WSSStormTests().onset(c) + 0.01 + Double(cycle) * c.interval,
                stormContext: context)
            targets.append(target)
            commands.append(command)
            context.reset()  // Encoded commands must retain these immutable buffers.
        }
        for command in commands { command.commit() }
        for command in commands {
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
        }
        for target in targets {
            var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
            bytes.withUnsafeMutableBytes {
                target.getBytes(
                    $0.baseAddress!, bytesPerRow: 256, from: MTLRegionMake2D(0, 0, 64, 64),
                    mipmapLevel: 0)
            }
            XCTAssertTrue(bytes.contains { $0 > 0 })
        }
    }
    func testMaximumCacheBudgetAndParameterBoundsOnGPU() throws {
        let device = try WSSStaticTests().device()
        var c = configuration()
        c.branchDepth = 3
        c.length = 8192
        c.spread = 2048
        c.width = 32
        c.glow = 128
        let context = WSSStormRenderContext()
        XCTAssertEqual(MemoryLayout<WSSStormRenderer.Segment>.stride, 48)
        for index in 0..<8 {
            let entry = try context.entry(
                index: index, configuration: c, event: UInt64(index), device: device)
            XCTAssertEqual(entry.count, 256)
        }
        XCTAssertEqual(context.bufferBytes, 96 * 1024)
        XCTAssertThrowsError(
            try context.entry(index: 8, configuration: c, event: 0, device: device))
        XCTAssertThrowsError(
            try context.entry(index: 128, configuration: c, event: 0, device: device))
    }

    @MainActor func testPlayerPauseResolutionAndCompatibleParameterUpdates() throws {
        let c = configuration()
        let model = try WSSStormTests().model(c)
        let r = try resources([.storm(.init(storm: c))])
        let player = WSSStaticPlayer(
            resources: r, size: CGSize(width: 64, height: 64), scale: 2, maxDimension: 128, fps: 24,
            resolution: .hiDPI, offset: WSSStormTests().onset(c) + 0.01, onError: { XCTFail($0) })
        defer { player.stop() }
        XCTAssertEqual(player.diagnostics.shader, "WSS storm v1")
        player.play()
        player.draw(in: player.view)
        player.pause()
        let frozen = player.elapsed
        XCTAssertEqual(player.elapsed, frozen)
        let buffer = player.stormContext.entries[0]?.buffer
        player.setRenderResolution(.standard)
        XCTAssertEqual(player.elapsed, frozen)
        if let buffer { XCTAssertTrue(buffer === player.stormContext.entries[0]?.buffer) }
        var updated = model
        if case .storm(var layer) = updated.layers[0].content {
            layer.storm.brightness = 0
            updated.layers[0].content = .storm(layer)
        }
        let reused = try XCTUnwrap(r.updatingTransforms(from: model, to: updated))
        XCTAssertTrue(r.sharesPreparedResources(with: reused))
        XCTAssertTrue(player.updateTransforms(reused))
        player.play()
        XCTAssertTrue(player.view.isPaused)  // Neutral storm uses on-demand rendering.
        XCTAssertTrue(player.updateTransforms(r))
        XCTAssertFalse(player.view.isPaused)
        XCTAssertGreaterThanOrEqual(player.elapsed, frozen)
    }
    func testConnectedStraightSegmentsHaveNoPeriodicBrightnessPeaks() throws {
        var c = WSSStormConfiguration()
        c.x = 128
        c.y = 240
        c.length = 224
        c.spread = 0
        c.branchDepth = 0
        c.red = 1
        c.green = 1
        c.blue = 1
        c.brightness = 0.1
        c.glow = 8
        let scene = WSSScene(width: 256, height: 256, layers: [.storm(.init(storm: c))])
        let r = try WSSStaticResources(
            scene: scene, assets: WSSStaticTests.Assets(values: [:]),
            device: WSSStaticTests().device())
        let bytes = try WSSCloudsTests().render(
            r, time: WSSStormTests().onset(c) + 0.01, width: 256, height: 256
        ).0
        for x in [127, 128, 130, 134] {
            let values = (24..<232).map { Int(bytes[($0 * 256 + x) * 4]) }
            XCTAssertGreaterThan(values.max()!, 0)
            XCTAssertLessThanOrEqual(
                values.max()! - values.min()!, 2, "Periodic join peaks at x=\(x)")
        }
    }

    func testFixtureFrameAndOptionalVisualExport() throws {
        let c = WSSStormConfiguration()
        let scene = WSSScene(
            width: 1920, height: 1080, background: SIMD3(0.01, 0.02, 0.04),
            layers: [.storm(.init(storm: c))])
        let r = try WSSStaticResources(
            scene: scene, assets: WSSStaticTests.Assets(values: [:]),
            device: WSSStaticTests().device())
        let helper = WSSCloudsTests()
        let bytes = try helper.render(
            r, time: WSSStormTests().onset(c) + 0.02, width: 1920, height: 1080
        ).0
        XCTAssertTrue(stride(from: 0, to: bytes.count, by: 4).contains { bytes[$0] > 150 })
        if let path = ProcessInfo.processInfo.environment["WUPSY_WSS_STORM_QA"] {
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
    @MainActor func testManagedDesktopPlaybackWithPauseAndResume() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("Display required") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WSSStorm-" + UUID().uuidString
        ).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try WSSStormTests().model().encoded().write(
            to: source.appendingPathComponent("scene.wss.json"))
        let suite = "WSSStorm-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in ["conserve", "pauseOnBattery", "allDisplays"] {
            defaults.set(false, forKey: key)
        }
        let library = Library(
            storage: root.appendingPathComponent("Support/library.json"), defaults: defaults)
        defer { library.stop() }
        library.importURLs([source])
        for _ in 0..<500 {
            if !library.importing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(library.message)
        let item = try XCTUnwrap(library.items.first)
        try FileManager.default.removeItem(at: source)
        library.apply(item)
        let helper = WSSNativeSceneTests()
        let player = try await helper.running(library)
        XCTAssertNotNil(player.resources.storm)
        XCTAssertGreaterThan(player.metrics.snapshot().frames, 0)
        library.manuallyPaused = true
        let frozen = player.elapsed
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(player.elapsed, frozen)
        library.manuallyPaused = false
        let resumed = try await helper.running(library)
        XCTAssertGreaterThanOrEqual(resumed.elapsed, frozen - 0.02)
        XCTAssertLessThan(resumed.elapsed, frozen + 0.3)
        XCTAssertNil(library.message)
    }

}
