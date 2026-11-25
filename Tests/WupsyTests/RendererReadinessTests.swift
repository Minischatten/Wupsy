import MetalKit
import XCTest

@testable import Wupsy

@MainActor final class RendererReadinessTests: XCTestCase {
    func testImageReadinessRequiresInstalledImageAndFiresOnce() async throws {
        let fixture = try imageFixture()
        defer { try? fixture.helper.tearDownWithError() }
        let ready = expectation(description: "Image installed")
        var results: [RendererReadiness] = []
        let renderer = Renderer(
            maintenance: MaintenanceCoordinator(), wallpaper: fixture.item, screen: fixture.screen,
            initiallyPaused: true,
            onReadiness: {
                results.append($0)
                ready.fulfill()
            }, onError: { XCTFail($0) })
        defer { renderer.stop() }
        renderer.deferPresentation()
        renderer.setPaused(false)
        XCTAssertNil((renderer.window.contentView as? NSImageView)?.image)
        XCTAssertTrue(results.isEmpty)
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertNotNil((renderer.window.contentView as? NSImageView)?.image)
        XCTAssertFalse(renderer.window.isVisible)
        await renderer.stopAndDrainForMaintenance()
        XCTAssertEqual(results, [.ready])
        XCTAssertFalse(renderer.hasLiveResources)
    }

    func testImageDecodeFailureAndCancellationAreTerminal() async throws {
        let fixture = try imageFixture()
        defer { try? fixture.helper.tearDownWithError() }
        for cancel in [true, false] {
            if !cancel { try Data("invalid image".utf8).write(to: fixture.item.url) }
            let finished = expectation(description: "Image attempt resolved")
            var results: [RendererReadiness] = []
            let renderer = Renderer(
                maintenance: MaintenanceCoordinator(), wallpaper: fixture.item,
                screen: fixture.screen, initiallyPaused: true,
                onReadiness: {
                    results.append($0)
                    finished.fulfill()
                }, onError: { _ in })
            defer { renderer.stop() }
            renderer.deferPresentation()
            renderer.setPaused(false)
            if cancel { renderer.setPaused(true) }
            await fulfillment(of: [finished], timeout: 3)
            await renderer.stopAndDrainForMaintenance()
            XCTAssertEqual(results, [cancel ? .cancelled : .failed(.imageDecode)])
            XCTAssertFalse(renderer.hasLiveResources)
        }
    }

    func testScenePreparationFailureIsTerminal() async throws {
        let fixture = try imageFixture()
        defer { try? fixture.helper.tearDownWithError() }
        let folder = try fixture.helper.fixture()
        let item = try WallpaperImporter.resolve(folder)
        try FileManager.default.removeItem(at: item.url)
        let failed = expectation(description: "Missing scene fails preparation")
        var results: [RendererReadiness] = []
        let renderer = Renderer(
            maintenance: MaintenanceCoordinator(), wallpaper: item, screen: fixture.screen,
            initiallyPaused: true,
            onReadiness: {
                results.append($0)
                failed.fulfill()
            }, onError: { _ in })
        defer { renderer.stop() }
        renderer.deferPresentation()
        renderer.setPaused(false)
        await fulfillment(of: [failed], timeout: 3)
        await renderer.stopAndDrainForMaintenance()
        XCTAssertEqual(results.count, 1)
        guard case .failed = results.first else { return XCTFail("Expected preparation failure") }
        XCTAssertFalse(renderer.hasLiveResources)
    }

