import MetalKit
import XCTest

@testable import Wupsy

// Real Library/Renderer tests; isolated Legacy renderer tests construct their players directly.
@MainActor final class NativeLibraryPlaybackTests: XCTestCase {
    var helper: ManagedLibraryTests!
    var defaults: UserDefaults!
    var suite: String!
    override func setUpWithError() throws {
        helper = ManagedLibraryTests()
        try helper.setUpWithError()
        suite = UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        for key in ["conserve", "pauseOnBattery", "allDisplays"] {
            defaults.set(false, forKey: key)
        }
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try helper.tearDownWithError()
    }
    func library(
        _ preparation: @escaping (Wallpaper) async throws -> PreparedScenePlayback = {
            try await ScenePlayback.prepare(for: $0)
        }
    ) -> Library {
        Library(storage: helper.store.storage, defaults: defaults, scenePreparation: preparation)
    }

    func item() async throws -> Wallpaper {
        try await helper.store.importWallpaper(helper.nativeSource(), existing: [])
    }
    func running(_ library: Library) async throws -> any ScenePlaybackSession {
        for _ in 0..<500 {
            if let scene = library.renderers.first?.scene, scene.metrics.snapshot().frames > 0 {
                return scene
            }
            if library.message != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ImportFailure.message(library.message ?? "No live frame")
    }
    func reload(_ library: Library, _ item: Wallpaper) async {
        library.message = nil
        library.apply(item)
        for _ in 0..<500 {
            if library.message != nil
                || (!library.preparing && library.renderers.first?.scene != nil)
            {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
