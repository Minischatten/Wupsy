import AppKit
import Combine
import XCTest

@testable import Wupsy

@MainActor private final class RefreshClock: PlaylistScheduling {
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

@MainActor final class WSSActiveSaveRefreshTests: XCTestCase {
    func testCommittedActiveSnapshotRefreshesOnceAndNPlusOneStaysLocal() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        let storage = helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([project.handle.wallpaper]).write(to: storage)
        let suite = "WSSRefresh-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("eco", forKey: "profile")
        defaults.set(false, forKey: "manuallyPaused")
        defaults.set(false, forKey: "conserve")
        defaults.set(false, forKey: "pauseOnBattery")
        var starts = 0
        let library = Library(
            storage: storage, defaults: defaults, restoreOnLaunch: false,
            rendererStart: { renderer, _ in
                starts += 1
                renderer.setPaused(false)
            })
        defer { library.stop() }
        guard case .accepted = await library.apply(project.handle.wallpaper).outcome else {
            return XCTFail("apply failed")
        }
        let baselineStarts = starts
        var gate: CheckedContinuation<Void, Never>?
        let doc = WSSEditorDocument(
            project: project,
            save: {
                let snapshot = $0
                await withCheckedContinuation { gate = $0 }
                return try await library.saveWSSManifest(snapshot)
            }, prepare: { _, _, _ in project.resources })
        defer { doc.close() }
        let address = WSSEffectAddress(layerIndex: 0, effectIndex: 0)
        try doc.setParameter(.rippleAmplitude, at: address, value: 20)
        let n = doc.state.workingModel
        let task = Task { await doc.save() }
        while gate == nil { await Task.yield() }
        try doc.setParameter(.rippleAmplitude, at: address, value: 30)
        await doc.waitForPreview()
        gate?.resume()
        let saved = await task.value
        XCTAssertTrue(saved)
        XCTAssertEqual(doc.state.savedModel, n)
        XCTAssertEqual(
            try WSSSceneDocumentV1.load(entry: project.handle.entry, root: project.handle.root), n)
        let player = try XCTUnwrap(
            library.renderers.first?.scene as? WSSStaticPlayer,
            "pause=\(String(describing: library.pauseReason)) status=\(library.status) message=\(String(describing: library.message))"
        )
        XCTAssertEqual(
            player.resources.scene.imageLayers[0].effects, try n.scene().imageLayers[0].effects)
        XCTAssertEqual(starts, baselineStarts + library.renderers.count)
        XCTAssertEqual(
            WSSEditorParameter.rippleAmplitude.value(in: doc.state.workingModel, at: address), 30)
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.previewRevision, doc.state.workingRevision)
    }
    func testInactiveSaveAndFailedSavesNeverRefreshOrSwitchWallpaper() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        let folder = try helper.fixtures.fixture(name: "Wallpapers/WSS/Other")
        let other = Wallpaper(
            title: project.handle.wallpaper.title,
            path: folder.appendingPathComponent("scene.wss.json").path,
            root: folder.path, kind: .scene,
            managed: .init(directory: "WSS/Other", entry: "scene.wss.json"), sceneSource: .nativeWSS
        )
        let storage = helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([project.handle.wallpaper, other]).write(to: storage)
        let suite = "WSSRefresh-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("eco", forKey: "profile")
        defaults.set(false, forKey: "manuallyPaused")
        defaults.set(false, forKey: "conserve")
        defaults.set(false, forKey: "pauseOnBattery")
        let library = Library(
            storage: storage, defaults: defaults, restoreOnLaunch: false,
            rendererStart: { renderer, _ in renderer.setPaused(false) })
        defer { library.stop() }
        guard case .accepted = await library.apply(other).outcome else {
            return XCTFail("apply failed")
        }
        let renderers = library.renderers.map(ObjectIdentifier.init)
        let doc = WSSEditorDocument(
            project: project, save: { try await library.saveWSSManifest($0) },
            prepare: { _, _, _ in project.resources })
        defer { doc.close() }
        try doc.setParameter(.rippleAmplitude, at: .init(layerIndex: 0, effectIndex: 0), value: 20)
        let success = await doc.save()
        XCTAssertTrue(success)
        XCTAssertEqual(library.active?.id, other.id)
        XCTAssertEqual(library.renderers.map(ObjectIdentifier.init), renderers)
        guard case .accepted = await library.apply(project.handle.wallpaper).outcome else {
            return XCTFail("apply failed")
        }
        let failureRenderers = library.renderers.map(ObjectIdentifier.init)
        let fresh = try await WSSEditorProjectLoader().load(project.handle.wallpaper)
        var state = WSSEditorDocumentState(model: fresh.document, diskBasis: fresh.diskBasis)
        var invalid = fresh.document
        invalid.title = ""
        state.replaceWorkingModel(invalid)
        do {
            _ = try await library.saveWSSManifest(state.beginSave()!)
            XCTFail("validation accepted")
        } catch {
            guard case WSSSaveError.validationFailed = error else { return XCTFail("wrong error") }
        }
        state = WSSEditorDocumentState(model: fresh.document, diskBasis: fresh.diskBasis)
        invalid = fresh.document
        invalid.title = "changed"
        state.replaceWorkingModel(invalid)
        let conflict = state.beginSave()!
        try Data("external".utf8).write(to: project.handle.entry)
        do {
            _ = try await library.saveWSSManifest(conflict)
            XCTFail("conflict accepted")
        } catch { XCTAssertEqual(error as? WSSSaveError, .externalConflict) }
        XCTAssertEqual(library.renderers.map(ObjectIdentifier.init), failureRenderers)
    }
    func testRefreshFailureAfterCommitKeepsOldDesktopAndDocumentClean() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        let storage = helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([project.handle.wallpaper]).write(to: storage)
        let suite = "WSSRefresh-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("eco", forKey: "profile")
        defaults.set(false, forKey: "manuallyPaused")
        defaults.set(false, forKey: "conserve")
        defaults.set(false, forKey: "pauseOnBattery")
        var fails = false
        let library = Library(
            storage: storage, defaults: defaults, restoreOnLaunch: false,
            rendererStart: { renderer, _ in
                if fails { throw WSSSaveError.writeFailed("injected desktop failure") }
                renderer.setPaused(false)
            })
        defer { library.stop() }
        guard case .accepted = await library.apply(project.handle.wallpaper).outcome else {
            return XCTFail("apply failed")
        }
        let old = library.renderers.map(ObjectIdentifier.init)
        fails = true
        let doc = WSSEditorDocument(
            project: project, save: { try await library.saveWSSManifest($0) },
            prepare: { _, _, _ in project.resources })
        defer { doc.close() }
        var warning = ""
        doc.presentMessage = { _, detail in warning = detail }
        try doc.setParameter(.rippleAmplitude, at: .init(layerIndex: 0, effectIndex: 0), value: 20)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(
            warning,
            EditorText.desktopWarning.format(
                EditorErrorPresentation.message(
                    WSSSaveError.writeFailed("injected desktop failure"))))
        XCTAssertEqual(library.renderers.map(ObjectIdentifier.init), old)
        XCTAssertEqual(
            try WSSSceneDocumentV1.load(entry: project.handle.entry, root: project.handle.root),
            doc.state.savedModel)
    }
    func testPlaylistTimerShuffleAndWarningsAndNonSaveActions() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        let folder = try helper.fixtures.fixture(name: "Wallpapers/WSS/Other")
        let other = Wallpaper(
            title: "Other", path: folder.appendingPathComponent("scene.wss.json").path,
            root: folder.path, kind: .scene,
            managed: .init(directory: "WSS/Other", entry: "scene.wss.json"), sceneSource: .nativeWSS
        )
        let storage = helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([project.handle.wallpaper, other]).write(to: storage)
        let suite = "WSSRefresh-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("eco", forKey: "profile")
        defaults.set(false, forKey: "manuallyPaused")
        defaults.set(false, forKey: "conserve")
        defaults.set(false, forKey: "pauseOnBattery")
        var starts = 0
        let library = Library(
            storage: storage, defaults: defaults, restoreOnLaunch: false,
            rendererStart: { renderer, _ in
                starts += 1
                renderer.setPaused(false)
            })
        defer { library.stop() }
        let clock = RefreshClock()
        var shuffles = 0
        let playlistURL = helper.root.appendingPathComponent("playlists.json")
        let playlist = WallpaperPlaylist(
            library: library, storage: playlistURL, defaults: defaults, scheduler: clock,
            restoreOnLaunch: false,
            shuffle: { ids in
                shuffles += 1
                return ids.sorted { $0 == project.handle.id && $1 != project.handle.id }
            })
        defer { playlist.shutdown() }
        let id = try playlist.createPlaylist(name: "Refresh test")
        try playlist.add(project.handle.id, to: id)
        try playlist.add(other.id, to: id)
        try playlist.setPlaybackMode(playlistID: id, mode: .shuffle)
        playlist.activatePlaylist(id: id)
        for _ in 0..<10000 where clock.alarmID == nil { await Task.yield() }
        guard clock.alarmID != nil else {
            return XCTFail(
                "No playlist timer: \(String(describing: playlist.error)), pause=\(String(describing: library.pauseReason)), active=\(String(describing: library.active?.id))"
            )
        }
        XCTAssertEqual(library.active?.id, project.handle.id)
        let before = playlist.state
        let bytes = try Data(contentsOf: playlistURL)
        let alarm = clock.alarmID
        let scheduled = clock.schedules
        let shuffled = shuffles
        let baseline = starts
        let doc = WSSEditorDocument(project: project, prepare: { _, _, _ in project.resources })
        defer { doc.close() }
        let address = WSSEffectAddress(layerIndex: 0, effectIndex: 0)
        try doc.setParameter(.rippleAmplitude, at: address, value: 20)
        doc.undoManager.undo()
        doc.undoManager.redo()
        doc.revert()
        try doc.setParameter(.rippleAmplitude, at: address, value: 21)
        doc.chooseClose = { .cancel }
        let cancelled = await doc.resolveChanges()
        XCTAssertFalse(cancelled)
        doc.chooseClose = { .discard }
        let discarded = await doc.resolveChanges()
        XCTAssertTrue(discarded)
        XCTAssertEqual(starts, baseline)
        var state = WSSEditorDocumentState(model: project.document, diskBasis: project.diskBasis)
        state.replaceWorkingModel(doc.state.workingModel)
        let candidate = try await WSSManifestSaveValidator().prepare(
            state.beginSave()!, handle: project.handle)
        let receipt = try await ManagedWallpaperStore(storage: storage).commitWSSManifest(
            candidate,
            checkpoint: {
                if $0 == .afterCommit {
                    throw WSSSaveError.writeFailed("injected postcommit warning")
                }
            })
        let result = library.completeWSSSave(receipt, playback: candidate.playback)
        guard case .committed(let warnings) = result.outcome else {
            return XCTFail("not committed")
        }
        XCTAssertFalse(warnings.isEmpty)
        XCTAssertEqual(starts, baseline + library.renderers.count)
        XCTAssertEqual(playlist.state, before)
        XCTAssertEqual(try Data(contentsOf: playlistURL), bytes)
        XCTAssertEqual(clock.alarmID, alarm)
        XCTAssertEqual(clock.schedules, scheduled)
        XCTAssertEqual(shuffles, shuffled)
        state.accept(receipt)
        let unchanged = try await library.saveWSSManifest(state.beginSave()!)
        XCTAssertEqual(unchanged.outcome, .unchanged)
        XCTAssertEqual(starts, baseline + library.renderers.count)
        clock.fire()
        for _ in 0..<10000 where playlist.state.playback?.currentWallpaperID != other.id {
            await Task.yield()
        }
        XCTAssertEqual(library.active?.id, other.id)
        XCTAssertEqual(shuffles, shuffled)
    }

}
