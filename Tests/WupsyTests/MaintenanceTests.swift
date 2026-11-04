import AppKit
import WebKit
import XCTest

@testable import Wupsy

@MainActor final class MaintenanceTests: XCTestCase {
    func testWholeJobLeaseExcludesBothKindsAndReleasesForEveryExit() throws {
        let coordinator = MaintenanceCoordinator()
        for job in [MaintenanceCoordinator.Job.backup, .restore] {
            for exit in ["cancel", "error", "success"] {
                do {
                    let lease = try coordinator.reserve(job)
                    defer { lease.finish() }
                    XCTAssertThrowsError(try coordinator.reserve(.backup))
                    XCTAssertThrowsError(try coordinator.reserve(.restore))
                    if exit == "cancel" { throw CancellationError() }
                    if exit == "error" { throw MaintenanceError.drainFailed }
                    lease.finish()
                    lease.finish()
                } catch is CancellationError {
                    XCTAssertEqual(exit, "cancel")
                } catch {
                    XCTAssertEqual(error as? MaintenanceError, .drainFailed)
                    XCTAssertEqual(exit, "error")
                }
                XCTAssertEqual(coordinator.state, .normal)
            }
        }
    }
    func testFreezeWaitsForHighLevelLateContinuationAndRejectsEscapedAdmission() async throws {
        let coordinator = MaintenanceCoordinator()
        let job = try coordinator.reserve(.restore)
        defer { job.finish() }
        var ready: CheckedContinuation<Void, Never>?
        var ticket: UUID?
        var completed = false
        let operation = Task {
            try await coordinator.withMutationAsync {
                ticket = MaintenanceOperation.id
                await withCheckedContinuation { ready = $0 }
                XCTAssertTrue(coordinator.allowsMutation)
                try coordinator.withMutation { completed = true }
            }
        }
        while ready == nil { await Task.yield() }
        try coordinator.freeze()
        XCTAssertThrowsError(try coordinator.beginMutation())
        var drained = false
        let drain = Task {
            await coordinator.drain()
            drained = true
        }
        await Task.yield()
        XCTAssertFalse(drained)
        XCTAssertFalse(completed)
        ready?.resume()
        try await operation.value
        await drain.value
        XCTAssertTrue(completed)
        XCTAssertTrue(drained)
        XCTAssertEqual(coordinator.activeOperationCount, 0)
        MaintenanceOperation.$id.withValue(ticket) {
            XCTAssertFalse(coordinator.allowsMutation)
        }
        try coordinator.cancelFreeze()
        XCTAssertTrue(coordinator.allowsNewOperations)
    }
    func testEditorDecisionPermitAndFilesystemBarrierOrder() async throws {
        let coordinator = MaintenanceCoordinator()
        let job = try coordinator.reserve(.restore)
        defer { job.finish() }
        try coordinator.freeze()
        await coordinator.drain()
        try await coordinator.resolveEditors {
            XCTAssertTrue(coordinator.allowsMutation)
            try? coordinator.withMutation {
                let writer = try LibraryMutationBarrier.shared.mutation()
                withExtendedLifetime(writer) {}
            }
        }
        await coordinator.drain()
        let filesystem = try XCTUnwrap(LibraryMutationBarrier.shared.trySnapshot())
        withExtendedLifetime(filesystem) {}
        XCTAssertThrowsError(try coordinator.beginMutation())
        try coordinator.requireRestart()
        XCTAssertThrowsError(try coordinator.cancelFreeze())
        XCTAssertThrowsError(try coordinator.reserve(.backup))
        XCTAssertThrowsError(try coordinator.reserve(.restore))
        XCTAssertThrowsError(try coordinator.beginMutation())
        job.finish()
        XCTAssertEqual(coordinator.state, .restartRequired)
    }
    func testCancelledTaskRetainedUntilActualEnd() async {
        let tasks = RuntimeTaskDrain()
        var resume: CheckedContinuation<Void, Never>?
        var ended = false
        let task = Task {
            await withCheckedContinuation { resume = $0 }
            XCTAssertTrue(Task.isCancelled)
            ended = true
        }
        tasks.track(task)
        while resume == nil { await Task.yield() }
        task.cancel()
        var drained = false
        let drain = Task {
            await tasks.cancelAndDrain()
            drained = true
        }
        await Task.yield()
        XCTAssertFalse(ended)
        XCTAssertFalse(drained)
        resume?.resume()
        await drain.value
        XCTAssertTrue(ended)
        XCTAssertTrue(drained)
    }
    func testTerminalRuntimeGatesAndWriteFreeWidgetShutdown() async throws {
        let coordinator = MaintenanceCoordinator()
        let suite = "maintenance.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(
            maintenance: coordinator, storage: root.appendingPathComponent("library.json"),
            defaults: defaults, restoreOnLaunch: false)
        let widgets = DesktopWidgets(defaults: defaults, maintenance: coordinator)
        widgets.setEnabled(.clock, true)
        widgets.setEnabled(.custom, true)
        widgets.setEditing(true)
        let widgetWindows = widgets.windows
        let drag = try XCTUnwrap(
            widgetWindows.flatMap { $0.contentView?.subviews ?? [] }
                .compactMap { $0 as? WidgetDragSurface }.first)
        let lateDrag = try XCTUnwrap(drag.didDrag)
        let customView = try XCTUnwrap(
            widgetWindows.flatMap { $0.contentView?.subviews ?? [] }
                .compactMap { $0 as? WKWebView }.first)
        let playlist = WallpaperPlaylist(
            library: library, storage: root.appendingPathComponent("playlists.json"),
            defaults: defaults, restoreOnLaunch: false)
        let editors = WSSEditorCoordinator(
            maintenance: coordinator, lookup: { _ in throw WSSEditorOpenError.unavailable })
        let before = defaults.persistentDomain(forName: suite)! as NSDictionary
        let job = try coordinator.reserve(.restore)
        defer { job.finish() }
        try coordinator.freeze()
        let closed = await editors.resolveAndCloseAllForMaintenance()
        XCTAssertEqual(closed, .approved)
        await playlist.shutdownAndDrainForMaintenance()
        await library.stopAndDrainForMaintenance()
        widgets.shutdownForMaintenance()
        await coordinator.drain()
        try coordinator.requireRestart()
        library.selected = UUID()
        library.profile = .eco
        library.manuallyPaused = true
        library.importURLs([root])
        library.clearCache()
        lateDrag(NSRect(x: 100, y: 200, width: 300, height: 120))
        XCTAssertNil(customView.navigationDelegate)
        XCTAssertTrue(widgetWindows.allSatisfy { !$0.isVisible })
        widgets.setEnabled(.clock, false)
        widgets.setScale(.clock, 2)
        widgets.settings.allDisplays.toggle()
        widgets.applyCustom(.starter)
        widgets.resetLayout()
        widgets.setEditing(true)
        playlist.select(UUID())
        XCTAssertFalse(playlist.canEdit)
        XCTAssertThrowsError(try playlist.createPlaylist(name: "blocked"))
        XCTAssertFalse(editors.canCreateWallpaper)
        do {
            try await editors.open(wallpaperID: UUID())
            XCTFail()
        } catch {}
        let wallpaper = Wallpaper(title: "blocked", path: root.path, root: root.path, kind: .image)
        library.toggleFavorite(wallpaper)
        library.remove(wallpaper)
        let outcome = await library.apply(wallpaper).outcome
        if case .superseded = outcome {} else { XCTFail("Apply must be rejected") }
        XCTAssertTrue(widgets.windows.isEmpty)
        XCTAssertFalse(widgets.editing)
        XCTAssertTrue(library.renderers.isEmpty)
        XCTAssertEqual(defaults.persistentDomain(forName: suite)! as NSDictionary, before)
        let canQuit = await editors.approveTermination()
        XCTAssertTrue(canQuit)
        await editors.finishTermination()
        XCTAssertEqual(defaults.persistentDomain(forName: suite)! as NSDictionary, before)
    }
}
