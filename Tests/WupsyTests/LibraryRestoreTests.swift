import CArchive
import Darwin
import XCTest

@testable import Wupsy

final class LibraryRestoreTests: XCTestCase {
    var fixture: LibraryBackupTests!
    var target: URL { fixture.root.appendingPathComponent("CurrentA") }
    override func setUpWithError() throws {
        fixture = LibraryBackupTests()
        try fixture.setUpWithError()
        fixture.root = fixture.root.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: fixture.storage.deletingLastPathComponent().appendingPathComponent(
                "Wallpapers/NativeProjects"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try fixture.tearDownWithError() }
    func backup() throws -> URL {
        let (stage, manifest) = try fixture.snapshot()
        defer { try? stage.discard() }
        let output = try fixture.archive(stage, manifest)
        defer { try? output.discard() }
        // Use the production writer's actual ZIP64 bytes, never a second format.
        let url = fixture.root.appendingPathComponent(UUID().uuidString + ".wssbackup")
        try FileManager.default.copyItem(
            at: fixture.root.appendingPathComponent(output.temporary), to: url)
        return url
    }
    func prepare(_ url: URL) async throws -> PreparedLibraryRestore {
        try await LibraryRestorePreparer(supportRoot: target).prepare(url)
    }
    func rejected(
        _ url: URL, preparer: LibraryRestorePreparer? = nil, file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let result = try await (preparer ?? LibraryRestorePreparer(supportRoot: target))
                .prepare(url)
            try result.discard()
            XCTFail("Accepted invalid backup", file: file, line: line)
        } catch {}
        let staging = target.appendingPathComponent(".restore/staging")
        if FileManager.default.fileExists(atPath: staging.path) {
            XCTAssertEqual(
                try? FileManager.default.contentsOfDirectory(atPath: staging.path), [], file: file,
                line: line)
        }
    }
    func testEmptyWriterReaderStagingAndDiscard() async throws {
        let prepared = try await prepare(backup())
        XCTAssertTrue(prepared.plan.library.isEmpty)
        XCTAssertFalse(prepared.plan.incomplete)
        XCTAssertEqual(prepared.plan.manifest.backupFormatVersion, 1)
        XCTAssertTrue(prepared.plan.summary.contains("0 wallpapers"))
        try prepared.validate()
        let root = prepared.newRoot.deletingLastPathComponent()
        try prepared.discard()
        try prepared.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertThrowsError(try prepared.validate())
    }
    func testMixedRoundtripProjectionsAndIsolation() async throws {
        var items: [Wallpaper] = []
        for (name, kind) in [
            ("image.png", WallpaperKind.image), ("movie.mp4", .video), ("animation.gif", .web),
        ] {
            let item = try fixture.media(name, kind: kind)
            // External content must also become managed, preserving identity.
            items.append(
                Wallpaper(
                    id: item.id, title: item.title, path: item.path, root: item.root, kind: kind))
        }
        for (category, name, kind) in [
            ("Web", "nested/index.html", WallpaperKind.web)
        ] {
            let base = "Wallpapers/" + category + "/Input"
            let url = try fixture.file(base + "/" + name)
            _ = try fixture.file(base + "/nested/resource.bin")
            items.append(
                Wallpaper(
                    title: category, path: url.path,
                    root: fixture.storage.deletingLastPathComponent().appendingPathComponent(base)
                        .path,
                    kind: kind, managed: .init(directory: category + "/Input", entry: name)))
        }
        let native = try fixture.native("Wallpapers/WSS/Native")
        items.append(native)
        let recovery = UUID()
        _ = try fixture.native("Wallpapers/NativeProjects/" + recovery.uuidString, id: recovery)
        try fixture.save(items)
        fixture.defaults.set([native.id.uuidString], forKey: "favorites")
        fixture.defaults.set("eco", forKey: "profile")
        fixture.defaults.set("hiDPI", forKey: "sceneRenderResolution")
        fixture.defaults.set(60, forKey: "sceneFPS")
        fixture.defaults.set(
            try JSONEncoder().encode(CustomWidgetPackage.starter), forKey: "customWidgetPackage")
        let widgets = ["clock": WidgetPlacement(enabled: true, scale: 1.4)]
        fixture.defaults.set(try JSONEncoder().encode(widgets), forKey: "independentWidgets")
        var state = PlaylistCollectionState()
        state.definitions = [
            .init(
                name: "Mixed", wallpaperIDs: items.map(\.id), intervalSeconds: 60,
                playbackMode: .shuffle)
        ]
        try WallpaperPlaylistStore(
            url: fixture.storage.deletingLastPathComponent().appendingPathComponent(
                "playlists.json")
        ).save(state)
        // A remains opaque to prepare: bytes, source files and all default keys.
        try FileManager.default.createDirectory(
            at: target.appendingPathComponent("Wallpapers/Media/A"),
            withIntermediateDirectories: true)
        for path in ["library.json", "playlists.json", "Wallpapers/Media/A/current.png"] {
            try Data(("A:" + path).utf8).write(to: target.appendingPathComponent(path))
        }
        fixture.defaults.set("playing-A", forKey: "activeWallpaper")
        fixture.defaults.set(true, forKey: "playlistEnabled")
        let beforeDefaults =
            fixture.defaults.persistentDomain(forName: fixture.suite)! as NSDictionary
        let before = try productionBytes()
        let foreign = target.appendingPathComponent(".restore/foreign/keep")
        try FileManager.default.createDirectory(
            at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("foreign".utf8).write(to: foreign)
        var preparer = LibraryRestorePreparer(supportRoot: target)
        let currentRoot = target
        let defaultsWitness = RestoreDefaultsWitness(
            defaults: fixture.defaults, suite: fixture.suite)
        let observed = ChunkCounter()
        preparer.checkpoint = { phase, _, _ in
            guard phase == .extracting else { return }
            for (path, bytes) in before {
                guard try Data(contentsOf: currentRoot.appendingPathComponent(path)) == bytes else {
                    throw LibraryBackupError("A changed during preparation.")
                }
            }
            guard defaultsWitness.unchanged() else {
                throw LibraryBackupError("Preferences changed during preparation.")
            }
            observed.add(1)
        }
        let prepared = try await preparer.prepare(backup())
        defer { try? prepared.discard() }
        XCTAssertGreaterThan(observed.count, 0)
        XCTAssertEqual(prepared.plan.library.map(\.id), items.map(\.id))
        XCTAssertEqual(prepared.plan.library.map(\.title), items.map(\.title))
        XCTAssertTrue(prepared.plan.library.allSatisfy { $0.ownership == .managed })
        XCTAssertEqual(
            prepared.plan.library.map { $0.managed!.directory.split(separator: "/").first! },
            ["Media", "Media", "Media", "Web", "WSS"])
        XCTAssertEqual(prepared.plan.library[3].managed?.entry, "nested/index.html")
        XCTAssertEqual(prepared.plan.library[4].managed?.entry, "scene.wss.json")
        XCTAssertEqual(prepared.plan.favorites, [native.id])
        XCTAssertEqual(prepared.plan.playlists, state)
        XCTAssertNil(prepared.plan.playlists.playback)
        XCTAssertEqual(prepared.plan.settings.profile, .eco)
        XCTAssertEqual(prepared.plan.settings.sceneRenderResolution, "hiDPI")
        XCTAssertEqual(prepared.plan.settings.sceneFPS, 60)
        XCTAssertEqual(prepared.plan.widgets.customWidgetPackage, .starter)
        XCTAssertEqual(prepared.plan.widgets.independentWidgets, widgets)
        XCTAssertEqual(prepared.plan.projects.filter(\.recovery).map(\.id), [recovery])
        XCTAssertFalse(prepared.plan.library.contains { $0.id == recovery })
        XCTAssertTrue(
            prepared.plan.files.contains {
                $0.target == "Wallpapers/NativeProjects/" + recovery.uuidString + "/scene.wss.json"
            })
        try prepared.validate()
        XCTAssertEqual(try productionBytes(), before)
        XCTAssertEqual(
            fixture.defaults.persistentDomain(forName: fixture.suite)! as NSDictionary,
            beforeDefaults)
        try prepared.discard()
        XCTAssertEqual(try productionBytes(), before)
        XCTAssertEqual(try Data(contentsOf: foreign), Data("foreign".utf8))
        XCTAssertEqual(
            fixture.defaults.persistentDomain(forName: fixture.suite)! as NSDictionary,
            beforeDefaults)
    }
    func productionBytes() throws -> [String: Data] {
        var result: [String: Data] = [:]
        if let iterator = FileManager.default.enumerator(atPath: target.path) {
            for case let relative as String in iterator {
                if relative.hasPrefix(".restore/") { continue }
                let url = target.appendingPathComponent(relative)
                if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    result[relative] = try Data(contentsOf: url)
                }
            }
        }
        return result
    }
    func testNativeIdentityAndReferencesArePreservedWithoutPromotion() async throws {
        let item = try fixture.native("Wallpapers/WSS/Imported")
        try fixture.save([item])
        fixture.defaults.set([item.id.uuidString], forKey: "favorites")
        var playlists = PlaylistCollectionState()
        playlists.definitions = [.init(name: "Preserved", wallpaperIDs: [item.id])]
        try WallpaperPlaylistStore(
            url: fixture.storage.deletingLastPathComponent().appendingPathComponent(
                "playlists.json")
        ).save(playlists)
        let prepared = try await prepare(backup())
        defer { try? prepared.discard() }
        let restored = try XCTUnwrap(prepared.plan.library.first)
        XCTAssertFalse(prepared.plan.incomplete)
        XCTAssertTrue(prepared.plan.promotedToNative.isEmpty)
        XCTAssertEqual(restored.id, item.id)
        XCTAssertEqual(restored.title, item.title)
        XCTAssertEqual(restored.sceneSource, .nativeWSS)
        XCTAssertNil(restored.scenePlaybackMode)
        XCTAssertEqual(
            restored.managed, .init(directory: "WSS/" + item.id.uuidString, entry: "scene.wss.json")
        )
        XCTAssertEqual(prepared.plan.favorites, [item.id])
        XCTAssertEqual(prepared.plan.playlists, playlists)
    }
    func testVectorFieldRoundtrip() async throws {
        let item = try fixture.native("Wallpapers/WSS/Field")
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
        _ = try fixture.file(
            "Wallpapers/WSS/Field/assets/field.wssvf",
            bytes:
                WSSVectorFieldAsset(
                    width: 1, height: 1, vectors: Data(repeating: 0, count: 4),
                    coverage: nil, isNeutral: true
                ).encodedNative())
        try JSONSerialization.data(withJSONObject: json).write(to: item.url)
        try fixture.save([item])
        let prepared = try await prepare(backup())
        defer { try? prepared.discard() }
        XCTAssertTrue(prepared.plan.files.contains { $0.target.hasSuffix("assets/field.wssvf") })
        try prepared.validate()
    }
    // Hostile fixtures still use libarchive's ZIP writer; metadata mutations update
    // the inventory hashes so semantic rejection cannot pass on a hash error alone.
    func mutated(_ body: (inout [String: Data]) throws -> Void) throws -> URL {
        let (stage, _) = try fixture.snapshot()
        defer { try? stage.discard() }
        var files: [String: Data] = [:]
        let iterator = FileManager.default.enumerator(atPath: stage.url.path)!
        for case let path as String in iterator {
            let url = stage.url.appendingPathComponent(path)
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[path] = try Data(contentsOf: url)
            }
        }
        try body(&files)
        return try zip(files.sorted { $0.key < $1.key })
    }
    func json(_ files: inout [String: Data], _ path: String, _ body: (inout [String: Any]) -> Void)
        throws
    {
        var value = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: XCTUnwrap(files[path], "Missing fixture: \(path); \(files.keys)"))
                as? [String: Any])
        body(&value)
        files[path] = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        if path != "backup.json" { try rehash(&files) }
    }
    func rehash(_ files: inout [String: Data]) throws {
        let payloads = files
        try json(&files, "backup.json") { manifest in
            var entries = manifest["files"] as! [[String: Any]]
            for i in entries.indices {
                if let bytes = payloads[entries[i]["path"] as! String] {
                    entries[i]["size"] = bytes.count
                    entries[i]["sha256"] = LibraryBackupIO.digest(bytes)
                }
            }
            manifest["files"] = entries
            manifest["totalLogicalSize"] = entries.reduce(0) { $0 + ($1["size"] as! Int) }
        }
    }
    func zip(
        _ files: [(key: String, value: Data)], type: UInt32 = UInt32(S_IFREG),
        compression: String = "store"
    ) throws -> URL {
        let url = fixture.root.appendingPathComponent(UUID().uuidString + ".wssbackup")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        defer { close(fd) }
        let a = archive_write_new()!
        defer { archive_write_free(a) }
        try LibraryBackupArchive.check(archive_write_set_format_zip(a), a)
        try LibraryBackupArchive.check(
            archive_write_set_options(a, "zip:compression=" + compression + ",zip:zip64"), a)
        try LibraryBackupArchive.check(archive_write_open_fd(a, fd), a)
        for file in files {
            let e = archive_entry_new()!
            defer { archive_entry_free(e) }
            archive_entry_set_pathname(e, file.key)
            archive_entry_set_filetype(e, type)
            archive_entry_set_perm(e, 0o600)
            archive_entry_set_size(e, Int64(file.value.count))
            try LibraryBackupArchive.check(archive_write_header(a, e), a)
            if !file.value.isEmpty {
                let n = file.value.withUnsafeBytes {
                    archive_write_data(a, $0.baseAddress, $0.count)
                }
                guard n == file.value.count else {
                    throw LibraryBackupError("Test ZIP write failed.")
                }
            }
        }
        try LibraryBackupArchive.check(archive_write_close(a), a)
        return url
    }
    func testProductMarkersAreRejectedBeforeStagingOrMaintenance() async throws {
        let maintenance = await MainActor.run { MaintenanceCoordinator() }
        for marker in ["ambient-library-backup", "unknown-library-backup"] {
            let url = try mutated { files in
                try json(&files, "backup.json") { $0["format"] = marker }
            }
            XCTAssertThrowsError(try LibraryRestorePreflight.validate(url)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Wupsy"))
            }
            await rejected(url)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            await MainActor.run { XCTAssertEqual(maintenance.state, .normal) }
        }
        let url = try backup()
        try LibraryRestorePreflight.validate(url)
        let prepared = try await prepare(url)
        defer { try? prepared.discard() }
        XCTAssertEqual(prepared.plan.manifest.format, "wupsy-library-backup")
        XCTAssertEqual(prepared.plan.manifest.backupFormatVersion, 1)
        XCTAssertTrue(prepared.newRoot.path.hasPrefix(target.path + "/.restore/staging/"))
    }
    func testManifestVersionsAndDuplicateJSONKeys() async throws {
        for (key, value) in [
            ("format", "wrong" as Any), ("backupFormatVersion", 2),
            ("requiredFeatures", ["sha256", "portable-library-v1", "zip64", "future"]),
        ] {
            await rejected(
                try mutated { files in try json(&files, "backup.json") { $0[key] = value } })
        }
        await rejected(try mutated { $0.removeValue(forKey: "backup.json") })
        await rejected(
            try mutated { files in
                var text = String(data: files["backup.json"]!, encoding: .utf8)!
                text.insert(
                    contentsOf: "\"format\":\"wupsy-library-backup\",",
                    at: text.index(after: text.startIndex))
                files["backup.json"] = Data(text.utf8)
            })
        XCTAssertThrowsError(try LibraryRestoreJSON.validate(Data("{\"a\":1,\"\\u0061\":2}".utf8)))
    }
    func testCorruptionInventorySizesAndDigests() async throws {
        let raw = fixture.root.appendingPathComponent("notzip")
        try Data("not a zip archive at all!!!".utf8).write(to: raw)
        await rejected(raw)
        let url = try backup()
        var bytes = try Data(contentsOf: url)
        bytes.removeLast(30)
        try bytes.write(to: url)
        await rejected(url)
        await rejected(try mutated { $0["extra.txt"] = Data() })
        await rejected(try mutated { $0.removeValue(forKey: "settings.json") })
        await rejected(try mutated { $0["settings.json"] = Data("{}".utf8) })
        await rejected(
            try mutated { files in
                try json(&files, "backup.json") { m in
                    var list = m["files"] as! [[String: Any]]
                    list.removeLast()
                    m["files"] = list
                    m["fileCount"] = list.count + 1
                }
            })
        await rejected(
            try mutated { files in
                try json(&files, "backup.json") { m in
                    var list = m["files"] as! [[String: Any]]
                    list[0]["sha256"] = String(repeating: "0", count: 64)
                    m["files"] = list
                }
            })
    }
    func testUnsafeZIPPathsAndEntryKinds() async throws {
        let names = [
            "../escape", "/absolute", "a/../b", "a\\b", "a:b",
            String(repeating: "a/", count: 33) + "x", String(repeating: "x", count: 256),
            String(repeating: "abcd/", count: 31) + String(repeating: "y", count: 900),
            "e\u{301}.txt",
        ]
        for name in names { await rejected(try zip([(name, Data())])) }
        for names in [
            ["a", "a"], ["A", "a"], ["Dir/a", "dir/b"], ["é", "e\u{301}"], ["a", "a-", "a/b"],
        ] {
            await rejected(try zip(names.map { ($0, Data()) }))
        }
        // Unix external attributes are authoritative only for rejecting file kinds.
        for type in [UInt32(S_IFIFO), UInt32(S_IFLNK), UInt32(S_IFCHR)] {
            let url = try zip([("unsafe", Data())])
            var data = try Data(contentsOf: url)
            let index = try XCTUnwrap(data.range(of: Data([0x50, 0x4b, 0x01, 0x02]))).lowerBound
            let mode = (type | 0o600) << 16
            for n in 0..<4 { data[index + 38 + n] = UInt8(truncatingIfNeeded: mode >> (n * 8)) }
            try data.write(to: url)
            await rejected(url)
        }
        await rejected(
            try zip([("compressed", Data(repeating: 65, count: 500))], compression: "deflate"))
        // Encryption and multidisk flags must fail before libarchive payload reads.
        for mutation in 0..<2 {
            let url = try zip([("file", Data())])
            var data = try Data(contentsOf: url)
            if mutation == 0 {
                let index = try XCTUnwrap(data.range(of: Data([0x50, 0x4b, 0x01, 0x02]))).lowerBound
                data[index + 8] |= 1
            } else {
                data[data.count - 18] = 1
            }
            try data.write(to: url)
            await rejected(url)
        }
    }
    func testHardlinkAndSymlinkEntryGuard() throws {
        // ZIP has no portable hardlink encoding. Test libarchive's entry contract
        // directly, which the shared payload reader enforces before any output.
        for hardlink in [true, false] {
            let entry = archive_entry_new()!
            defer { archive_entry_free(entry) }
            archive_entry_set_filetype(entry, UInt32(S_IFREG))
            archive_entry_set_size(entry, 0)
            if hardlink {
                archive_entry_set_hardlink(entry, "../outside")
            } else {
                archive_entry_set_symlink(entry, "/outside")
            }
            XCTAssertThrowsError(try LibraryBackupArchive.regularEntry(entry))
        }
    }
    func testSemanticMetadataRejections() async throws {
        let item = try fixture.media()
        try fixture.save([item])
        await rejected(
            try mutated { files in
                try json(&files, "organization.json") { $0["favorites"] = [UUID().uuidString] }
            })
        await rejected(
            try mutated { files in
                try json(&files, "organization.json") {
                    $0["favorites"] = [item.id.uuidString, item.id.uuidString]
                }
            })
        await rejected(
            try mutated { files in try json(&files, "settings.json") { $0["sceneFPS"] = 15 } })
        await rejected(
            try mutated { files in
                try json(&files, "settings.json") { $0["sceneRenderResolution"] = "future" }
            })
        await rejected(
            try mutated { files in try json(&files, "settings.json") { $0["profile"] = "future" } })
        for placement in [
            ["unknown": ["enabled": true, "scale": 1]], ["clock": ["enabled": true, "scale": 5]],
        ] {
            await rejected(
                try mutated { files in
                    try json(&files, "widgets.json") { $0["independentWidgets"] = placement }
                })
        }
        await rejected(
            try mutated { files in
                try json(&files, "widgets.json") {
                    $0["customWidgetPackage"] = [
                        "version": 1, "name": "Bad", "html": "", "css": "", "height": 10,
                    ]
                }
            })
        await rejected(
            try mutated { files in
                try json(&files, "backup.json") { $0["completeness"] = "incomplete" }
            })
        await rejected(
            try mutated { files in
                files["library.json"] = Data("[]".utf8)
                try rehash(&files)
            })
        var state = PlaylistCollectionState()
        state.definitions = [.init(name: "Invalid", wallpaperIDs: [UUID()])]
        await rejected(
            try mutated { files in
                files["playlists.json"] = try JSONEncoder().encode(state)
                try json(&files, "backup.json") {
                    $0["playlistIDs"] = state.definitions.map { $0.id.uuidString }
                }
                try rehash(&files)
            })
    }
    func testIdentitySceneAndRecoveryInvariantRejections() async throws {
        let item = try fixture.native("Wallpapers/WSS/Native")
        try fixture.save([item])
        let recovery = UUID()
        _ = try fixture.native("Wallpapers/NativeProjects/" + recovery.uuidString, id: recovery)
        await rejected(
            try mutated { files in
                try json(&files, "backup.json") { m in
                    var list = m["wallpapers"] as! [[String: Any]]
                    list.append(list[0])
                    m["wallpapers"] = list
                }
            })
        await rejected(
            try mutated { files in
                try json(&files, "backup.json") { m in
                    var list = m["recovery"] as! [[String: Any]]
                    list.append(list[0])
                    m["recovery"] = list
                }
            })
        await rejected(
            try mutated { files in
                try json(&files, "backup.json") { m in
                    var list = m["recovery"] as! [[String: Any]]
                    list[0]["originalProjectID"] = item.id.uuidString
                    m["recovery"] = list
                }
            })
        // Keep portable library and manifest equal for semantic failures.
        for mutation in 0..<3 {
            await rejected(
                try mutated { files in
                    var records =
                        try JSONSerialization.jsonObject(with: files["library.json"]!)
                        as! [[String: Any]]
                    if mutation == 0 { records[0]["scenePlaybackMode"] = "compatibility" }
                    if mutation == 1 { records[0]["missingSource"] = true }
                    if mutation == 2 { records[0]["ownership"] = "external" }
                    files["library.json"] = try JSONSerialization.data(withJSONObject: records)
                    try json(&files, "backup.json") { $0["wallpapers"] = records }
                    try rehash(&files)
                })
        }
        var playlists = PlaylistCollectionState()
        let definition = PlaylistDefinition(name: "Duplicate")
        playlists.definitions = [definition, definition]
        await rejected(
            try mutated { files in
                files["playlists.json"] = try JSONEncoder().encode(playlists)
                try json(&files, "backup.json") {
                    $0["playlistIDs"] = playlists.definitions.map { $0.id.uuidString }
                }
                try rehash(&files)
            })
    }
    func testMetadataLimitAndPinnedInputRejections() async throws {
        await rejected(
            try mutated { files in
                files["settings.json"] = Data(repeating: 32, count: 4097)
                try rehash(&files)
            })
        let url = try backup()
        let link = fixture.root.appendingPathComponent("selected-link.wssbackup")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        await rejected(link)
        let pinned = try LibraryRestoreArchive(url: url, limits: .init())
        let fd = open(url.path, O_WRONLY | O_APPEND)
        defer { close(fd) }
        XCTAssertEqual(Darwin.write(fd, "x", 1), 1)
        XCTAssertThrowsError(try pinned.unchanged())
        // Corrupt payload bytes without changing its declared size.
        let corrupt = try mutated { files in
            var bytes = files["settings.json"]!
            bytes[0] = 91
            files["settings.json"] = bytes
        }
        await rejected(corrupt)
    }
    func testWSSSemanticAndMissingResourceRejections() async throws {
        let item = try fixture.native("Wallpapers/WSS/Native")
        try fixture.save([item])
        let prefix = "payloads/" + item.id.uuidString + "/source/"
        await rejected(
            try mutated { files in
                files[prefix + "scene.wss.json"] = Data("{}".utf8)
                try rehash(&files)
            })
        await rejected(
            try mutated { files in
                files.removeValue(forKey: prefix + "assets/mask.png")
                try json(&files, "backup.json") { m in
                    let list = (m["files"] as! [[String: Any]]).filter {
                        $0["path"] as! String != prefix + "assets/mask.png"
                    }
                    m["files"] = list
                    m["fileCount"] = list.count + 1
                }
                try rehash(&files)
            })
    }
    func testBudgetsStreamingCancelAndFailureCleanup() async throws {
        let item = try fixture.media("large.mp4", kind: .video)
        try Data(repeating: 47, count: LibraryBackupLimits.chunk * 3 + 123).write(to: item.url)
        try fixture.save([item])
        let url = try backup()
        for limits in [
            LibraryRestoreLimits(total: 100), LibraryRestoreLimits(file: 100),
            LibraryRestoreLimits(files: 6), LibraryRestoreLimits(manifest: 20),
        ] {
            var p = LibraryRestorePreparer(supportRoot: target)
            p.limits = limits
            await rejected(url, preparer: p)
        }
        let chunks = ChunkCounter()
        var success = LibraryRestorePreparer(supportRoot: target)
        success.checkpoint = { phase, _, n in if phase == .extracting { chunks.add(n) } }
        let prepared = try await success.prepare(url)
        XCTAssertEqual(chunks.total, LibraryBackupLimits.chunk * 3 + 123)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertLessThanOrEqual(chunks.maximum, LibraryBackupLimits.chunk)
        try prepared.discard()
        for cancel in [false, true] {
            var p = LibraryRestorePreparer(supportRoot: target)
            p.checkpoint = { phase, _, _ in
                if phase == .extracting {
                    if cancel {
                        withUnsafeCurrentTask { $0?.cancel() }
                        try Task.checkCancellation()
                    }
                    throw LibraryBackupError("Injected write failure")
                }
            }
            await rejected(url, preparer: p)
        }
        for phase in [LibraryRestorePreparer.Phase.bootstrap, .reconstructing, .validating] {
            var p = LibraryRestorePreparer(supportRoot: target)
            p.checkpoint = { current, _, _ in
                if current == phase { throw LibraryBackupError("Injected failure") }
            }
            await rejected(url, preparer: p)
        }
    }
    func testFinalInventoryLinksAndStagingIdentity() async throws {
        let item = try fixture.media()
        try fixture.save([item])
        let archive = try backup()
        let outside = fixture.root.appendingPathComponent("outside-file")
        try Data("untouched".utf8).write(to: outside)
        for hardlink in [false, true] {
            let prepared = try await prepare(archive)
            let extra = prepared.newRoot.appendingPathComponent("unexpected")
            if hardlink {
                try FileManager.default.linkItem(at: outside, to: extra)
            } else {
                try FileManager.default.createSymbolicLink(at: extra, withDestinationURL: outside)
            }
            XCTAssertThrowsError(try prepared.validate())
            try prepared.discard()
            XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
        }
        let prepared = try await prepare(archive)
        let root = prepared.newRoot.deletingLastPathComponent()
        let moved = root.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: moved)
        XCTAssertThrowsError(try prepared.discard())
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: moved, to: root)
        try prepared.discard()
    }
    func testOwnershipAndFinalValidatorFailClosed() async throws {
        let item = try fixture.media()
        try fixture.save([item])
        let prepared = try await prepare(backup())
        let owner = prepared.newRoot.deletingLastPathComponent().appendingPathComponent(
            "owner.json")
        let original = try Data(contentsOf: owner)
        try Data("foreign".utf8).write(to: owner)
        XCTAssertThrowsError(try prepared.discard())
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.newRoot.path))
        try original.write(to: owner)
        let entry = prepared.newRoot.appendingPathComponent(prepared.plan.files[0].target)
        try Data("tampered".utf8).write(to: entry)
        XCTAssertThrowsError(try prepared.validate())
        try prepared.discard()
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let support = fixture.root.appendingPathComponent("SymlinkSupport")
        try FileManager.default.createSymbolicLink(at: support, withDestinationURL: outside)
        await rejected(try backup(), preparer: LibraryRestorePreparer(supportRoot: support))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
}
private final class ChunkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func add(_ n: Int) {
        lock.lock()
        defer { lock.unlock() }
        values.append(n)
    }
    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.reduce(0, +)
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }
    var maximum: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.max() ?? 0
    }
}

// UserDefaults supports concurrent reads; the copied NSDictionary is immutable.
// Keep those Foundation objects behind this read-only test witness.
private final class RestoreDefaultsWitness: @unchecked Sendable {
    private let defaults: UserDefaults
    private let suite: String
    private let expected: NSDictionary
    init(defaults: UserDefaults, suite: String) {
        self.defaults = defaults
        self.suite = suite
        expected = defaults.persistentDomain(forName: suite)! as NSDictionary
    }
    func unchanged() -> Bool {
        defaults.persistentDomain(forName: suite)! as NSDictionary == expected
    }
}
