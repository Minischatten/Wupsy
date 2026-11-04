import CArchive
import Darwin
import XCTest

@testable import Wupsy

final class LibraryBackupTests: XCTestCase {
    var root: URL!
    var storage: URL { root.appendingPathComponent("Wupsy/library.json") }
    var defaults: UserDefaults!
    var suite: String!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Backup-tests-" + UUID().uuidString
        ).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
        suite = "backup-tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }
    func save(_ items: [Wallpaper]) throws { try JSONEncoder().encode(items).write(to: storage) }
    func file(_ path: String, bytes: Data = Data("source".utf8)) throws -> URL {
        let url = storage.deletingLastPathComponent().appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }
    func media(_ name: String = "photo.png", kind: WallpaperKind = .image) throws -> Wallpaper {
        let url = try file("Wallpapers/Media/Test/" + name)
        return Wallpaper(
            title: "My renamed wallpaper", path: url.path,
            root: url.deletingLastPathComponent().path,
            kind: kind, managed: .init(directory: "Media/Test", entry: name))
    }
    func snapshot() throws -> (LibraryBackupStaging, LibraryBackupManifest) {
        let stage = try LibraryBackupStaging(parent: root)
        do {
            let plan = try LibraryBackupPlan.analyze(storage: storage)
            return (
                stage,
                try plan.snapshot(
                    to: stage.url, preferences: .init(defaults: defaults), progress: { _ in })
            )
        } catch {
            try stage.discard()
            throw error
        }
    }
    func archive(_ stage: LibraryBackupStaging, _ manifest: LibraryBackupManifest) throws
        -> LibraryBackupDestination
    {
        let output = try LibraryBackupDestination(
            root.appendingPathComponent(UUID().uuidString + ".wssbackup"))
        try LibraryBackupArchive.write(
            snapshot: stage.url, manifest: manifest, fd: output.fd, progress: { _ in })
        return output
    }
    func testEmptyLibraryRoundtripAndZIP64() throws {
        let (stage, manifest) = try snapshot()
        defer { try? stage.discard() }
        let output = try archive(stage, manifest)
        defer { try? output.discard() }
        try LibraryBackupArchive.verify(fd: output.fd, expected: manifest)
        XCTAssertEqual(manifest.backupFormatVersion, 1)
        XCTAssertEqual(manifest.libraryRepresentationVersion, 1)
        XCTAssertEqual(manifest.playlistFormatVersion, 1)
        XCTAssertEqual(manifest.wssSceneSchemaVersion, 1)
        XCTAssertEqual(manifest.fileCount, 6)
        let bytes = try Data(contentsOf: root.appendingPathComponent(output.temporary))
        XCTAssertNotNil(bytes.range(of: Data([0x50, 0x4b, 0x06, 0x06])))
        XCTAssertEqual(
            try JSONDecoder().decode(
                LibraryBackupManifest.self, from: JSONEncoder().encode(manifest)), manifest)
    }
    func testUnsafeAndNonNormalizedPaths() throws {
        for path in [
            "/a", "../a", "a/../b", "a//b", "a\\b", "a:b", "a/", "e\u{301}", "a\0b",
            String(repeating: "x/", count: 33) + "x", String(repeating: "x", count: 256),
        ] {
            XCTAssertThrowsError(try LibraryBackupLimits.path(path), path)
        }
        XCTAssertEqual(try LibraryBackupLimits.path("É/a"), try LibraryBackupLimits.path("é/A"))
    }
    func testManifestLimitsFeaturesAndCollisions() throws {
        let (stage, manifest) = try snapshot()
        defer { try? stage.discard() }
        var bad = manifest
        bad.backupFormatVersion = 2
        XCTAssertThrowsError(try bad.validate())
        bad = manifest
        bad.requiredFeatures.append("unknown")
        XCTAssertThrowsError(try bad.validate())
        bad = manifest
        bad.files.append(bad.files[0])
        bad.fileCount += 1
        XCTAssertThrowsError(try bad.validate())
        bad = manifest
        bad.totalLogicalSize += 1
        XCTAssertThrowsError(try bad.validate())
        bad = manifest
        bad.fileCount = LibraryBackupLimits.files + 1
        XCTAssertThrowsError(try bad.validate())
        bad = manifest
        bad.files[0] = .init(
            path: bad.files[0].path, size: LibraryBackupLimits.file + 1, sha256: bad.files[0].sha256
        )
        XCTAssertThrowsError(try bad.validate())
        for name in ["LIBRARY.JSON", "library.json/child"] {
            bad = manifest
            bad.files.append(.init(path: name, size: 0, sha256: String(repeating: "0", count: 64)))
            bad.fileCount += 1
            XCTAssertThrowsError(try bad.validate())
        }
    }
    func testSHA256KnownVector() {
        XCTAssertEqual(
            LibraryBackupIO.digest(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    func testMediaTypesAndByteIdentity() throws {
        for (name, kind) in [("x.png", WallpaperKind.image), ("x.gif", .web), ("x.mp4", .video)] {
            let item = try media(name, kind: kind)
            try save([item])
            let (stage, manifest) = try snapshot()
            defer { try? stage.discard() }
            let path = "payloads/" + item.id.uuidString + "/source/" + name
            XCTAssertEqual(
                try Data(contentsOf: stage.url.appendingPathComponent(path)), Data("source".utf8))
            XCTAssertEqual(manifest.wallpapers.first?.kind, kind)
            XCTAssertEqual(manifest.wallpapers.first?.title, item.title)
            let output = try archive(stage, manifest)
            defer { try? output.discard() }
            try LibraryBackupArchive.verify(fd: output.fd, expected: manifest)
        }
    }
    func testWebProjectsPreserveCompleteTrees() throws {
        let url = try file("Wallpapers/Web/Test/index.html")
        _ = try file("Wallpapers/Web/Test/nested/extra.dat")
        let item = Wallpaper(
            title: "Web", path: url.path, root: url.deletingLastPathComponent().path,
            kind: .web, managed: .init(directory: "Web/Test", entry: "index.html"))
        try save([item])
        let (stage, manifest) = try snapshot()
        defer { try? stage.discard() }
        XCTAssertEqual(manifest.files.filter { $0.path.hasPrefix("payloads/") }.count, 2)
    }
    func testOrganizationAndAllowlist() throws {
        let first = try media()
        let second = Wallpaper(title: "external", path: first.path, root: first.root, kind: .image)
        try save([second, first])
        defaults.set([first.id.uuidString], forKey: "favorites")
        defaults.set("private/path", forKey: "selectedWallpaper")
        defaults.set("eco", forKey: "profile")
        defaults.set(60, forKey: "sceneFPS")
        defaults.set(
            try JSONEncoder().encode(CustomWidgetPackage.starter), forKey: "customWidgetPackage")
        var playlists = PlaylistCollectionState()
        playlists.definitions = [
            .init(
                name: "Second", wallpaperIDs: [second.id, first.id], intervalSeconds: 60,
                playbackMode: .shuffle), .init(name: "First"),
        ]
        try WallpaperPlaylistStore(
            url: storage.deletingLastPathComponent().appendingPathComponent("playlists.json")
        ).save(playlists)
        let (stage, manifest) = try snapshot()
        defer { try? stage.discard() }
        XCTAssertEqual(manifest.wallpapers.map(\.id), [second.id, first.id])
        XCTAssertEqual(manifest.playlistIDs, playlists.definitions.map(\.id))
        XCTAssertEqual(
            try JSONDecoder().decode(
                PlaylistCollectionState.self,
                from: Data(contentsOf: stage.url.appendingPathComponent("playlists.json"))),
            playlists)
        let settings = try Data(contentsOf: stage.url.appendingPathComponent("settings.json"))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: settings) as? [String: Any])
        XCTAssertEqual(
            Set(keys.keys),
            Set([
                "profile", "sceneRenderResolution", "sceneFPS", "conserve", "pauseOnBattery",
                "allDisplays",
            ]))
        let widgets = try JSONDecoder().decode(
            LibraryBackupWidgets.self,
            from: Data(contentsOf: stage.url.appendingPathComponent("widgets.json")))
        XCTAssertEqual(widgets.customWidgetPackage, .starter)
        let output = try archive(stage, manifest)
        defer { try? output.discard() }
        try LibraryBackupArchive.verify(fd: output.fd, expected: manifest)
    }
    func native(_ directory: String, id: UUID = UUID()) throws -> Wallpaper {
        let helper = WSSNativeSceneTests()
        let root = storage.deletingLastPathComponent().appendingPathComponent(directory)
        _ = try file(directory + "/assets/base.png", bytes: helper.png())
        _ = try file(directory + "/assets/mask.png", bytes: helper.png())
        _ = try file(directory + "/unreferenced.png")
        _ = try file(
            directory + "/scene.wss.json",
            bytes: JSONSerialization.data(withJSONObject: helper.document(clouds: true, mask: true))
        )
        return Wallpaper(
            id: id, title: "Native", path: root.appendingPathComponent("scene.wss.json").path,
            root: root.path, kind: .scene,
            managed: .init(
                directory: directory.replacingOccurrences(of: "Wallpapers/", with: ""),
                entry: "scene.wss.json"), sceneSource: .nativeWSS)
    }
    func testWSSReferencedImageMaskAndSavedState() throws {
        let item = try native("Wallpapers/WSS/Native")
        try save([item])
        let before = try Data(contentsOf: item.url)
        let (stage, manifest) = try snapshot()
        defer { try? stage.discard() }
        let source = "payloads/" + item.id.uuidString + "/source/"
        XCTAssertEqual(
            Set(
                manifest.files.filter { $0.path.hasPrefix(source) }.map {
                    String($0.path.dropFirst(source.count))
                }), Set(["scene.wss.json", "assets/base.png", "assets/mask.png"]))
        XCTAssertEqual(
            try Data(contentsOf: stage.url.appendingPathComponent(source + "scene.wss.json")),
            before)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: item.root).appendingPathComponent("unreferenced.png")
                    .path))
    }
    func testNativeBackupAndMissingProjectFailClosed() throws {
        let item = try native("Wallpapers/WSS/Test")
        try save([item])
        let (stage, complete) = try snapshot()
        defer { try? stage.discard() }
        XCTAssertNil(complete.wallpapers[0].native)
        XCTAssertEqual(complete.completeness, "complete")
        try FileManager.default.removeItem(at: item.url)
        XCTAssertThrowsError(try snapshot())
    }
    func testRecoveryAndDraftExclusion() throws {
        let id = UUID()
        _ = try native("Wallpapers/NativeProjects/" + id.uuidString, id: id)
        _ = try file("Wallpapers/.import-draft/payload/private.dat")
        let (stage, manifest) = try snapshot()
        defer { try? stage.discard() }
        XCTAssertEqual(manifest.recovery.map(\.originalProjectID), [id])
        XCTAssertTrue(manifest.wallpapers.isEmpty)
        XCTAssertFalse(manifest.files.contains { $0.path.contains("draft") })
        XCTAssertTrue(manifest.notes.contains { $0.contains("Historical cache") })
    }
    func testMissingSourceFailsWithoutMutatingLibrary() throws {
        let item = try media()
        try save([item])
        try FileManager.default.removeItem(at: item.url)
        let before = try Data(contentsOf: storage)
        XCTAssertThrowsError(try snapshot())
        XCTAssertEqual(try Data(contentsOf: storage), before)
    }
    func testLinksRejectedAndDestinationContainment() throws {
        let item = try media()
        try save([item])
        let plan = try LibraryBackupPlan.analyze(storage: storage)
        XCTAssertThrowsError(
            try plan.validateDestination(
                storage.deletingLastPathComponent().appendingPathComponent("x.wssbackup")))
        XCTAssertThrowsError(try plan.validateDestination(item.url))
        let link = root.appendingPathComponent("link.wssbackup")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: item.url)
        XCTAssertThrowsError(try plan.validateDestination(link))
        let sourceLink = try file("Wallpapers/Web/Test/index.html")
        try FileManager.default.createSymbolicLink(
            at: sourceLink.deletingLastPathComponent().appendingPathComponent("bad"),
            withDestinationURL: item.url)
        let web = Wallpaper(
            title: "Web", path: sourceLink.path, root: sourceLink.deletingLastPathComponent().path,
            kind: .web, managed: .init(directory: "Web/Test", entry: "index.html"))
        try save([web])
        XCTAssertThrowsError(try snapshot())
    }
    func testBarrierDrainsAndRejectsMutations() throws {
        let barrier = LibraryMutationBarrier()
        var mutation: LibraryMutationBarrier.Lease? = try barrier.mutation()
        XCTAssertNil(barrier.trySnapshot())
        withExtendedLifetime(mutation) {}
        mutation = nil
        var snapshot = barrier.trySnapshot()
        XCTAssertNotNil(snapshot)
        XCTAssertThrowsError(try barrier.mutation())
        withExtendedLifetime(snapshot) {}
        snapshot = nil
        XCTAssertNoThrow(try barrier.mutation())
    }
    func testStreamingChunksAndWriteFailure() throws {
        let url = try file(
            "large.bin", bytes: Data(repeating: 123, count: LibraryBackupLimits.chunk * 3 + 17))
        let fd = try LibraryBackupIO.input(url)
        defer { close(fd) }
        var sizes: [Int] = []
        let (count, _) = try LibraryBackupIO.stream(fd) { sizes.append($0.count) }
        XCTAssertEqual(count, Int64(LibraryBackupLimits.chunk * 3 + 17))
        XCTAssertEqual(sizes.count, 4)
        XCTAssertLessThanOrEqual(sizes.max()!, LibraryBackupLimits.chunk)
        XCTAssertThrowsError(
            try Data([1]).withUnsafeBytes { try LibraryBackupIO.write($0, fd: -1) })
    }
    func testCorruptPayloadSizeHashAndMissingInventoryFailVerification() throws {
        let item = try media()
        try save([item])
        let (stage, manifest) = try snapshot()
        defer { try? stage.discard() }
        let payload = try XCTUnwrap(manifest.files.first { $0.path.hasPrefix("payloads/") })
        try Data("CHANGED".utf8).write(to: stage.url.appendingPathComponent(payload.path))
        let output = try archive(stage, manifest)
        defer { try? output.discard() }
        XCTAssertThrowsError(try LibraryBackupArchive.verify(fd: output.fd, expected: manifest))
        for adjustment in [-1, 1] {
            var altered = manifest
            let index = try XCTUnwrap(altered.files.firstIndex { $0.path == payload.path })
            altered.files[index] = .init(
                path: payload.path, size: payload.size + Int64(adjustment), sha256: payload.sha256)
            XCTAssertThrowsError(try LibraryBackupArchive.verify(fd: output.fd, expected: altered))
        }
        var missing = manifest
        missing.files.removeLast()
        missing.fileCount -= 1
        XCTAssertThrowsError(try LibraryBackupArchive.verify(fd: output.fd, expected: missing))
    }
    func testDestinationPublicationAndFailedVerificationPreserveExisting() throws {
        let url = root.appendingPathComponent("existing.wssbackup")
        try Data("old".utf8).write(to: url)
        let target = try LibraryBackupDestination(url)
        try Data("new".utf8).withUnsafeBytes { try LibraryBackupIO.write($0, fd: target.fd) }
        try target.discard()
        XCTAssertEqual(try Data(contentsOf: url), Data("old".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(target.temporary).path))
        let (stage, manifest) = try snapshot()
        defer { try? stage.discard() }
        let replacement = try LibraryBackupDestination(url)
        try LibraryBackupArchive.write(
            snapshot: stage.url, manifest: manifest, fd: replacement.fd, progress: { _ in })
        XCTAssertThrowsError(try replacement.publish())
        try replacement.verify(expected: manifest)
        try replacement.publish()
        try replacement.discard()
        let fd = try LibraryBackupIO.input(url)
        defer { close(fd) }
        try LibraryBackupArchive.verify(fd: fd, expected: manifest)
    }
    func testCancelledStreamAndPublicationLeaveOldBackup() async throws {
        let url = try file(
            "cancel.bin", bytes: Data(repeating: 1, count: LibraryBackupLimits.chunk * 2))
        let task = Task.detached {
            let fd = try LibraryBackupIO.input(url)
            defer { close(fd) }
            return try LibraryBackupIO.stream(fd) { _ in throw CancellationError() }
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { throw error }
    }
    func testWSSVectorFieldIsIncluded() throws {
        let item = try native("Wallpapers/WSS/Field")
        var json = WSSNativeSceneTests().document()
        var layers = json["layers"] as! [[String: Any]]
        layers[0]["effects"] = [
            [
                "type": "flow",
                "flowMap": [
                    "format": "wss-vector-field-f16", "version": 1, "asset": "assets/field.wssvf",
                ],
            ]
        ]
        json["layers"] = layers
        _ = try file(
            "Wallpapers/WSS/Field/assets/field.wssvf",
            bytes: WSSVectorFieldAsset(
                width: 1, height: 1, vectors: Data(repeating: 0, count: 4), coverage: nil,
                isNeutral: true
            ).encodedNative())
        try JSONSerialization.data(withJSONObject: json).write(to: item.url)
        try save([item])
        let (stage, manifest) = try snapshot()
        defer { try? stage.discard() }
        XCTAssertTrue(manifest.files.contains { $0.path.hasSuffix("assets/field.wssvf") })
        XCTAssertFalse(manifest.files.contains { $0.path.hasSuffix("assets/mask.png") })
    }
    @MainActor func testDirtyEditorBackupContainsSavedAAndKeepsWorkingB() async throws {
        let helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
        let doc = helper.document()
        do {
            let storage = helper.helper.root.appendingPathComponent("library.json")
            try JSONEncoder().encode([helper.item!]).write(to: storage)
            let before = try Data(contentsOf: helper.item.url)
            try doc.setParameter(
                .cloudsIntensity, at: .init(layerIndex: 0, effectIndex: 0), value: 0.8)
            XCTAssertTrue(doc.isDirty)
            let working = doc.state.workingModel
            let stage = try LibraryBackupStaging(parent: root)
            do {
                let plan = try LibraryBackupPlan.analyze(storage: storage)
                let manifest = try plan.snapshot(
                    to: stage.url, preferences: .init(defaults: defaults), progress: { _ in })
                let entry = try XCTUnwrap(
                    manifest.files.first { $0.path.hasSuffix("source/scene.wss.json") })
                XCTAssertEqual(
                    try Data(contentsOf: stage.url.appendingPathComponent(entry.path)), before)
                XCTAssertEqual(doc.state.workingModel, working)
                XCTAssertTrue(doc.isDirty)
                try stage.discard()
            } catch {
                try? stage.discard()
                throw error
            }
            doc.close()
            try await helper.tearDown()
        } catch {
            doc.close()
            try await helper.tearDown()
            throw error
        }
    }
    func testSnapshotLeasePreventsRenameAndImportWithoutDiskChanges() async throws {
        let item = try media()
        try save([item])
        let store = ManagedWallpaperStore(storage: storage)
        let before = try Data(contentsOf: storage)
        var lease =
            try XCTUnwrap(LibraryMutationBarrier.shared.trySnapshot())
            as LibraryMutationBarrier.Lease?
        do {
            _ = try await store.rename(wallpaperID: item.id, newTitle: "Changed")
            XCTFail("Expected snapshot exclusion")
        } catch {}
        do {
            _ = try await store.importWallpaper(item.url, existing: [item])
            XCTFail("Expected snapshot exclusion")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: storage), before)
        withExtendedLifetime(lease) {}
        lease = nil
        _ = try await store.rename(wallpaperID: item.id, newTitle: "After snapshot")
        XCTAssertEqual(try store.load().first?.title, "After snapshot")
    }
    func testEndToEndPublicationPreservesSourceAndReplacesDestination() async throws {
        let item = try media()
        try save([item])
        let before = try Data(contentsOf: storage)
        let preferences = try LibraryBackupPreferences(defaults: defaults)
        let target = root.appendingPathComponent("end-to-end.wssbackup")
        for _ in 0..<2 {
            let manifest = try await LibraryBackupCoordinator.perform(
                storage: storage, destination: target,
                preferences: preferences, release: {}, progress: { _ in })
            let fd = try LibraryBackupIO.input(target)
            defer { close(fd) }
            try LibraryBackupArchive.verify(fd: fd, expected: manifest)
            XCTAssertEqual(try Data(contentsOf: storage), before)
        }
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
                $0.hasPrefix(".Wupsy-backup-")
            })
    }

    func rawArchive(
        stage: LibraryBackupStaging, manifest: LibraryBackupManifest,
        omit: String? = nil, extra: String? = nil
    ) throws -> LibraryBackupDestination {
        let target = try LibraryBackupDestination(
            root.appendingPathComponent(UUID().uuidString + ".wssbackup"))
        let a = try XCTUnwrap(archive_write_new())
        defer { archive_write_free(a) }
        try LibraryBackupArchive.check(archive_write_set_format_zip(a), a)
        try LibraryBackupArchive.check(archive_write_open_fd(a, target.fd), a)
        var paths = ["backup.json"] + manifest.files.map(\.path)
        if let extra { paths.append(extra) }
        for path in paths where path != omit {
            let data =
                path == extra
                ? Data("extra".utf8) : try Data(contentsOf: stage.url.appendingPathComponent(path))
            let entry = try XCTUnwrap(archive_entry_new())
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname(entry, path)
            archive_entry_set_size(entry, Int64(data.count))
            archive_entry_set_filetype(entry, UInt32(S_IFREG))
            archive_entry_set_perm(entry, 0o600)
            try LibraryBackupArchive.check(archive_write_header(a, entry), a)
            XCTAssertEqual(
                data.withUnsafeBytes { archive_write_data(a, $0.baseAddress, $0.count) }, data.count
            )
        }
        try LibraryBackupArchive.check(archive_write_close(a), a)
        return target
    }
    func testExactArchiveInventoryMissingAdditionalDuplicateAndTraversal() throws {
        let (stage, manifest) = try snapshot()
        defer { try? stage.discard() }
        let missing = try rawArchive(stage: stage, manifest: manifest, omit: "widgets.json")
        defer { try? missing.discard() }
        XCTAssertThrowsError(try LibraryBackupArchive.verify(fd: missing.fd, expected: manifest))
        for path in ["extra.dat", "widgets.json", "../escape", "WIDGETS.JSON"] {
            let target = try rawArchive(stage: stage, manifest: manifest, extra: path)
            defer { try? target.discard() }
            XCTAssertThrowsError(
                try LibraryBackupArchive.verify(fd: target.fd, expected: manifest), path)
        }
    }
    func testWrongHashInOtherwiseConsistentManifestIsRejected() throws {
        let (stage, original) = try snapshot()
        defer { try? stage.discard() }
        var manifest = original
        let file = manifest.files[0]
        manifest.files[0] = .init(
            path: file.path, size: file.size, sha256: String(repeating: "0", count: 64))
        try JSONEncoder().encode(manifest).write(
            to: stage.url.appendingPathComponent("backup.json"))
        let output = try archive(stage, manifest)
        defer { try? output.discard() }
        XCTAssertThrowsError(try LibraryBackupArchive.verify(fd: output.fd, expected: manifest))
    }
    func testFailureAndCancelAtEveryPhaseKeepOldBackupAndCleanStaging() async throws {
        let item = try media()
        try save([item])
        let before = try Data(contentsOf: storage)
        let preferences = try LibraryBackupPreferences(defaults: defaults)
        let target = root.appendingPathComponent("old.wssbackup")
        try Data("old backup".utf8).write(to: target)
        for phase in LibraryBackupCheckpoint.allCases {
            let observed = LibraryBackupPhaseTracker()
            do {
                _ = try await LibraryBackupCoordinator.perform(
                    storage: storage, destination: target,
                    preferences: preferences, release: {}, progress: { observed.phase = $0.phase },
                    checkpoint: {
                        if $0 == phase { throw CancellationError() }
                    })
                XCTFail("Expected failure at \(phase)")
            } catch is CancellationError {} catch { throw error }
            let expected: LibraryBackupPhase
            switch phase {
            case .snapshot: expected = .snapshot
            case .archive: expected = .archive
            case .verification: expected = .verification
            case .publication: expected = .publication
            }
            XCTAssertEqual(observed.phase, expected)
            XCTAssertEqual(try Data(contentsOf: target), Data("old backup".utf8))
            XCTAssertEqual(try Data(contentsOf: storage), before)
            XCTAssertFalse(
                try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
                    $0.hasPrefix(".Wupsy-backup-")
                })
        }
    }
    func testDestinationChangedWhileWritingIsNotReplaced() throws {
        let url = root.appendingPathComponent("changed.wssbackup")
        try Data("old".utf8).write(to: url)
        let output = try LibraryBackupDestination(url)
        defer { try? output.discard() }
        let (stage, manifest) = try snapshot()
        defer { try? stage.discard() }
        try LibraryBackupArchive.write(
            snapshot: stage.url, manifest: manifest, fd: output.fd, progress: { _ in })
        try output.verify(expected: manifest)
        try Data("changed by another writer".utf8).write(to: url)
        XCTAssertThrowsError(try output.publish())
        XCTAssertEqual(try Data(contentsOf: url), Data("changed by another writer".utf8))
    }

    func testDirectoryCaseCollisionsAreRejectedEvenWithDifferentLeaves() throws {
        let item = try media()
        try save([item])
        let (stage, original) = try snapshot()
        defer { try? stage.discard() }
        var manifest = original
        let prefix = "payloads/" + item.id.uuidString + "/source/"
        for path in ["Assets/a", "assets/b"] {
            manifest.files.append(
                .init(path: prefix + path, size: 0, sha256: String(repeating: "0", count: 64)))
            manifest.fileCount += 1
        }
        XCTAssertThrowsError(try manifest.validate())
    }
    func testPreferencesAreIndependentValuesAndOmitDisplayPositions() throws {
        let item = try media()
        try save([item])
        defaults.set([item.id.uuidString], forKey: "favorites")
        defaults.set("eco", forKey: "profile")
        defaults.set(Data("private display IDs".utf8), forKey: "widgetPositions")
        let frozen = try LibraryBackupPreferences(defaults: defaults)
        defaults.set([], forKey: "favorites")
        defaults.set("original", forKey: "profile")
        let stage = try LibraryBackupStaging(parent: root)
        defer { try? stage.discard() }
        let plan = try LibraryBackupPlan.analyze(storage: storage)
        _ = try plan.snapshot(to: stage.url, preferences: frozen, progress: { _ in })
        let organization = try JSONDecoder().decode(
            LibraryBackupOrganization.self,
            from: Data(contentsOf: stage.url.appendingPathComponent("organization.json")))
        XCTAssertEqual(organization.favorites, [item.id])
        let settings = try JSONDecoder().decode(
            LibraryBackupSettings.self,
            from: Data(contentsOf: stage.url.appendingPathComponent("settings.json")))
        XCTAssertEqual(settings.profile, .eco)
        let widgets = try Data(contentsOf: stage.url.appendingPathComponent("widgets.json"))
        XCTAssertFalse(String(decoding: widgets, as: UTF8.self).contains("private display IDs"))
        XCTAssertEqual(defaults.string(forKey: "profile"), "original")
    }
    func testSavedRenameIsIncludedAfterMutationCompletes() async throws {
        let item = try media()
        try save([item])
        let store = ManagedWallpaperStore(storage: storage)
        _ = try await store.rename(wallpaperID: item.id, newTitle: "Saved before snapshot")
        let (stage, manifest) = try snapshot()
        defer { try? stage.discard() }
        XCTAssertEqual(manifest.wallpapers.first?.title, "Saved before snapshot")
    }

    func testVerifiedTemporaryCannotBeModifiedBeforePublication() throws {
        let (stage, manifest) = try snapshot()
        defer { try? stage.discard() }
        let output = try archive(stage, manifest)
        defer { try? output.discard() }
        try output.verify(expected: manifest)
        XCTAssertEqual(lseek(output.fd, 0, SEEK_SET), 0)
        try Data([0]).withUnsafeBytes { try LibraryBackupIO.write($0, fd: output.fd) }
        XCTAssertThrowsError(try output.publish())
    }

    func testSourceFilenameIsNormalizedWithoutChangingSourceBytes() throws {
        let name = "e\u{301}.png"
        let item = try media(name)
        try save([item])
        let (stage, manifest) = try snapshot()
        defer { try? stage.discard() }
        let entry = try XCTUnwrap(manifest.wallpapers.first?.entry)
        XCTAssertTrue(entry.utf8.elementsEqual("é.png".utf8))
        let path = "payloads/" + item.id.uuidString + "/source/" + entry
        XCTAssertTrue(manifest.files.contains { $0.path == path })
        XCTAssertEqual(
            try Data(contentsOf: stage.url.appendingPathComponent(path)),
            try Data(contentsOf: item.url))
    }

    func testExistingNativePlaybackPreparationDoesNotNeedMutationLease() async throws {
        let item = try native("Wallpapers/WSS/Playback")
        try save([item])
        let lease = try XCTUnwrap(LibraryMutationBarrier.shared.trySnapshot())
        defer { withExtendedLifetime(lease) {} }
        let resources = try await WSSStaticPreparation.shared.prepare(item)
        XCTAssertEqual(resources.scene.width, 64)
    }

    func testCorruptAndOversizedLibraryAreNeverTreatedAsEmpty() throws {
        try Data("not JSON".utf8).write(to: storage)
        XCTAssertThrowsError(try LibraryBackupPlan.analyze(storage: storage))
        let fd = open(storage.path, O_WRONLY | O_TRUNC)
        defer { close(fd) }
        XCTAssertEqual(ftruncate(fd, off_t(LibraryBackupLimits.manifest + 1)), 0)
        XCTAssertThrowsError(try LibraryBackupPlan.analyze(storage: storage))
    }

}
