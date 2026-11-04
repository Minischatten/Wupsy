import AppKit
import XCTest

@testable import Wupsy

@MainActor private final class PresentationWindow: WSSEditorWindow {
    let document: WSSEditorDocument
    let onClose: () -> Void
    var focuses = 0
    init(_ document: WSSEditorDocument, _ onClose: @escaping () -> Void) {
        self.document = document
        self.onClose = onClose
    }
    func focus() { focuses += 1 }
    func close() { onClose() }
}

@MainActor final class WSSEditorAppPresentationTests: XCTestCase {
    func testSessionsAndShutdownOwnPolicyNotFocusOrPreview() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        var second = project.handle.wallpaper
        second.id = UUID()
        let entries = [project.handle.id: project.handle.wallpaper, second.id: second]
        var policies: [NSApplication.ActivationPolicy] = []
        var windows: [PresentationWindow] = []
        let coordinator = WSSEditorCoordinator(
            lookup: { try XCTUnwrap(entries[$0]) },
            load: { item in
                WSSLoadedEditorProject(
                    handle: WSSProjectHandle(
                        wallpaper: item, root: project.handle.root, entry: project.handle.entry,
                        origin: .native), document: project.document, scene: project.scene,
                    assets: project.assets, resources: project.resources,
                    diskBasis: project.diskBasis)
            },
            makeWindow: { document, close in
                let window = PresentationWindow(document, close)
                windows.append(window)
                return window
            },
            presentation: WSSEditorAppPresentation {
                policies.append($0)
                return true
            })
        try await coordinator.open(wallpaperID: project.handle.id)
        XCTAssertEqual(policies, [.regular])
        try await coordinator.open(wallpaperID: project.handle.id)
        XCTAssertEqual(windows[0].focuses, 2)
        XCTAssertEqual(windows.count, 1)
        try await coordinator.open(wallpaperID: second.id)
        XCTAssertEqual(policies, [.regular])
        let controller = WSSEditorWindowController(document: windows[1].document, onClose: {})
        let host = WSSPreviewHost(document: windows[1].document)
        controller.window?.contentView = host
        host.expand()
        XCTAssertNotNil(host.expandedWindow)
        XCTAssertTrue(
            WSSEditorCoordinator.document(in: host.expandedWindow) === windows[1].document)
        XCTAssertEqual(coordinator.openIDs.count, 2)
        XCTAssertEqual(policies, [.regular])
        host.restore()
        XCTAssertEqual(policies, [.regular])
        host.shutdown()
        controller.window?.miniaturize(nil)
        XCTAssertEqual(coordinator.openIDs.count, 2)
        coordinator.close(wallpaperID: project.handle.id)
        XCTAssertEqual(policies, [.regular])
        coordinator.close(wallpaperID: second.id)
        XCTAssertEqual(policies, [.regular, .accessory])
        controller.window?.close()
        try await coordinator.open(wallpaperID: project.handle.id)
        XCTAssertEqual(policies, [.regular, .accessory, .regular])
        coordinator.shutdown()
        XCTAssertEqual(policies, [.regular, .accessory, .regular])
    }

    func testPendingAndFailedOpenNeverPromote() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        var continuation: CheckedContinuation<WSSLoadedEditorProject, Error>?
        var policies: [NSApplication.ActivationPolicy] = []
        let coordinator = WSSEditorCoordinator(
            lookup: { _ in project.handle.wallpaper },
            load: { _ in try await withCheckedThrowingContinuation { continuation = $0 } },
            makeWindow: { PresentationWindow($0, $1) },
            presentation: WSSEditorAppPresentation {
                policies.append($0)
                return true
            })
        let request = Task { try await coordinator.open(wallpaperID: project.handle.id) }
        while continuation == nil { await Task.yield() }
        XCTAssertTrue(coordinator.openIDs.isEmpty)
        XCTAssertTrue(policies.isEmpty)
        continuation?.resume(throwing: WSSEditorOpenError.unavailable)
        do {
            try await request.value
            XCTFail("Expected failed open")
        } catch {}
        XCTAssertTrue(policies.isEmpty)
        XCTAssertTrue(coordinator.openIDs.isEmpty)
        coordinator.shutdown()
    }

    func testCancelledCloseFailedSaveAndCancelledQuitKeepRegular() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        var policies: [NSApplication.ActivationPolicy] = []
        var controller: WSSEditorWindowController!
        let coordinator = WSSEditorCoordinator(
            lookup: { _ in project.handle.wallpaper },
            save: { _ in throw WSSSaveError.externalConflict }, load: { _ in project },
            makeWindow: { document, close in
                controller = WSSEditorWindowController(document: document, onClose: close)
                return controller
            },
            presentation: WSSEditorAppPresentation {
                policies.append($0)
                return true
            })
        defer { coordinator.shutdown() }
        try await coordinator.open(wallpaperID: project.handle.id)
        let doc = controller.editorDocument
        try doc.setParameter(.rippleAmplitude, at: .init(layerIndex: 0, effectIndex: 0), value: 20)
        doc.presentMessage = { _, _ in }
        var choice: CheckedContinuation<WSSEditorDocument.CloseChoice, Never>?
        doc.chooseClose = { await withCheckedContinuation { choice = $0 } }
        controller.close()
        while choice == nil { await Task.yield() }
        XCTAssertEqual(policies, [.regular])
        XCTAssertEqual(coordinator.openIDs.count, 1)
        choice?.resume(returning: .cancel)
        while doc.isResolvingClose { await Task.yield() }
        XCTAssertEqual(policies, [.regular])
        choice = nil
        controller.close()
        while choice == nil { await Task.yield() }
        choice?.resume(returning: .save)
        while doc.isResolvingClose { await Task.yield() }
        XCTAssertEqual(policies, [.regular])
        XCTAssertEqual(coordinator.openIDs.count, 1)
        doc.chooseClose = { .cancel }
        let approved = await coordinator.approveTermination()
        XCTAssertFalse(approved)
        XCTAssertEqual(policies, [.regular])
        XCTAssertFalse(doc.closed)
        doc.chooseClose = { .discard }
        controller.close()
        while !coordinator.openIDs.isEmpty { await Task.yield() }
        XCTAssertEqual(policies, [.regular, .accessory])
    }

    func testPolicyFailureIsRecordedWithoutRetryLoops() {
        var calls: [NSApplication.ActivationPolicy] = []
        let presentation = WSSEditorAppPresentation {
            calls.append($0)
            return false
        }
        presentation.synchronize(hasEditors: true)
        XCTAssertEqual(presentation.failedPolicy, .regular)
        presentation.synchronize(hasEditors: true)
        XCTAssertEqual(calls, [.regular])
        presentation.synchronize(hasEditors: false)
        XCTAssertEqual(calls, [.regular, .accessory])
        XCTAssertEqual(presentation.failedPolicy, .accessory)
    }

    func testCommandsRouteToTheirWindowAndRespectTextSelectionAndModalBounds() async throws {
        _ = NSApplication.shared
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        let a = WSSEditorEditingTests().editor(project)
        let b = WSSEditorEditingTests().editor(project)
        let ca = WSSEditorWindowController(document: a, onClose: {})
        let cb = WSSEditorWindowController(document: b, onClose: {})
        defer {
            a.close()
            b.close()
            ca.close()
            cb.close()
        }
        let wa = try XCTUnwrap(ca.window)
        let wb = try XCTUnwrap(cb.window)
        wa.contentView = NSView()
        wb.contentView = NSView()
        var zoomsA = 0
        var zoomsB = 0
        a.canvasZoomCommand = { _ in
            zoomsA += 1
            return true
        }
        b.canvasZoomCommand = { _ in
            zoomsB += 1
            return true
        }
        a.canvasZoomAvailable = { true }
        b.canvasZoomAvailable = { true }
        // XCTest is not a foreground app. Inject only the system key-window lookup,
        // retaining real AppKit windows, controllers, and responder validation.
        var frontmost: NSWindow? = wa
        let coordinator = WSSEditorCoordinator(
            lookup: { _ in project.handle.wallpaper }, keyWindow: { frontmost })
        XCTAssertTrue(coordinator.activeDocument === a)
        coordinator.activeCommands?.perform(.zoom(.zoomIn))
        XCTAssertEqual(zoomsA, 1)
        XCTAssertEqual(zoomsB, 0)
        frontmost = wb
        XCTAssertTrue(coordinator.activeDocument === b)
        coordinator.activeCommands?.perform(.zoom(.fit))
        XCTAssertEqual(zoomsA, 1)
        XCTAssertEqual(zoomsB, 1)
        let commands = try XCTUnwrap(WSSEditorCommands.inWindow(wb))
        XCTAssertTrue(commands.canPerform(.delete))
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        field.isFieldEditor = true
        wb.contentView?.addSubview(field)
        XCTAssertTrue(wb.makeFirstResponder(field))
        XCTAssertFalse(commands.canPerform(.delete))
        commands.perform(.delete)
        XCTAssertEqual(b.identity.layers.count, 2)
        field.string = "123"
        field.setSelectedRange(NSRange(location: 1, length: 1))
        commands.perform(.zoom(.zoomOut))
        XCTAssertEqual(field.string, "123")
        XCTAssertEqual(field.selectedRange(), NSRange(location: 1, length: 1))
        XCTAssertFalse(b.isDirty)
        XCTAssertFalse(b.undoManager.canUndo)
        wb.makeFirstResponder(nil)
        b.selection = nil
        XCTAssertFalse(commands.canPerform(.delete))
        b.selection = .layer(a.identity.layers[0].id)
        XCTAssertFalse(commands.canPerform(.delete))
        b.selection = .effect(b.identity.layers[0].id, b.identity.layers[0].effects[0])
        XCTAssertTrue(commands.canPerform(.delete))
        XCTAssertEqual(b.deleteSelectionTitle, EditorText.deleteEffect.text)
        b.selection = .layer(b.identity.layers[0].id)
        b.interactionLocked = true
        XCTAssertFalse(commands.canPerform(.delete))
        XCTAssertFalse(commands.canPerform(.zoom(.fit)))
        b.interactionLocked = false
        b.saveAsBusy = true
        XCTAssertFalse(commands.canPerform(.saveAs))
        XCTAssertFalse(commands.canPerform(.delete))
        b.saveAsBusy = false
        let sheet = NSWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        let sheetFinished = Task { @MainActor in await wb.beginSheet(sheet) }
        while wb.attachedSheet == nil { await Task.yield() }
        for action in [WSSEditorCommands.Action.save, .saveAs, .revert, .delete, .zoom(.fit)] {
            XCTAssertFalse(commands.canPerform(action))
            XCTAssertFalse(WSSEditorCommands.inWindow(sheet)?.canPerform(action) == true)
        }
        wb.endSheet(sheet)
        _ = await sheetFinished.value
        sheet.orderOut(nil)
        XCTAssertNil(wb.attachedSheet)
        // AppKit may restore the field editor after ending a sheet.
        XCTAssertTrue(wb.makeFirstResponder(nil))
        XCTAssertTrue(commands.canPerform(.delete))
        commands.perform(.delete)
        XCTAssertEqual(b.identity.layers.count, 1)
        XCTAssertFalse(commands.canPerform(.delete))
        XCTAssertEqual(a.identity.layers.count, 2)
        coordinator.shutdown()
    }
}

