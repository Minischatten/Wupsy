import AppKit
import SwiftUI

extension WSSPreviewSurface {
    convenience init(document: WSSEditorDocument) {
        self.init(
            resources: document.editorPreviewResources, playing: document.playing,
            offset: document.initialPreviewTime, editorPlayback: true,
            onError: { [weak document] in document?.previewFailed($0) })
        document.stopPreview = { [weak self] in self?.shutdown() }
    }
}

// SwiftUI owns this stable host. Expansion reparents its one native surface;
// the surface preserves the paused player and applies the running transfer policy.
@MainActor final class WSSPreviewHost: NSView, NSWindowDelegate {
    let surface: WSSPreviewSurface
    let performanceDiagnosis: PerformanceDiagnosis
    private lazy var performanceOverlay = NSHostingView(
        rootView: EditorPerformanceOverlay(
            diagnosis: performanceDiagnosis, toggle: { [weak self] in self?.togglePerformance() },
            metrics: interfaceMetrics))
    private var performanceConstraints: [NSLayoutConstraint] = []
    private weak var document: WSSEditorDocument?
    private(set) var expandedWindow: NSWindow?
    private var expandedContent: WSSExpandedPreviewContent?
    private let placeholder = NSTextField(wrappingLabelWithString: EditorText.previewEnlarged.text)
    private var stopped = false
    var interfaceMetrics = WupsyMetrics() {
        didSet {
            guard interfaceMetrics != oldValue else { return }
            placeholder.font = .systemFont(ofSize: interfaceMetrics.points(NSFont.systemFontSize))
            expandedContent?.interfaceMetrics = interfaceMetrics
            performanceOverlay.rootView.metrics = interfaceMetrics
        }
    }

    init(document: WSSEditorDocument, performanceDefaults: UserDefaults = .standard) {
        performanceDiagnosis = PerformanceDiagnosis(
            defaults: performanceDefaults, detailsKey: "performance.editor.details")
        self.document = document
        surface = WSSPreviewSurface(document: document)
        super.init(frame: .zero)
        addSubview(surface)
        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        placeholder.isHidden = true
        addSubview(placeholder)
        attachPerformanceOverlay(to: self, top: 8)
        document.displayFogDrift = { [weak self] resources in
            self?.surface.player?.updateFogDragPreview(resources)
        }
        surface.frameControlsChanged = { [weak self, weak document] controls in
            if let document, document.previewFrameControls != controls {
                document.previewFrameControls = controls
            }
            self?.expandedContent?.updateFrameControls(controls)
        }
        document.stepPreviewFrame = { [weak self] in self?.stepFrame($0) }
        document.togglePreviewExpansion = { [weak self] in self?.toggleExpansion() }
        document.stopPreview = { [weak self] in self?.shutdown() }
    }
    required init?(coder: NSCoder) { fatalError() }
    func togglePerformance() {
        guard !stopped else { return }
        let enabled = !performanceDiagnosis.active
        performanceDiagnosis.setActive(enabled)
        surface.performancePlayerChanged =
            enabled ? { [weak self] in self?.bindPerformance() } : nil
        bindPerformance()
    }

    private func bindPerformance() {
        performanceDiagnosis.bind(surface.player)
    }

