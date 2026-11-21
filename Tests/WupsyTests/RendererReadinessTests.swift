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

    func testScenePresentationWithDesktopWindowCover() async throws {
        let fixture = try imageFixture()
        defer { try? fixture.helper.tearDownWithError() }
        let screen = fixture.screen
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
                "Covered desktop WSS animated=\(animated), GPU frames=\(player.metrics.snapshot().frames), readiness=\(results)"
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
            await renderer.stopAndDrainForMaintenance()
            XCTAssertEqual(results, [.ready])
            XCTAssertNil(player.view.delegate)
            XCTAssertFalse(renderer.hasLiveResources)
        }
    }

    private func imageFixture() throws -> (
        helper: WSSNativeSceneTests, item: Wallpaper, screen: NSScreen
    ) {
        guard let screen = NSScreen.main else { throw XCTSkip("Desktop display required") }
        let helper = WSSNativeSceneTests()
        try helper.setUpWithError()
        let url = helper.root.appendingPathComponent("wallpaper.png")
        try helper.png().write(to: url)
        return (helper, try WallpaperImporter.resolve(url), screen)
    }
}