extension WSSEditorAppPresentationTests {
    func testSaveCapturesFrontmostDocumentAndToolbarSharesValidation() async throws {
        _ = NSApplication.shared
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        var saved: [String] = []
        let a = WSSEditorEditingTests().editor(
            project,
            save: {
                saved.append("A")
                return WSSSaveReceipt(
                    snapshot: $0, diskBasis: $0.diskBasis, outcome: .committed(warnings: []))
            })
        let b = WSSEditorEditingTests().editor(
            project,
            save: {
                saved.append("B")
                return WSSSaveReceipt(
                    snapshot: $0, diskBasis: $0.diskBasis, outcome: .committed(warnings: []))
            })
        let ca = WSSEditorWindowController(document: a, onClose: {})
        let cb = WSSEditorWindowController(document: b, onClose: {})
        defer {
            a.close()
            b.close()
            ca.close()
            cb.close()
        }
        let wa = try XCTUnwrap(ca.window)
        let wb = try XCTUnwrap(cb.window)
        wa.contentView = NSView()
        wb.contentView = NSView()
        try a.setParameter(.rippleAmplitude, at: .init(layerIndex: 0, effectIndex: 0), value: 20)
        try b.setParameter(.rippleAmplitude, at: .init(layerIndex: 0, effectIndex: 0), value: 21)
        var frontmost: NSWindow? = wb
        let coordinator = WSSEditorCoordinator(
            lookup: { _ in project.handle.wallpaper }, keyWindow: { frontmost })
        defer { coordinator.shutdown() }
        XCTAssertTrue(coordinator.activeDocument === b)
        let commands = try XCTUnwrap(coordinator.activeCommands)
        let saveItem = NSToolbarItem(itemIdentifier: .init("wss.save"))
        XCTAssertEqual(cb.validateToolbarItem(saveItem), commands.canPerform(.save))
        XCTAssertTrue(commands.canPerform(.save))
        commands.perform(.save)
        frontmost = wa
        for _ in 0..<1000 {
            if saved.count == 1 && !b.saving { break }
            await Task.yield()
        }
        XCTAssertEqual(saved, ["B"])
        XCTAssertFalse(b.isDirty)
        XCTAssertTrue(a.isDirty)
        for action in [WSSEditorCommands.Action.save, .saveAs, .revert] {
            let id: NSToolbarItem.Identifier
            switch action {
            case .save: id = .init("wss.save")
            case .saveAs: id = .init("wss.saveAs")
            default: id = .init("wss.revert")
            }
            let item = NSToolbarItem(itemIdentifier: id)
            a.interactionLocked = true
            let current = WSSEditorCommands(document: a, window: wa)
            XCTAssertFalse(current.canPerform(action))
            XCTAssertEqual(ca.validateToolbarItem(item), current.canPerform(action))
            a.interactionLocked = false
        }
        let native = try XCTUnwrap(wa as? WSSEditorNativeWindow)
        let undo = NSMenuItem(
            title: "Undo", action: #selector(WSSEditorNativeWindow.undo(_:)), keyEquivalent: "z")
        XCTAssertTrue(native.validateMenuItem(undo))
        native.undo(nil)
        XCTAssertFalse(a.isDirty)
        XCTAssertFalse(b.isDirty)
        native.redo(nil)
        XCTAssertTrue(a.isDirty)
        a.interactionLocked = true
        XCTAssertFalse(native.validateMenuItem(undo))
        native.undo(nil)
        XCTAssertTrue(a.isDirty)
        a.interactionLocked = false
    }
}

extension WSSEditorAppPresentationTests {
    func testActiveAccessoryWaitsForResignationBeforeEditorOnlyPresentation() async throws {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        let menu = NSMenu()
        for title in ["File", "Edit", "View"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            menu.addItem(item)
        }
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = previousMenu }
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        let notifications = NotificationCenter()
        var active = true
        var policies: [NSApplication.ActivationPolicy] = []
        var window: PresentationWindow!
        let presentation = WSSEditorAppPresentation(
            isActive: { active }, notifications: notifications,
            setPolicy: {
                policies.append($0)
                return true
            })
        let coordinator = WSSEditorCoordinator(
            lookup: { _ in project.handle.wallpaper }, load: { _ in project },
            makeWindow: { document, closed in
                window = PresentationWindow(document, closed)
                return window
            }, presentation: presentation)
        defer { coordinator.shutdown() }
        try await coordinator.open(wallpaperID: project.handle.id)
        XCTAssertEqual(policies, [.prohibited])
        XCTAssertEqual(window.focuses, 0)
        XCTAssertEqual(coordinator.openIDs, [project.handle.id])
        XCTAssertTrue(NSApp.mainMenu === menu)
        active = false
        notifications.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        // The observer must finish before the regular presentation starts.
        XCTAssertEqual(policies, [.prohibited])
        for _ in 0..<1000 {
            if window.focuses == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(policies, [.prohibited, .regular])
        XCTAssertEqual(window.focuses, 1)
        XCTAssertTrue(NSApp.mainMenu === menu)
        XCTAssertEqual(menu.items.map(\.title), ["File", "Edit", "View"])
        notifications.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        await Task.yield()
        XCTAssertEqual(window.focuses, 1)
        try await coordinator.open(wallpaperID: project.handle.id)
        XCTAssertEqual(window.focuses, 2)
        XCTAssertEqual(policies, [.prohibited, .regular])
        coordinator.close(wallpaperID: project.handle.id)
        XCTAssertEqual(policies, [.prohibited, .regular, .accessory])
    }