    private func attachPerformanceOverlay(to view: NSView, top: CGFloat) {
        NSLayoutConstraint.deactivate(performanceConstraints)
        performanceOverlay.removeFromSuperview()
        performanceOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(performanceOverlay)
        performanceConstraints = [
            performanceOverlay.topAnchor.constraint(equalTo: view.topAnchor, constant: top),
            performanceOverlay.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -8),
            performanceOverlay.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor, constant: 8),
            performanceOverlay.bottomAnchor.constraint(
                lessThanOrEqualTo: view.bottomAnchor, constant: -8),
        ]
        NSLayoutConstraint.activate(performanceConstraints)
    }

    fileprivate func updatePerformanceLayout(_ size: CGSize, top: CGFloat) {
        let available = CGSize(
            width: max(0, size.width - 16), height: max(0, size.height - top - 8))
        guard performanceOverlay.rootView.availableSize != available else { return }
        performanceOverlay.rootView.availableSize = available
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, document?.previewExpanded == true, expandedWindow == nil, !stopped {
            Task { @MainActor [weak self] in
                guard let self, !stopped, window != nil, document?.previewExpanded == true else {
                    return
                }
                expand()
            }
        }
    }
    override func layout() {
        super.layout()
        if expandedWindow == nil, let document {
            updatePerformanceLayout(bounds.size, top: 8)
            let fit = WSSPreviewGeometry.fit(
                canvas: CGSize(
                    width: document.project.scene.width, height: document.project.scene.height),
                available: bounds.size)
            surface.frame = CGRect(
                x: bounds.midX - fit.width / 2, y: bounds.midY - fit.height / 2, width: fit.width,
                height: fit.height)
        }
        placeholder.frame = bounds.insetBy(dx: 12, dy: max(12, (bounds.height - 40) / 2))
    }
    func update(_ document: WSSEditorDocument) {
        guard !stopped else { return }
        surface.update(resources: document.editorPreviewResources, playing: document.playing)
        expandedContent?.update(playing: document.playing, current: document.previewIsCurrent)
        expandedContent?.updateFrameControls(surface.frameControls)
    }
    func toggleExpansion() {
        if expandedWindow != nil { restore() } else { expand() }
    }
    func expand() {
        guard !stopped, expandedWindow == nil, let document, !document.closed,
            document.previewError == nil, let parent = window
        else { return }
        let available = (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame
        let size = NSSize(
            width: max(300, available.width * 0.85), height: max(220, available.height * 0.85 - 40))
        let enlarged = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        enlarged.title = EditorText.previewTitle.format(document.project.handle.wallpaper.title)
        enlarged.isReleasedWhenClosed = false
        enlarged.contentMinSize = NSSize(width: min(480, size.width), height: min(300, size.height))
        enlarged.collectionBehavior.insert(.fullScreenPrimary)
        enlarged.tabbingMode = .disallowed
        enlarged.acceptsMouseMovedEvents = true
        expandedWindow = enlarged
        surface.transferPresentation {
            surface.removeFromSuperview()
            let content = WSSExpandedPreviewContent(
                surface: surface,
                canvas: CGSize(
                    width: document.project.scene.width, height: document.project.scene.height),
                target: self)
            expandedContent = content
            content.interfaceMetrics = interfaceMetrics
            attachPerformanceOverlay(to: content, top: 54)
            enlarged.contentView = content
            enlarged.delegate = self
            content.update(playing: document.playing, current: document.previewIsCurrent)
            placeholder.isHidden = false
            document.previewExpanded = true
            parent.addChildWindow(enlarged, ordered: .above)
            enlarged.setFrameOrigin(
                NSPoint(
                    x: available.midX - enlarged.frame.width / 2,
                    y: available.midY - enlarged.frame.height / 2))
            enlarged.makeKeyAndOrderFront(nil)
            content.layoutSubtreeIfNeeded()
        }
        expandedContent?.updateFrameControls(surface.frameControls)
    }
    func restore(closeWindow: Bool = true) {
        guard let enlarged = expandedWindow else { return }
        surface.transferPresentation {
            expandedWindow = nil
            enlarged.delegate = nil
            surface.removeFromSuperview()
            enlarged.contentView = nil
            enlarged.parent?.removeChildWindow(enlarged)
            expandedContent = nil
            if closeWindow { enlarged.close() }
            placeholder.isHidden = true
            document?.previewExpanded = false
            if !stopped {
                addSubview(surface, positioned: .below, relativeTo: placeholder)
                attachPerformanceOverlay(to: self, top: 8)
                needsLayout = true
                layoutSubtreeIfNeeded()
            }
        }
    }
    func windowWillClose(_ notification: Notification) { restore(closeWindow: false) }
    @objc func closeExpanded(_ sender: Any?) { restore() }
    @objc func togglePlayback(_ sender: Any?) {
        guard let document, !stopped else { return }
        document.playing.toggle()
        update(document)
    }
    private func stepFrame(_ direction: WSSPreviewFrameDirection) {
        guard let document, !stopped, !document.playing, document.previewError == nil else {
            return
        }
        surface.stepFrame(direction)
    }
    @objc fileprivate func previousFrame(_ sender: Any?) { stepFrame(.backward) }
    @objc fileprivate func nextFrame(_ sender: Any?) { stepFrame(.forward) }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        surface.performancePlayerChanged = nil
        performanceDiagnosis.setActive(false)
        NSLayoutConstraint.deactivate(performanceConstraints)
        performanceConstraints = []
        performanceOverlay.removeFromSuperview()
        restore()
        surface.shutdown()
        surface.removeFromSuperview()
        document?.togglePreviewExpansion = nil
        document?.stepPreviewFrame = nil
        document = nil
    }
}

