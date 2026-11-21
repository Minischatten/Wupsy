import AppKit
import MetalKit
import XCTest

@testable import Wupsy

@MainActor final class WallpaperTransitionTests: XCTestCase {
    func testImageAndBothSceneKindsReplaceOnlyAfterCoverageIsInstalled() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var started: [Renderer] = []
        let library = fixture.library(rendererStart: { renderer, _ in
            started.append(renderer)
            renderer.setPaused(false)
        })
        defer { library.stop() }
        try await accepted(library.apply(fixture.image))
        var previous = try XCTUnwrap(library.renderers.first)
        for item in [
            fixture.secondImage, fixture.staticScene, fixture.animatedScene, fixture.image,
        ] {
            let request = library.apply(item, source: .automatic)
            XCTAssertTrue(library.renderers.first === previous)
            XCTAssertFalse(previous.stopped)
            try await accepted(request)
            let current = try XCTUnwrap(library.renderers.first)
            XCTAssertTrue(current === started.last)
            XCTAssertTrue(current.window.isVisible)
            XCTAssertTrue(previous.stopped)
            XCTAssertFalse(previous.hasLiveResources)
            XCTAssertEqual(library.active?.id, item.id)
            XCTAssertEqual(
                fixture.store.defaults.string(forKey: "activeWallpaper"), item.id.uuidString)
            if item.kind == .scene {
                XCTAssertNotNil(current.scene)
                XCTAssertTrue(current.hasTransitionStill)
                XCTAssertNotNil(current.window.contentView)
            } else {
                XCTAssertNotNil((current.window.contentView as? NSImageView)?.image)
            }
            previous = current
        }
        library.stop()
        XCTAssertFalse(previous.hasLiveResources)
    }

    func testFailureAndSupersessionKeepOldCoverageUntilNewestApply() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let entered = expectation(description: "B started preparing")
        var resumeB: CheckedContinuation<Void, Never>?
        let library = fixture.library(scenePreparation: { item in
            if item.id == fixture.animatedScene.id {
                await withCheckedContinuation {
                    resumeB = $0
                    entered.fulfill()
                }
            }
            return try await ScenePlayback.prepare(for: item)
        })
        defer {
            resumeB?.resume()
            library.stop()
        }
        try await accepted(library.apply(fixture.image))
        let old = try XCTUnwrap(library.renderers.first)

        try FileManager.default.removeItem(at: fixture.staticScene.url)
        let failed = await library.apply(fixture.staticScene).outcome
        guard case .failed = failed else { return XCTFail("Expected invalid scene to fail") }
        XCTAssertEqual(library.active?.id, fixture.image.id)
        XCTAssertTrue(library.renderers.first === old)
        XCTAssertTrue(old.window.isVisible)

        let b = library.apply(fixture.animatedScene)
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(library.renderers.first === old)
        let c = library.apply(fixture.secondImage)
        guard case .superseded = await b.outcome else { return XCTFail("Expected B to cancel") }
        XCTAssertFalse(old.stopped)
        try await accepted(c)
        resumeB?.resume()
        resumeB = nil
        XCTAssertEqual(library.active?.id, fixture.secondImage.id)
        XCTAssertFalse(old.hasLiveResources)
    }

    func testTopologyChangeBeforeCommitDiscardsCandidate() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var available = [fixture.screen]
        var candidate: Renderer?
        let library = fixture.library(
            screens: { available },
            rendererStart: { renderer, _ in
                renderer.setPaused(false)
                if renderer.wallpaper.id == fixture.secondImage.id {
                    candidate = renderer
                    available = []
                }
            })
        defer { library.stop() }
        try await accepted(library.apply(fixture.image))
        let old = try XCTUnwrap(library.renderers.first)
        guard case .failed = await library.apply(fixture.secondImage).outcome else {
            return XCTFail("Expected topology rejection")
        }
        XCTAssertTrue(library.renderers.first === old)
        XCTAssertFalse(old.stopped)
        XCTAssertFalse(try XCTUnwrap(candidate).hasLiveResources)
    }

    func testWebAndGIFStillUseTheExistingStartPath() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let html = try fixture.store.file("index.html", bytes: Data("<html>Test</html>".utf8))
        let gif = try fixture.store.file(
            "animated.gif",
            bytes: XCTUnwrap(
                Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")))
        let library = fixture.library()
        defer { library.stop() }
        for (url, nativeGIF) in [(html, false), (gif, true)] {
            try await accepted(library.apply(fixture.image))
            let old = try XCTUnwrap(library.renderers.first)
            let item = Wallpaper(
                title: "Media", path: url.path, root: url.deletingLastPathComponent().path,
                kind: .web)
            let request = library.apply(item)
            XCTAssertTrue(old.stopped)
            try await accepted(request)
            let current = try XCTUnwrap(library.renderers.first)
            XCTAssertEqual(current.gif != nil, nativeGIF)
            XCTAssertEqual(current.web != nil, !nativeGIF)
            XCTAssertFalse(current.hasTransitionStill)
        }
    }

    private func accepted(_ request: WallpaperApplyRequest) async throws {
        guard case .accepted = await request.outcome else {
            throw ImportFailure.message("Expected an accepted Apply request")
        }
    }

    private struct Fixture {
        let store = LibraryBackupTests()
        let scenes = WSSNativeSceneTests()
        let screen: NSScreen
        let image: Wallpaper
        let secondImage: Wallpaper
        let staticScene: Wallpaper
        let animatedScene: Wallpaper

        init() throws {
            guard let display = NSScreen.main else { throw XCTSkip("Desktop display required") }
            screen = display
            try store.setUpWithError()
            try scenes.setUpWithError()
            store.defaults.set(false, forKey: "conserve")
            store.defaults.set(false, forKey: "pauseOnBattery")
            store.defaults.set(
                SceneRenderResolution.standard.rawValue, forKey: SceneRenderResolution.preferenceKey
            )
            image = try WallpaperImporter.resolve(store.file("a.png", bytes: scenes.png()))
            secondImage = try WallpaperImporter.resolve(store.file("c.png", bytes: scenes.png()))
            staticScene = try WallpaperImporter.resolve(scenes.fixture(name: "Static"))
            animatedScene = try WallpaperImporter.resolve(
                scenes.fixture(scenes.document(clouds: true), name: "Animated"))
            try store.save([image, secondImage, staticScene, animatedScene])
        }

        @MainActor func library(
            screens: (() -> [NSScreen])? = nil,
            rendererStart: @escaping @MainActor (Renderer, Int) throws -> Void = { renderer, _ in
                renderer.setPaused(false)
            },
            scenePreparation: @escaping (Wallpaper) async throws -> PreparedScenePlayback = {
                try await ScenePlayback.prepare(for: $0)
            }
        ) -> Library {
            Library(
                maintenance: MaintenanceCoordinator(), storage: store.storage,
                defaults: store.defaults,
                restoreOnLaunch: false, targetScreens: screens ?? { [screen] },
                rendererStart: rendererStart, scenePreparation: scenePreparation)
        }

        func cleanUp() {
            try? scenes.tearDownWithError()
            try? store.tearDownWithError()
        }
    }
}
