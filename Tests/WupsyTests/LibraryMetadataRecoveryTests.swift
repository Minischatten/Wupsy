import Darwin
import XCTest

@testable import Wupsy

final class LibraryMetadataRecoveryTests: XCTestCase {
    var root: URL!
    var historical: [Wallpaper] = []
    var target: [Wallpaper] { Array(historical.prefix(11)) }
    var preserved: [String] = []
    var original: [String: Data] = [:]
    let playlistID = UUID()
    var lease: RestoreRuntimeQuiescence {
        get throws { try .init(callerGuaranteesQuiescentRuntime: true) }
    }
    let manifest = Data(
        #"{"format":"wss-scene","version":1,"title":"Synthetic native","canvas":{"width":2,"height":2},"layers":[{"image":"assets/test.png","transform":{"center":[1,1],"size":[2,2]}}]}"#
            .utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("metadata-recovery.tests." + UUID().uuidString)
        XCTAssertFalse(root.path.contains("Library/Application Support"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<13 {
            let id = UUID()
            let category = index < 10 ? "WSS" : "Media"
            let entry =
                category == "Loose"
                ? "scene.json" : (category == "WSS" ? "scene.wss.json" : "test.png")
            let directory = category + "/" + id.uuidString
            historical.append(
                Wallpaper(
                    id: id, title: "Historical \(index)", path: "", root: "",
                    kind: category == "Media" ? .image : .scene,
                    managed: .init(directory: directory, entry: entry),
                    sceneSource: category == "WSS" ? .nativeWSS : nil))
            if index < 11 {
                if category == "Loose" {
                    try file("Wallpapers/" + directory + "/scene.json", Data("{}".utf8))
                    try file("Wallpapers/" + directory + "/project.json", Data("{}".utf8))
                    try native("Wallpapers/NativeProjects/" + id.uuidString)
                } else if category == "WSS" {
                    try native("Wallpapers/" + directory)
                } else {
                    try file("Wallpapers/" + directory + "/test.png", Data("synthetic media".utf8))
                }
            }
        }
        // Historical item 11 is a WE source removed later; only its native working project remains.
        let id = historical[11].id
        historical[11] = Wallpaper(
            id: id, title: "Historical source removed", path: "", root: "", kind: .scene,
            managed: .init(directory: "Loose/" + id.uuidString, entry: "scene.json"))
        preserved = [id, UUID(), UUID()].map { "Wallpapers/NativeProjects/" + $0.uuidString }
        for path in preserved { try native(path) }
        try file("library.json", Data("[  ]\n".utf8))
        try file(
            "playlists.json",
            JSONEncoder().encode(
                PlaylistCollectionState(definitions: [
                    .init(id: playlistID, name: "Synthetic_1", intervalSeconds: 60)
                ])))
        original = try metadata()
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
        historical = []
    }
    func file(_ path: String, _ bytes: Data) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }
    func native(_ path: String) throws {
        try file(path + "/scene.wss.json", manifest)
        try file(path + "/assets/test.png", Data("synthetic resource bytes".utf8))
    }
    func plan(
        items: [Wallpaper]? = nil, playlists: PlaylistCollectionState? = nil, id: UUID = UUID()
    ) throws -> LibraryRecoveryPlan {
        let items = items ?? target
        let projects = try items.map { item -> RecoveryProjectEvidence in
            let source = try RecoveryTreeEvidence.capture(
                root: root, directory: "Wallpapers/" + item.managed!.directory)
            return .init(id: item.id, source: source, native: nil)
        }
        let collection =
            playlists
            ?? PlaylistCollectionState(definitions: [
                .init(
                    id: playlistID, name: "Synthetic_1",
                    wallpaperIDs: Array(target.prefix(5)).map(\.id), intervalSeconds: 60)
            ])
        return try .init(
            version: 1, id: id, expectedMetadata: LibraryRecoveryPlan.metadata(root: root),
            library: JSONEncoder().encode(items), playlists: JSONEncoder().encode(collection),
            expectedIDs: items.map(\.id),
            excludedIDs: Array(historical.suffix(2)).map(\.id)
                + preserved.dropFirst().compactMap {
                    UUID(uuidString: URL(fileURLWithPath: $0).lastPathComponent)
                },
            projects: projects,
            preserved: preserved.map { try .capture(root: root, directory: $0) },
            absentProjectDirectories: historical.suffix(2).map {
                "Wallpapers/" + $0.managed!.directory
            },
            historicalMetadataSource: "synthetic verified backup")
    }
    func metadata() throws -> [String: Data] {
        try Dictionary(
            uniqueKeysWithValues: LibraryMetadataRecovery.names.map {
                ($0, try Data(contentsOf: root.appendingPathComponent($0)))
            })
    }
    func payload() throws -> [RecoveryTreeEvidence] {
        try
            (target.map { "Wallpapers/" + $0.managed!.directory }
            + preserved)
            .map { try .capture(root: root, directory: $0) }
    }
    func testSyntheticThirteenToElevenAndRetainedEvidence() throws {
        XCTAssertEqual(historical.count, 13)
        let before = try payload()
        let plan = try plan()
        let core = LibraryMetadataRecovery(root: root)
        XCTAssertEqual(try core.apply(plan, quiescence: lease), .committed(plan.id))
        let library = try ManagedWallpaperStore(
            storage: root.appendingPathComponent("library.json")
        ).load()
        XCTAssertEqual(library.map(\.id), target.map(\.id))
        let playlist = try WallpaperPlaylistStore(
            url: root.appendingPathComponent("playlists.json")
        ).load()
        XCTAssertEqual(playlist.definitions[0].wallpaperIDs, Array(target.prefix(5)).map(\.id))
        XCTAssertNil(playlist.playback)
        XCTAssertEqual(try payload(), before)
        XCTAssertEqual(try core.preflight(quiescence: lease), .committed(plan.id))
        XCTAssertThrowsError(try core.apply(plan, quiescence: lease))
        for path in LibraryMetadataRecovery.names {
            XCTAssertEqual(
                try Data(
                    contentsOf: root.appendingPathComponent(
                        ".restore/staging/" + plan.id.uuidString + "/before-" + path)),
                original[path])
        }
        // Terminal transactions must not replay over later legitimate metadata edits.
        try file("library.json", Data("[]".utf8))
        XCTAssertEqual(try core.preflight(quiescence: lease), .committed(plan.id))
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("library.json")), Data("[]".utf8))
    }
    func testEveryCrashBoundaryRollsBackOnNewStartup() throws {
        let points: [LibraryMetadataRecovery.Point] = [
            .beforeFirstInstall, .afterFirstInstall,
            .beforeSecondInstall, .afterSecondInstall, .beforeCommit, .beforeRename, .afterRename,
            .journalRenamed,
        ]
        for point in points {
            let plan = try plan()
            let before = try payload()
            var core = LibraryMetadataRecovery(root: root)
            core.checkpoint = { hit, _ in if hit == point { throw RestoreSimulatedCrash() } }
            XCTAssertThrowsError(try core.apply(plan, quiescence: lease))
            XCTAssertThrowsError(try LibraryMetadataRecovery.requireReadable(root: root))
            if point == .afterFirstInstall || point == .beforeSecondInstall || point == .afterRename
            {
                let mixed = try metadata()
                XCTAssertEqual(mixed["library.json"], original["library.json"])
                XCTAssertEqual(mixed["playlists.json"], plan.playlists)
            }
            var constructed = false
            try WupsyStartup.run(
                context: .init(supportRoot: root, preferenceDomain: "metadata-recovery.tests"),
                probe: { context in
                    // Metadata recovery must finish before the restore-journal probe.
                    XCTAssertEqual(try self.metadata(), self.original)
                    return try WupsyStartup.needsRecovery(context)
                },
                constructRuntime: {
                    XCTAssertEqual(try? self.metadata(), self.original)
                    constructed = true
                })
            XCTAssertTrue(constructed)
            XCTAssertEqual(try metadata(), original)
            XCTAssertEqual(try payload(), before)
            XCTAssertEqual(
                try LibraryMetadataRecovery(root: root).preflight(quiescence: lease),
                .rolledBack(plan.id))
            XCTAssertThrowsError(
                try LibraryMetadataRecovery(root: root).apply(plan, quiescence: lease))
        }
    }
    func testCrashAfterDurableCommitRetainsTarget() throws {
        let plan = try plan()
        var core = LibraryMetadataRecovery(root: root)
        core.checkpoint = { hit, _ in if hit == .afterCommit { throw RestoreSimulatedCrash() } }
        XCTAssertThrowsError(try core.apply(plan, quiescence: lease))
        XCTAssertEqual(
            try LibraryMetadataRecovery(root: root).preflight(quiescence: lease),
            .committed(plan.id))
        XCTAssertEqual(
            try metadata(), ["library.json": plan.library, "playlists.json": plan.playlists])
    }
    func testOrdinaryErrorAtEachPrecommitBoundaryRestoresExactBytes() throws {
        for point in [
            LibraryMetadataRecovery.Point.beforeFirstInstall, .afterFirstInstall,
            .beforeSecondInstall, .afterSecondInstall, .beforeCommit, .afterRename,
        ] {
            let plan = try plan()
            var fired = false
            var core = LibraryMetadataRecovery(root: root)
            core.checkpoint = { hit, _ in
                if hit == point && !fired {
                    fired = true
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            XCTAssertThrowsError(try core.apply(plan, quiescence: lease))
            XCTAssertEqual(try metadata(), original)
            try LibraryMetadataRecovery.requireReadable(root: root)
        }
    }
    func testRollbackFailureStaysBlockedThenCanResume() throws {
        let plan = try plan()
        var core = LibraryMetadataRecovery(root: root)
        core.checkpoint = { hit, _ in
            if hit == .afterFirstInstall || hit == .rollback { throw CocoaError(.fileWriteUnknown) }
        }
        XCTAssertThrowsError(try core.apply(plan, quiescence: lease)) { error in
            XCTAssertTrue(error.localizedDescription.contains("rollback unresolved"))
        }
        XCTAssertThrowsError(try LibraryMetadataRecovery.requireReadable(root: root))
        XCTAssertEqual(
            try LibraryMetadataRecovery(root: root).preflight(quiescence: lease),
            .rolledBack(plan.id))
        XCTAssertEqual(try metadata(), original)
    }
    func testChangedMetadataOrProjectRejectedBeforeMutation() throws {
        let plan = try plan()
        try file("playlists.json", Data("changed".utf8))
        XCTAssertThrowsError(try LibraryMetadataRecovery(root: root).apply(plan, quiescence: lease))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(".restore").path))
        try file("playlists.json", original["playlists.json"]!)
        try file(
            "Wallpapers/" + target[0].managed!.directory + "/scene.wss.json", Data("changed".utf8))
        XCTAssertThrowsError(try LibraryMetadataRecovery(root: root).apply(plan, quiescence: lease))
        XCTAssertEqual(try metadata(), original)
    }
    func testMissingEntryOrResourceRejectedBeforeMutation() throws {
        let plan = try plan()
        let path = root.appendingPathComponent(
            "Wallpapers/" + target[0].managed!.directory + "/scene.wss.json")
        try FileManager.default.removeItem(at: path)
        XCTAssertThrowsError(try LibraryMetadataRecovery(root: root).apply(plan, quiescence: lease))
        XCTAssertEqual(try metadata(), original)
        try file("Wallpapers/" + target[0].managed!.directory + "/scene.wss.json", manifest)
        let missing = root.appendingPathComponent(
            "Wallpapers/" + target[6].managed!.directory + "/assets/test.png")
        try FileManager.default.removeItem(at: missing)
        // Even a newly sealed incomplete tree must fail semantic validation.
        let incomplete = try self.plan()
        XCTAssertThrowsError(
            try LibraryMetadataRecovery(root: root).apply(incomplete, quiescence: lease))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(".restore").path))
    }
    func testDuplicateIDsUnknownPlaylistAndPlaybackRejected() throws {
        let duplicate = try plan(items: [target[0], target[0]])
        XCTAssertThrowsError(
            try LibraryMetadataRecovery(root: root).apply(duplicate, quiescence: lease))
        let unknown = try plan(
            playlists: .init(definitions: [.init(name: "Bad", wallpaperIDs: [UUID()])]))
        XCTAssertThrowsError(
            try LibraryMetadataRecovery(root: root).apply(unknown, quiescence: lease))
        let active = try plan(
            playlists: .init(
                definitions: [
                    .init(
                        id: playlistID, name: "Active",
                        wallpaperIDs: Array(target.prefix(2)).map(\.id))
                ],
                playback: .init(playlistID: playlistID, enabled: true)))
        XCTAssertThrowsError(
            try LibraryMetadataRecovery(root: root).apply(active, quiescence: lease))
        var mistyped = target
        mistyped[10].kind = .video
        let wrongKind = try plan(items: mistyped)
        XCTAssertThrowsError(
            try LibraryMetadataRecovery(root: root).apply(wrongKind, quiescence: lease))
        XCTAssertEqual(try metadata(), original)
    }
    func testCorruptJournalAndSnapshotFailClosedWithoutRuntime() throws {
        let plan = try plan()
        var core = LibraryMetadataRecovery(root: root)
        core.checkpoint = { hit, _ in if hit == .afterFirstInstall { throw RestoreSimulatedCrash() }
        }
        XCTAssertThrowsError(try core.apply(plan, quiescence: lease))
        let journalURL = root.appendingPathComponent(".restore/metadata-recovery.json")
        let valid = try Data(contentsOf: journalURL)
        try file(".restore/metadata-recovery.json", Data("{}".utf8))
        var runtime = false
        XCTAssertThrowsError(
            try WupsyStartup.run(
                context: .init(supportRoot: root, preferenceDomain: "metadata-recovery.tests")
            ) { runtime = true })
        XCTAssertFalse(runtime)
        try valid.write(to: journalURL)
        try file(
            ".restore/staging/" + plan.id.uuidString + "/before-library.json", Data("tampered".utf8)
        )
        XCTAssertThrowsError(try LibraryMetadataRecovery(root: root).preflight(quiescence: lease))
        XCTAssertThrowsError(try LibraryMetadataRecovery.requireReadable(root: root))
    }
    func testLegitimateEmptyPlanDoesNotRegisterOrphans() throws {
        let empty = try plan(items: [], playlists: .init())
        XCTAssertEqual(
            try LibraryMetadataRecovery(root: root).apply(empty, quiescence: lease),
            .committed(empty.id))
        XCTAssertTrue(
            try ManagedWallpaperStore(storage: root.appendingPathComponent("library.json")).load()
                .isEmpty)
        for path in preserved {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        }
    }
    func testExpectedAbsentSourceAppearingInvalidatesPlan() throws {
        let plan = try plan()
        try file("Wallpapers/" + historical[11].managed!.directory + "/scene.json", Data("{}".utf8))
        XCTAssertThrowsError(try LibraryMetadataRecovery(root: root).apply(plan, quiescence: lease))
        XCTAssertEqual(try metadata(), original)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(".restore").path))
    }
    func altered(_ plan: LibraryRecoveryPlan, change: (inout [String: Any]) -> Void) throws
        -> LibraryRecoveryPlan
    {
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        change(&json)
        return try JSONDecoder().decode(
            LibraryRecoveryPlan.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func testExcludedIDUnsafePathAndWrongNativeMappingFailBeforeMutation() throws {
        let plan = try plan()
        let excluded = try altered(plan) { $0["excludedIDs"] = [target[0].id.uuidString] }
        XCTAssertThrowsError(
            try LibraryMetadataRecovery(root: root).apply(excluded, quiescence: lease))
        let wrong = try altered(plan) { json in
            var projects = json["projects"] as! [[String: Any]]
            projects[0]["native"] = projects[1]["source"]
            json["projects"] = projects
        }
        XCTAssertThrowsError(
            try LibraryMetadataRecovery(root: root).apply(wrong, quiescence: lease))
        let unsafe = try altered(plan) {
            $0["absentProjectDirectories"] = ["Wallpapers/Loose/../../outside"]
        }
        XCTAssertThrowsError(
            try LibraryMetadataRecovery(root: root).apply(unsafe, quiescence: lease))
        XCTAssertEqual(try metadata(), original)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(".restore").path))
    }
    func testInterruptedRollbackCanRestartAndDoesNotOverwriteThirdPartyBytes() throws {
        let plan = try plan()
        var core = LibraryMetadataRecovery(root: root)
        core.checkpoint = { hit, _ in
            if hit == .afterSecondInstall { throw RestoreSimulatedCrash() }
        }
        XCTAssertThrowsError(try core.apply(plan, quiescence: lease))
        var recovery = LibraryMetadataRecovery(root: root)
        recovery.checkpoint = { hit, _ in if hit == .afterRename { throw RestoreSimulatedCrash() } }
        XCTAssertThrowsError(try recovery.preflight(quiescence: lease))
        XCTAssertThrowsError(try LibraryMetadataRecovery.requireReadable(root: root))
        XCTAssertEqual(
            try LibraryMetadataRecovery(root: root).preflight(quiescence: lease),
            .rolledBack(plan.id))
        XCTAssertEqual(try metadata(), original)

        let next = try self.plan()
        XCTAssertThrowsError(try core.apply(next, quiescence: lease))
        try file("library.json", Data("unrelated third-party bytes".utf8))
        XCTAssertThrowsError(try LibraryMetadataRecovery(root: root).preflight(quiescence: lease))
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("library.json")),
            Data("unrelated third-party bytes".utf8))
        XCTAssertThrowsError(try LibraryMetadataRecovery.requireReadable(root: root))
    }

}