    func testPendingActivationCannotPresentAfterLastCloseOrShutdown() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        for shuttingDown in [false, true] {
            for notificationAlreadyPosted in [false, true] {
                let notifications = NotificationCenter()
                var policies: [NSApplication.ActivationPolicy] = []
                var window: PresentationWindow!
                let presentation = WSSEditorAppPresentation(
                    isActive: { true }, notifications: notifications,
                    setPolicy: {
                        policies.append($0)
                        return true
                    })
                let coordinator = WSSEditorCoordinator(
                    lookup: { _ in project.handle.wallpaper }, load: { _ in project },
                    makeWindow: { document, closed in
                        window = PresentationWindow(document, closed)
                        return window
                    }, presentation: presentation)
                try await coordinator.open(wallpaperID: project.handle.id)
                XCTAssertEqual(policies, [.prohibited])
                if notificationAlreadyPosted {
                    notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
                }
                if shuttingDown {
                    coordinator.shutdown()
                } else {
                    coordinator.close(wallpaperID: project.handle.id)
                }
                notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
                for _ in 0..<10 { await Task.yield() }
                XCTAssertEqual(policies, shuttingDown ? [.prohibited] : [.prohibited, .accessory])
                XCTAssertEqual(window.focuses, 0)
                XCTAssertTrue(coordinator.openIDs.isEmpty)
                coordinator.shutdown()
            }
        }
    }

