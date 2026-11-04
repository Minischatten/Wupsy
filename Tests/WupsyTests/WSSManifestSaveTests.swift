import AppKit
import Darwin
import XCTest

@testable import Wupsy

private final class ManifestFixture {
    let helper = WSSEditorProjectTests()
    let item: Wallpaper
    let storage: URL
    let store: ManagedWallpaperStore
    var root: URL { helper.root }
    let manifest: URL
    init() throws {
        try helper.setUpWithError()
        item = try helper.native()
        manifest = item.url
        storage = helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([item]).write(to: storage)
        store = ManagedWallpaperStore(storage: storage)
    }
    func close() throws { try helper.tearDownWithError() }
    func load() async throws -> WSSLoadedEditorProject {
        try await WSSEditorProjectLoader().load(item)
    }
    func changed(_ project: WSSLoadedEditorProject, suffix: String = " changed") -> WSSSaveSnapshot
    {
        var state = WSSEditorDocumentState(model: project.document, diskBasis: project.diskBasis)
        var model = project.document
        model.title += suffix
        state.replaceWorkingModel(model)
        return state.beginSave()!
    }
    func candidate(_ project: WSSLoadedEditorProject) async throws -> WSSValidatedManifestCandidate
    {
        try await WSSManifestSaveValidator().prepare(changed(project), handle: project.handle)
    }
    func tempNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: manifest.deletingLastPathComponent().path
        ).filter { $0.hasPrefix(".wss-save-") }
    }
}

final class WSSManifestSaveTests: XCTestCase {
    func aclText(_ path: String) throws -> String {
        let acl = try XCTUnwrap(acl_get_file(path, ACL_TYPE_EXTENDED))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let text = try XCTUnwrap(acl_to_text(acl, nil))
        defer { acl_free(text) }
        return String(cString: text)
    }

