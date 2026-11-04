import MetalKit
import XCTest

@testable import Wupsy

final class WSSFlowFixtureTests: XCTestCase {
    var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Test-Wallpaper")
    }
    func testOwnFixturesLoadWithoutExternalResourcesAndAnimate() throws {
        for name in ["WSS-Flow-v1", "WSS-Flow-Ripple-v1"] {
            let folder = root.appendingPathComponent(name)
            let scene = try WSSSceneDocumentV1.load(
                entry: folder.appendingPathComponent("scene.wss.json"), root: folder
            ).scene()
            XCTAssertTrue(scene.isAnimated)
            let r = try WSSStaticResources(
                scene: scene, assets: WSSNativeAssets(root: folder),
                device: WSSStaticTests().device())
            XCTAssertNotNil(r.flow)
            XCTAssertNil(r.rain)
            let helper = WSSRippleChainTests()
            let context = WSSRippleRenderContext(device: r.device)
            var hashes = Set<String>()
            for time in [0.0, 0.25, 0.5, 1, 2, 4, 8] {
                let bytes = try helper.render(
                    r, context: context, time: time, width: 960, height: 540
                ).0
                hashes.insert(NativeTestData.digest(bytes))
                if let path = ProcessInfo.processInfo.environment["AMBIENT_WSS_FLOW_QA"] {
                    let out = URL(fileURLWithPath: path).appendingPathComponent(name)
                    try FileManager.default.createDirectory(
                        at: out, withIntermediateDirectories: true)
                    try WSSRippleTests().writePNG(
                        bytes, width: 960, height: 540,
                        to: out.appendingPathComponent("t\(time).png"))
                }
            }
            XCTAssertGreaterThan(hashes.count, 1)
            if name == "WSS-Flow-v1" {
                XCTAssertEqual(context.textureBytes, 0)
            } else {
                XCTAssertGreaterThan(context.textureBytes, 0)
            }
        }
    }
    func testDiagnosticWarmPerformanceAndScratchBudget() throws {
        guard let path = ProcessInfo.processInfo.environment["AMBIENT_WSS_FLOW_QA"] else {
            throw XCTSkip("Set AMBIENT_WSS_FLOW_QA for performance diagnostics")
        }
        let folder = root.appendingPathComponent("WSS-Flow-v1")
        let original = try WSSSceneDocumentV1.load(
            entry: folder.appendingPathComponent("scene.wss.json"), root: folder
        ).scene()
        let device = try WSSStaticTests().device()
        let helper = WSSRippleChainTests()
        var report: [[String: Any]] = []
        for chain in [false, true] {
            var scene = original
            if chain {
                scene.testImages[0].effects.append(
                    .ripple(WSSRippleEffect(amplitude: 8, wavelength: 90, seed: 31337)))
            }
            let resources = try WSSStaticResources(
                scene: scene, assets: WSSNativeAssets(root: folder), device: device)
            for (width, height) in [(3840, 2160), (6400, 3600)] {
                let context = WSSRippleRenderContext(device: device)
                let target = try helper.target(device, width: width, height: height)
                var times: [Double] = []
                // Reuse the output target and scratch across warm and measured draws.
                for i in 0..<15 {
                    let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = target
                    pass.colorAttachments[0].loadAction = .clear
                    pass.colorAttachments[0].storeAction = .store
                    try resources.encode(
                        command: command, descriptor: pass,
                        size: CGSize(width: width, height: height),
                        time: Double(i) / 30, rippleContext: context)
                    command.commit()
                    command.waitUntilCompleted()
                    XCTAssertEqual(command.status, .completed)
                    if i >= 3 { times.append((command.gpuEndTime - command.gpuStartTime) * 1000) }
                }
                // Exercise both live slots without CPU waiting between encodes.
                var pending: [MTLCommandBuffer] = []
                for i in 0..<2 {
                    let output = try helper.target(device, width: width, height: height)
                    let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = output
                    pass.colorAttachments[0].loadAction = .clear
                    pass.colorAttachments[0].storeAction = .store
                    try resources.encode(
                        command: command, descriptor: pass,
                        size: CGSize(width: width, height: height),
                        time: 1 + Double(i) / 30, rippleContext: context)
                    pending.append(command)
                }
                for command in pending { command.commit() }
                for command in pending {
                    command.waitUntilCompleted()
                    XCTAssertEqual(command.status, .completed)
                }
                XCTAssertLessThanOrEqual(context.textureBytes, 256 * 1024 * 1024)
                if chain {
                    XCTAssertGreaterThanOrEqual(context.textureBytes, width * height * 4 * 2)
                } else {
                    XCTAssertEqual(context.textureBytes, 0)
                }
                let item: [String: Any] = [
                    "chain": chain, "width": width, "height": height, "device": device.name,
                    "warmupFrames": 3, "measuredFrames": times.count,
                    "gpuMeanMilliseconds": times.reduce(0, +) / Double(times.count),
                    "gpuMinMilliseconds": times.min()!, "gpuMaxMilliseconds": times.max()!,
                    "scratchAllocatedBytesTwoSlots": context.textureBytes,
                    "flowMapAllocatedBytes": resources.flow!.textureBytes,
                    "immutableTextureBytes": resources.textureBytes, "draws": chain ? 2 : 1,
                    "flowTextureSamplesMax": 6, "rippleTextureSamples": chain ? 2 : 0,
                ]
                report.append(item)
                print("FLOW PERF \(item)")
            }
        }
        let out = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("performance.json"))
    }
    @MainActor func testManagedNativeFlowImportSurvivesSourceRemoval() async throws {
        let helper = WSSNativeSceneTests()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let source = helper.root.appendingPathComponent("FlowSource")
        try FileManager.default.copyItem(at: root.appendingPathComponent("WSS-Flow-v1"), to: source)
        let suite = "FlowImport-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in ["conserve", "pauseOnBattery", "allDisplays"] {
            defaults.set(false, forKey: key)
        }
        let library = Library(
            storage: helper.root.appendingPathComponent("managed/library.json"), defaults: defaults)
        defer { library.stop() }
        library.importURLs([source])
        for _ in 0..<500 {
            if !library.importing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(library.message)
        let item = try XCTUnwrap(library.items.first)
        XCTAssertEqual(item.sceneSource, .nativeWSS)
        try FileManager.default.removeItem(at: source)
        library.apply(item)
        let player = try await helper.running(library)
        XCTAssertNotNil(player.resources.flow)
        for resolution in [SceneRenderResolution.standard, .hiDPI] {
            library.sceneRenderResolution = resolution
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(player.resolution, resolution)
        }
        library.manuallyPaused = true
        let offset = library.renderers.first?.scene?.elapsed
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(offset, library.renderers.first?.scene?.elapsed)
        library.manuallyPaused = false
        _ = try await helper.running(library)
        XCTAssertNil(library.message)
    }
}
