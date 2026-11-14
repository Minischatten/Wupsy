import AppKit
import Combine
import WebKit
import XCTest

@testable import Wupsy

@MainActor private final class ReplacementClock: PlaylistScheduling {
    var now: TimeInterval = 0
    var schedules = 0
    var due: TimeInterval = 0
    var alarmID: UUID?
    var action: (() -> Void)?
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void)
        -> AnyCancellable
    {
        schedules += 1
        due = now + seconds
        let id = UUID()
        alarmID = id
        self.action = action
        return AnyCancellable { [weak self] in
            if self?.alarmID == id {
                self?.alarmID = nil
                self?.action = nil
            }
        }
    }
    func fire() {
        now = due
        let callback = action
        alarmID = nil
        action = nil
        callback?()
    }
}

@MainActor final class WSSImageReplacementPlaybackTests: XCTestCase {
    private var helper: WSSDraftTests!
    private var store: ManagedWallpaperStore!
    private var defaults: UserDefaults!
    private var suite: String!
    private var libraries: [Library] = []
    private var playlists: [WallpaperPlaylist] = []
    private var projects: [WSSLoadedEditorProject] = []
    override func setUp() async throws {
        helper = WSSDraftTests()
        try await helper.setUp()
        store = helper.store()
        suite = "ReplacementPlayback-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "conserve")
        defaults.set(false, forKey: "pauseOnBattery")
        defaults.set("eco", forKey: "profile")
    }
    override func tearDown() async throws {
        for playlist in playlists { playlist.shutdown() }
        for library in libraries {
            library.stop()
            await library.stopAndDrainForMaintenance()
        }
        for project in projects { try project.handle.draftOwner?.discard() }
        playlists = []
        libraries = []
        projects = []
        defaults.removePersistentDomain(forName: suite)
        try await helper.tearDown()
    }
    private func image() async throws -> Wallpaper {
        try await store.importWallpaper(helper.image(), existing: [])
    }
    private func draft(_ item: Wallpaper) async throws -> (
        WSSLoadedEditorProject, WSSSaveAsSnapshot
    ) {
        let (project, target) = try await WSSDraftPreparation().create(libraryImage: item)
        projects.append(project)
        let snapshot = try WSSSaveAsSnapshot(
            document: project.document,
            state: WSSEditorDocumentState(model: project.document, diskBasis: project.diskBasis),
            source: project.handle, name: item.title, destinationID: project.handle.id,
            publication: .replacing(target))
        return (project, snapshot)
    }
    private func library(
        hook: @escaping (String) async -> Void = { _ in },
        screens: (() -> [NSScreen])? = nil,
        start: @escaping @MainActor (Renderer, Int) throws -> Void = { renderer, _ in
            renderer.setPaused(false)
        },
        preparation: @escaping (Wallpaper) async throws -> PreparedScenePlayback = {
            try await ScenePlayback.prepare(for: $0)
        },
        preview: ((WSSLoadedEditorProject) async -> Bool)? = nil
    ) throws -> Library {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let lib = Library(
            maintenance: MaintenanceCoordinator(), beforeLibraryPublication: hook,
            storage: store.storage, defaults: defaults, restoreOnLaunch: false,
            targetScreens: screens ?? { [screen] }, rendererStart: start,
            scenePreparation: preparation,
            makeVideoOptimizer: {
                VideoOptimizer(directory: self.helper.root.appendingPathComponent("cache"))
            },
            draftPreview: preview)
        libraries.append(lib)
        return lib
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Playback condition timed out")
        throw WSSSaveAsError.invalid
    }
    private func accept(_ request: WallpaperApplyRequest) async {
        guard case .accepted = await request.outcome else {
            return XCTFail("Apply was not accepted")
        }
    }
    private func playlist(
        _ lib: Library, first: Wallpaper, second: Wallpaper, clock: ReplacementClock,
        shuffle: @escaping ([UUID]) -> [UUID]
    ) async throws -> WallpaperPlaylist {
        let value = WallpaperPlaylist(
            library: lib, storage: helper.root.appendingPathComponent("playlists.json"),
            defaults: defaults, scheduler: clock, restoreOnLaunch: false, shuffle: shuffle)
        playlists.append(value)
        let id = try value.createPlaylist(name: "Retain timer and shuffle")
        try value.add(first.id, to: id)
        try value.add(second.id, to: id)
        try value.setPlaybackMode(playlistID: id, mode: .shuffle)
        value.activatePlaylist(id: id)
        try await wait { clock.alarmID != nil }
        XCTAssertEqual(lib.active?.id, first.id)
        return value
    }
    func testInactiveReplacementKeepsPlaylistTimerShuffleAndUsesSceneOnNextTick() async throws {
        let a = try await image()
        let b = try await image()
        let (_, snapshot) = try await draft(b)
        var starts = 0
        let lib = try library(start: { renderer, _ in
            starts += 1
            renderer.setPaused(false)
        })
        let clock = ReplacementClock()
        var shuffles = 0
        let list = try await playlist(
            lib, first: a, second: b, clock: clock,
            shuffle: { ids in
                shuffles += 1
                return ids.sorted { $0 == a.id && $1 != a.id }
            })
        let state = list.state
        let alarm = clock.alarmID
        let due = clock.due
        let schedules = clock.schedules
        let baseline = starts
        let rounds = shuffles
        let bytes = try Data(contentsOf: helper.root.appendingPathComponent("playlists.json"))
        let old = lib.renderers.map(ObjectIdentifier.init)
        let order = lib.items.map(\.id)
        clock.now += 7
        let receipt = try await lib.publishWSSDraft(snapshot)
        XCTAssertTrue(receipt.warnings.isEmpty)
        XCTAssertEqual(lib.active, a)
        XCTAssertEqual(lib.renderers.map(ObjectIdentifier.init), old)
        XCTAssertEqual(starts, baseline)
        XCTAssertEqual(list.state, state)
        XCTAssertEqual(clock.alarmID, alarm)
        XCTAssertEqual(clock.due, due)
        XCTAssertEqual(clock.schedules, schedules)
        XCTAssertEqual(shuffles, rounds)
        XCTAssertEqual(lib.items.map(\.id), order)
        XCTAssertEqual(
            try Data(contentsOf: helper.root.appendingPathComponent("playlists.json")), bytes)
        clock.fire()
        try await wait { list.state.playback?.currentWallpaperID == b.id && clock.alarmID != nil }
        XCTAssertEqual(lib.active?.kind, .scene)
        XCTAssertEqual(lib.renderers.first?.wallpaper.kind, .scene)
        XCTAssertEqual(shuffles, rounds)
    }
    func testActiveReplacementStagesBothDisplaysAndPreservesPlaylistInterval() async throws {
        let a = try await image()
        let b = try await image()
        let (_, snapshot) = try await draft(a)
        let screen = try XCTUnwrap(NSScreen.screens.first)
        var lib: Library!
        var stages = 0
        lib = try library(
            screens: { [screen, screen] },
            start: { renderer, _ in
                if renderer.wallpaper.kind == .scene {
                    XCTAssertTrue(
                        lib.renderers.allSatisfy { !$0.stopped && $0.wallpaper.kind == .image })
                    XCTAssertFalse(renderer.window.isVisible)
                    stages += 1
                }
                renderer.setPaused(false)
                if renderer.wallpaper.kind == .scene { XCTAssertFalse(renderer.window.isVisible) }
            })
        let clock = ReplacementClock()
        var shuffles = 0
        let list = try await playlist(
            lib, first: a, second: b, clock: clock,
            shuffle: { ids in
                shuffles += 1
                return ids.sorted { $0 == a.id && $1 != a.id }
            })
        let state = list.state
        let alarm = clock.alarmID
        let due = clock.due
        let schedules = clock.schedules
        let rounds = shuffles
        let old = lib.renderers
        let bytes = try Data(contentsOf: helper.root.appendingPathComponent("playlists.json"))
        clock.now += 9
        _ = try await lib.publishWSSDraft(snapshot)
        XCTAssertEqual(stages, 2)
        XCTAssertTrue(old.allSatisfy { $0.stopped })
        XCTAssertEqual(lib.renderers.count, 2)
        XCTAssertTrue(
            lib.renderers.allSatisfy { $0.wallpaper.kind == .scene && $0.window.isVisible })
        XCTAssertEqual(lib.active?.id, a.id)
        XCTAssertEqual(lib.active?.kind, .scene)
        XCTAssertEqual(defaults.string(forKey: "activeWallpaper"), a.id.uuidString)
        XCTAssertEqual(list.state, state)
        XCTAssertEqual(clock.alarmID, alarm)
        XCTAssertEqual(clock.due, due)
        XCTAssertEqual(clock.schedules, schedules)
        XCTAssertEqual(shuffles, rounds)
        XCTAssertEqual(
            try Data(contentsOf: helper.root.appendingPathComponent("playlists.json")), bytes)
    }
    func testTargetSelectionPreservesOtherWallpaperSlotsAndRejectsMissingDisplay() async throws {
        let a = try await image()
        let b = try await image()
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let renderers = [a, b, a].map {
            Renderer(
                wallpaper: $0, screen: screen, initiallyPaused: true,
                onError: { _ in XCTFail("Unexpected renderer error") })
        }
        defer { for renderer in renderers { renderer.stop() } }
        let chosen = try WSSDesktopRefreshTargets.select(
            id: a.id, renderers: renderers, screens: [screen])
        XCTAssertEqual(chosen.map(\.index), [0, 2])
        XCTAssertFalse(chosen.contains { $0.renderer === renderers[1] })
        XCTAssertFalse(renderers[1].stopped)
        XCTAssertThrowsError(
            try WSSDesktopRefreshTargets.select(id: a.id, renderers: renderers, screens: []))
    }
    func testPausedAcceptedAndStoppedPlaybackDoNotReactivateUnexpectedly() async throws {
        for stop in [false, true] {
            let item = try await image()
            let (_, snapshot) = try await draft(item)
            let lib = try library()
            await accept(lib.apply(item))
            if stop { lib.stop() } else { lib.manuallyPaused = true }
            _ = try await lib.publishWSSDraft(snapshot)
            if stop {
                XCTAssertNil(lib.active)
                XCTAssertTrue(lib.renderers.isEmpty)
            } else {
                XCTAssertEqual(lib.active?.kind, .scene)
                XCTAssertEqual(lib.pauseReason, .manual)
                XCTAssertTrue(lib.renderers.allSatisfy { $0.paused && !$0.window.isVisible })
                lib.manuallyPaused = false
                XCTAssertTrue(lib.renderers.allSatisfy { $0.wallpaper.kind == .scene })
            }
            lib.stop()
        }
    }
    func testStartupFailureAfterCommitKeepsOldDesktopAndSaveDoesNotRepublish() async throws {
        let item = try await image()
        let (project, snapshot) = try await draft(item)
        let screen = try XCTUnwrap(NSScreen.screens.first)
        var failures = true
        var candidates: [Renderer] = []
        let lib = try library(
            screens: { [screen, screen] },
            start: { renderer, index in
                renderer.setPaused(false)
                if renderer.wallpaper.kind == .scene {
                    candidates.append(renderer)
                    if failures && index == 1 { throw WSSSaveAsError.storage }
                }
            })
        await accept(lib.apply(item))
        let old = lib.renderers
        let doc = WSSEditorDocument(project: project, save: { try await lib.saveWSSManifest($0) })
        defer { doc.close() }
        doc.libraryImageReplacement = snapshot.publication.replacement
        var choices = 0
        var warnings = 0
        doc.chooseImageFirstSave = { name in
            choices += 1
            return .init(name: name, replace: true)
        }
        doc.publishDraft = { try await lib.publishWSSDraft($0) }
        doc.presentMessage = { _, _ in warnings += 1 }
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(warnings, 1)
        XCTAssertEqual(lib.items.first?.kind, .scene)
        XCTAssertEqual(lib.active?.kind, .image)
        XCTAssertEqual(lib.renderers.map(ObjectIdentifier.init), old.map(ObjectIdentifier.init))
        XCTAssertTrue(old.allSatisfy { !$0.stopped && $0.window.isVisible })
        XCTAssertTrue(candidates.allSatisfy { $0.stopped && !$0.window.isVisible })
        failures = false
        try doc.addEffect(.ripple)
        let again = await doc.save()
        XCTAssertTrue(again)
        XCTAssertEqual(lib.active?.kind, .scene)
        XCTAssertEqual(choices, 1)
        XCTAssertEqual(lib.items.count, 1)
    }
    func testThumbnailFailureIsWarningAfterSuccessfulDesktopHandoff() async throws {
        let item = try await image()
        let (_, snapshot) = try await draft(item)
        let lib = try library(preview: { _ in false })
        await accept(lib.apply(item))
        let receipt = try await lib.publishWSSDraft(snapshot)
        XCTAssertEqual(receipt.warnings, [EditorText.thumbnailWarning.text])
        XCTAssertEqual(lib.active?.kind, .scene)
        XCTAssertEqual(lib.items.count, 1)
        XCTAssertTrue(lib.renderers.allSatisfy { $0.wallpaper.kind == .scene })
    }
    func testPlaylistCanSwitchAwayOrIntoTargetDuringPublication() async throws {
        for switchInto in [false, true] {
            let a = try await image()
            let b = try await image()
            let target = switchInto ? b : a
            let (_, snapshot) = try await draft(target)
            let clock = ReplacementClock()
            var list: WallpaperPlaylist!
            let lib = try library(hook: { operation in
                if operation == "publishWSSDraft" {
                    clock.fire()
                    try? await self.wait { list.state.playback?.currentWallpaperID == b.id }
                }
            })
            var shuffles = 0
            list = try await playlist(
                lib, first: a, second: b, clock: clock,
                shuffle: { ids in
                    shuffles += 1
                    return ids.sorted { $0 == a.id && $1 != a.id }
                })
            let schedules = clock.schedules
            let rounds = shuffles
            let result = try await lib.publishWSSDraft(snapshot)
            XCTAssertTrue(result.warnings.isEmpty)
            XCTAssertEqual(lib.active?.id, b.id)
            XCTAssertEqual(lib.active?.kind, switchInto ? .scene : .image)
            XCTAssertEqual(list.state.playback?.currentWallpaperID, b.id)
            XCTAssertEqual(clock.schedules, schedules + 1)
            XCTAssertEqual(shuffles, rounds)
            list.shutdown()
            lib.stop()
        }
    }
    func testPendingRequestRetargetsAndLateCompletionCannotDefeatManualSuccessor() async throws {
        for supersede in [false, true] {
            let item = try await image()
            let other = try await image()
            let (project, snapshot) = try await draft(item)
            var gate: CheckedContinuation<Void, Never>?
            let lib = try library(preparation: { _ in
                await withCheckedContinuation { gate = $0 }
                return PreparedScenePlayback(wss: project.resources)
            })
            lib.manuallyPaused = true
            let request = lib.apply(item, source: .automatic)
            _ = try await lib.publishWSSDraft(snapshot)
            XCTAssertEqual(lib.active?.kind, .scene)
            lib.manuallyPaused = false
            try await wait { gate != nil }
            var successor: WallpaperApplyRequest?
            if supersede { successor = lib.apply(other) }
            gate?.resume()
            gate = nil
            if let successor {
                await accept(successor)
                if case .superseded = await request.outcome {} else { XCTFail("Old request won") }
                XCTAssertEqual(lib.active?.id, other.id)
                XCTAssertTrue(lib.renderers.allSatisfy { $0.wallpaper.id == other.id })
            } else {
                await accept(request)
                XCTAssertEqual(lib.active?.kind, .scene)
                XCTAssertEqual(defaults.string(forKey: "activeWallpaper"), item.id.uuidString)
            }
            lib.stop()
        }
    }
    func testNewManualActionOrShutdownInsideStartupWinsOverRefresh() async throws {
        for shutdown in [false, true] {
            let item = try await image()
            let other = try await image()
            let (_, snapshot) = try await draft(item)
            var lib: Library!
            var successor: WallpaperApplyRequest?
            lib = try library(start: { renderer, _ in
                renderer.setPaused(false)
                if renderer.wallpaper.kind == .scene {
                    if shutdown {
                        lib.stop(preserveSelection: true)
                    } else {
                        successor = lib.apply(other)
                    }
                }
            })
            await accept(lib.apply(item))
            _ = try await lib.publishWSSDraft(snapshot)
            if let successor { await accept(successor) }
            XCTAssertEqual(lib.active?.id, shutdown ? nil : other.id)
            XCTAssertTrue(lib.renderers.allSatisfy { $0.wallpaper.id != item.id })
            XCTAssertEqual(lib.items.first { $0.id == item.id }?.kind, .scene)
            lib.stop()
        }
    }
    func testDisplayTopologyChangeAbandonsCandidateAndKeepsOldRenderer() async throws {
        for added in [false, true] {
            let item = try await image()
            let (_, snapshot) = try await draft(item)
            let screen = try XCTUnwrap(NSScreen.screens.first)
            var changed = false
            let lib = try library(
                screens: { changed ? (added ? [screen, screen] : []) : [screen] },
                start: { renderer, _ in
                    renderer.setPaused(false)
                    if renderer.wallpaper.kind == .scene { changed = true }
                })
            await accept(lib.apply(item))
            let old = lib.renderers
            let receipt = try await lib.publishWSSDraft(snapshot)
            XCTAssertEqual(receipt.warnings.count, 1)
            XCTAssertEqual(lib.renderers.map(ObjectIdentifier.init), old.map(ObjectIdentifier.init))
            XCTAssertFalse(old[0].stopped)
            XCTAssertEqual(lib.items.first { $0.id == item.id }?.kind, .scene)
            lib.stop()
        }
    }
    func testRefreshFailureDoesNotStopPlaylistOrRearmItsTimer() async throws {
        let a = try await image()
        let b = try await image()
        let (_, snapshot) = try await draft(a)
        let lib = try library(start: { renderer, _ in
            if renderer.wallpaper.kind == .scene { throw WSSSaveAsError.storage }
            renderer.setPaused(false)
        })
        let clock = ReplacementClock()
        var shuffles = 0
        let list = try await playlist(
            lib, first: a, second: b, clock: clock,
            shuffle: { ids in
                shuffles += 1
                return ids.sorted { $0 == a.id && $1 != a.id }
            })
        let state = list.state
        let alarm = clock.alarmID
        let due = clock.due
        let schedules = clock.schedules
        let rounds = shuffles
        let old = lib.renderers.map(ObjectIdentifier.init)
        let receipt = try await lib.publishWSSDraft(snapshot)
        XCTAssertEqual(receipt.warnings.count, 1)
        XCTAssertEqual(lib.renderers.map(ObjectIdentifier.init), old)
        XCTAssertEqual(list.state, state)
        XCTAssertEqual(clock.alarmID, alarm)
        XCTAssertEqual(clock.due, due)
        XCTAssertEqual(clock.schedules, schedules)
        XCTAssertEqual(shuffles, rounds)
        clock.fire()
        try await wait { list.state.playback?.currentWallpaperID == b.id && clock.alarmID != nil }
        XCTAssertEqual(lib.active?.id, b.id)
    }