    func testSaveCommitsOnlyManifestPreservesSecurityAndNoopKeepsOriginalBytes() async throws {
        let fixture = try ManifestFixture()
        defer { try? fixture.close() }
        let project = try await fixture.load()
        let before = try fixture.helper.snapshot()
        let original = try Data(contentsOf: fixture.manifest)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640], ofItemAtPath: fixture.manifest.path)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = [
            "+a", "\(NSUserName()) allow read,write,readsecurity", fixture.manifest.path,
        ]
        try chmod.run()
        chmod.waitUntilExit()
        XCTAssertEqual(chmod.terminationStatus, 0)
        let sourceACL = try aclText(fixture.manifest.path)
        let candidate = try await fixture.candidate(project)
        let receipt = try await fixture.store.commitWSSManifest(candidate)
        guard case .committed = receipt.outcome else { return XCTFail("not committed") }
        let saved = try WSSSceneDocumentV1.load(
            entry: fixture.manifest, root: fixture.manifest.deletingLastPathComponent())
        XCTAssertEqual(saved, candidate.snapshot.model)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: fixture.manifest.path)[
                .posixPermissions] as? Int, 0o640)
        XCTAssertEqual(try aclText(fixture.manifest.path), sourceACL)
        var after = try fixture.helper.snapshot()
        after["Wallpapers/WSS/Native/scene.wss.json"] = original
        XCTAssertEqual(after, before)
        try receipt.diskBasis.verify(project.handle)
        let fresh = try await fixture.load()
        var state = WSSEditorDocumentState(model: fresh.document, diskBasis: fresh.diskBasis)
        let noChange = try await WSSManifestSaveValidator().prepare(
            state.beginSave()!, handle: fresh.handle)
        let bytes = try Data(contentsOf: fixture.manifest)
        let inode =
            try FileManager.default.attributesOfItem(atPath: fixture.manifest.path)[
                .systemFileNumber] as? NSNumber
        let unchanged = try await fixture.store.commitWSSManifest(noChange)
        XCTAssertEqual(unchanged.outcome, .unchanged)
        XCTAssertEqual(try Data(contentsOf: fixture.manifest), bytes)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: fixture.manifest.path)[
                .systemFileNumber] as? NSNumber, inode)
    }
    func testEveryPrecommitFaultLeavesOldManifestAndNoTemps() async throws {
        let fixture = try ManifestFixture()
        defer { try? fixture.close() }
        let project = try await fixture.load()
        let candidate = try await fixture.candidate(project)
        let original = try Data(contentsOf: fixture.manifest)
        for stage in [
            WSSManifestWriter.Stage.createTemp, .partialWrite, .flush, .close, .beforeCommit,
            .replace,
        ] {
            do {
                _ = try await fixture.store.commitWSSManifest(
                    candidate,
                    checkpoint: {
                        if $0 == stage { throw NSError(domain: "WSSSaveFault", code: 1) }
                    })
                XCTFail("injected fault succeeded")
            } catch {
                if stage == .replace {
                    guard case WSSSaveError.commitFailed = error else {
                        return XCTFail("wrong error: \(error)")
                    }
                } else {
                    guard case WSSSaveError.writeFailed = error else {
                        return XCTFail("wrong error: \(error)")
                    }
                }
            }
            XCTAssertEqual(try Data(contentsOf: fixture.manifest), original)
            _ = try await fixture.load()
            XCTAssertTrue(try fixture.tempNames().isEmpty)
        }
    }
    func testPostcommitFaultReturnsCommittedWarningAndAdvancesSavedState() async throws {
        let fixture = try ManifestFixture()
        defer { try? fixture.close() }
        let project = try await fixture.load()
        var state = WSSEditorDocumentState(model: project.document, diskBasis: project.diskBasis)
        var model = project.document
        model.title = "committed despite warning"
        state.replaceWorkingModel(model)
        let snapshot = state.beginSave()!
        let candidate = try await WSSManifestSaveValidator().prepare(
            snapshot, handle: project.handle)
        let receipt = try await fixture.store.commitWSSManifest(
            candidate,
            checkpoint: {
                if $0 == .afterCommit { throw NSError(domain: "postcommit", code: 1) }
            })
        guard case .committed(let warnings) = receipt.outcome else {
            return XCTFail("wrong outcome")
        }
        XCTAssertFalse(warnings.isEmpty)
        state.accept(receipt)
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(state.savedRevision, snapshot.revision)
        XCTAssertEqual(
            try WSSSceneDocumentV1.decode(data: Data(contentsOf: fixture.manifest)), model)
        XCTAssertTrue(try fixture.tempNames().isEmpty)
    }
    func testContentConflictsIgnoreMtimeAndUnreferencedFilesButDetectSameSizedEdits() async throws {
        let fixture = try ManifestFixture()
        defer { try? fixture.close() }
        let project = try await fixture.load()
        try Data("irrelevant".utf8).write(
            to: fixture.manifest.deletingLastPathComponent().appendingPathComponent("notes.txt"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: fixture.manifest.path
        )
        try project.diskBasis.verify(project.handle)
        let candidate = try await fixture.candidate(project)
        let original = try Data(contentsOf: fixture.manifest)
        let date = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fixture.manifest.path)[.modificationDate])
        let changed = Data(
            String(decoding: original, as: UTF8.self).replacingOccurrences(
                of: "Native test", with: "Edited test"
            ).utf8)
        XCTAssertEqual(changed.count, original.count)
        XCTAssertNotEqual(changed, original)
        try changed.write(to: fixture.manifest)
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: fixture.manifest.path)
        do {
            _ = try await fixture.store.commitWSSManifest(candidate)
            XCTFail("conflict overwritten")
        } catch { XCTAssertEqual(error as? WSSSaveError, .externalConflict) }
        XCTAssertEqual(try Data(contentsOf: fixture.manifest), changed)
        try original.write(to: fixture.manifest)
        let asset = fixture.manifest.deletingLastPathComponent().appendingPathComponent(
            "assets/base.png")
        var pixels = try Data(contentsOf: asset)
        pixels[pixels.count - 1] ^= 1
        try pixels.write(to: asset)
        XCTAssertThrowsError(try project.diskBasis.verify(project.handle))
    }
    func testConflictImmediatelyBeforeReplaceCleansOnlyOwnTemp() async throws {
        let fixture = try ManifestFixture()
        defer { try? fixture.close() }
        let project = try await fixture.load()
        let candidate = try await fixture.candidate(project)
        var foreign = project.document
        foreign.title = "external writer"
        let bytes = try foreign.encoded()
        do {
            _ = try await fixture.store.commitWSSManifest(
                candidate,
                checkpoint: {
                    if $0 == .beforeCommit {
                        try bytes.write(to: fixture.manifest, options: .atomic)
                    }
                })
            XCTFail("conflict overwritten")
        } catch { XCTAssertEqual(error as? WSSSaveError, .externalConflict) }
        XCTAssertEqual(try Data(contentsOf: fixture.manifest), bytes)
        XCTAssertTrue(try fixture.tempNames().isEmpty)
    }
    func testDisappearedManifestAndReplacedRootAreNeverRecreated() async throws {
        for replaceRoot in [false, true] {
            let fixture = try ManifestFixture()
            defer { try? fixture.close() }
            let project = try await fixture.load()
            let candidate = try await fixture.candidate(project)
            if replaceRoot {
                let root = fixture.manifest.deletingLastPathComponent()
                let moved = root.deletingLastPathComponent().appendingPathComponent("old-root")
                try FileManager.default.moveItem(at: root, to: moved)
                try FileManager.default.copyItem(at: moved, to: root)
            } else {
                try FileManager.default.removeItem(at: fixture.manifest)
            }
            do {
                _ = try await fixture.store.commitWSSManifest(candidate)
                XCTFail("target recreated")
            } catch { XCTAssertEqual(error as? WSSSaveError, .targetDisappeared) }
            if !replaceRoot {
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manifest.path))
            }
        }
    }
    func testValidationEncodingAndResourceChangeFailuresNeverWrite() async throws {
        let fixture = try ManifestFixture()
        defer { try? fixture.close() }
        let project = try await fixture.load()
        let before = try fixture.helper.snapshot()
        var invalid = project.document
        invalid.title = ""
        var models = [invalid]
        invalid = project.document
        invalid.background = [.nan, 0, 0]
        models.append(invalid)
        invalid = project.document
        if case .image(var image) = invalid.layers[0].content {
            image.asset = "assets/other.png"
            invalid.layers[0].content = .image(image)
        }
        models.append(invalid)
        for model in models {
            var state = WSSEditorDocumentState(
                model: project.document, diskBasis: project.diskBasis)
            state.replaceWorkingModel(model)
            let snapshot = state.beginSave()!
            do {
                _ = try await WSSManifestSaveValidator().prepare(snapshot, handle: project.handle)
                XCTFail("invalid save")
            } catch {
                guard case WSSSaveError.validationFailed = error else {
                    return XCTFail("wrong error: \(error)")
                }
            }
            state.failed(snapshot)
            XCTAssertEqual(state.savedRevision, 0)
            XCTAssertTrue(state.isDirty)
            XCTAssertNotNil(state.beginSave())
            XCTAssertEqual(try fixture.helper.snapshot(), before)
        }
    }
    func testRemoveFirstAndSaveFirstForNativeProjects() async throws {
        do {
            for saveFirst in [false, true] {
                let fixture = try ManifestFixture()
                defer { try? fixture.close() }
                let project = try await fixture.load()
                let candidate = try await fixture.candidate(project)
                if saveFirst {
                    _ = try await fixture.store.commitWSSManifest(candidate)
                    _ = try await fixture.store.remove(fixture.item, existing: [fixture.item])
                } else {
                    _ = try await fixture.store.remove(fixture.item, existing: [fixture.item])
                    do {
                        _ = try await fixture.store.commitWSSManifest(candidate)
                        XCTFail("removed entry saved")
                    } catch { XCTAssertEqual(error as? WSSSaveError, .targetDisappeared) }
                }
                let remaining = try fixture.store.load()
                XCTAssertTrue(remaining.isEmpty)
                XCTAssertEqual(
                    FileManager.default.fileExists(atPath: fixture.manifest.path), false)
            }
        }
    }
    func testLoadedReadBytesCannotBeConfusedWithLaterDiskBytes() async throws {
        let fixture = try ManifestFixture()
        defer { try? fixture.close() }
        let project = try await fixture.load()
        let capture = WSSProjectReadCapture()
        var source = project.assets
        let asset = fixture.manifest.deletingLastPathComponent().appendingPathComponent(
            "assets/base.png")
        source.didRead = { path, data in
            try capture.record(path, data)
            var changed = data
            changed[changed.count - 1] ^= 1
            try changed.write(to: asset)
        }
        _ = try source.image(for: WSSAssetID(value: "assets/base.png"))
        XCTAssertEqual(
            capture.assets["assets/base.png"], project.diskBasis.assets["assets/base.png"])
        XCTAssertThrowsError(try project.diskBasis.verify(project.handle))
        XCTAssertThrowsError(try capture.record("assets/base.png", Data("different read".utf8)))
    }
    func testAmbiguousManagedDirectoryRejectsSaveEvenWithDifferentEntry() async throws {
        let fixture = try ManifestFixture()
        defer { try? fixture.close() }
        let project = try await fixture.load()
        let candidate = try await fixture.candidate(project)
        let original = try Data(contentsOf: fixture.manifest)
        var other = fixture.item
        other.id = UUID()
        other.managed = ManagedWallpaperLocation(
            directory: fixture.item.managed!.directory, entry: "other.wss.json")
        try JSONEncoder().encode([fixture.item, other]).write(to: fixture.storage)
        do {
            _ = try await fixture.store.commitWSSManifest(candidate)
            XCTFail("ambiguous directory saved")
        } catch { XCTAssertEqual(error as? WSSSaveError, .targetDisappeared) }
        XCTAssertEqual(try Data(contentsOf: fixture.manifest), original)
        XCTAssertTrue(try fixture.tempNames().isEmpty)
    }
    func testSnapshotNDoesNotMarkNewerStateCleanAndClosedSessionsIgnoreReceipts() async throws {
        let fixture = try ManifestFixture()
        defer { try? fixture.close() }
        let project = try await fixture.load()
        var state = WSSEditorDocumentState(model: project.document, diskBasis: project.diskBasis)
        var n = project.document
        n.title = "N"
        state.replaceWorkingModel(n)
        let snapshot = state.beginSave()!
        XCTAssertNil(state.beginSave())
        let candidate = try await WSSManifestSaveValidator().prepare(
            snapshot, handle: project.handle)
        var newer = n
        newer.title = "N+1"
        state.replaceWorkingModel(newer)
        let receipt = try await fixture.store.commitWSSManifest(candidate)
        var closed = state
        closed.close()
        closed.accept(receipt)
        XCTAssertEqual(closed.savedRevision, 0)
        state.accept(receipt)
        XCTAssertEqual(state.savedModel, n)
        XCTAssertEqual(state.savedRevision, snapshot.revision)
        XCTAssertEqual(state.workingModel, newer)
        XCTAssertTrue(state.isDirty)
        state.replaceWorkingModel(n)
        XCTAssertTrue(state.workingRevision > state.savedRevision)
        XCTAssertFalse(state.isDirty)
        let next = state.beginSave()!
        let noop = try await WSSManifestSaveValidator().prepare(next, handle: project.handle)
        let unchanged = try await fixture.store.commitWSSManifest(noop)
        state.accept(unchanged)
        XCTAssertEqual(state.savedRevision, snapshot.revision)
    }
    @MainActor func testInternalSaveRefreshesActiveDesktopWithoutApplyPauseStopOrPlaylistChange()
        async throws
    {
        let fixture = try ManifestFixture()
        defer { try? fixture.close() }
        let suite = "WSSManifestIsolation-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "conserve")
        defaults.set(false, forKey: "pauseOnBattery")
        let library = Library(storage: fixture.storage, defaults: defaults, restoreOnLaunch: false)
        defer { library.stop() }
        let playlist = WallpaperPlaylist(
            library: library, storage: fixture.root.appendingPathComponent("playlists.json"),
            defaults: defaults, restoreOnLaunch: false)
        defer { playlist.shutdown() }
        let result = await library.apply(fixture.item).outcome
        guard case .accepted = result else { return XCTFail("desktop failed") }
        let renderers = library.renderers.map(ObjectIdentifier.init)
        let resources = library.renderers.first?.scene
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let playlistState = try encoder.encode(playlist.state)
        let preferences = defaults.dictionaryRepresentation() as NSDictionary
        let libraryBytes = try Data(contentsOf: fixture.storage)
        let prior = library.onPlaybackCommand
        var commands = 0
        library.onPlaybackCommand = { command in
            commands += 1
            prior?(command)
        }
        let project = try await fixture.load()
        _ = try await library.saveWSSManifest(fixture.changed(project))
        XCTAssertEqual(commands, 0)
        XCTAssertEqual(library.active?.id, fixture.item.id)
        XCTAssertFalse(library.manuallyPaused)
        XCTAssertNotEqual(library.renderers.map(ObjectIdentifier.init), renderers)
        XCTAssertFalse(library.renderers.first?.scene === resources)
        XCTAssertEqual(try encoder.encode(playlist.state), playlistState)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, preferences)
        XCTAssertEqual(try Data(contentsOf: fixture.storage), libraryBytes)
    }
}