@MainActor private final class WSSExpandedPreviewContent: NSView {
    private let surface: WSSPreviewSurface
    private let canvas: CGSize
    private weak var target: WSSPreviewHost?
    private let play: NSButton
    private let close: NSButton
    private let previous: NSButton
    private let next: NSButton
    private let status = NSTextField(labelWithString: EditorText.livePreview.text)
    var interfaceMetrics = WupsyMetrics() {
        didSet {
            guard interfaceMetrics != oldValue else { return }
            let font = NSFont.systemFont(ofSize: interfaceMetrics.points(NSFont.systemFontSize))
            for button in [previous, play, next, close] {
                button.controlSize = interfaceMetrics.nativeControlSize
                button.font = font
            }
            status.font = font
            needsLayout = true
        }
    }
    private static func frameButton(
        _ direction: WSSPreviewFrameDirection, target: WSSPreviewHost, action: Selector
    ) -> NSButton {
        let label = direction.title.text
        let button = NSButton(title: label, target: target, action: action)
        if let image = NSImage(systemSymbolName: direction.symbol, accessibilityDescription: label)
        {
            button.image = image
            button.imagePosition = .imageOnly
        }
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.isEnabled = false
        return button
    }
    init(surface: WSSPreviewSurface, canvas: CGSize, target: WSSPreviewHost) {
        self.surface = surface
        self.canvas = canvas
        self.target = target
        play = NSButton(
            title: "", target: target, action: #selector(WSSPreviewHost.togglePlayback(_:)))
        play.imagePosition = .imageOnly
        previous = Self.frameButton(
            .backward, target: target, action: #selector(WSSPreviewHost.previousFrame(_:)))
        next = Self.frameButton(
            .forward, target: target, action: #selector(WSSPreviewHost.nextFrame(_:)))
        close = NSButton(
            title: EditorText.returnEditor.text, target: target,
            action: #selector(WSSPreviewHost.closeExpanded(_:)))
        close.keyEquivalent = "\u{1b}"
        close.toolTip = EditorText.returnEditor.text
        close.setAccessibilityLabel(EditorText.returnEditor.text)
        close.image = NSImage(
            systemSymbolName: "arrow.down.right.and.arrow.up.left",
            accessibilityDescription: EditorText.returnEditor.text)
        close.imagePosition = .noImage
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        addSubview(surface)
        addSubview(status)
        addSubview(previous)
        addSubview(play)
        addSubview(next)
        addSubview(close)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(playing: Bool, current: Bool) {
        let playbackLabel = playing ? EditorText.pausePreview.text : EditorText.playPreview.text
        play.setAccessibilityLabel(playbackLabel)
        play.toolTip = playbackLabel
        play.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: playbackLabel)
        status.stringValue =
            current ? EditorText.livePreview.text : EditorText.previewNotCurrent.text
        status.toolTip = status.stringValue
    }
    func updateFrameControls(_ controls: WSSPreviewFrameControls) {
        previous.isEnabled = controls.backward
        next.isEnabled = controls.forward
    }
    override func layout() {
        super.layout()
        target?.updatePerformanceLayout(bounds.size, top: 54)
        let pad = interfaceMetrics.spacing(12)
        let buttonHeight = interfaceMetrics.target(26)
        let gap = interfaceMetrics.spacing(6)
        let stepWidth = interfaceMetrics.target(30)
        let regularPlayWidth = interfaceMetrics.target(72)
        let labeledCloseWidth = interfaceMetrics.target(154)
        let labeledToolbarWidth =
            2 * pad + 4 * gap + 2 * stepWidth
            + regularPlayWidth + labeledCloseWidth + interfaceMetrics.points(110)
        let compact = bounds.width < labeledToolbarWidth
        let playWidth = compact ? stepWidth : regularPlayWidth
        let closeWidth = compact ? stepWidth : labeledCloseWidth
        close.imagePosition = compact ? .imageOnly : .noImage
        let buttonY = bounds.height - pad - buttonHeight
        let closeX = bounds.width - pad - closeWidth
        let nextX = closeX - gap - stepWidth
        let playX = nextX - gap - playWidth
        let previousX = playX - gap - stepWidth
        let area = CGRect(
            x: pad, y: pad, width: max(0, bounds.width - 2 * pad),
            height: max(0, bounds.height - interfaceMetrics.spacing(56)))
        let fit = WSSPreviewGeometry.fit(canvas: canvas, available: area.size)
        surface.frame = CGRect(
            x: area.midX - fit.width / 2, y: area.midY - fit.height / 2, width: fit.width,
            height: fit.height)
        close.frame = CGRect(x: closeX, y: buttonY, width: closeWidth, height: buttonHeight)
        play.frame = CGRect(x: playX, y: buttonY, width: playWidth, height: buttonHeight)
        previous.frame = CGRect(x: previousX, y: buttonY, width: stepWidth, height: buttonHeight)
        next.frame = CGRect(x: nextX, y: buttonY, width: stepWidth, height: buttonHeight)
        status.frame = CGRect(
            x: pad, y: buttonY + interfaceMetrics.spacing(4), width: max(0, previousX - 2 * pad),
            height: interfaceMetrics.points(22))
    }
}
