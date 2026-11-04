import AppKit
import WebKit
import XCTest

@testable import Wupsy

@MainActor final class WallpaperApplyTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var libraries: [Library] = []

    override func setUpWithError() throws {
        suite = "WupsyApplyTests-" + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "conserve")
        defaults.set(false, forKey: "pauseOnBattery")
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        for library in libraries { library.stop() }
        libraries.removeAll()
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }
    private func item(_ name: String = "image") throws -> Wallpaper {
        let url = root.appendingPathComponent(name + ".png")
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return Wallpaper(title: name, path: url.path, root: root.path, kind: .image)
    }
    private func library(
        screens: (() -> [NSScreen])? = nil,
        start: @escaping @MainActor (Renderer, Int) throws -> Void = { renderer, _ in
            renderer.setPaused(false)
        },
        prepare: @escaping (Wallpaper) async throws -> PreparedScenePlayback = {
            try await ScenePlayback.prepare(for: $0)
        }
    ) throws -> Library {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let library = Library(
            storage: root.appendingPathComponent("library.json"), defaults: defaults,
            targetScreens: screens ?? { [screen] }, rendererStart: start,
            scenePreparation: prepare)
        libraries.append(library)
        return library
    }
    private func accepted(
        _ outcome: WallpaperApplyOutcome, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .accepted = outcome else {
            return XCTFail("Expected acceptance", file: file, line: line)
        }
    }
    private func failed(
        _ outcome: WallpaperApplyOutcome, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .failed = outcome else {
            return XCTFail("Expected failure", file: file, line: line)
        }
    }
    private func superseded(
        _ outcome: WallpaperApplyOutcome, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .superseded = outcome else {
            return XCTFail("Expected supersession", file: file, line: line)
        }
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition did not become true")
    }
    func testAcceptancePersistsOnlyAfterAllTargetsStartAndQuitPreservesIt() async throws {
        let wallpaper = try item()
        var started = 0
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let lib = try library(
            screens: { [screen, screen] },
            start: { renderer, _ in
                XCTAssertNil(self.defaults.string(forKey: "activeWallpaper"))
                renderer.setPaused(false)
                started += 1
            })
        let request = lib.apply(wallpaper)
        XCTAssertNil(defaults.string(forKey: "activeWallpaper"))
        accepted(await request.outcome)
        XCTAssertEqual(started, 2)
        XCTAssertEqual(lib.renderers.count, 2)
        XCTAssertEqual(defaults.string(forKey: "activeWallpaper"), wallpaper.id.uuidString)
        lib.stop(preserveSelection: true)
        XCTAssertEqual(defaults.string(forKey: "activeWallpaper"), wallpaper.id.uuidString)
        accepted(await request.outcome)
        lib.stop()
        XCTAssertNil(defaults.string(forKey: "activeWallpaper"))
    }
    func testMissingFileFailsSynchronouslyWithoutReplacingAcceptedReference() async throws {
        let lib = try library()
        let first = try item()
        accepted(await lib.apply(first).outcome)
        var missing = first
        missing.id = UUID()
        missing.path = root.appendingPathComponent("missing.png").path
        failed(await lib.apply(missing).outcome)
        XCTAssertEqual(lib.active?.id, first.id)
        XCTAssertEqual(defaults.string(forKey: "activeWallpaper"), first.id.uuidString)
    }
    func testAsyncPreparationFailureDoesNotPersistCandidate() async throws {
        let first = try item()
        let lib = try library(prepare: { _ in throw ImportFailure.message("injected preparation") })
        accepted(await lib.apply(first).outcome)
        var scene = first
        scene.id = UUID()
        scene.kind = .scene
        failed(await lib.apply(scene).outcome)
        XCTAssertEqual(lib.message, "injected preparation")
        XCTAssertEqual(lib.messagePresentation, ProductText.playbackError.text)
        XCTAssertEqual(defaults.string(forKey: "activeWallpaper"), first.id.uuidString)
        XCTAssertNil(lib.active)
        XCTAssertTrue(lib.renderers.isEmpty)
    }
    func testLateFailureFromSupersededPreparationCannotAffectNewRequest() async throws {
        var continuation: CheckedContinuation<PreparedScenePlayback, Error>?
        let lib = try library(prepare: { _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        })
        let next = try item()
        var slow = next
        slow.id = UUID()
        slow.kind = .scene
        let a = lib.apply(slow)
        try await waitUntil { continuation != nil }
        let b = lib.apply(next)
        superseded(await a.outcome)
        accepted(await b.outcome)
        continuation?.resume(throwing: ImportFailure.message("obsolete error"))
        await Task.yield()
        XCTAssertNil(lib.message)
        XCTAssertEqual(lib.active?.id, next.id)
        XCTAssertEqual(defaults.string(forKey: "activeWallpaper"), next.id.uuidString)
        superseded(await a.outcome)
    }
    func testPauseDefersAcceptanceAndSupersessionUntilResume() async throws {
        let lib = try library()
        lib.manuallyPaused = true
        let first = try item("first")
        let next = try item("next")
        let a = lib.apply(first)
        XCTAssertFalse(lib.preparing)
        XCTAssertTrue(lib.renderers.isEmpty)
        XCTAssertNil(defaults.string(forKey: "activeWallpaper"))
        let b = lib.apply(next)
        superseded(await a.outcome)
        lib.profile = .eco  // Internal rebuild must retain B's request.
        lib.manuallyPaused = false
        accepted(await b.outcome)
        XCTAssertEqual(defaults.string(forKey: "activeWallpaper"), next.id.uuidString)
        lib.manuallyPaused = true
        XCTAssertTrue(lib.renderers.allSatisfy { !$0.hasLiveResources })
        accepted(await b.outcome)
    }
    func testPartialDisplayStartupFailureStopsEveryRendererWithoutAcceptance() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        var created: [Renderer] = []
        let lib = try library(
            screens: { [screen, screen] },
            start: { renderer, index in
                created.append(renderer)
                if index == 1 { throw ImportFailure.message("second display failed") }
                renderer.setPaused(false)
            })
        failed(await lib.apply(try item()).outcome)
        XCTAssertEqual(created.count, 2)
        XCTAssertTrue(created.allSatisfy { !$0.hasLiveResources })
        XCTAssertTrue(lib.renderers.isEmpty)
        XCTAssertNil(defaults.string(forKey: "activeWallpaper"))
    }
    func testNoTargetsFailsAndInternalRebuildDoesNotChangeTerminalOutcome() async throws {
        var connected = true
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let lib = try library(screens: { connected ? [screen] : [] })
        let wallpaper = try item()
        let request = lib.apply(wallpaper)
        accepted(await request.outcome)
        connected = false
        lib.allDisplays = false
        try await waitUntil { lib.message != nil }
        accepted(await request.outcome)
        XCTAssertEqual(defaults.string(forKey: "activeWallpaper"), wallpaper.id.uuidString)
        failed(await lib.apply(wallpaper).outcome)
    }
    func testLateRuntimeFailurePausesWithoutRewritingAcceptedOutcome() async throws {
        let lib = try library()
        let request = lib.apply(try item())
        accepted(await request.outcome)
        let renderer = try XCTUnwrap(lib.renderers.first)
        renderer.webViewWebContentProcessDidTerminate(WKWebView())
        try await waitUntil { lib.manuallyPaused }
        XCTAssertTrue(lib.manuallyPaused)
        XCTAssertTrue(lib.renderers.allSatisfy { !$0.hasLiveResources })
        accepted(await request.outcome)
        XCTAssertNotNil(defaults.string(forKey: "activeWallpaper"))
    }
    func testCallerCancellationStopsPendingRequest() async throws {
        let lib = try library()
        lib.manuallyPaused = true
        let request = lib.apply(try item())
        let waiter = Task { await request.outcome }
        waiter.cancel()
        superseded(await waiter.value)
        XCTAssertNil(lib.active)
        XCTAssertNil(defaults.string(forKey: "activeWallpaper"))
    }
    func testSynchronousGIFStartupFailureIsNotAccepted() async throws {
        let url = root.appendingPathComponent("bad.gif")
        try Data("invalid gif".utf8).write(to: url)
        let lib = try library()
        let wallpaper = Wallpaper(title: "Bad GIF", path: url.path, root: root.path, kind: .web)
        failed(await lib.apply(wallpaper).outcome)
        XCTAssertFalse(lib.manuallyPaused)
        XCTAssertTrue(lib.renderers.isEmpty)
        XCTAssertNil(defaults.string(forKey: "activeWallpaper"))
    }
    func testLateSuccessfulPreparationCannotInstallAfterSupersessionOrPause() async throws {
        let helper = NativeProjectTestFixture()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let scene = try helper.item()
        let resources = try await ScenePlayback.prepare(for: scene)
        var continuations: [CheckedContinuation<PreparedScenePlayback, Error>] = []
        let lib = try library(prepare: { _ in
            try await withCheckedThrowingContinuation { continuations.append($0) }
        })
        let a = lib.apply(scene)
        try await waitUntil { continuations.count == 1 }
        lib.manuallyPaused = true
        XCTAssertFalse(lib.preparing)
        XCTAssertNil(defaults.string(forKey: "activeWallpaper"))
        lib.manuallyPaused = false
        try await waitUntil { continuations.count == 2 }
        continuations[0].resume(returning: resources)
        await Task.yield()
        XCTAssertTrue(lib.renderers.isEmpty)
        let next = try item()
        let b = lib.apply(next)
        superseded(await a.outcome)
        continuations[1].resume(returning: resources)
        accepted(await b.outcome)
        await Task.yield()
        XCTAssertEqual(lib.renderers.count, 1)
        XCTAssertEqual(lib.renderers.first?.wallpaper.id, next.id)
        XCTAssertNil(lib.message)
        XCTAssertEqual(defaults.string(forKey: "activeWallpaper"), next.id.uuidString)
    }
    func testDamagedNativeProjectFailsWithoutChangingSourceOrNativeFiles() async throws {
        let helper = NativeProjectTestFixture()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let scene = try helper.item()
        _ = try await ScenePlayback.prepare(for: scene)
        let project = try helper.project(scene)
        try Data("damaged native document".utf8).write(
            to: project.appendingPathComponent("scene.wss.json"))
        let nativeBefore = try helper.snapshot(project)
        let sourceBefore = try helper.snapshot(URL(fileURLWithPath: scene.root))
        let lib = try library()
        failed(await lib.apply(scene).outcome)
        XCTAssertEqual(try helper.snapshot(project), nativeBefore)
        XCTAssertEqual(try helper.snapshot(URL(fileURLWithPath: scene.root)), sourceBefore)
        XCTAssertNil(defaults.string(forKey: "activeWallpaper"))
    }
    func testStopAndRejectedSuccessorResolvePendingRequest() async throws {
        let lib = try library()
        lib.manuallyPaused = true
        let wallpaper = try item()
        let a = lib.apply(wallpaper)
        var missing = wallpaper
        missing.path = root.appendingPathComponent("missing").path
        failed(await lib.apply(missing).outcome)
        superseded(await a.outcome)
        XCTAssertNil(lib.active)
        let b = lib.apply(wallpaper)
        lib.stop()
        superseded(await b.outcome)
    }
    func testRebuildDuringPreparationRetainsExternalRequest() async throws {
        let helper = NativeProjectTestFixture()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let scene = try helper.item()
        let resources = try await ScenePlayback.prepare(for: scene)
        var continuations: [CheckedContinuation<PreparedScenePlayback, Error>] = []
        let lib = try library(prepare: { _ in
            try await withCheckedThrowingContinuation { continuations.append($0) }
        })
        let request = lib.apply(scene)
        try await waitUntil { continuations.count == 1 }
        lib.profile = .balanced
        try await waitUntil { continuations.count == 2 }
        continuations[0].resume(throwing: ImportFailure.message("obsolete rebuild"))
        continuations[1].resume(returning: resources)
        accepted(await request.outcome)
        XCTAssertEqual(lib.renderers.first?.profile, .balanced)
        XCTAssertNil(lib.message)
    }
    func testRealImageGIFHTMLAndSceneSwitchesReleasePreviousResources() async throws {
        let helper = NativeProjectTestFixture()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let lib = try library()
        let gif = root.appendingPathComponent("tiny.gif")
        try XCTUnwrap(
            Data(
                base64Encoded:
                    "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")
        ).write(to: gif)
        let html = root.appendingPathComponent("index.html")
        try Data("<html><body>Apply integration fixture</body></html>".utf8).write(to: html)
        let entries = [
            try item(),
            Wallpaper(title: "GIF", path: gif.path, root: root.path, kind: .web),
            Wallpaper(title: "HTML", path: html.path, root: root.path, kind: .web),
            try helper.item(),
            try item("last"),
        ]
        var previous: Renderer?
        for entry in entries {
            accepted(await lib.apply(entry).outcome)
            if let previous { XCTAssertFalse(previous.hasLiveResources) }
            previous = try XCTUnwrap(lib.renderers.first)
            XCTAssertEqual(previous?.wallpaper.id, entry.id)
        }
    }

    func testRestartRestoresAcceptedWallpaperInsteadOfPendingCandidate() async throws {
        let first = try item("accepted")
        let next = try item("pending")
        try JSONEncoder().encode([first, next]).write(
            to: root.appendingPathComponent("library.json"))
        let lib = try library()
        accepted(await lib.apply(first).outcome)
        lib.manuallyPaused = true
        let request = lib.apply(next)
        lib.stop(preserveSelection: true)
        superseded(await request.outcome)
        let restarted = try library()
        restarted.restorePlayback()
        XCTAssertEqual(restarted.active?.id, first.id)
        XCTAssertTrue(restarted.manuallyPaused)
        XCTAssertTrue(restarted.renderers.isEmpty)
        restarted.manuallyPaused = false
        try await waitUntil { !restarted.preparing && !restarted.renderers.isEmpty }
        XCTAssertEqual(defaults.string(forKey: "activeWallpaper"), first.id.uuidString)
        XCTAssertEqual(restarted.renderers.first?.wallpaper.id, first.id)
    }
    func testPendingRequestResolvesWhenLibraryIsReleased() async throws {
        var lib: Library? = Library(
            storage: root.appendingPathComponent("library.json"), defaults: defaults)
        lib?.manuallyPaused = true
        let request = try XCTUnwrap(lib).apply(try item())
        weak var released = lib
        lib = nil
        XCTAssertNil(released)
        superseded(await request.outcome)
    }

    func testQueuedRuntimeErrorFromPreviousApplyCannotPauseSuccessor() async throws {
        let lib = try library()
        accepted(await lib.apply(try item("first")).outcome)
        let renderer = try XCTUnwrap(lib.renderers.first)
        renderer.webViewWebContentProcessDidTerminate(WKWebView())
        let next = try item("next")
        accepted(await lib.apply(next).outcome)
        XCTAssertFalse(lib.manuallyPaused)
        XCTAssertNil(lib.message)
        XCTAssertEqual(lib.active?.id, next.id)
    }

}