    func testSceneEncodingFailureDoesNotReportPresentation() async throws {
        let fixture = try imageFixture()
        defer { try? fixture.helper.tearDownWithError() }
        let item = try WallpaperImporter.resolve(fixture.helper.fixture())
        let prepared = try await ScenePlayback.prepare(for: item)
        let window = DesktopWindow(
            contentRect: NSRect(x: 80, y: 80, width: 240, height: 160),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        let failed = expectation(description: "Invalid playback time rejected while encoding")
        let player = prepared.makePlayer(
            size: window.frame.size, scale: 1, maxDimension: 240, fps: 30,
            resolution: .standard, offset: -.infinity,
            onFirstFramePresented: { XCTFail("An invalid frame was reported as presented") },
            onError: { _ in failed.fulfill() })
        defer {
            player.stop()
            window.close()
        }
        window.contentView = player.view
        window.orderFrontRegardless()
        player.play()
        for _ in 0..<100 {
            if player.view.delegate == nil { break }
            player.view.draw()
            try await Task.sleep(for: .milliseconds(20))
        }
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertNil(player.view.delegate)
    }

    func testSceneGPUCompletionAndZeroTimeLeaveReadinessPending() async throws {
        let fixture = try imageFixture()
        defer { try? fixture.helper.tearDownWithError() }
        let item = try WallpaperImporter.resolve(fixture.helper.fixture())
        let prepared = try await ScenePlayback.prepare(for: item)
        var results: [RendererReadiness] = []
        let renderer = makeDetachedSceneRenderer(item, prepared, screen: fixture.screen) {
            results.append($0)
        }
        defer { renderer.stop() }
        let player = try XCTUnwrap(renderer.scene as? WSSStaticPlayer)
        XCTAssertFalse(renderer.window.isVisible)
        let resources = player.resources
        let target = try WSSRippleChainTests().target(resources.device)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
        try resources.encode(
            command: command, descriptor: pass, size: CGSize(width: 64, height: 64), time: 0,
            rippleContext: player.rippleContext)
        let metrics = try XCTUnwrap(player.startMeasuring())
        let completed = expectation(description: "Offscreen WSS completed")
        command.addCompletedHandler(
            player.frameCompletionHandler(retryTransitionFrame: false) { completed.fulfill() })
        command.commit()
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(command.status, .completed)
        XCTAssertEqual(metrics.snapshot().frames, 1)
        XCTAssertTrue(results.isEmpty)
        XCTAssertNil(player.receivePresentation(at: 0))
        XCTAssertTrue(results.isEmpty)
        let presentation = try XCTUnwrap(player.receivePresentation(at: 1))
        let duplicate = try XCTUnwrap(player.receivePresentation(at: 2))
        await presentation.value
        await duplicate.value
        XCTAssertEqual(results, [.ready])
        await renderer.stopAndDrainForMaintenance()
        XCTAssertEqual(results, [.ready])
    }

    func testStoppedSceneIgnoresQueuedAndLatePresentationsAfterReplacement() async throws {
        let fixture = try imageFixture()
        defer { try? fixture.helper.tearDownWithError() }
        let first = try WallpaperImporter.resolve(fixture.helper.fixture(name: "First"))
        let next = try WallpaperImporter.resolve(fixture.helper.fixture(name: "Next"))
        let firstPrepared = try await ScenePlayback.prepare(for: first)
        let nextPrepared = try await ScenePlayback.prepare(for: next)
        var firstResults: [RendererReadiness] = []
        let firstRenderer = makeDetachedSceneRenderer(first, firstPrepared, screen: fixture.screen)
        {
            firstResults.append($0)
        }
        defer { firstRenderer.stop() }
        let stopped = try XCTUnwrap(firstRenderer.scene as? WSSStaticPlayer)
        let queued = try XCTUnwrap(stopped.receivePresentation(at: 1))
        firstRenderer.stop()
        XCTAssertEqual(firstResults, [.cancelled])

        var nextResults: [RendererReadiness] = []
        let nextRenderer = makeDetachedSceneRenderer(next, nextPrepared, screen: fixture.screen) {
            nextResults.append($0)
        }
        defer { nextRenderer.stop() }
        let current = try XCTUnwrap(nextRenderer.scene as? WSSStaticPlayer)
        XCTAssertFalse(stopped === current)
        let late = try XCTUnwrap(stopped.receivePresentation(at: 2))
        await queued.value
        await late.value
        XCTAssertEqual(firstResults, [.cancelled])
        XCTAssertTrue(nextResults.isEmpty)
        let presentation = try XCTUnwrap(current.receivePresentation(at: 3))
        await presentation.value
        XCTAssertEqual(nextResults, [.ready])

        var maintenanceResults: [RendererReadiness] = []
        let maintenanceRenderer = makeDetachedSceneRenderer(
            next, nextPrepared, screen: fixture.screen
        ) { maintenanceResults.append($0) }
        defer { maintenanceRenderer.stop() }
        let maintenancePlayer = try XCTUnwrap(maintenanceRenderer.scene as? WSSStaticPlayer)
        await maintenanceRenderer.stopAndDrainForMaintenance()
        let afterMaintenance = try XCTUnwrap(maintenancePlayer.receivePresentation(at: 4))
        await afterMaintenance.value
        XCTAssertEqual(maintenanceResults, [.cancelled])
        XCTAssertFalse(maintenanceRenderer.hasLiveResources)
    }

    private func makeDetachedSceneRenderer(
        _ item: Wallpaper, _ scene: PreparedScenePlayback, screen: NSScreen,
        onReadiness: @escaping (RendererReadiness) -> Void
    ) -> Renderer {
        let renderer = Renderer(
            maintenance: MaintenanceCoordinator(), wallpaper: item, screen: screen,
            initiallyPaused: true, scenePlayback: scene, sceneRenderResolution: .standard,
            onReadiness: onReadiness, onError: { XCTFail($0) })
        renderer.deferPresentation()
        renderer.setPaused(false)
        return renderer
    }

    func testScenePresentationWithDesktopWindowCover() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else {
            return XCTFail("WUPSY_METAL_PROBE result=failed attempts=0 reason=no usable display")
        }
        let strict = ProcessInfo.processInfo.environment["WUPSY_REQUIRE_METAL_PRESENTATION"] == "1"
        switch await MetalPresentationProbe.run(on: screen) {
        case .confirmed:
            print("WUPSY_METAL_PROBE result=confirmed strict=\(strict) running cover test")
        case .notConfirmed:
            let reason =
                "WUPSY_METAL_PROBE result=notConfirmed strict=\(strict) "
                + "after 3 successful GPU completions, 2 zero timestamps before close, "
                + "and 1 zero timestamp during window close; no on-screen presentation confirmed"
            print(reason)
            if strict { return XCTFail(reason) }
            throw XCTSkip(reason)
        case .failed(let reason):
            return XCTFail("WUPSY_METAL_PROBE result=failed strict=\(strict) reason=\(reason)")
        }
        let fixture = try imageFixture(screen: screen)
        defer { try? fixture.helper.tearDownWithError() }
        for animated in [false, true] {
            let folder = try fixture.helper.fixture(fixture.helper.document(clouds: animated))
            let item = try WallpaperImporter.resolve(folder)
            let prepared = try await ScenePlayback.prepare(for: item)
            let cover = Renderer(
                maintenance: MaintenanceCoordinator(), wallpaper: fixture.item, screen: screen,
                onError: { XCTFail($0) })
            defer { cover.stop() }
            var results: [RendererReadiness] = []
            let renderer = Renderer(
                maintenance: MaintenanceCoordinator(), wallpaper: item, screen: screen,
                initiallyPaused: true, scenePlayback: prepared, sceneRenderResolution: .standard,
                onReadiness: { results.append($0) }, onError: { XCTFail($0) })
            defer { renderer.stop() }
            renderer.deferPresentation()
            renderer.setPaused(false)
            let player = try XCTUnwrap(renderer.scene)
            let metrics = try XCTUnwrap(player.startMeasuring())
            XCTAssertTrue(results.isEmpty)
            renderer.window.order(.below, relativeTo: cover.window.windowNumber)
            XCTAssertTrue(renderer.window.isVisible)
            XCTAssertTrue(cover.window.isVisible)
            XCTAssertEqual(renderer.window.frame, cover.window.frame)
            // Bound the observation without treating GPU work as presentation.
            for _ in 0..<50 where results.isEmpty {
                try await Task.sleep(for: .milliseconds(20))
            }
            print(
                "Covered desktop WSS animated=\(animated), GPU frames=\(metrics.snapshot().frames), readiness=\(results)"
            )
            cover.stop()
            // A desktop-level window can remain covered by other apps on the test host.
            // Move the same view to a small, unobscured window for the positive control.
            renderer.window.level = .floating
            renderer.window.setFrame(
                NSRect(
                    x: screen.visibleFrame.midX, y: screen.visibleFrame.midY,
                    width: 240, height: 160),
                display: true)
            renderer.window.orderFrontRegardless()
            for _ in 0..<50 where !renderer.window.occlusionState.contains(.visible) {
                try await Task.sleep(for: .milliseconds(20))
            }
            for _ in 0..<150 where results.isEmpty {
                if !animated { player.view.draw() }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(results, [.ready], "Visible WSS, animated=\(animated)")
            // Give both Metal handlers time to report before closing the measurement window.
            try await Task.sleep(for: .seconds(1))
            let frameWindow = try XCTUnwrap(player.performanceSnapshot()?.frameWindow)
            XCTAssertGreaterThan(frameWindow.confirmedPresentations, 0, "Visible WSS presentation")
            let presentedRate = try XCTUnwrap(frameWindow.presentedFPS)
            print(
                "Visible WSS animated=\(animated), target FPS=\(player.view.preferredFramesPerSecond), "
                    + "presented FPS=\(presentedRate), confirmations=\(frameWindow.confirmedPresentations), "
                    + "GPU completions/s=\(frameWindow.gpuCompletionsPerSecond), "
                    + "CPU encoding ms=\(String(describing: frameWindow.averageCPUMilliseconds)) "
                    + "(n=\(frameWindow.cpuSamples)), "
                    + "GPU ms=\(String(describing: frameWindow.averageGPUMilliseconds)) "
                    + "(n=\(frameWindow.gpu.gpuSamples))"
            )
            await renderer.stopAndDrainForMaintenance()
            XCTAssertEqual(results, [.ready])
            XCTAssertNil(player.view.delegate)
            XCTAssertFalse(renderer.hasLiveResources)
        }
    }

    private func imageFixture(screen providedScreen: NSScreen? = nil) throws -> (
        helper: WSSNativeSceneTests, item: Wallpaper, screen: NSScreen
    ) {
        guard let screen = providedScreen ?? NSScreen.main else {
            throw XCTSkip("Desktop display required")
        }
        let helper = WSSNativeSceneTests()
        try helper.setUpWithError()
        let url = helper.root.appendingPathComponent("wallpaper.png")
        try helper.png().write(to: url)
        return (helper, try WallpaperImporter.resolve(url), screen)
    }
}
