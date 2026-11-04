import AppKit
import XCTest

@testable import Wupsy

@MainActor final class RuntimeMaintenanceTests: XCTestCase {
    func testPendingPreparationAndSupersededApplyAreCancelledAndActuallyDrained() async throws {
        let helper = ManagedLibraryTests()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let item = try await helper.store.importWallpaper(helper.nativeSource(), existing: [])
        let suite = "runtime-maintenance.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "conserve")
        defaults.set(false, forKey: "pauseOnBattery")
        defaults.set("A-selection", forKey: "activeWallpaper")
        let maintenance = MaintenanceCoordinator()
        var continuations: [CheckedContinuation<PreparedScenePlayback, Error>] = []
        let library = Library(
            maintenance: maintenance, storage: helper.store.storage, defaults: defaults,
            restoreOnLaunch: false,
            scenePreparation: { _ in
                try await withCheckedThrowingContinuation { continuations.append($0) }
            })
        library.apply(item)
        while continuations.count < 1 { await Task.yield() }
        // Reapply cancels the first preparation; both handles must remain drainable.
        library.profile = .eco
        while continuations.count < 2 { await Task.yield() }
        let before = defaults.persistentDomain(forName: suite)! as NSDictionary
        let job = try maintenance.reserve(.restore)
        defer { job.finish() }
        try maintenance.freeze()
        var stopped = false
        let stop = Task {
            await library.stopAndDrainForMaintenance()
            stopped = true
        }
        await Task.yield()
        XCTAssertFalse(stopped)
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
        await stop.value
        await maintenance.drain()
        XCTAssertTrue(stopped)
        XCTAssertTrue(library.renderers.isEmpty)
        XCTAssertNil(library.active)
        XCTAssertFalse(library.preparing)
        XCTAssertEqual(defaults.persistentDomain(forName: suite)! as NSDictionary, before)
        XCTAssertEqual(maintenance.activeOperationCount, 0)
        library.restorePlayback()
        XCTAssertNil(library.active)
    }
    func testTerminalLibraryStopWaitsForAcceptedSelectionWriteback() async throws {
        let maintenance = MaintenanceCoordinator()
        let suite = "runtime-drain.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let library = Library(
            maintenance: maintenance,
            storage: root.appendingPathComponent("library.json"), defaults: defaults,
            restoreOnLaunch: false)
        let selected = UUID()
        var continuation: CheckedContinuation<Void, Never>?
        let writer = Task {
            try await maintenance.withMutationAsync {
                await withCheckedContinuation { continuation = $0 }
                library.selected = selected
            }
        }
        while continuation == nil { await Task.yield() }
        let job = try maintenance.reserve(.restore)
        defer { job.finish() }
        try maintenance.freeze()
        var stopping = false
        let stop = Task {
            stopping = true
            await library.stopAndDrainForMaintenance()
        }
        while !stopping { await Task.yield() }
        continuation?.resume()
        try await writer.value
        await stop.value
        XCTAssertEqual(library.selected, selected)
        XCTAssertEqual(defaults.string(forKey: "selectedWallpaper"), selected.uuidString)
        XCTAssertEqual(maintenance.activeOperationCount, 0)
        library.selected = UUID()
        XCTAssertEqual(library.selected, selected)
    }

}
