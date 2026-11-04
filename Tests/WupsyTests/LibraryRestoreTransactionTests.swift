import CoreFoundation
import Darwin
import XCTest

@testable import Wupsy

final class LibraryRestoreTransactionTests: XCTestCase {
    var fixture: LibraryBackupTests!
    var root: URL { fixture.root.appendingPathComponent("InjectedSupport") }
    var domain: String!
    var preferences: LibraryRestorePreferences!
    var lease: RestoreRuntimeQuiescence {
        get throws { try .init(callerGuaranteesQuiescentRuntime: true) }
    }
    override func setUpWithError() throws {
        fixture = LibraryBackupTests()
        try fixture.setUpWithError()
        fixture.root = fixture.root.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        XCTAssertTrue(root.path.hasPrefix(temporary))
        XCTAssertFalse(root.path.contains("Library/Application Support"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        domain = "restore-transaction.tests." + UUID().uuidString
        XCTAssertTrue(domain.hasPrefix("restore-transaction.tests."))
        preferences = try LibraryRestorePreferences(domain: domain)
    }
    override func tearDownWithError() throws {
        CFPreferencesSetMultiple(
            nil, (LibraryRestorePreferences.keys + ["widgetPositions"]) as CFArray,
            domain as CFString,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        try preferences.synchronize()
        try fixture.tearDownWithError()
    }
    func file(_ path: String, _ bytes: Data = Data("A".utf8)) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }
    func a(full: Bool = true) throws {
        if full {
            for name in RestoreSlot.names.prefix(6) { try file(name + "/only-A/nested.dat") }
            try file("library.json", JSONEncoder().encode([Wallpaper]()))
            try file("playlists.json", JSONEncoder().encode(PlaylistCollectionState()))
        }
        try file("unrelated/keep", Data("unrelated".utf8))
        try file("Caches/keep", Data("cache".utf8))
        try file(".restore/foreign/keep", Data("foreign".utf8))
        try Data("external".utf8).write(
            to: fixture.root.appendingPathComponent("external-original"))
        try preferences.write(.init([UUID().uuidString]), key: "favorites")
        try preferences.write(.init("balanced"), key: "profile")
        try preferences.write(.init("old-selection"), key: "activeWallpaper")
        try preferences.write(.init("old-selection"), key: "selectedWallpaper")
        try preferences.write(.init("old-playlist"), key: "selectedPlaylistID")
        try preferences.write(.init(true), key: "manuallyPaused")
        CFPreferencesSetValue(
            "widgetPositions" as CFString, Data("A-local-positions".utf8) as CFData,
            domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        try preferences.write(.init(Data("A-custom".utf8)), key: "customWidgetPackage")
        try preferences.synchronize()
    }
    func b(empty: Bool = false, id: UUID? = nil) async throws -> PreparedLibraryRestore {
        var items: [Wallpaper] = []
        if !empty {
            var item = try fixture.media("new.png")
            if let id { item.id = id }
            try Data("B-content".utf8).write(to: item.url)
            items = [item]
        }
        try fixture.save(items)
        fixture.defaults.set(items.map { $0.id.uuidString }, forKey: "favorites")
        fixture.defaults.set("eco", forKey: "profile")
        fixture.defaults.set(60, forKey: "sceneFPS")
        fixture.defaults.set(false, forKey: "conserve")
        fixture.defaults.set(
            try JSONEncoder().encode(CustomWidgetPackage.starter), forKey: "customWidgetPackage")
        fixture.defaults.set(
            try JSONEncoder().encode(["clock": WidgetPlacement(enabled: true, scale: 1.2)]),
            forKey: "independentWidgets")
        var playlists = PlaylistCollectionState()
        playlists.definitions = [.init(name: "B", wallpaperIDs: items.map(\.id))]
        try WallpaperPlaylistStore(
            url: fixture.storage.deletingLastPathComponent().appendingPathComponent(
                "playlists.json")
        ).save(playlists)
        let (stage, manifest) = try fixture.snapshot()
        defer { try? stage.discard() }
        let archive = try fixture.archive(stage, manifest)
        defer { try? archive.discard() }
        return try await LibraryRestorePreparer(supportRoot: root).prepare(
            fixture.root.appendingPathComponent(archive.temporary))
    }
    func transaction() throws -> LibraryRestoreTransaction {
        try .init(root: root, preferenceDomain: domain)
    }
    func recovery() throws -> LibraryRestoreRecovery {
        try .init(root: root, preferenceDomain: domain)
    }
    func bytes() throws -> [String: Data] {
        var result: [String: Data] = [:]
        let iterator = FileManager.default.enumerator(atPath: root.path)!
        for case let path as String in iterator where !path.hasPrefix(".restore/") {
            let url = root.appendingPathComponent(path)
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[path] = try Data(contentsOf: url)
            } else {
                result[path + "/"] = Data()
            }
        }
        return result
    }
    func assertKept(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("unrelated/keep")),
            Data("unrelated".utf8), file: file, line: line)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("Caches/keep")), Data("cache".utf8),
            file: file, line: line)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent(".restore/foreign/keep")),
            Data("foreign".utf8), file: file, line: line)
        XCTAssertEqual(
            try Data(contentsOf: fixture.root.appendingPathComponent("external-original")),
            Data("external".utf8), file: file, line: line)
    }
    func assertB(_ plan: LibraryRestorePlan, file: StaticString = #filePath, line: UInt = #line)
        throws
    {
        let library = try ManagedWallpaperStore(
            storage: root.appendingPathComponent("library.json")
        ).load()
        XCTAssertEqual(library.map(\.id), plan.library.map(\.id), file: file, line: line)
        XCTAssertEqual(library.map(\.managed), plan.library.map(\.managed), file: file, line: line)
        XCTAssertEqual(
            try WallpaperPlaylistStore(url: root.appendingPathComponent("playlists.json")).load(),
            plan.playlists, file: file, line: line)
        let expected = Set(plan.files.map(\.target)).union(["library.json", "playlists.json"])
        let actual = try bytes().keys.filter {
            !$0.hasSuffix("/") && (RestoreSlot.names.contains($0) || $0.hasPrefix("Wallpapers/"))
        }
        XCTAssertEqual(Set(actual), expected, file: file, line: line)
        for item in plan.files {
            XCTAssertEqual(
                LibraryBackupIO.digest(
                    try Data(contentsOf: root.appendingPathComponent(item.target))),
                item.source.sha256, file: file, line: line)
        }
        try preferences.confirm(
            LibraryRestorePreferences.projection(plan, preservingLocalState: preferences.snapshot())
        )
        try assertKept(file: file, line: line)
    }
    func crash(
        _ prepared: PreparedLibraryRestore, point: LibraryRestoreTransaction.Point,
        detail: String? = nil
    ) throws {
        var transaction = try transaction()
        transaction.checkpoint = { current, label in
            if current == point, detail == nil || label == detail! { throw RestoreSimulatedCrash() }
        }
        do {
            _ = try transaction.publish(prepared, quiescence: lease)
            XCTFail("Crash point was not reached: \(point):\(detail ?? "")")
        } catch is RestoreSimulatedCrash {} catch { XCTFail("Unexpected crash result: \(error)") }
    }
    func testPublishReceiptProjectionsAndReplace() async throws {
        try a()
        let prepared = try await b()
        let plan = prepared.plan
        let receipt = try transaction().publish(prepared, quiescence: lease)
        XCTAssertEqual(receipt.transactionID, prepared.stagingID)
        XCTAssertEqual(receipt.planFingerprint.count, 64)
        XCTAssertFalse(receipt.cleanupPending)
        try assertB(plan)
        XCTAssertEqual(try recovery().inspect(), .none)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: prepared.newRoot.deletingLastPathComponent().path))
        XCTAssertThrowsError(try prepared.discard())
        XCTAssertThrowsError(try prepared.validate())
        XCTAssertFalse(try XCTUnwrap(preferences.snapshot()["manuallyPaused"]?.value()) as! Bool)
        for key in [
            "activeWallpaper", "selectedWallpaper", "selectedPlaylistID",
        ] {
            XCTAssertNil(try preferences.snapshot()[key]?.value())
        }
    }
    func testEmptyAAndEmptyBAndSameUUIDChangedContents() async throws {
        try a(full: false)
        let first = try await b()
        let id = first.plan.library[0].id
        _ = try transaction().publish(first, quiescence: lease)
        try assertB(first.plan)
        // Same UUID B replaces the current bytes, never merges with A's directory.
        let media = root.appendingPathComponent("Wallpapers/Media/" + id.uuidString + "/new.png")
        try Data("old-same-UUID".utf8).write(to: media)
        let second = try await b(id: id)
        _ = try transaction().publish(second, quiescence: lease)
        try assertB(second.plan)
        let empty = try await b(empty: true)
        _ = try transaction().publish(empty, quiescence: lease)
        try assertB(empty.plan)
        XCTAssertTrue(empty.plan.library.isEmpty)
    }
    func testCaptureAAtPublicationBoundary() async throws {
        try a()
        let prepared = try await b()
        try file("library.json", Data("A-saved-after-prepare".utf8))
        try preferences.write(.init("after-prepare"), key: "profile")
        try preferences.synchronize()
        let aBytes = try bytes()
        let aPreferences = try preferences.snapshot()
        try crash(prepared, point: .afterAllNew)
        _ = try recovery().recover(quiescence: lease)
        XCTAssertEqual(try bytes(), aBytes)
        XCTAssertEqual(try preferences.snapshot(), aPreferences)
    }
    func testCrashMatrixEverySlotAndPreferenceWrite() async throws {
        // Every rename endpoint and every persistent partial preference projection.
        var cases: [(LibraryRestoreTransaction.Point, String?, Bool)] = [
            (.beforePrepared, nil, false), (.afterPrepared, nil, false), (.afterAllOld, nil, false),
            (.afterAllNew, nil, false), (.beforePreferences, "B", false),
            (.afterPreferences, "B", false),
            (.beforeCommit, nil, false), (.afterCommit, nil, true), (.cleanupEntry, nil, true),
            (.journalTempWritten, "prepared", false), (.journalRenamed, "prepared", false),
            (.journalRenamed, "newStatePublished", false),
            (.journalTempWritten, "metadataCommitted", false),
            (.journalRenamed, "metadataCommitted", true),
            (.journalRenamed, "cleanupComplete", true), (.cleanupOwnerRemoved, nil, true),
            (.cleanupRootRemoved, nil, true), (.journalRemoved, nil, true),
        ]
        for slot in RestoreSlot.names {
            for point in [
                LibraryRestoreTransaction.Point.beforeOldRename, .afterOldRename, .beforeNewRename,
                .afterNewRename,
            ] { cases.append((point, slot, false)) }
            cases.append((.beforeRename, "moveOld:old/" + slot, false))
            cases.append((.beforeRename, "publishNew:" + slot, false))
            cases.append((.afterRename, "moveOld:old/" + slot, false))
            cases.append((.afterRename, "publishNew:" + slot, false))
        }
        for key in LibraryRestorePreferences.keys {
            cases.append((.preferenceWrite, "B:" + key, false))
        }
        XCTAssertEqual(cases.count, 97)
        for (point, label, committed) in cases {
            try a()
            let prepared = try await b()
            let before = try bytes()
            let oldPreferences = try preferences.snapshot()
            let localPositions =
                CFPreferencesCopyValue(
                    "widgetPositions" as CFString, domain as CFString,
                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Data
            try crash(prepared, point: point, detail: label)
            let fresh = try recovery()
            _ = try fresh.recover(quiescence: lease)
            if committed {
                try assertB(prepared.plan)
            } else {
                XCTAssertEqual(try bytes(), before, "\(point):\(label ?? "")")
                XCTAssertEqual(
                    try preferences.snapshot(), oldPreferences, "\(point):\(label ?? "")")
            }
            XCTAssertEqual(
                CFPreferencesCopyValue(
                    "widgetPositions" as CFString, domain as CFString,
                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Data, localPositions)
            XCTAssertEqual(try fresh.inspect(), .none)
            _ = try fresh.recover(quiescence: lease)
            try assertKept()
            // Orphans from a crash before prepared are deliberately retained.
            if point == .beforePrepared || (point == .journalTempWritten && label == "prepared") {
                try prepared.discard()
            }
        }
    }
    func testEmptyParentRenameIntentCrashAndRecovery() async throws {
        try a(full: false)
        let prepared = try await b()
        let before = try bytes()
        let oldPreferences = try preferences.snapshot()
        try crash(prepared, point: .afterRename, detail: "installParent:Wallpapers")
        _ = try recovery().recover(quiescence: lease)
        XCTAssertEqual(try bytes(), before)
        XCTAssertEqual(try preferences.snapshot(), oldPreferences)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("Wallpapers").path))
    }
    func testRecoveryCrashesAgainDuringRollback() async throws {
        let points: [(LibraryRestoreTransaction.Point, String?)] = [
            (.recovery, nil), (.rollback, "begin"),
            (.afterRename, "returnNew:new/library.json"), (.afterRename, "restoreOld:library.json"),
            (.preferenceWrite, "A-rollback:profile"), (.rollback, "complete"), (.cleanupEntry, nil),
        ]
        for (point, label) in points {
            try a()
            let prepared = try await b()
            let before = try bytes()
            let oldPreferences = try preferences.snapshot()
            try crash(prepared, point: .beforeCommit)
            var second = try recovery()
            second.checkpoint = { current, detail in
                if current == point, label == nil || label == detail {
                    throw RestoreSimulatedCrash()
                }
            }
            XCTAssertThrowsError(try second.recover(quiescence: lease))
            _ = try recovery().recover(quiescence: lease)
            XCTAssertEqual(try bytes(), before, "\(point)")
            XCTAssertEqual(try preferences.snapshot(), oldPreferences)
        }
    }
    func testPostCommitFailuresAndRepeatedCleanupRecoveryKeepB() async throws {
        try a()
        let prepared = try await b()
        var tx = try transaction()
        tx.checkpoint = { point, _ in
            if point == .cleanupEntry { throw LibraryBackupError("Disk full/cleanup failure") }
        }
        let receipt = try tx.publish(prepared, quiescence: lease)
        XCTAssertTrue(receipt.cleanupPending)
        try assertB(prepared.plan)
        XCTAssertEqual(try recovery().inspect(), .finishCommitted(receipt.transactionID))
        var recover = try recovery()
        recover.checkpoint = { point, _ in
            if point == .cleanupEntry { throw RestoreSimulatedCrash() }
        }
        XCTAssertThrowsError(try recover.recover(quiescence: lease))
        _ = try recovery().recover(quiescence: lease)
        try assertB(prepared.plan)
    }
    func testOrdinaryFailuresRollBackAndPostCommitErrorCannotUndo() async throws {
        for point in [
            LibraryRestoreTransaction.Point.afterPrepared, .beforeOldRename, .afterOldRename,
            .afterAllOld,
            .beforeNewRename, .afterNewRename, .afterAllNew, .preferenceWrite, .beforeCommit,
        ] {
            try a()
            let prepared = try await b()
            let before = try bytes()
            let oldPreferences = try preferences.snapshot()
            let fault = RestoreOneShot(point: point)
            var tx = try transaction()
            tx.checkpoint = { point, label in try fault.hit(point, label) }
            XCTAssertThrowsError(try tx.publish(prepared, quiescence: lease), "\(point)")
            XCTAssertEqual(try bytes(), before, "\(point)")
            XCTAssertEqual(try preferences.snapshot(), oldPreferences)
            XCTAssertEqual(try recovery().inspect(), .none)
        }
        try a()
        let prepared = try await b()
        var tx = try transaction()
        tx.checkpoint = { point, _ in
            if point == .afterCommit { throw LibraryBackupError("Runtime failed after commit") }
        }
        XCTAssertTrue(try tx.publish(prepared, quiescence: lease).cleanupPending)
        try assertB(prepared.plan)
        _ = try recovery().recover(quiescence: lease)
        try assertB(prepared.plan)
    }
    func testRollbackFailureRetainsJournalAndOldForRecovery() async throws {
        try a()
        let prepared = try await b()
        let before = try bytes()
        let oldPreferences = try preferences.snapshot()
        var tx = try transaction()
        tx.checkpoint = { point, _ in
            if point == .afterAllNew || point == .rollback {
                throw LibraryBackupError("Injected rollback I/O error")
            }
        }
        XCTAssertThrowsError(try tx.publish(prepared, quiescence: lease))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".restore/journal.json").path))
        _ = try recovery().recover(quiescence: lease)
        XCTAssertEqual(try bytes(), before)
        XCTAssertEqual(try preferences.snapshot(), oldPreferences)
    }
    func journal(_ transform: (inout [String: Any]) -> Void) throws {
        let url = root.appendingPathComponent(".restore/journal.json")
        var value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        transform(&value)
        try JSONSerialization.data(withJSONObject: value).write(to: url)
    }
    func testCorruptJournalOwnershipVersionAndContradictoryStateFailClosed() async throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["version"] = 99 }, { $0["id"] = UUID().uuidString },
            { $0["owner"] = Data("foreign".utf8).base64EncodedString() },
            { j in
                var i = j["transaction"] as! [String: Any]
                i["inode"] = 1
                j["transaction"] = i
            },
            { j in
                var i = j["support"] as! [String: Any]
                i["device"] = 1
                j["support"] = i
            },
            { $0["phase"] = "metadataCommitted" },
            { $0["preferenceDomain"] = "not-the-injected-domain" },
            { $0["intent"] = ["action": "restoreOld", "index": 0] },
        ]
        for mutation in mutations {
            try a()
            let prepared = try await b()
            try crash(prepared, point: .afterPrepared)
            let original = try Data(
                contentsOf: root.appendingPathComponent(".restore/journal.json"))
            let before = try bytes()
            let oldPreferences = try preferences.snapshot()
            try journal(mutation)
            XCTAssertThrowsError(try recovery().recover(quiescence: lease))
            XCTAssertEqual(try bytes(), before)
            XCTAssertEqual(try preferences.snapshot(), oldPreferences)
            try original.write(to: root.appendingPathComponent(".restore/journal.json"))
            _ = try recovery().recover(quiescence: lease)
        }
        try a()
        let prepared = try await b()
        try crash(prepared, point: .afterPrepared)
        let url = root.appendingPathComponent(".restore/journal.json")
        let original = try Data(contentsOf: url)
        try Data("{broken".utf8).write(to: url)
        XCTAssertThrowsError(try recovery().inspect())
        try original.write(to: url)
        let owner = prepared.newRoot.deletingLastPathComponent().appendingPathComponent(
            "owner.json")
        let marker = try Data(contentsOf: owner)
        try FileManager.default.removeItem(at: owner)
        XCTAssertThrowsError(try recovery().recover(quiescence: lease))
        try marker.write(to: owner)
        _ = try recovery().recover(quiescence: lease)
    }
    func testCriticalSymlinksAndUnexpectedOldOrProductiveTargets() async throws {
        try a()
        var prepared = try await b()
        let old = prepared.newRoot.deletingLastPathComponent().appendingPathComponent("old")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        let before = try bytes()
        XCTAssertThrowsError(try transaction().publish(prepared, quiescence: lease))
        XCTAssertEqual(try bytes(), before)
        try prepared.discard()
        prepared = try await b()
        let media = root.appendingPathComponent("Wallpapers/Media")
        let saved = root.appendingPathComponent("saved-media")
        try FileManager.default.moveItem(at: media, to: saved)
        try FileManager.default.createSymbolicLink(at: media, withDestinationURL: saved)
        XCTAssertThrowsError(try transaction().publish(prepared, quiescence: lease))
        try FileManager.default.removeItem(at: media)
        try FileManager.default.moveItem(at: saved, to: media)
        try prepared.discard()
        prepared = try await b()
        try crash(prepared, point: .afterAllOld)
        try file("library.json", Data("unexpected".utf8))
        let withForeign = try bytes()
        XCTAssertThrowsError(try recovery().recover(quiescence: lease))
        XCTAssertEqual(try bytes(), withForeign)
        try FileManager.default.removeItem(at: root.appendingPathComponent("library.json"))
        _ = try recovery().recover(quiescence: lease)
        XCTAssertEqual(try bytes(), before)
    }
    func testAbsentASlotsAndMissingPreparedBSlot() async throws {
        for slot in RestoreSlot.names {
            try a()
            try FileManager.default.removeItem(at: root.appendingPathComponent(slot))
            let prepared = try await b()
            let before = try bytes()
            let oldPreferences = try preferences.snapshot()
            try crash(prepared, point: .afterAllNew)
            _ = try recovery().recover(quiescence: lease)
            XCTAssertEqual(try bytes(), before, slot)
            XCTAssertEqual(try preferences.snapshot(), oldPreferences)
        }
        try a()
        let prepared = try await b()
        try FileManager.default.removeItem(
            at: prepared.newRoot.appendingPathComponent("Wallpapers/Media"))
        let before = try bytes()
        XCTAssertThrowsError(try transaction().publish(prepared, quiescence: lease))
        XCTAssertEqual(try bytes(), before)
        try prepared.discard()
    }
    func testJournalWriteFailuresBeforeAndAfterCommitRename() async throws {
        for point in [LibraryRestoreTransaction.Point.journalTempWritten, .journalRenamed] {
            for phase in ["prepared", "publishing", "newStatePublished", "metadataCommitted"] {
                try a()
                let prepared = try await b()
                let before = try bytes()
                let oldPreferences = try preferences.snapshot()
                let fault = RestoreOneShot(point: point, label: phase)
                var tx = try transaction()
                tx.checkpoint = { point, label in try fault.hit(point, label) }
                if point == .journalRenamed && phase == "metadataCommitted" {
                    XCTAssertTrue(try tx.publish(prepared, quiescence: lease).cleanupPending)
                    try assertB(prepared.plan)
                    _ = try recovery().recover(quiescence: lease)
                } else {
                    XCTAssertThrowsError(try tx.publish(prepared, quiescence: lease))
                    _ = try recovery().recover(quiescence: lease)
                    XCTAssertEqual(try bytes(), before)
                    XCTAssertEqual(try preferences.snapshot(), oldPreferences)
                }
                if point == .journalTempWritten && phase == "prepared" { try prepared.discard() }
            }
        }
    }
    func testJournalSymlinkValidWrongTokenDeviceAndUnknownOldTarget() async throws {
        try a()
        var prepared = try await b()
        try crash(prepared, point: .afterPrepared)
        let journalURL = root.appendingPathComponent(".restore/journal.json")
        let original = try Data(contentsOf: journalURL)
        let outside = fixture.root.appendingPathComponent("external-original")
        try FileManager.default.removeItem(at: journalURL)
        try FileManager.default.createSymbolicLink(at: journalURL, withDestinationURL: outside)
        XCTAssertThrowsError(try recovery().recover(quiescence: lease))
        try FileManager.default.removeItem(at: journalURL)
        try original.write(to: journalURL)
        let owner = prepared.newRoot.deletingLastPathComponent().appendingPathComponent(
            "owner.json")
        let marker = try Data(contentsOf: owner)
        var token = try JSONSerialization.jsonObject(with: marker) as! [String: String]
        token["token"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: token).write(to: owner)
        XCTAssertThrowsError(try recovery().recover(quiescence: lease))
        try marker.write(to: owner)
        try journal { j in
            var slots = j["slots"] as! [[String: Any]]
            var identity = slots[0]["new"] as! [String: Any]
            identity["device"] = 12345
            slots[0]["new"] = identity
            j["slots"] = slots
        }
        XCTAssertThrowsError(try recovery().recover(quiescence: lease))
        try original.write(to: journalURL)
        let unexpected = prepared.newRoot.deletingLastPathComponent().appendingPathComponent(
            "old/library.json")
        try Data("unknown".utf8).write(to: unexpected)
        XCTAssertThrowsError(try recovery().recover(quiescence: lease))
        XCTAssertEqual(try Data(contentsOf: unexpected), Data("unknown".utf8))
        try FileManager.default.removeItem(at: unexpected)
        _ = try recovery().recover(quiescence: lease)
        prepared = try await b()
        try crash(prepared, point: .afterAllOld)
        try FileManager.default.removeItem(at: journalURL)
        // A missing journal cannot grant discard authority back to a claimed B.
        XCTAssertThrowsError(try prepared.discard())
        try assertKept()
    }
    func testCleanupPendingRefusesReplacedOldSlotWithoutRollback() async throws {
        try a()
        let prepared = try await b()
        try crash(prepared, point: .cleanupEntry)
        let old = prepared.newRoot.deletingLastPathComponent().appendingPathComponent(
            "old/library.json")
        let saved = fixture.root.appendingPathComponent("saved-A-metadata")
        try FileManager.default.moveItem(at: old, to: saved)
        try Data("unknown-old-object".utf8).write(to: old)
        XCTAssertThrowsError(try recovery().recover(quiescence: lease))
        try assertB(prepared.plan)
        XCTAssertEqual(try Data(contentsOf: old), Data("unknown-old-object".utf8))
        try FileManager.default.removeItem(at: old)
        try FileManager.default.moveItem(at: saved, to: old)
        _ = try recovery().recover(quiescence: lease)
        try assertB(prepared.plan)
    }
    func testTargetMacWidgetPositionsAndLegacyLayoutSurviveCommitRollbackRecovery() async throws {
        XCTAssertFalse(LibraryRestorePreferences.keys.contains("widgetPositions"))
        for point in [LibraryRestoreTransaction.Point.beforeCommit, .afterCommit, .preferenceWrite]
        {
            try a()
            let positions = try JSONEncoder().encode([
                "clock:target-display": WidgetPosition(x: 0.17, y: 0.82)
            ])
            CFPreferencesSetValue(
                "widgetPositions" as CFString, positions as CFData, domain as CFString,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            var layout = DesktopWidgetSettings()
            layout.x = 0.27
            layout.y = 0.73
            layout.scale = 1.9
            layout.allDisplays = true
            try preferences.write(.init(JSONEncoder().encode(layout)), key: "desktopWidgets")
            try preferences.synchronize()
            let prepared = try await b()
            let old = try preferences.snapshot()
            try crash(
                prepared, point: point,
                detail: point == .preferenceWrite ? "B:independentWidgets" : nil)
            _ = try recovery().recover(quiescence: lease)
            XCTAssertEqual(
                CFPreferencesCopyValue(
                    "widgetPositions" as CFString, domain as CFString,
                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Data, positions)
            let data = try XCTUnwrap(preferences.snapshot()["desktopWidgets"]?.value() as? Data)
            let actual = try JSONDecoder().decode(DesktopWidgetSettings.self, from: data)
            XCTAssertEqual(actual.x, layout.x)
            XCTAssertEqual(actual.y, layout.y)
            XCTAssertEqual(actual.scale, layout.scale)
            if point == .afterCommit {
                XCTAssertEqual(actual.allDisplays, prepared.plan.widgets.allDisplays)
                try assertB(prepared.plan)
            } else {
                XCTAssertEqual(try preferences.snapshot(), old)
            }
        }
        CFPreferencesSetValue(
            "widgetPositions" as CFString, nil, domain as CFString,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        try preferences.synchronize()
        let prepared = try await b()
        _ = try transaction().publish(prepared, quiescence: lease)
        XCTAssertNil(
            CFPreferencesCopyValue(
                "widgetPositions" as CFString, domain as CFString,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
    }
    func testRootLockReleaseAndStaleFileDoNotBlockLaterContexts() throws {
        var held: RestoreTransactionIO? = try RestoreTransactionIO(root: root)
        let restore = held!.restore
        let identity = try RestoreObjectIdentity.read(restore, "transaction.lock")
        try withExtendedLifetime(held) { XCTAssertThrowsError(try recovery().inspect()) }
        held = nil
        // The lock file intentionally survives; only the descriptor owns flock.
        XCTAssertEqual(try recovery().inspect(), .none)
        let later = try RestoreTransactionIO(root: root)
        XCTAssertEqual(try RestoreObjectIdentity.read(later.restore, "transaction.lock"), identity)
    }
    func testCapabilityDomainRootAndMutualTransactionExclusion() async throws {
        XCTAssertThrowsError(try RestoreRuntimeQuiescence(callerGuaranteesQuiescentRuntime: false))
        XCTAssertThrowsError(try LibraryRestorePreferences(domain: ""))
        try a()
        let prepared = try await b()
        let second = fixture.root.appendingPathComponent("OtherRoot")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try LibraryRestoreTransaction(root: second, preferenceDomain: domain).publish(
                prepared, quiescence: lease))
        let held = try RestoreTransactionIO(root: root)
        XCTAssertThrowsError(try transaction().publish(prepared, quiescence: lease))
        withExtendedLifetime(held) {}
        try prepared.discard()
    }
}
private final class RestoreOneShot: @unchecked Sendable {
    private let lock = NSLock()
    let point: LibraryRestoreTransaction.Point
    let label: String?
    private var fired = false
    init(point: LibraryRestoreTransaction.Point, label: String? = nil) {
        self.point = point
        self.label = label
    }
    func hit(_ current: LibraryRestoreTransaction.Point, _ label: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if current == point && !fired && (self.label == nil || self.label == label) {
            fired = true
            throw LibraryBackupError("Injected disk-full/write failure")
        }
    }
}
