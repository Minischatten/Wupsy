import AppKit

extension WSSPreviewSurface {
    convenience init(document: WSSEditorDocument) {
        self.init(
            resources: document.editorPreviewResources, playing: document.playing,
            offset: document.initialPreviewTime,
            onError: { [weak document] in document?.previewFailed($0) })
        document.stopPreview = { [weak self] in self?.shutdown() }
    }
}

// SwiftUI owns this stable host. Expansion reparents its one native surface;
// neither presentation creates another player or another resource preparation.
@MainActor final class WSSPreviewHost: NSView, NSWindowDelegate {
    let surface: WSSPreviewSurface
    private weak var document: WSSEditorDocument?
    private(set) var expandedWindow: NSWindow?
    private var expandedContent: WSSExpandedPreviewContent?
    private let placeholder = NSTextField(wrappingLabelWithString: EditorText.previewEnlarged.text)
    private var stopped = false

    init(document: WSSEditorDocument) {
        self.document = document
        surface = WSSPreviewSurface(document: document)
        super.init(frame: .zero)
        addSubview(surface)
        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        placeholder.isHidden = true
        addSubview(placeholder)
        document.togglePreviewExpansion = { [weak self] in self?.toggleExpansion() }
        document.stopPreview = { [weak self] in self?.shutdown() }
    }
    required init?(coder: NSCoder) { fatalError() }
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
    func shutdown() {
        guard !stopped else { return }
        stopped = true
        restore()
        surface.shutdown()
        surface.removeFromSuperview()
        document?.togglePreviewExpansion = nil
        document = nil
    }
}

@MainActor private final class WSSExpandedPreviewContent: NSView {
    private let surface: WSSPreviewSurface
    private let canvas: CGSize
    private let play: NSButton
    private let close: NSButton
    private let status = NSTextField(labelWithString: EditorText.livePreview.text)
    init(surface: WSSPreviewSurface, canvas: CGSize, target: WSSPreviewHost) {
        self.surface = surface
        self.canvas = canvas
        play = NSButton(
            title: ProductText.pause.text, target: target,
            action: #selector(WSSPreviewHost.togglePlayback(_:)))
        close = NSButton(
            title: EditorText.returnEditor.text, target: target,
            action: #selector(WSSPreviewHost.closeExpanded(_:)))
        close.keyEquivalent = "\u{1b}"
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        status.textColor = .secondaryLabelColor
        addSubview(surface)
        addSubview(status)
        addSubview(play)
        addSubview(close)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(playing: Bool, current: Bool) {
        play.title = playing ? ProductText.pause.text : EditorText.play.text
        play.setAccessibilityLabel(
            playing ? EditorText.pausePreview.text : EditorText.playPreview.text)
        status.stringValue =
            current ? EditorText.livePreview.text : EditorText.previewNotCurrent.text
    }
    override func layout() {
        super.layout()
        let area = CGRect(
            x: 12, y: 12, width: max(0, bounds.width - 24), height: max(0, bounds.height - 56))
        let fit = WSSPreviewGeometry.fit(canvas: canvas, available: area.size)
        surface.frame = CGRect(
            x: area.midX - fit.width / 2, y: area.midY - fit.height / 2, width: fit.width,
            height: fit.height)
        close.frame = CGRect(x: bounds.width - 166, y: bounds.height - 38, width: 154, height: 26)
        play.frame = CGRect(x: bounds.width - 246, y: bounds.height - 38, width: 72, height: 26)
        status.frame = CGRect(
            x: 12, y: bounds.height - 34, width: max(0, bounds.width - 270), height: 22)
    }
}