    func testOnlySurvivingEditorPresentsAfterSharedActivationTransition() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        var other = project.handle.wallpaper
        other.id = UUID()
        let entries = [project.handle.id: project.handle.wallpaper, other.id: other]
        let notifications = NotificationCenter()
        var policies: [NSApplication.ActivationPolicy] = []
        var windows: [PresentationWindow] = []
        let coordinator = WSSEditorCoordinator(
            lookup: { try XCTUnwrap(entries[$0]) },
            load: { item in
                WSSLoadedEditorProject(
                    handle: WSSProjectHandle(
                        wallpaper: item, root: project.handle.root,
                        entry: project.handle.entry, origin: .native),
                    document: project.document, scene: project.scene, assets: project.assets,
                    resources: project.resources, diskBasis: project.diskBasis)
            },
            makeWindow: { document, closed in
                let window = PresentationWindow(document, closed)
                windows.append(window)
                return window
            },
            presentation: WSSEditorAppPresentation(
                isActive: { true }, notifications: notifications,
                setPolicy: {
                    policies.append($0)
                    return true
                }))
        defer { coordinator.shutdown() }
        try await coordinator.open(wallpaperID: project.handle.id)
        try await coordinator.open(wallpaperID: other.id)
        XCTAssertEqual(policies, [.prohibited])
        coordinator.close(wallpaperID: project.handle.id)
        XCTAssertEqual(policies, [.prohibited])
        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        for _ in 0..<1000 {
            if windows[1].focuses == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(windows[0].focuses, 0)
        XCTAssertEqual(windows[1].focuses, 1)
        XCTAssertEqual(policies, [.prohibited, .regular])
        coordinator.close(wallpaperID: other.id)
        XCTAssertEqual(policies, [.prohibited, .regular, .accessory])
    }

