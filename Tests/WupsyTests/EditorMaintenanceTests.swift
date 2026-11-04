import AppKit
import XCTest

@testable import Wupsy

@MainActor private final class MaintenanceEditorWindow: WSSEditorWindow {
    private let onClose: () -> Void
    init(_ onClose: @escaping () -> Void) { self.onClose = onClose }
    func focus() {}
    func close() { onClose() }
}

@MainActor final class EditorMaintenanceTests: XCTestCase {
    func testCleanAndDirtySaveDiscardCancelAcrossMultipleEditors() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        for choice in [WSSEditorDocument.CloseChoice.save, .discard, .cancel] {
            let maintenance = MaintenanceCoordinator()
            var documents: [WSSEditorDocument] = []
            var second = project.handle.wallpaper
            second.id = UUID()
            var saves = 0
            var terminations = 0
            let coordinator = WSSEditorCoordinator(
                maintenance: maintenance,
                lookup: { id in id == second.id ? second : project.handle.wallpaper },
                save: { snapshot in
                    saves += 1
                    return WSSSaveReceipt(
                        snapshot: snapshot, diskBasis: snapshot.diskBasis,
                        outcome: .committed(warnings: []))
                }, onTermination: { terminations += 1 }, load: { _ in project },
                makeWindow: { doc, close in
                    documents.append(doc)
                    return MaintenanceEditorWindow(close)
                })
            try await coordinator.open(wallpaperID: project.handle.id)
            try await coordinator.open(wallpaperID: second.id)
            // One clean editor plus one dirty editor; no window closes before all approval.
            try documents[1].setParameter(
                .rippleAmplitude, at: .init(layerIndex: 0, effectIndex: 0), value: 20)
            var prompts = 0
            documents[1].chooseClose = {
                prompts += 1
                return choice
            }
            let runtime = choice == .cancel ? try maintenance.beginMutation(kind: .runtime) : nil
            defer { runtime?.finish() }
            let job = try maintenance.reserve(.restore)
            try maintenance.freeze()
            let result = await coordinator.resolveAndCloseAllForMaintenance()
            XCTAssertEqual(result, choice == .cancel ? .cancelled : .approved)
            XCTAssertEqual(prompts, 1)
            XCTAssertEqual(saves, choice == .save ? 1 : 0)
            XCTAssertEqual(terminations, 0)
            if choice == .cancel {
                XCTAssertEqual(coordinator.openIDs.count, 2)
                XCTAssertTrue(documents.allSatisfy { !$0.closed && !$0.interactionLocked })
                try maintenance.cancelFreeze()
                job.finish()
                XCTAssertEqual(maintenance.state, .normal)
                XCTAssertEqual(maintenance.activeOperationCount, 1)
                try await coordinator.open(wallpaperID: project.handle.id)
                runtime?.finish()
            } else {
                XCTAssertTrue(documents.allSatisfy(\.closed))
                XCTAssertTrue(coordinator.openIDs.isEmpty)
                await maintenance.drain()
                XCTAssertEqual(maintenance.activeOperationCount, 0)
                let saveAfterClose = await documents[1].save()
                XCTAssertFalse(saveAfterClose)
            }
            coordinator.shutdown()
            job.finish()
        }
    }
    func testLastCancellationAfterSaveRetainsEditorsAndExplicitSave() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        let maintenance = MaintenanceCoordinator()
        var document: WSSEditorDocument!
        var saves = 0
        var closed = false
        let coordinator = WSSEditorCoordinator(
            maintenance: maintenance, lookup: { _ in project.handle.wallpaper },
            save: { snapshot in
                saves += 1
                return WSSSaveReceipt(
                    snapshot: snapshot, diskBasis: snapshot.diskBasis,
                    outcome: .committed(warnings: []))
            }, load: { _ in project },
            makeWindow: { doc, _ in
                document = doc
                return MaintenanceEditorWindow { closed = true }
            })
        try await coordinator.open(wallpaperID: project.handle.id)
        try document.setParameter(
            .rippleAmplitude, at: .init(layerIndex: 0, effectIndex: 0), value: 20)
        document.chooseClose = { .save }
        let job = try maintenance.reserve(.restore)
        try maintenance.freeze()
        let result = await coordinator.resolveAndCloseAllForMaintenance {
            XCTAssertEqual(saves, 1)
            XCTAssertEqual(maintenance.activeOperationCount, 0)
            XCTAssertFalse(document.closed)
            return false
        }
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(closed)
        XCTAssertFalse(document.closed)
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(document.interactionLocked)
        try maintenance.cancelFreeze()
        job.finish()
        XCTAssertEqual(maintenance.state, .normal)
        coordinator.shutdown()
    }
    func testPendingOpenAndCreateCancellationWaitsForActualEnd() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        for createPending in [false, true] {
            let maintenance = MaintenanceCoordinator()
            var continuation: CheckedContinuation<Void, Never>?
            var created = false
            let coordinator = WSSEditorCoordinator(
                maintenance: maintenance, lookup: { _ in project.handle.wallpaper },
                publishDraft: { _ in throw WSSSaveAsError.library },
                load: { _ in
                    await withCheckedContinuation { continuation = $0 }
                    XCTAssertTrue(Task.isCancelled)
                    return project
                },
                makeWindow: { _, close in
                    created = true
                    return MaintenanceEditorWindow(close)
                })
            coordinator.chooseNewImage = {
                await withCheckedContinuation { continuation = $0 }
                XCTAssertTrue(Task.isCancelled)
                return nil
            }
            let open = Task {
                if createPending {
                    await coordinator.newWallpaper()
                } else {
                    try? await coordinator.open(wallpaperID: project.handle.id)
                }
            }
            while continuation == nil { await Task.yield() }
            let job = try maintenance.reserve(.restore)
            try maintenance.freeze()
            var finished = false
            let close = Task {
                try? await coordinator.cancelPendingForMaintenance()
                await maintenance.drainMutations()
                let result = await coordinator.resolveAndCloseAllForMaintenance()
                XCTAssertEqual(result, .approved)
                finished = true
            }
            while !coordinator.quitting { await Task.yield() }
            XCTAssertFalse(finished)
            XCTAssertGreaterThan(maintenance.activeOperationCount, 0)
            continuation?.resume()
            await close.value
            await open.value
            await maintenance.drain()
            XCTAssertFalse(created)
            XCTAssertTrue(coordinator.openIDs.isEmpty)
            XCTAssertEqual(maintenance.activeOperationCount, 0)
            job.finish()
        }
    }
    func testMaintenanceWaitsForRunningSaveAndResourceOperationBeforeCloseCompletes() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        let maintenance = MaintenanceCoordinator()
        var document: WSSEditorDocument!
        var saveContinuation: CheckedContinuation<Void, Never>?
        let coordinator = WSSEditorCoordinator(
            maintenance: maintenance, lookup: { _ in project.handle.wallpaper },
            save: { snapshot in
                await withCheckedContinuation { saveContinuation = $0 }
                return WSSSaveReceipt(
                    snapshot: snapshot, diskBasis: snapshot.diskBasis,
                    outcome: .committed(warnings: []))
            }, load: { _ in project },
            makeWindow: { doc, close in
                document = doc
                return MaintenanceEditorWindow(close)
            })
        try await coordinator.open(wallpaperID: project.handle.id)
        try document.setParameter(
            .rippleAmplitude, at: .init(layerIndex: 0, effectIndex: 0), value: 20)
        let save = Task { await document.save() }
        while saveContinuation == nil { await Task.yield() }
        document.beginResourceOperation()
        let job = try maintenance.reserve(.restore)
        try maintenance.freeze()
        var complete = false
        let closing = Task {
            let result = await coordinator.resolveAndCloseAllForMaintenance()
            XCTAssertEqual(result, .approved)
            complete = true
        }
        while !coordinator.quitting { await Task.yield() }
        XCTAssertFalse(complete)
        saveContinuation?.resume()
        let saved = await save.value
        XCTAssertTrue(saved)
        while !document.closed { await Task.yield() }
        XCTAssertFalse(complete)
        document.endResourceOperation()
        await closing.value
        await maintenance.drain()
        XCTAssertTrue(complete)
        XCTAssertEqual(maintenance.activeOperationCount, 0)
        job.finish()
    }
}
