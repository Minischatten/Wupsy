import AppKit
import XCTest

@testable import Wupsy

@MainActor private final class CopyWindow: WSSEditorWindow {
    var document: WSSEditorDocument
    var callback: () -> Void
    var fail = false
    init(_ document: WSSEditorDocument, _ callback: @escaping () -> Void) {
        self.document = document
        self.callback = callback
    }
    func focus() {}
    func close() { if !document.saveAsBusy && !document.interactionLocked { callback() } }
    func replaceDocument(_ document: WSSEditorDocument, onClose: @escaping () -> Void) throws {
        if fail { throw WSSSaveAsError.invalid }
        self.document = document
        callback = onClose
    }
}

@MainActor final class WSSSaveAsCoordinatorTests: XCTestCase {
    var helper: WSSEditorWorkspaceTests!
    var store: ManagedWallpaperStore!
    var coordinator: WSSEditorCoordinator!
    private var windows: [CopyWindow] = []
    var storage: URL!
    var calls = 0
    var policies: [NSApplication.ActivationPolicy] = []
    override func setUp() async throws {
        helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
        storage = helper.helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([helper.item!]).write(to: storage)
        store = ManagedWallpaperStore(storage: storage)
    }
    override func tearDown() async throws {
        coordinator?.shutdown()
        coordinator = nil
        windows = []
        store = nil
        try await helper.tearDown()
        helper = nil
    }
    func open(
        service: WSSEditorCoordinator.SaveAs? = nil, maintenance: MaintenanceCoordinator? = nil
    ) async throws -> WSSEditorDocument {
        let localStore = store!
        coordinator = WSSEditorCoordinator(
            maintenance: maintenance,
            lookup: { id in try localStore.load().first { $0.id == id }.unwrap() },
            save: { snapshot in
                let item = try localStore.load().first {
                    $0.id == snapshot.diskBasis.identity.wallpaperID
                }.unwrap()
                let candidate = try await WSSManifestSaveValidator().prepare(
                    snapshot, handle: WSSExistingProjectResolver.resolve(item))
                return try await localStore.commitWSSManifest(candidate)
            },
            saveAs: service ?? { snapshot in
                self.calls += 1
                return try await localStore.saveWSSAs(snapshot)
            },
            makeWindow: { document, callback in
                let window = CopyWindow(document, callback)
                self.windows.append(window)
                return window
            },
            presentation: WSSEditorAppPresentation { policy in
                self.policies.append(policy)
                return true
            })
        try await coordinator.open(wallpaperID: helper.item.id)
        let document = windows[0].document
        document.chooseSaveAsName = { _ in "Copy" }
        document.presentMessage = { _, _ in }
        return document
    }
    func testMaintenanceWaitsForWholeSaveAsIncludingNamingAndTakeover() async throws {
        let maintenance = MaintenanceCoordinator()
        let doc = try await open(maintenance: maintenance)
        var naming: CheckedContinuation<String?, Never>?
        doc.chooseSaveAsName = { _ in await withCheckedContinuation { naming = $0 } }
        let copying = Task { await doc.requestSaveAs?() }
        while naming == nil { await Task.yield() }
        let job = try maintenance.reserve(.restore)
        defer { job.finish() }
        try maintenance.freeze()
        var complete = false
        let closing = Task {
            let result = await self.coordinator.resolveAndCloseAllForMaintenance()
            XCTAssertEqual(result, .approved)
            complete = true
        }
        while !coordinator.quitting { await Task.yield() }
        XCTAssertFalse(complete)
        naming?.resume(returning: nil)
        _ = await copying.value
        await closing.value
        await maintenance.drain()
        XCTAssertTrue(complete)
        XCTAssertTrue(coordinator.openIDs.isEmpty)
        XCTAssertEqual(maintenance.activeOperationCount, 0)
        XCTAssertEqual(try store.load().count, 1)
    }
    func testMaintenanceWaitsForSaveAsCommitContinuation() async throws {
        let maintenance = MaintenanceCoordinator()
        let localStore = store!
        var commit: CheckedContinuation<Void, Never>?
        let doc = try await open(
            service: { snapshot in
                await withCheckedContinuation { commit = $0 }
                return try await localStore.saveWSSAs(snapshot)
            }, maintenance: maintenance)
        let copying = Task { await doc.requestSaveAs?() }
        while commit == nil { await Task.yield() }
        let job = try maintenance.reserve(.restore)
        defer { job.finish() }
        try maintenance.freeze()
        var complete = false
        let closing = Task {
            let result = await self.coordinator.resolveAndCloseAllForMaintenance()
            XCTAssertEqual(result, .approved)
            complete = true
        }
        while !coordinator.quitting { await Task.yield() }
        XCTAssertFalse(complete)
        commit?.resume()
        _ = await copying.value
        await closing.value
        await maintenance.drain()
        XCTAssertTrue(doc.closed)
        XCTAssertEqual(try store.load().count, 2)
        XCTAssertEqual(maintenance.activeOperationCount, 0)
    }
    func testSaveAsPublishesCustomNormalizedCopyName() async throws {
        let doc = try await open()
        doc.chooseSaveAsName = { proposed in
            XCTAssertEqual(proposed, self.helper.item.title + " Copy")
            return "  Custom Copy  "
        }
        let copied = await doc.requestSaveAs?()
        XCTAssertEqual(copied, true)
        let copy = try XCTUnwrap(windows.first?.document)
        XCTAssertEqual(copy.project.document.title, "Custom Copy")
        XCTAssertEqual(
            try store.load().first { $0.id == copy.project.handle.id }?.title, "Custom Copy")
        XCTAssertNotEqual(copy.project.handle.id, doc.project.handle.id)
        XCTAssertEqual(calls, 1)
    }
    func testSaveAsToolbarUsesExistingCommandAndEnablement() async throws {
        _ = NSApplication.shared
        let doc = try await open()
        let controller = WSSEditorWindowController(document: doc, onClose: {})
        defer { controller.window?.close() }
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        let id = NSToolbarItem.Identifier("wss.saveAs")
        XCTAssertTrue(controller.toolbarDefaultItemIdentifiers(toolbar).contains(id))
        let item = try XCTUnwrap(
            controller.toolbar(
                toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: true))
        XCTAssertEqual(item.label, EditorText.saveAs.text)
        XCTAssertEqual(item.toolTip, EditorText.saveAsHelp.text)
        XCTAssertTrue(controller.validateToolbarItem(item))
        XCTAssertTrue(WSSEditorCoordinator.document(in: controller.window) === doc)
        XCTAssertNil(WSSEditorCoordinator.document(in: NSWindow()))
        var requested = 0
        doc.chooseSaveAsName = { _ in
            requested += 1
            return nil
        }
        _ = controller.perform(try XCTUnwrap(item.action), with: item)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(requested, 1)
        XCTAssertEqual(calls, 0)
        doc.saveAsBusy = true
        XCTAssertFalse(controller.validateToolbarItem(item))
        _ = controller.perform(try XCTUnwrap(item.action), with: item)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(requested, 1)
        doc.saveAsBusy = false
        doc.interactionLocked = true
        XCTAssertFalse(controller.validateToolbarItem(item))
        doc.interactionLocked = false
        doc.requestSaveAs = nil
        XCTAssertFalse(controller.validateToolbarItem(item))
    }
    func testCancelAndDefaultNameDoNotMutateAnything() async throws {
        let doc = try await open()
        let before = try helper.helper.snapshot()
        doc.chooseSaveAsName = { name in
            XCTAssertEqual(name, self.helper.item.title + " Copy")
            return nil
        }
        let success = await doc.requestSaveAs?()
        XCTAssertEqual(success, false)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try helper.helper.snapshot(), before)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertFalse(doc.saveAsBusy)
        XCTAssertFalse(doc.interactionLocked)
    }
    func testDefaultNameUsesCurrentLibraryRenameMetadata() async throws {
        let doc = try await open()
        _ = try await store.rename(wallpaperID: helper.item.id, newTitle: "Renamed")
        doc.chooseSaveAsName = { name in
            XCTAssertEqual(name, "Renamed Copy")
            return nil
        }
        let success = await doc.requestSaveAs?()
        XCTAssertEqual(success, false)
        XCTAssertEqual(calls, 0)
    }
    func testSaveAsCleanNewDocumentEmptyHistoryAndStaleCloseCallbackCannotCloseB() async throws {
        let a = try await open()
        let callbackA = windows[0].callback
        let sessionA = a.state.sessionID
        let success = await a.requestSaveAs?()
        XCTAssertEqual(success, true)
        let b = windows[0].document
        XCTAssertTrue(a.closed)
        XCTAssertFalse(b === a)
        XCTAssertNotEqual(b.state.sessionID, sessionA)
        XCTAssertFalse(b.isDirty)
        XCTAssertFalse(b.undoManager.canUndo)
        XCTAssertFalse(b.undoManager.canRedo)
        XCTAssertEqual(coordinator.openIDs, [b.project.handle.id])
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(policies, [.regular])
        callbackA()
        XCTAssertEqual(coordinator.openIDs, [b.project.handle.id])
        windows[0].close()
        XCTAssertTrue(b.closed)
        XCTAssertTrue(coordinator.openIDs.isEmpty)
        XCTAssertEqual(policies, [.regular, .accessory])
    }
    func testUnexpectedUnderlyingErrorsDoNotExposePrivatePaths() async throws {
        let a = try await open(service: { _ in
            throw ImportFailure.message("/private/user/secret/library.json")
        })
        var messages: [String] = []
        a.presentMessage = { title, text in messages.append(title + text) }
        let success = await a.requestSaveAs?()
        XCTAssertEqual(success, false)
        XCTAssertFalse(messages.isEmpty)
        XCTAssertFalse(messages.joined().contains("/private"))
        XCTAssertFalse(a.interactionLocked)
        XCTAssertFalse(a.closed)
    }
    func testPrecommitFailurePreservesWorkingHistoryAndUnlocks() async throws {
        let a = try await open(service: { _ in throw WSSSaveAsError.storage })
        try a.setImage(.opacity, value: 0.4, layer: a.identity.layers[0].id)
        let model = a.state.workingModel
        let success = await a.requestSaveAs?()
        XCTAssertEqual(success, false)
        XCTAssertFalse(a.closed)
        XCTAssertEqual(a.state.workingModel, model)
        XCTAssertTrue(a.isDirty)
        XCTAssertTrue(a.undoManager.canUndo)
        XCTAssertFalse(a.interactionLocked)
        XCTAssertFalse(a.saveAsBusy)
        XCTAssertEqual(coordinator.openIDs, [helper.item.id])
    }
    func testEditingUndoSaveCloseQuitAndSecondSaveAsBlockedDuringOperation() async throws {
        var gate: CheckedContinuation<Void, Never>?
        let localStore = store!
        let a = try await open(service: { snapshot in
            await withCheckedContinuation { gate = $0 }
            return try await localStore.saveWSSAs(snapshot)
        })
        try a.setImage(.opacity, value: 0.5, layer: a.identity.layers[0].id)
        let before = a.state.workingModel
        let task = Task { await a.requestSaveAs?() }
        while gate == nil { await Task.yield() }
        XCTAssertTrue(a.interactionLocked)
        XCTAssertTrue(a.saveAsBusy)
        try a.setImage(.centerX, value: 5, layer: a.identity.layers[0].id)
        a.undoManager.undo()
        XCTAssertFalse(a.beginCanvasTransform(a.identity.layers[0].id, kind: .move))
        let generation = try await WSSImageImporter().normalize(
            WSSImageImportTests().image(), extension: "png")
        do {
            try await a.installImage(generation)
            XCTFail("import allowed")
        } catch {}
        let save = await a.save()
        let second = await a.requestSaveAs?()
        let quit = await coordinator.approveTermination()
        XCTAssertFalse(save)
        XCTAssertEqual(second, false)
        XCTAssertFalse(quit)
        coordinator.close(wallpaperID: a.project.handle.id)
        XCTAssertFalse(a.closed)
        XCTAssertEqual(a.state.workingModel, before)
        gate?.resume()
        let result1 = await task.value
        XCTAssertEqual(result1, true)
    }
    func testPostcommitTakeoverFailureRetrySwitchesExistingCopyWithoutDuplicating() async throws {
        let a = try await open()
        try a.setImage(.opacity, value: 0.5, layer: a.identity.layers[0].id)
        let before = a.state.workingModel
        windows[0].fail = true
        let result2 = await a.requestSaveAs?()
        XCTAssertEqual(result2, false)
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(a.committedCopy)
        XCTAssertFalse(a.closed)
        XCTAssertEqual(a.state.workingModel, before)
        XCTAssertTrue(a.undoManager.canUndo)
        XCTAssertEqual(try store.load().count, 2)
        windows[0].fail = false
        let result3 = await a.requestSaveAs?()
        XCTAssertEqual(result3, true)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try store.load().count, 2)
    }
    func testRetryAfterNewEditsDoesNotDiscardThemOrCreateAnotherCopy() async throws {
        let a = try await open()
        windows[0].fail = true
        let result4 = await a.requestSaveAs?()
        XCTAssertEqual(result4, false)
        try a.setImage(.centerX, value: 17, layer: a.identity.layers[0].id)
        let before = a.state.workingModel
        windows[0].fail = false
        let result5 = await a.requestSaveAs?()
        XCTAssertEqual(result5, false)
        XCTAssertEqual(a.state.workingModel, before)
        XCTAssertFalse(a.closed)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try store.load().count, 2)
    }
    func testDestinationReservedWhilePostcommitFollowUpIsPending() async throws {
        let localStore = store!
        var gate: CheckedContinuation<Void, Never>?
        var destination: UUID?
        let a = try await open(service: { snapshot in
            let receipt = try await localStore.saveWSSAs(snapshot)
            destination = receipt.project.handle.id
            await withCheckedContinuation { gate = $0 }
            return receipt
        })
        let task = Task { await a.requestSaveAs?() }
        while gate == nil { await Task.yield() }
        do {
            try await coordinator.open(wallpaperID: destination!)
            XCTFail("second editor opened")
        } catch {}
        XCTAssertEqual(windows.count, 1)
        gate?.resume()
        let result6 = await task.value
        XCTAssertEqual(result6, true)
        XCTAssertEqual(windows.count, 1)
    }
    func testRemovedCommittedDestinationCannotBecomeEditorTarget() async throws {
        let localStore = store!
        let localStorage = storage!
        let originalItem = helper.item!
        let a = try await open(service: { snapshot in
            let receipt = try await localStore.saveWSSAs(snapshot)
            // Simulate a concurrent removal after commit, before editor adoption.
            try JSONEncoder().encode([originalItem]).write(to: localStorage)
            return receipt
        })
        let success = await a.requestSaveAs?()
        XCTAssertEqual(success, false)
        XCTAssertFalse(a.closed)
        XCTAssertEqual(coordinator.openIDs, [originalItem.id])
        XCTAssertNotNil(a.committedCopy)
        XCTAssertEqual(try localStore.load().count, 1)
    }
    func testStaleCompletionAfterShutdownCannotInstallNewWindowSession() async throws {
        let localStore = store!
        var gate: CheckedContinuation<Void, Never>?
        let a = try await open(service: { snapshot in
            await withCheckedContinuation { gate = $0 }
            return try await localStore.saveWSSAs(snapshot)
        })
        let task = Task { await a.requestSaveAs?() }
        while gate == nil { await Task.yield() }
        coordinator.shutdown()
        gate?.resume()
        let result7 = await task.value
        XCTAssertEqual(result7, false)
        XCTAssertTrue(coordinator.openIDs.isEmpty)
        XCTAssertTrue(a.closed)
        XCTAssertEqual(try store.load().count, 2)  // committed copy is retained
    }
    func testActualNSWindowTakeoverAndFollowingSaveRouteOnlyToB() async throws {
        _ = NSApplication.shared
        let localStore = store!
        var controller: WSSEditorWindowController!
        coordinator = WSSEditorCoordinator(
            lookup: { id in try localStore.load().first { $0.id == id }.unwrap() },
            save: { snapshot in
                let item = try localStore.load().first {
                    $0.id == snapshot.diskBasis.identity.wallpaperID
                }.unwrap()
                let candidate = try await WSSManifestSaveValidator().prepare(
                    snapshot, handle: WSSExistingProjectResolver.resolve(item))
                return try await localStore.commitWSSManifest(candidate)
            }, saveAs: { try await localStore.saveWSSAs($0) },
            makeWindow: { document, callback in
                document.initialCanvasZoom = 2
                document.playing = false
                document.initialPreviewTime = 12.5
                controller = WSSEditorWindowController(document: document, onClose: callback)
                return controller
            })
        try await coordinator.open(wallpaperID: helper.item.id)
        let a = controller.editorDocument
        a.chooseSaveAsName = { _ in "Native Copy" }
        a.presentMessage = { _, _ in }
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 80_000_000)
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            return view.subviews.lazy.compactMap { find(type, in: $0) }.first
        }
        let oldPreview = try XCTUnwrap(find(WSSPreviewHost.self, in: window.contentView!))
        oldPreview.expand()
        XCTAssertNotNil(oldPreview.expandedWindow)
        let original = try Data(contentsOf: a.project.handle.entry)
        try a.setImage(.centerX, value: 21, layer: a.identity.layers[0].id)
        let model = a.state.workingModel
        let result8 = await a.requestSaveAs?()
        XCTAssertEqual(result8, true)
        let b = controller.editorDocument
        // Save As completes with B's inherited presentation already restored;
        // no later event-loop turn or focus call may be required for takeover.
        let takenOverPreview = try XCTUnwrap(find(WSSPreviewHost.self, in: window.contentView!))
        XCTAssertNotNil(takenOverPreview.expandedWindow)
        XCTAssertTrue(WSSEditorCoordinator.document(in: takenOverPreview.expandedWindow) === b)
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue((window as? WSSEditorNativeWindow)?.editorDocument === b)
        XCTAssertEqual(window.title, EditorText.windowTitle.format("Native Copy"))
        XCTAssertFalse(window.isDocumentEdited)
        XCTAssertEqual(b.state.workingModel.layers, model.layers)
        XCTAssertFalse(b.playing)
        XCTAssertEqual(b.initialCanvasZoom, 2)
        XCTAssertFalse(b.undoManager.canUndo)
        controller.focus()
        try await Task.sleep(nanoseconds: 50_000_000)
        // XCTest has no app event loop/key-window ownership. Exercise the same
        // production command resolver with the actual editor and preview windows.
        XCTAssertTrue(WSSEditorCoordinator.document(in: window) === b)
        let newPreview = try XCTUnwrap(find(WSSPreviewHost.self, in: window.contentView!))
        XCTAssertNil(oldPreview.surface.player)
        XCTAssertNotNil(newPreview.expandedWindow)
        XCTAssertTrue(WSSEditorCoordinator.document(in: newPreview.expandedWindow) === b)
        XCTAssertEqual(try XCTUnwrap(newPreview.surface.player).elapsed, 12.5, accuracy: 0.01)
        XCTAssertTrue(try XCTUnwrap(newPreview.surface.player).view.isPaused)
        XCTAssertEqual(find(WSSCanvasScrollView.self, in: window.contentView!)?.presentationZoom, 2)
        try b.setImage(.centerX, value: 47, layer: b.identity.layers[0].id)
        let commandTarget = try XCTUnwrap(WSSEditorCoordinator.document(in: window))
        let saved = await commandTarget.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(try Data(contentsOf: a.project.handle.entry), original)
        let loaded = try await WSSEditorProjectLoader().load(b.project.handle.wallpaper)
        XCTAssertEqual(loaded.document.layers[0].imageTransform?.center[0], 47)
        b.chooseClose = { .discard }
        try b.setImage(.opacity, value: 0.5, layer: b.identity.layers[0].id)
        let terminated = await coordinator.approveTermination()
        XCTAssertTrue(terminated)
    }
}

extension Optional {
    fileprivate func unwrap() throws -> Wrapped {
        guard let value = self else { throw WSSEditorOpenError.unavailable }
        return value
    }
}
