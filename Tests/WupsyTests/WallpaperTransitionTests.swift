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
                if item.id == fixture.animatedScene.id {
                    let player = try XCTUnwrap(current.scene)
                    let metrics = try XCTUnwrap(player.startMeasuring())
                    for _ in 0..<120 where metrics.snapshot().frames < 3 {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    XCTAssertGreaterThanOrEqual(metrics.snapshot().frames, 3)
                    XCTAssertGreaterThan(player.elapsed, 0)
                }
            } else {
                XCTAssertNotNil((current.window.contentView as? NSImageView)?.image)
            }
            previous = current
        }
        library.stop()
        XCTAssertFalse(previous.hasLiveResources)
    }

    func testDesktopPauseKeepsVisiblePlayerAndDefersApply() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let library = fixture.library()
        defer { library.stop() }
        try await accepted(library.apply(fixture.animatedScene))
        let renderer = try XCTUnwrap(library.renderers.first)
        let player = try XCTUnwrap(renderer.scene as? WSSStaticPlayer)
        let view = player.view
        let collector = try XCTUnwrap(player.startMeasuring())
        for _ in 0..<120 where collector.snapshot().frames == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(collector.snapshot().frames, 0)
        library.manuallyPaused = true
        try await Task.sleep(for: .milliseconds(250))
        let frozen = player.elapsed
        _ = player.performanceSnapshot()
        let completed = collector.snapshot()
        for _ in 0..<5 { view.draw() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(player.elapsed, frozen)
        XCTAssertEqual(collector.snapshot(), completed)
        XCTAssertTrue(renderer.window.isVisible)
        XCTAssertTrue(renderer.scene === player)
        XCTAssertTrue(player.view === view)
        let paused = try XCTUnwrap(player.performanceSnapshot())
        let frames = try XCTUnwrap(paused.frameWindow)
        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(frames.submissions, 0)
        XCTAssertEqual(frames.presentedFPS, 0)
        XCTAssertEqual(frames.gpuCompletionsPerSecond, 0)
        XCTAssertNil(frames.averageCPUMilliseconds)
        XCTAssertNil(frames.averageGPUMilliseconds)

        library.manuallyPaused = false
        for _ in 0..<120 where collector.snapshot().frames < completed.frames + 3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(collector.snapshot().frames, completed.frames + 3)
        XCTAssertTrue(renderer.scene === player)
        XCTAssertGreaterThan(player.elapsed, frozen)
        library.manuallyPaused = true
        library.manuallyPaused = false
        library.manuallyPaused = true
        let replaced = library.apply(fixture.image)
        let queued = library.apply(fixture.secondImage)
        guard case .superseded = await replaced.outcome else {
            return XCTFail("Expected the newer deferred apply to replace the first")
        }
        XCTAssertTrue(library.renderers.first === renderer)
        XCTAssertEqual(library.active?.id, fixture.animatedScene.id)
        XCTAssertTrue(renderer.window.isVisible)
        library.manuallyPaused = false
        try await accepted(queued)
        XCTAssertEqual(library.active?.id, fixture.secondImage.id)
        XCTAssertFalse(renderer.hasLiveResources)

        try await accepted(library.apply(fixture.animatedScene))
        let last = try XCTUnwrap(library.renderers.first)
        library.manuallyPaused = true
        let cancelled = library.apply(fixture.image)
        library.stop()
        guard case .superseded = await cancelled.outcome else {
            return XCTFail("Expected Stop to cancel the deferred apply")
        }
        XCTAssertFalse(last.hasLiveResources)
        XCTAssertFalse(last.window.isVisible)
    }

    func testRetainedDesktopPauseCanStillReleaseUnderSystemPolicy() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let library = fixture.library()
        defer { library.stop() }
        try await accepted(library.apply(fixture.animatedScene))
        let renderer = try XCTUnwrap(library.renderers.first)
        library.manuallyPaused = true
        XCTAssertTrue(renderer.hasFrozenScene)
        var conditions = PlaybackConditions()
        conditions.manual = true
        conditions.memoryPressure = true
        XCTAssertEqual(conditions.reason(conserve: false, pauseOnBattery: false), .manual)
        XCTAssertEqual(conditions.systemReason(conserve: false, pauseOnBattery: false), .memory)
        renderer.setPaused(true, retainingScene: false)
        XCTAssertFalse(renderer.hasLiveResources)
        XCTAssertFalse(renderer.window.isVisible)
        await renderer.stopAndDrainForMaintenance()
        XCTAssertTrue(renderer.stopped)
    }

    func testAnimatedDesktopTransitionClockDoesNotWaitForPresentation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let library = fixture.library()
        defer { library.stop() }
        var document = fixture.scenes.document()
        var notes = WSSMusicNotesLayer(region: .init(x: 0, y: 0, width: 64, height: 64))
        notes.placement = .freeSingle
        notes.freeSymbol = .init()
        notes.freeSymbol?.rotationMode = .continuous
        notes.freeSymbol?.spinAxis = .vertical
        notes.freeSymbol?.spinPeriod = 5
        let node = WSSSceneDocumentV1.Layer(content: .musicNotes(notes))
        document["layers"] = [try JSONSerialization.jsonObject(with: JSONEncoder().encode(node))]
        let item = try WallpaperImporter.resolve(
            fixture.scenes.fixture(document, name: "Spinning Notes"))

        // No presented drawable is possible in this detached view. The
        // transition must still start the clock and arm the timed draw loop.
        let prepared = try await ScenePlayback.prepare(for: item)
        let detached = WSSStaticPlayer(
            resources: prepared.resources, size: CGSize(width: 128, height: 128), scale: 1,
            maxDimension: 128, fps: 30, resolution: .standard, offset: 0,
            onFirstFramePresented: { XCTFail("Detached view cannot present") },
            onError: { XCTFail($0) })
        let detachedMetrics = try XCTUnwrap(detached.startMeasuring())
        detached.playFromStill()
        XCTAssertFalse(detached.view.isPaused)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(detachedMetrics.snapshot().frames, 0)
        XCTAssertGreaterThan(detached.elapsed, 0)
        detached.stop()

        try await accepted(library.apply(fixture.image))
        try await accepted(library.apply(item))
        let desktop = try XCTUnwrap(library.renderers.first?.scene as? WSSStaticPlayer)
        let metrics = try XCTUnwrap(desktop.startMeasuring())
        guard case .musicNotes(let loaded) = desktop.resources.scene.layers.first else {
            return XCTFail("Saved Music Notes layer missing from desktop resources")
        }
        XCTAssertEqual(loaded, notes)
        for _ in 0..<120 where metrics.snapshot().frames < 3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(metrics.snapshot().frames, 3)
        let time = desktop.elapsed
        XCTAssertGreaterThan(time, 0)
        XCTAssertFalse(desktop.view.isPaused)
        let render = WSSStormLightingRenderTests()
        let still = try render.render(desktop.resources, time: 0).0
        let advanced = try render.render(desktop.resources, time: max(time, 0.3)).0
        XCTAssertNotEqual(still, advanced)
        desktop.pause()
        let paused = desktop.elapsed
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(desktop.elapsed, paused)
        let completed = metrics.snapshot().frames
        desktop.play()
        for _ in 0..<100 where metrics.snapshot().frames <= completed {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(desktop.elapsed, paused)
        XCTAssertGreaterThan(metrics.snapshot().frames, completed)
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