    func testRetiredRendererDiagnosticQueuedBeforeSwapCannotPauseNewScene() async throws {
        let item = try await image()
        let (_, snapshot) = try await draft(item)
        var lib: Library!
        lib = try library(start: { renderer, _ in
            if renderer.wallpaper.kind == .scene {
                lib.renderers.first?.webViewWebContentProcessDidTerminate(WKWebView())
            }
            renderer.setPaused(false)
        })
        await accept(lib.apply(item))
        _ = try await lib.publishWSSDraft(snapshot)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(lib.manuallyPaused)
        XCTAssertEqual(lib.active?.kind, .scene)
        XCTAssertTrue(lib.renderers.allSatisfy { !$0.paused })
    }
    func testNewerEditorSaveDuringThumbnailWorkRemainsAuthoritative() async throws {
        let item = try await image()
        let (_, snapshot) = try await draft(item)
        var lib: Library!
        lib = try library(preview: { project in
            var state = WSSEditorDocumentState(
                model: project.document, diskBasis: project.diskBasis)
            var model = project.document
            model.title = "Newer editor snapshot"
            model.background = [0.25, 0.5, 0.75]
            state.replaceWorkingModel(model)
            do { _ = try await lib.saveWSSManifest(state.beginSave()!) } catch {
                XCTFail("Newer save failed: \(error)")
            }
            return true
        })
        await accept(lib.apply(item))
        _ = try await lib.publishWSSDraft(snapshot)
        let scene = try XCTUnwrap(lib.items.first)
        let loaded = try WSSEditorProjectLoader.read(scene)
        XCTAssertEqual(loaded.document.title, "Newer editor snapshot")
        let player = try XCTUnwrap(lib.renderers.first?.scene as? WSSStaticPlayer)
        XCTAssertEqual(player.resources.scene.background, SIMD3<Float>(0.25, 0.5, 0.75))
        XCTAssertEqual(lib.items.count, 1)
    }
    func testShutdownDuringRetargetedPreparationDoesNotResurrectWallpaper() async throws {
        let item = try await image()
        let (project, snapshot) = try await draft(item)
        var gate: CheckedContinuation<Void, Never>?
        let lib = try library(preparation: { _ in
            await withCheckedContinuation { gate = $0 }
            return .init(wss: project.resources)
        })
        lib.manuallyPaused = true
        let request = lib.apply(item, source: .automatic)
        _ = try await lib.publishWSSDraft(snapshot)
        lib.manuallyPaused = false
        try await wait { gate != nil }
        lib.stop(preserveSelection: true)
        let drain = Task { await lib.stopAndDrainForMaintenance() }
        gate?.resume()
        gate = nil
        await drain.value
        if case .superseded = await request.outcome {
        } else {
            XCTFail("Shutdown accepted old work")
        }
        XCTAssertNil(lib.active)
        XCTAssertTrue(lib.renderers.isEmpty)
        XCTAssertEqual(lib.items.first?.kind, .scene)
    }

