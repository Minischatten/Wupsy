import AppKit
import XCTest

@testable import Wupsy

@MainActor private final class LifecycleWindow: WSSEditorWindow {
    let callback: () -> Void
    init(_ callback: @escaping () -> Void) { self.callback = callback }
    func focus() {}
    func close() { callback() }
}

@MainActor final class WSSEditorLifecycleTests: XCTestCase {
    let address = WSSEffectAddress(layerIndex: 0, effectIndex: 0)
    func testCloseCleanSaveDiscardCancelAndFailure() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        for choice in [WSSEditorDocument.CloseChoice.save, .discard, .cancel] {
            for fails in [false, true] {
                let doc = WSSEditorEditingTests().editor(
                    project,
                    save: {
                        if fails { throw WSSSaveError.externalConflict }
                        return WSSSaveReceipt(
                            snapshot: $0, diskBasis: $0.diskBasis, outcome: .committed(warnings: [])
                        )
                    })
                let clean = await doc.resolveChanges()
                XCTAssertTrue(clean)
                try doc.setParameter(.rippleAmplitude, at: address, value: 20)
                doc.chooseClose = { choice }
                let accepted = await doc.resolveChanges()
                XCTAssertEqual(accepted, choice == .discard || (choice == .save && !fails))
                XCTAssertFalse(doc.closed)
                XCTAssertFalse(doc.interactionLocked)
                if choice == .discard { XCTAssertTrue(doc.isDirty) }
                doc.close()
            }
        }
    }
    func testCloseWaitsForSaveNAndPromptsForNewerStateWithoutSecondConcurrentSave() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        var continuation: CheckedContinuation<WSSSaveReceipt, Error>?
        var snapshot: WSSSaveSnapshot?
        var calls = 0
        let doc = WSSEditorEditingTests().editor(
            project,
            save: { value in
                calls += 1
                if calls > 1 {
                    return WSSSaveReceipt(
                        snapshot: value, diskBasis: value.diskBasis,
                        outcome: .committed(warnings: []))
                }
                snapshot = value
                return try await withCheckedThrowingContinuation { continuation = $0 }
            })
        defer { doc.close() }
        try doc.setParameter(.rippleAmplitude, at: address, value: 10)
        let saving = Task { await doc.save() }
        while continuation == nil { await Task.yield() }
        try doc.setParameter(.rippleAmplitude, at: address, value: 20)
        var prompts = 0
        doc.chooseClose = {
            prompts += 1
            return .save
        }
        let closing = Task { await doc.resolveChanges() }
        while !doc.interactionLocked { await Task.yield() }
        try doc.setParameter(.rippleAmplitude, at: address, value: 30)
        XCTAssertEqual(
            WSSEditorParameter.rippleAmplitude.value(in: doc.state.workingModel, at: address), 20)
        let n = try XCTUnwrap(snapshot)
        continuation?.resume(
            returning: WSSSaveReceipt(
                snapshot: n, diskBasis: n.diskBasis, outcome: .committed(warnings: [])))
        _ = await saving.value
        let approved = await closing.value
        XCTAssertTrue(approved)
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(doc.isDirty)
    }
    func testWindowDirtyIndicatorUndoManagerAndCloseRouting() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        let doc = WSSEditorEditingTests().editor(project)
        var closed = false
        let controller = WSSEditorWindowController(
            document: doc,
            onClose: {
                closed = true
                doc.close()
            })
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(controller.windowWillReturnUndoManager(window) === doc.undoManager)
        XCTAssertFalse(window.title.contains("Read Only"))
        try doc.setParameter(.rippleAmplitude, at: address, value: 20)
        XCTAssertTrue(window.isDocumentEdited)
        let native = try XCTUnwrap(window as? WSSEditorNativeWindow)
        native.undo(nil)
        XCTAssertFalse(doc.isDirty)
        native.redo(nil)
        XCTAssertTrue(doc.isDirty)
        doc.interactionLocked = true
        native.undo(nil)
        XCTAssertTrue(doc.isDirty)
        doc.interactionLocked = false
        doc.chooseClose = { .cancel }
        XCTAssertFalse(controller.windowShouldClose(window))
        while doc.interactionLocked { await Task.yield() }
        // Let the scheduled close decision finish; no real UI sheet is used.
        _ = await doc.resolveChanges()
        XCTAssertFalse(closed)
        doc.chooseClose = { .discard }
        let approved = await doc.resolveChanges()
        XCTAssertTrue(approved)
        doc.close()
        controller.close()
    }
    func testQuitMultipleDocumentsCancelFailureAndMixedDecisionsPreserveSessions() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        for failure in [false, true] {
            var second = project.handle.wallpaper
            second.id = UUID()
            var documents: [WSSEditorDocument] = []
            var decision = 0
            let coordinator = WSSEditorCoordinator(
                lookup: { id in id == second.id ? second : project.handle.wallpaper },
                save: { snapshot in
                    if failure { throw WSSSaveError.writeFailed("injected") }
                    return WSSSaveReceipt(
                        snapshot: snapshot, diskBasis: snapshot.diskBasis,
                        outcome: .committed(warnings: []))
                }, load: { _ in project },
                makeWindow: { doc, close in
                    documents.append(doc)
                    return LifecycleWindow(close)
                })
            try await coordinator.open(wallpaperID: project.handle.id)
            try await coordinator.open(wallpaperID: second.id)
            for doc in documents {
                try doc.setParameter(.rippleAmplitude, at: address, value: 20)
                doc.chooseClose = {
                    decision += 1
                    return failure ? .save : (decision == 1 ? .discard : .cancel)
                }
            }
            let approved = await coordinator.approveTermination()
            XCTAssertFalse(approved)
            XCTAssertEqual(coordinator.openIDs.count, 2)
            XCTAssertTrue(
                documents.allSatisfy { !$0.closed && !$0.interactionLocked && $0.isDirty })
            for doc in documents { doc.chooseClose = { .discard } }
            let discarded = await coordinator.approveTermination()
            XCTAssertTrue(discarded)
            XCTAssertEqual(coordinator.openIDs.count, 2)
            coordinator.shutdown()
        }
    }
    func testQuitSavesOneDocumentThenCancelRetainsAllSessionsAndCompletedSave() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        var second = project.handle.wallpaper
        second.id = UUID()
        var documents: [WSSEditorDocument] = []
        var choices = 0
        var saves = 0
        var desktopStops = 0
        let coordinator = WSSEditorCoordinator(
            lookup: { id in id == second.id ? second : project.handle.wallpaper },
            save: { snapshot in
                saves += 1
                return WSSSaveReceipt(
                    snapshot: snapshot, diskBasis: snapshot.diskBasis,
                    outcome: .committed(warnings: []))
            }, onTermination: { desktopStops += 1 }, load: { _ in project },
            makeWindow: { doc, close in
                documents.append(doc)
                return LifecycleWindow(close)
            })
        try await coordinator.open(wallpaperID: project.handle.id)
        try await coordinator.open(wallpaperID: second.id)
        for doc in documents {
            try doc.setParameter(.rippleAmplitude, at: address, value: 20)
            doc.chooseClose = {
                choices += 1
                return choices == 1 ? .save : .cancel
            }
        }
        let cancelled = await coordinator.approveTermination()
        XCTAssertFalse(cancelled)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(documents.filter { !$0.isDirty }.count, 1)
        XCTAssertTrue(documents.allSatisfy { !$0.closed })
        for doc in documents { doc.chooseClose = { .save } }
        let accepted = await coordinator.approveTermination()
        XCTAssertTrue(accepted)
        XCTAssertTrue(documents.allSatisfy { !$0.isDirty })
        XCTAssertEqual(saves, 2)
        XCTAssertEqual(desktopStops, 0)
        coordinator.shutdown()
        XCTAssertEqual(desktopStops, 1)
    }
    func testQuitDuringCloseDoesNotUnlockOrDiscardPendingDocument() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        var document: WSSEditorDocument?
        let coordinator = WSSEditorCoordinator(
            lookup: { _ in project.handle.wallpaper }, load: { _ in project },
            makeWindow: { doc, close in
                document = doc
                return LifecycleWindow(close)
            })
        try await coordinator.open(wallpaperID: project.handle.id)
        let doc = try XCTUnwrap(document)
        try doc.setParameter(.rippleAmplitude, at: address, value: 20)
        var choice: CheckedContinuation<WSSEditorDocument.CloseChoice, Never>?
        doc.chooseClose = { await withCheckedContinuation { choice = $0 } }
        let close = Task { await doc.resolveChanges() }
        while choice == nil { await Task.yield() }
        let quit = await coordinator.approveTermination()
        XCTAssertFalse(quit)
        XCTAssertTrue(doc.interactionLocked)
        XCTAssertEqual(coordinator.openIDs.count, 1)
        choice?.resume(returning: .cancel)
        let closed = await close.value
        XCTAssertFalse(closed)
        XCTAssertFalse(doc.interactionLocked)
        coordinator.shutdown()
    }
    func testQuitLocksAllDocumentsAndBlocksOpeningUntilDecision() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        var document: WSSEditorDocument?
        var saving: CheckedContinuation<WSSSaveReceipt, Error>?
        var snapshot: WSSSaveSnapshot?
        let coordinator = WSSEditorCoordinator(
            lookup: { _ in project.handle.wallpaper },
            save: { value in
                snapshot = value
                return try await withCheckedThrowingContinuation { saving = $0 }
            }, load: { _ in project },
            makeWindow: { doc, close in
                document = doc
                return LifecycleWindow(close)
            })
        try await coordinator.open(wallpaperID: project.handle.id)
        let doc = try XCTUnwrap(document)
        try doc.setParameter(.rippleAmplitude, at: address, value: 20)
        let saveTask = Task { await doc.save() }
        while saving == nil { await Task.yield() }
        try doc.setParameter(.rippleAmplitude, at: address, value: 21)
        var continuation: CheckedContinuation<WSSEditorDocument.CloseChoice, Never>?
        doc.chooseClose = { await withCheckedContinuation { continuation = $0 } }
        let quit = Task { await coordinator.approveTermination() }
        while !doc.interactionLocked { await Task.yield() }
        XCTAssertNil(continuation)
        let n = try XCTUnwrap(snapshot)
        saving?.resume(
            returning: WSSSaveReceipt(
                snapshot: n, diskBasis: n.diskBasis, outcome: .committed(warnings: [])))
        _ = await saveTask.value
        while continuation == nil { await Task.yield() }
        XCTAssertTrue(doc.interactionLocked)
        do {
            try await coordinator.open(wallpaperID: project.handle.id)
            XCTFail("opened during quit")
        } catch {}
        try doc.setParameter(.rippleAmplitude, at: address, value: 30)
        XCTAssertEqual(
            WSSEditorParameter.rippleAmplitude.value(in: doc.state.workingModel, at: address), 21)
        continuation?.resume(returning: .cancel)
        let approved = await quit.value
        XCTAssertFalse(approved)
        XCTAssertFalse(doc.interactionLocked)
        coordinator.shutdown()
    }
}