    func testRejectedActivationHandoffDoesNotWaitOrRetry() async {
        let notifications = NotificationCenter()
        var policies: [NSApplication.ActivationPolicy] = []
        var presented = 0
        let presentation = WSSEditorAppPresentation(
            isActive: { true }, notifications: notifications,
            setPolicy: {
                policies.append($0)
                return false
            })
        presentation.synchronize(hasEditors: true, present: { presented += 1 })
        XCTAssertEqual(policies, [.prohibited])
        XCTAssertEqual(presentation.failedPolicy, .prohibited)
        XCTAssertEqual(presented, 1)
        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        await Task.yield()
        XCTAssertEqual(policies, [.prohibited])
        XCTAssertEqual(presented, 1)
    }
}

extension WSSEditorAppPresentationTests {
    func testStandardDeleteResponderRoutesTypedTargetAndPreservesTextDeletion() async throws {
        _ = NSApplication.shared
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        let doc = WSSEditorEditingTests().editor(project)
        let controller = WSSEditorWindowController(document: doc, onClose: {})
        defer {
            doc.close()
            controller.close()
        }
        let window = try XCTUnwrap(controller.window as? WSSEditorNativeWindow)
        window.contentView = NSView()
        let item = NSMenuItem(
            title: "Delete", action: #selector(WSSEditorNativeWindow.delete(_:)), keyEquivalent: "")
        let layer = doc.identity.layers[0]
        doc.select(.effect(layer.id, layer.effects[1]))
        XCTAssertTrue(window.validateMenuItem(item))
        XCTAssertEqual(doc.currentDeletableSelection, .effect(layer.id, layer.effects[1]))
        window.delete(item)
        XCTAssertEqual(doc.identity.layers[0].effects, [layer.effects[0]])
        XCTAssertEqual(doc.identity.layers.count, 2)
        doc.undoManager.undo()
        doc.select(.layer(layer.id))
        XCTAssertEqual(doc.currentDeletableSelection, .layer(layer.id))
        window.delete(item)
        XCTAssertEqual(doc.identity.layers.count, 1)
        doc.undoManager.undo()
        let before = doc.state.workingModel
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        field.isFieldEditor = true
        field.string = "123"
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        field.setSelectedRange(NSRange(location: 1, length: 1))
        XCTAssertFalse(window.validateMenuItem(item))
        window.delete(item)
        XCTAssertEqual(doc.state.workingModel, before)
        // Native text action remains owned by the text responder.
        field.delete(item)
        XCTAssertEqual(field.string, "13")
        XCTAssertEqual(doc.state.workingModel, before)
        window.makeFirstResponder(nil)
        doc.select(nil)
        XCTAssertFalse(window.validateMenuItem(item))
        window.delete(item)
        XCTAssertEqual(doc.state.workingModel, before)
    }
}
