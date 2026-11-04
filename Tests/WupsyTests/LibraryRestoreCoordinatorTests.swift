import XCTest

@testable import Wupsy

@MainActor final class LibraryRestoreCoordinatorTests: XCTestCase {
    var fixture: LibraryRestoreTransactionTests!
    var maintenance: MaintenanceCoordinator!
    var coordinator: LibraryRestoreCoordinator!
    var events: [String] = []
    var artifact: PreparedLibraryRestore?
    let barrier = LibraryMutationBarrier()
    override func setUpWithError() throws {
        fixture = LibraryRestoreTransactionTests()
        try fixture.setUpWithError()
        try fixture.a()
        maintenance = MaintenanceCoordinator()
        coordinator = LibraryRestoreCoordinator(maintenance: maintenance)
        events = []
    }
    override func tearDownWithError() throws {
        coordinator = nil
        maintenance = nil
        artifact = nil
        try fixture.tearDownWithError()
    }
    var context: WupsyLaunchContext {
        .init(supportRoot: fixture.root, preferenceDomain: fixture.domain)
    }
    func assertJobsBlocked() {
        XCTAssertThrowsError(try maintenance.reserve(.backup))
        XCTAssertThrowsError(try maintenance.reserve(.restore))
    }
    func actions() -> LibraryRestoreCoordinator.Actions {
        .init(
            select: { [self] in
                XCTAssertEqual(maintenance.state, .restorePreparing)
                assertJobsBlocked()
                events.append("select")
                return fixture.root.appendingPathComponent("synthetic.wssbackup")
            },
            prepare: { [self] _, progress in
                XCTAssertTrue(maintenance.allowsNewOperations)
                events.append("prepare")
                progress(.preparing)
                let prepared = try await fixture.b()
                artifact = prepared
                return prepared
            },
            confirm: { [self] plan in
                XCTAssertEqual(maintenance.state, .restorePreparing)
                XCTAssertTrue(maintenance.allowsNewOperations)
                XCTAssertEqual(plan.summary, artifact?.plan.summary)
                events.append("confirm")
                return true
            },
            cancelPendingEditors: { [self] in
                XCTAssertEqual(maintenance.state, .restoreFreezing)
                events.append("pending")
            },
            resolveEditors: { [self] boundary in
                XCTAssertEqual(maintenance.state, .restoreFreezing)
                XCTAssertTrue(coordinator.canCancel)
                events.append("editors")
                return boundary() ? .approved : .cancelled
            },
            stopPlaylist: { [self] in
                XCTAssertTrue(coordinator.terminal)
                XCTAssertFalse(coordinator.canCancel)
                events.append("playlist")
            },
            stopLibrary: { [self] in events.append("library+renderer") },
            closeLibrary: { [self] in events.append("window") },
            stopWidgets: { [self] in events.append("widgets") },
            snapshot: { [self] in
                XCTAssertEqual(maintenance.activeOperationCount, 0)
                XCTAssertTrue(coordinator.blocksLibrary)
                events.append("barrier")
                return barrier.trySnapshot()!
            },
            publish: { [self] prepared in
                XCTAssertThrowsError(try barrier.mutation())
                events.append("publish")
                try await LibraryRestorePublication.publish(prepared, context: context)
            },
            recover: { [self] in
                events.append("recovery")
                return try await LibraryRestorePublication.recover(context: context)
            },
            failure: { [self] _ in events.append("failure") },
            completion: { [self] result in
                XCTAssertEqual(maintenance.state, .restartRequired)
                XCTAssertEqual(result, coordinator.outcome)
                events.append("completion")
            })
    }
    func assertNormalA(_ before: [String: Data], file: StaticString = #filePath, line: UInt = #line)
        throws
    {
        XCTAssertEqual(maintenance.state, .normal, file: file, line: line)
        XCTAssertFalse(coordinator.running, file: file, line: line)
        XCTAssertFalse(coordinator.terminal, file: file, line: line)
        XCTAssertEqual(try fixture.bytes(), before, file: file, line: line)
        let job = try maintenance.reserve(.backup)
        job.finish()
        if let artifact {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: artifact.newRoot.path), file: file,
                line: line)
        }
        XCTAssertFalse(events.contains("playlist"), file: file, line: line)
        XCTAssertFalse(events.contains("publish"), file: file, line: line)
    }
    func assertTerminal(_ expected: LibraryRestoreCoordinator.Outcome) throws {
        // Resolve every presentation language against the same real terminal result.
        for language in ["en", "de", "zz"] {
            let presentation = RestoreTerminalPresentation(expected, language: language)
            XCTAssertEqual(presentation.outcome, expected)
            XCTAssertFalse(presentation.title.isEmpty)
            XCTAssertEqual(coordinator.outcome, expected)
            XCTAssertEqual(maintenance.state, .restartRequired)
            XCTAssertTrue(coordinator.terminal)
            XCTAssertFalse(coordinator.canCancel)
        }
        XCTAssertEqual(coordinator.outcome, expected)
        XCTAssertEqual(maintenance.state, .restartRequired)
        XCTAssertTrue(coordinator.terminal)
        XCTAssertFalse(coordinator.canCancel)
        XCTAssertTrue(coordinator.blocksLibrary)
        XCTAssertFalse(coordinator.running)
        XCTAssertThrowsError(try maintenance.reserve(.backup))
        XCTAssertThrowsError(try maintenance.reserve(.restore))
        XCTAssertThrowsError(try maintenance.beginMutation())
        XCTAssertThrowsError(try barrier.mutation())
    }
    func testLeaseExcludesBackupSecondRestoreAndRestart() async throws {
        let job = try maintenance.reserve(.backup)
        XCTAssertThrowsError(try coordinator.start(actions()))
        job.finish()
        let running = try coordinator.start(actions())
        XCTAssertThrowsError(try coordinator.start(actions()))
        await running.value
        try assertTerminal(.committed)
    }
    func testOpenPanelCancelReleasesWithoutPreparation() async throws {
        let before = try fixture.bytes()
        var a = actions()
        a.select = { nil }
        await (try coordinator.start(a)).value
        try assertNormalA(before)
        XCTAssertEqual(events, [])
    }
    func testInvalidBackupUsesExistingReaderAndReleases() async throws {
        let before = try fixture.bytes()
        let url = fixture.root.appendingPathComponent("invalid.wssbackup")
        try Data("invalid".utf8).write(to: url)
        var a = actions()
        a.prepare = { [self] _, _ in
            try await LibraryRestorePreparer(supportRoot: fixture.root).prepare(url)
        }
        // Include the controlled invalid input in the unchanged A inventory.
        let inventory = try fixture.bytes()
        await (try coordinator.start(a)).value
        try assertNormalA(inventory)
        XCTAssertTrue(events.contains("failure"))
        XCTAssertEqual(before["library.json"], inventory["library.json"])
    }
    func testPreparationErrorReleasesWithoutRecovery() async throws {
        let before = try fixture.bytes()
        var a = actions()
        a.prepare = { _, _ in throw MaintenanceError.drainFailed }
        await (try coordinator.start(a)).value
        try assertNormalA(before)
        XCTAssertEqual(events, ["select", "failure"])
    }
    func testPreparationCancelDiscardsReturnedArtifact() async throws {
        let before = try fixture.bytes()
        var a = actions()
        let original = a.prepare
        a.prepare = { [self] url, progress in
            let prepared = try await original(url, progress)
            coordinator.cancel()
            return prepared
        }
        await (try coordinator.start(a)).value
        try assertNormalA(before)
        XCTAssertFalse(events.contains("failure"))
    }
    func testConfirmationCancelHasNoFreezeOrRuntimeChange() async throws {
        let before = try fixture.bytes()
        var a = actions()
        a.confirm = { [self] _ in
            XCTAssertEqual(maintenance.state, .restorePreparing)
            return false
        }
        await (try coordinator.start(a)).value
        try assertNormalA(before)
        XCTAssertEqual(events, ["select", "prepare"])
    }
    func testEditorCancelUnfreezesAndDiscards() async throws {
        let before = try fixture.bytes()
        var a = actions()
        a.resolveEditors = { _ in .cancelled }
        await (try coordinator.start(a)).value
        try assertNormalA(before)
    }
    func testFinalCancellationBoundaryDoesNotCloseOrStop() async throws {
        let before = try fixture.bytes()
        var a = actions()
        a.resolveEditors = { [self] boundary in
            coordinator.cancel()
            XCTAssertFalse(boundary())
            return .cancelled
        }
        await (try coordinator.start(a)).value
        try assertNormalA(before)
    }
    func testDrainWaitsForAcceptedWritebackBeforeEditorsAndTerminalStop() async throws {
        let lease = try maintenance.beginMutation()
        var a = actions()
        a.cancelPendingEditors = { [self] in
            XCTAssertEqual(maintenance.state, .restoreFreezing)
            // A previously accepted continuation finishes while new work is frozen.
            XCTAssertThrowsError(try maintenance.beginMutation())
            Task { @MainActor in
                await Task.yield()
                events.append("late-A-writeback")
                lease.finish()
            }
        }
        await (try coordinator.start(a)).value
        XCTAssertEqual(
            events,
            [
                "select", "prepare", "confirm", "late-A-writeback", "editors",
                "playlist", "library+renderer", "window", "widgets", "barrier",
                "publish", "completion",
            ])
        try assertTerminal(.committed)
    }
    func testActualCommitConsumesStagingAndDoesNotRecoverForCompletionError() async throws {
        var a = actions()
        a.completion = { [self] _ in
            // A presentation failure is outside the publication/recovery catch entirely.
            do { throw MaintenanceError.drainFailed } catch { events.append("UI-error") }
        }
        await (try coordinator.start(a)).value
        try assertTerminal(.committed)
        let prepared = try XCTUnwrap(artifact)
        try fixture.assertB(prepared.plan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.newRoot.path))
        XCTAssertFalse(events.contains("recovery"))
        XCTAssertEqual(events.last, "UI-error")
    }
    func crashingActions(_ point: LibraryRestoreTransaction.Point)
        -> LibraryRestoreCoordinator.Actions
    {
        var a = actions()
        a.publish = { [self] prepared in
            let context = context
            try await Task.detached {
                var transaction = try LibraryRestoreTransaction(
                    root: context.supportRoot, preferenceDomain: context.preferenceDomain)
                transaction.checkpoint = { actual, _ in
                    if actual == point { throw RestoreSimulatedCrash() }
                }
                _ = try transaction.publish(
                    prepared, quiescence: .init(callerGuaranteesQuiescentRuntime: true))
            }.value
        }
        return a
    }
    func testPublishErrorRecoveryRestoresAAndStillRequiresRestart() async throws {
        let before = try fixture.bytes()
        await (try coordinator.start(crashingActions(.afterAllNew))).value
        try assertTerminal(.restoredA)
        XCTAssertEqual(try fixture.bytes(), before)
        XCTAssertTrue(events.contains("recovery"))
    }
    func testPublishErrorRecoveryConfirmsB() async throws {
        await (try coordinator.start(crashingActions(.afterCommit))).value
        try assertTerminal(.committed)
        try fixture.assertB(XCTUnwrap(artifact).plan)
        XCTAssertTrue(events.contains("recovery"))
    }
    func testRecoveryErrorFailsClosedWithoutDiscardingClaimedArtifact() async throws {
        var a = crashingActions(.afterPrepared)
        a.recover = { throw MaintenanceError.drainFailed }
        await (try coordinator.start(a)).value
        try assertTerminal(.unresolved)
        let prepared = try XCTUnwrap(artifact)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.newRoot.path))
        XCTAssertThrowsError(try prepared.discard())
        XCTAssertTrue(try WupsyStartup.needsRecovery(context))
    }
    func testAbsentJournalAfterThrownPublishIsNotAssumedA() async throws {
        var a = actions()
        a.publish = { _ in throw MaintenanceError.drainFailed }
        await (try coordinator.start(a)).value
        try assertTerminal(.unresolved)
        // No post-handoff generic discard, even when this particular failure preceded claim.
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(artifact).newRoot.path))
    }
    func testQuitDuringPreparationCancelsAndAwaitsOwnedCleanup() async throws {
        let before = try fixture.bytes()
        var a = actions()
        let original = a.prepare
        a.prepare = { [self] url, progress in
            let prepared = try await original(url, progress)
            Task { @MainActor in await coordinator.prepareToQuit() }
            while !Task.isCancelled { await Task.yield() }
            return prepared
        }
        await (try coordinator.start(a)).value
        try assertNormalA(before)
        XCTAssertFalse(events.contains("failure"))
    }
    func testQuitDuringPublicationWaitsAndCannotCancelCommittedB() async throws {
        var a = actions()
        let publish = a.publish
        a.publish = { [self] prepared in
            let quit = Task { @MainActor in await coordinator.prepareToQuit() }
            await Task.yield()
            XCTAssertFalse(Task.isCancelled)
            coordinator.cancel()
            try await publish(prepared)
            // Do not await quit here: it intentionally waits for this whole restore job.
            _ = quit
        }
        await (try coordinator.start(a)).value
        try assertTerminal(.committed)
        XCTAssertFalse(events.contains("completion"))
        try fixture.assertB(XCTUnwrap(artifact).plan)
    }
    func testSummaryUsesValidatedDateCountsSizeRecoveryAndIncomplete() async throws {
        let prepared = try await fixture.b()
        defer { try? prepared.discard() }
        let text = LibraryRestoreSummary.text(prepared.plan, language: "en")
        XCTAssertTrue(
            text.contains(
                LibraryBackupCompletionSummary.string(
                    wallpapers: prepared.plan.library.count,
                    playlists: prepared.plan.playlists.definitions.count,
                    bytes: prepared.plan.manifest.totalLogicalSize, language: "en")))
        let date = LibraryRestoreSummary.date(prepared.plan.manifest.createdAt, language: "en")
        XCTAssertTrue(text.contains(date))
        XCTAssertTrue(text.contains("replace the current"))
        XCTAssertFalse(text.contains("incomplete"))
        XCTAssertFalse(text.contains("recovery project"))
        // The reader tests already prove incomplete/recovery validation. Exercise the UI
        // using another fully validated plan produced from those supported source cases.
        let f = fixture.fixture!
        let missing = try f.native("Wallpapers/WSS/Imported")
        let recovery = UUID()
        _ = try f.native("Wallpapers/NativeProjects/" + recovery.uuidString, id: recovery)
        try f.save([missing])
        f.defaults.set([missing.id.uuidString], forKey: "favorites")
        try WallpaperPlaylistStore(
            url: f.storage.deletingLastPathComponent().appendingPathComponent("playlists.json")
        ).save(PlaylistCollectionState())
        let (stage, manifest) = try f.snapshot()
        defer { try? stage.discard() }
        let archive = try f.archive(stage, manifest)
        defer { try? archive.discard() }
        let incomplete = try await LibraryRestorePreparer(supportRoot: fixture.root).prepare(
            f.root.appendingPathComponent(archive.temporary))
        defer { try? incomplete.discard() }
        let summary = LibraryRestoreSummary.text(incomplete.plan, language: "en")
        XCTAssertFalse(incomplete.plan.incomplete)
        XCTAssertFalse(summary.contains("incomplete"))
        XCTAssertTrue(summary.contains("1 recovery project"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(incomplete.plan.manifest)
        for language in ["en", "de", "zz"] {
            let localized = LibraryRestoreSummary.text(incomplete.plan, language: language)
            XCTAssertFalse(localized.contains(RestoreText.incomplete.localized(language: language)))
            XCTAssertTrue(
                localized.contains(RestoreText.recoveryCount.format(Int64(1), language: language)))
            XCTAssertEqual(try encoder.encode(incomplete.plan.manifest), before)
            XCTAssertFalse(incomplete.plan.incomplete)
        }
        XCTAssertTrue(
            summary.contains(
                LibraryBackupCompletionSummary.string(
                    wallpapers: incomplete.plan.library.count,
                    playlists: incomplete.plan.playlists.definitions.count,
                    bytes: incomplete.plan.manifest.totalLogicalSize, language: "en")))
    }
}
