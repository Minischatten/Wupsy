import MetalKit
import XCTest

@testable import Wupsy

final class ScenePlaybackTests: XCTestCase {

    func fixture() throws -> (URL, Wallpaper) {
        let helper = WSSNativeSceneTests()
        try helper.setUpWithError()
        let folder = try helper.fixture()
        return (helper.root, try WallpaperImporter.resolve(folder))
    }
    @MainActor func testPreparationDelegatesAndPlayerInputsArePreserved() async throws {
        let (root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try await WSSStaticPreparation.shared.prepare(item)
        let prepared = try await ScenePlayback.prepare(for: item)
        let session = prepared.makePlayer(
            size: CGSize(width: 100, height: 50), scale: 2, maxDimension: 160, fps: 24,
            resolution: .standard, offset: 7, onError: { XCTFail($0) })
        defer { session.stop() }
        let native = try XCTUnwrap(session as? WSSStaticPlayer)
        XCTAssertEqual(native.resources.scene.width, original.scene.width)
        XCTAssertEqual(session.view.bounds.size, CGSize(width: 100, height: 50))
        XCTAssertEqual(session.view.preferredFramesPerSecond, 24)
        XCTAssertEqual(session.view.drawableSize, CGSize(width: 100, height: 50))
        XCTAssertEqual(native.resolution, .standard)
        XCTAssertGreaterThanOrEqual(session.elapsed, 7)
        XCTAssertLessThan(session.elapsed, 8)
        XCTAssertTrue(session.metrics === native.metrics)
        XCTAssertEqual(session.diagnostics.sourceWidth, 64)
        XCTAssertEqual(session.diagnostics.sourceHeight, 64)
        XCTAssertEqual(session.diagnostics.textureBytes, original.textureBytes)
        XCTAssertEqual(session.diagnostics.intermediateTextureBytes, 0)
        XCTAssertEqual(session.diagnostics.deviceName, original.device.name)
        XCTAssertEqual(session.diagnostics.shader, "WSS static images")
        let context = native.rippleContext
        session.setRenderResolution(.hiDPI)
        XCTAssertEqual(session.view.drawableSize, CGSize(width: 160, height: 80))
        session.setRenderResolution(.standard)
        XCTAssertEqual(session.view.drawableSize, CGSize(width: 100, height: 50))
        XCTAssertTrue(context === native.rippleContext)
        session.play()
        XCTAssertTrue(session.view.isPaused)  // Existing static-scene draw-on-demand contract.
        session.stop()
        XCTAssertNil(session.view.delegate)
    }

    @MainActor func testRendererPreparedPlaybackPauseAndAsyncReload() async throws {
        guard let screen = NSScreen.main else { throw XCTSkip("Display required") }
        let (root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var errors: [String] = []
        let prepared = try await ScenePlayback.prepare(for: item)
        let renderer = Renderer(
            wallpaper: item, screen: screen, profile: .original, initiallyPaused: true,
            scenePlayback: prepared, sceneFPS: 24, sceneRenderResolution: .standard,
            onError: { errors.append($0) })
        defer { renderer.stop() }
        XCTAssertNil(renderer.scene)
        renderer.setPaused(false)
        let first = try XCTUnwrap(renderer.scene)
        XCTAssertTrue(first is WSSStaticPlayer)
        XCTAssertTrue(renderer.window.contentView === first.view)
        XCTAssertEqual(first.view.preferredFramesPerSecond, 24)
        renderer.setSceneRenderResolution(.hiDPI)
        XCTAssertEqual((first as? WSSStaticPlayer)?.resolution, .hiDPI)
        renderer.setPaused(true)
        let savedTime = first.elapsed
        XCTAssertNil(renderer.scene)
        XCTAssertNil(first.view.delegate)
        XCTAssertFalse(renderer.hasLiveResources)
        try await Task.sleep(for: .milliseconds(100))
        renderer.setPaused(false)
        for _ in 0..<100 {
            if renderer.scene != nil || !errors.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
        let resumed = try XCTUnwrap(renderer.scene)
        XCTAssertFalse(first === resumed)
        XCTAssertEqual((resumed as? WSSStaticPlayer)?.resolution, .hiDPI)
        XCTAssertGreaterThanOrEqual(resumed.elapsed, savedTime - 0.02)
        XCTAssertLessThan(resumed.elapsed, savedTime + 0.1)
        renderer.stop()
        renderer.setPaused(false)
        XCTAssertNil(renderer.scene)
        XCTAssertFalse(renderer.hasLiveResources)
    }

    @MainActor func testOptionalWSSReferencePlaybackSmoke() async throws {
        let keys = [
            "AMBIENT_LOOSE_SCENE_FIXTURE", "AMBIENT_R2_SCENE_FIXTURE",
            "AMBIENT_R2_PARTICLE_FIXTURE", "AMBIENT_R3_SCENE_FIXTURE", "AMBIENT_W7_SCENE_FIXTURE",
        ]
        for key in keys {
            guard let path = ProcessInfo.processInfo.environment[key] else {
                throw XCTSkip("Set all native reference fixture variables")
            }
            try await smoke(URL(fileURLWithPath: path))
        }
    }

    @MainActor private func smoke(_ root: URL) async throws {
        guard let screen = NSScreen.main else { throw XCTSkip("Display required") }
        let item = try WallpaperImporter.resolve(root)
        let prepared = try await ScenePlayback.prepare(for: item)
        var errors: [String] = []
        let renderer = Renderer(
            wallpaper: item, screen: screen, scenePlayback: prepared, onError: { errors.append($0) }
        )
        defer { renderer.stop() }
        let session = try XCTUnwrap(renderer.scene)
        for _ in 0..<100 {
            if session.metrics.snapshot().frames > 0 || !errors.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
        XCTAssertGreaterThan(session.metrics.snapshot().frames, 0, root.lastPathComponent)
        print(
            "Playback boundary: \(root.lastPathComponent), \(session.metrics.snapshot().frames) live GPU frames"
        )
    }
}