    func testPendingReplacementFailureReportsCommittedSaveAndKeepsOneEntry() async throws {
        let item = try await image()
        let (_, snapshot) = try await draft(item)
        let lib = try library(start: { _, _ in throw WSSSaveAsError.storage })
        lib.manuallyPaused = true
        let request = lib.apply(item, source: .automatic)
        _ = try await lib.publishWSSDraft(snapshot)
        lib.manuallyPaused = false
        if case .failed = await request.outcome {
        } else {
            XCTFail("Startup error was not reported")
        }
        XCTAssertEqual(lib.items.count, 1)
        XCTAssertEqual(lib.items.first?.kind, .scene)
        XCTAssertNotNil(lib.message)
        XCTAssertEqual(
            lib.messagePresentation,
            EditorText.desktopWarning.format(
                EditorErrorPresentation.message(WSSSaveAsError.storage)))
    }

    func testSourceConflictBeforeCommitNeverTouchesActiveDesktop() async throws {
        let item = try await image()
        let (_, snapshot) = try await draft(item)
        let lib = try library()
        await accept(lib.apply(item))
        let old = lib.renderers
        try Data("changed externally".utf8).write(to: item.url)
        do {
            _ = try await lib.publishWSSDraft(snapshot)
            XCTFail("Committed stale source")
        } catch { XCTAssertTrue(error is WSSImagePublicationError) }
        XCTAssertEqual(lib.items.first?.kind, .image)
        XCTAssertEqual(lib.renderers.map(ObjectIdentifier.init), old.map(ObjectIdentifier.init))
        XCTAssertFalse(old[0].stopped)
    }
}
