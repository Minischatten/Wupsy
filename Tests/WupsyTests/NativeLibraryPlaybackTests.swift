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
        Library(
            storage: helper.store.storage, defaults: defaults,
            rendererStart: { renderer, _ in
                renderer.measuresPerformance = true
                renderer.setPaused(false)
            },
            scenePreparation: preparation)
    }

    func item() async throws -> Wallpaper {
        try await helper.store.importWallpaper(helper.nativeSource(), existing: [])
    }
    func testNativeApplyAndEditorOpenKeepTheSameManifestCause() async throws {
        let item = try await item()
        let library = library()
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: item.url)) as? [String: Any])
        var layers = try XCTUnwrap(json["layers"] as? [[String: Any]])
        layers[0]["futureField"] = true
        json["layers"] = layers
        try JSONSerialization.data(withJSONObject: json).write(to: item.url)
        let expected = WSSDocumentError.unknownFields(["futureField"], path: "$.layers[0]")
        let outcome = await library.apply(item).outcome
        guard case .failed(let applyError) = outcome else {
            return XCTFail("Expected preparation to fail")
        }
        XCTAssertEqual(applyError as? WSSDocumentError, expected)
        let playbackReport = try XCTUnwrap(library.importFailureReport)
        let playback = try XCTUnwrap(playbackReport.failures.first)
        XCTAssertEqual(playbackReport.heading, ProductText.wallpaperPlaybackFailed.text)
        XCTAssertTrue(playback.technicalDetails.contains("$.layers[0]"))
        XCTAssertNil(library.message)

        do {
            _ = try await WSSEditorProjectLoader().load(item)
            XCTFail("Expected editor loading to fail")
        } catch {
            XCTAssertEqual(error as? WSSDocumentError, expected)
            library.presentWallpaperFailure(error, item: item, operation: .editorOpenError)
            let editorReport = try XCTUnwrap(library.importFailureReport)
            let editor = try XCTUnwrap(editorReport.failures.first)
            XCTAssertEqual(editorReport.heading, ProductText.editorOpenError.text)
            XCTAssertEqual(editor.explanation, playback.explanation)
            XCTAssertEqual(editor.technicalDetails, playback.technicalDetails)
        }
    }

    func running(_ library: Library) async throws -> any ScenePlaybackSession {
        for _ in 0..<500 {
            if let scene = library.renderers.first?.scene,
                let metrics = scene.metrics, metrics.snapshot().frames > 0
            {
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
