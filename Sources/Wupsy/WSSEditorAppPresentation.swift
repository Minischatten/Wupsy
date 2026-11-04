import AppKit

/// Presentation only: the coordinator supplies completed session transitions.
@MainActor final class WSSEditorAppPresentation {
    private let setPolicy: (NSApplication.ActivationPolicy) -> Bool
    private let isActive: () -> Bool
    private let notifications: NotificationCenter
    private var hasEditors = false
    private var promotion: UUID?
    private var resignationObserver: NSObjectProtocol?
    private var presentations: [() -> Void] = []
    private(set) var failedPolicy: NSApplication.ActivationPolicy?

    init(
        isActive: @escaping () -> Bool = { false },
        notifications: NotificationCenter = .default,
        setPolicy: @escaping (NSApplication.ActivationPolicy) -> Bool
    ) {
        self.setPolicy = setPolicy
        self.isActive = isActive
        self.notifications = notifications
    }
    deinit {
        if let resignationObserver { notifications.removeObserver(resignationObserver) }
    }
    static func live() -> WSSEditorAppPresentation {
        WSSEditorAppPresentation(
            isActive: { NSApp.isActive }, setPolicy: { NSApp.setActivationPolicy($0) })
    }
    func synchronize(hasEditors: Bool, present: (() -> Void)? = nil) {
        if hasEditors, let present { presentations.append(present) }
        guard self.hasEditors != hasEditors else {
            if promotion == nil { presentEditors() }
            return
        }
        self.hasEditors = hasEditors
        guard hasEditors else {
            cancelPendingPresentation()
            _ = apply(.accessory)
            return
        }
        guard isActive() else {
            _ = apply(.regular)
            presentEditors()
            return
        }
        // An already-active accessory app needs a real activation transition;
        // activate() alone does not reinstall interactive main-menu tracking.
        // deactivate() does not reliably resign an active accessory app. Use the
        // app's own policy, then wait for AppKit's event before presenting windows.
        let token = UUID()
        promotion = token
        resignationObserver = notifications.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.promotion == token else { return }
                self.removeResignationObserver()
                // Finish the AppKit notification before changing policy again.
                Task { @MainActor [weak self] in self?.completePromotion(token) }
            }
        }
        if !apply(.prohibited) {
            // No event can be relied on after a rejected policy change. Keep the
            // existing accessory-window fallback, without retries or a stuck wait.
            promotion = nil
            removeResignationObserver()
            presentEditors()
        }
    }
    private func completePromotion(_ token: UUID) {
        guard promotion == token, hasEditors else { return }
        promotion = nil
        _ = apply(.regular)
        presentEditors()
    }
    private func presentEditors() {
        let ready = presentations
        presentations.removeAll()
        for present in ready { present() }
    }
    private func removeResignationObserver() {
        if let resignationObserver { notifications.removeObserver(resignationObserver) }
        resignationObserver = nil
    }
    func cancelPendingPresentation() {
        promotion = nil
        removeResignationObserver()
        presentations.removeAll()
    }
    @discardableResult private func apply(_ policy: NSApplication.ActivationPolicy) -> Bool {
        if setPolicy(policy) {
            failedPolicy = nil
            return true
        }
        failedPolicy = policy
        NSLog("Wupsy: activation policy change to %@ failed", String(describing: policy))
        return false
    }
}

/// The same document actions and validation serve menus and the native toolbar.
@MainActor struct WSSEditorCommands {
    enum Action {
        case save, saveAs, revert, delete
        case zoom(WSSCanvasZoomCommand)
    }
    let document: WSSEditorDocument
    let window: NSWindow?

    private var hasSheet: Bool {
        var candidate = window
        while let current = candidate {
            if current.attachedSheet != nil || current.sheetParent != nil { return true }
            candidate = current.parent
        }
        return false
    }
    var permitsDocumentCommands: Bool {
        !document.closed && !document.interactionLocked && !document.saveAsBusy
            && !document.isResolvingClose && !document.importingImage
            && !document.hasActivePaintInteraction
            && !hasSheet
            && NSApp?.modalWindow == nil
    }
    func canPerform(_ action: Action) -> Bool {
        guard permitsDocumentCommands else { return false }
        switch action {
        case .save: return document.canSave
        case .saveAs: return document.canSaveAs
        case .revert: return document.canRevert
        case .delete:
            return !(window?.firstResponder is NSTextView)
                && !(window?.firstResponder is NSTextField)
                && document.currentDeletableSelection != nil
        case .zoom:
            if let text = window?.firstResponder as? NSTextView,
                text.isRichText && !text.isFieldEditor
            {
                return false
            }
            return document.canvasZoomCommand != nil && document.canvasZoomAvailable?() == true
        }
    }
    func perform(_ action: Action) {
        guard canPerform(action) else { return }
        // Capture this document before entering an asynchronous operation.
        let document = document
        switch action {
        case .save:
            Task {
                guard canPerform(.save) else { return }
                _ = await document.save()
            }
        case .saveAs:
            Task {
                guard canPerform(.saveAs) else { return }
                _ = await document.requestSaveAs?()
            }
        case .revert: document.revert()
        case .delete: try? document.deleteSelection()
        case .zoom(let command): _ = document.canvasZoomCommand?(command)
        }
    }
    static func inWindow(_ window: NSWindow?) -> Self? {
        guard let document = WSSEditorCoordinator.document(in: window) else { return nil }
        return Self(document: document, window: window)
    }
}
