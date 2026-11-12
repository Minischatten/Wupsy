import MetalKit
import SwiftUI

struct WSSCanvasPresentation {
    let zoom: CGFloat?
    let origin: CGPoint
}

struct WSSCanvasView: NSViewRepresentable {
    @ObservedObject var document: WSSEditorDocument
    @Binding var zoom: CGFloat?  // nil is Fit; 1 is one Scene unit per point.
    func makeNSView(context: Context) -> WSSCanvasScrollView {
        WSSCanvasScrollView(document: document)
    }
    func updateNSView(_ view: WSSCanvasScrollView, context: Context) {
        view.onZoom = { zoom = $0 }
        view.update(document, zoom: zoom)
    }
    static func dismantleNSView(_ view: WSSCanvasScrollView, coordinator: ()) { view.shutdown() }
}

@MainActor final class WSSCanvasScrollView: NSScrollView {
    let surface: WSSStaticCanvasSurface
    private var zoom: CGFloat?
    private var pendingPresentation: WSSCanvasPresentation?
    private var currentZoom: CGFloat = 1
    private var imageOrigin = CGPoint.zero
    var onZoom: ((CGFloat?) -> Void)?
    var presentationZoom: CGFloat? { zoom }
    private weak var document: WSSEditorDocument?
    private var pending:
        (gesture: WSSCanvasGesture, layer: WSSLayerID, start: CGPoint, active: Bool)?
    private var focusObservers: [NSObjectProtocol] = []
    enum InteractionPhase {
        case idle, pendingTransform, moving, scaling, rotating, panning, painting
    }
    var interactionPhase: InteractionPhase {
        if panPoint != nil { return .panning }
        if document?.activeCanvasPaint?.isDrawing == true { return .painting }
        guard let pending else { return .idle }
        guard pending.active else { return .pendingTransform }
        switch pending.gesture.kind {
        case .move: return .moving
        case .scale: return .scaling
        case .rotate: return .rotating
        }
    }
    var isTransforming: Bool { pending != nil }
    private var spaceDown: Bool { document?.canvasSpaceDown == true }
    private var panPoint: CGPoint?
    override var acceptsFirstResponder: Bool { true }
    // NSScrollView's default implementation forwards focus to its document view
    // (or the window). Canvas input must retain the responder it explicitly requests.
    override func becomeFirstResponder() -> Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, let action = WSSCanvasZoomCommand.decode(event) {
            return performZoom(action)
        }
        return super.performKeyEquivalent(with: event)
    }
    var canPerformZoom: Bool {
        guard let document else { return false }
        return !document.closed && !isTransforming && !document.interactionLocked
            && !document.hasActivePaintInteraction
    }
    @discardableResult func performZoom(_ action: WSSCanvasZoomCommand) -> Bool {
        guard let document, !document.closed else { return false }
        // Consume valid shortcuts without a beep, but keep active gesture geometry frozen.
        guard canPerformZoom else { return true }
        switch action {
        case .zoomIn: setZoom(currentZoom * 1.25)
        case .zoomOut: setZoom(currentZoom / 1.25)
        case .fit: setZoom(nil)
        case .actualSize: setZoom(1)
        }
        return true
    }
    override func magnify(with event: NSEvent) {
        applyMagnification(
            event.magnification, at: surface.convert(event.locationInWindow, from: nil))
    }
    func applyMagnification(_ delta: CGFloat, at anchor: CGPoint) {
        guard delta.isFinite, delta != 0, delta > -1, anchor.x.isFinite, anchor.y.isFinite,
            let document, !document.closed, !isTransforming,
            !document.interactionLocked, !document.hasActivePaintInteraction
        else { return }
        setZoom(currentZoom * (1 + delta), anchor: anchor)
    }
    private func setZoom(_ value: CGFloat?, anchor: CGPoint? = nil) {
        let anchoredScene = anchor.map {
            WSSCanvasGeometry.scenePoint(
                $0, origin: imageOrigin, zoom: currentZoom, height: surface.sceneSize.height)
        }
        let viewportOffset = anchor.map {
            CGPoint(x: $0.x - contentView.bounds.minX, y: $0.y - contentView.bounds.minY)
        }
        zoom = value.map { min(4, max(0.05, $0)) }
        resizeCanvas()
        if let anchoredScene, let viewportOffset {
            let point = viewPoint(for: anchoredScene)
            let desired = CGPoint(x: point.x - viewportOffset.x, y: point.y - viewportOffset.y)
            contentView.scroll(
                to: contentView.constrainBoundsRect(CGRect(origin: desired, size: contentSize))
                    .origin)
            reflectScrolledClipView(contentView)
            refreshMaskCursor()
        }
        onZoom?(zoom)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if document?.cancelPaintInteraction() == true
                || document?.cancelTransformInteraction() == true
            {
                return
            }
        }
        if event.keyCode == 49 {
            guard !isTransforming, document?.activeCanvasPaint?.isDrawing != true else { return }
            document?.canvasSpaceDown = true
        } else {
            super.keyDown(with: event)
        }
    }
    override func cancelOperation(_ sender: Any?) {
        if document?.cancelPaintInteraction() != true
            && document?.cancelTransformInteraction() != true
        {
            super.cancelOperation(sender)
        }
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            document?.canvasSpaceDown = false
        } else {
            super.keyUp(with: event)
        }
    }
    override func resignFirstResponder() -> Bool {
        cancelInputForFocusLoss()
        return super.resignFirstResponder()
    }
    private func cancelMaskStroke() {
        if surface.ownsMaskSession { document?.activeCanvasPaint?.cancelStroke() }
    }
    func beginPan(_ event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        if spaceDown {
            surface.maskCursor = nil
            panPoint = event.locationInWindow
            NSCursor.closedHand.set()
        }
    }
    func dragPan(_ event: NSEvent) {
        // The mouse gesture remains Pan-owned until mouse-up, but release stops
        // its motion immediately. A trailing drag must never turn into painting.
        guard let old = panPoint else { return }
        let point = event.locationInWindow
        panPoint = point
        guard spaceDown else { return }
        let origin = contentView.bounds.origin
        contentView.scroll(
            to: contentView.constrainBoundsRect(
                CGRect(
                    origin: CGPoint(x: origin.x - point.x + old.x, y: origin.y + point.y - old.y),
                    size: contentView.bounds.size)
            ).origin)
        reflectScrolledClipView(contentView)
        surface.refreshDirectionOverlay()
    }
    func endPan() {
        panPoint = nil
        updateSpaceCursor()
    }
    private func updateSpaceCursor() {
        let focusedView = window?.firstResponder as? NSView
        let hasCanvasFocus = focusedView === self || focusedView?.isDescendant(of: self) == true
        guard hasCanvasFocus || panPoint != nil,
            !isTransforming, document?.activeCanvasPaint?.isDrawing != true
        else { return }
        if spaceDown {
            surface.maskCursor = nil
            if panPoint == nil { NSCursor.openHand.set() } else { NSCursor.closedHand.set() }
        } else {
            refreshMaskCursor(force: true)
            if surface.maskCursor != nil, document?.paintBrushEnabled == true {
                NSCursor.crosshair.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
    private func cancelInputForFocusLoss() {
        cancelMaskStroke()
        finishTransform()
        if surface.ownsMaskSession { document?.canvasSpaceDown = false }
        panPoint = nil
        surface.maskCursor = nil
        NSCursor.arrow.set()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
        focusObservers.removeAll()
        if let window {
            for (name, object): (Notification.Name, AnyObject) in [
                (NSWindow.didResignKeyNotification, window),
                (NSApplication.didResignActiveNotification, NSApplication.shared),
            ] {
                focusObservers.append(
                    NotificationCenter.default.addObserver(
                        forName: name, object: object, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.cancelInputForFocusLoss() }
                    })
            }
        } else {
            cancelInputForFocusLoss()
        }
    }
    override func scrollWheel(with event: NSEvent) {
        cancelMaskStroke()
        guard !isTransforming else { return }
        super.scrollWheel(with: event)
        refreshMaskCursor()
    }
    private func refreshMaskCursor(force: Bool = false) {
        surface.refreshDirectionOverlay()
        guard force || surface.maskCursor != nil, document?.paintBrushEnabled == true, let window
        else { return }
        let point = surface.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        surface.maskCursor =
            surface.visibleRect.contains(point)
            ? WSSCanvasGeometry.scenePoint(
                point, origin: imageOrigin, zoom: currentZoom, height: surface.sceneSize.height)
            : nil
    }
    func viewPoint(for scenePoint: SIMD2<Float>) -> CGPoint {
        WSSCanvasGeometry.viewportPoint(
            scenePoint, origin: imageOrigin, zoom: currentZoom, height: surface.sceneSize.height)
    }
    func canvasHit(at point: CGPoint) -> WSSCanvasHit? {
        guard let document, !document.closed, !document.interactionLocked else { return nil }
        return WSSCanvasInteractionGeometry.hit(
            point: point, scene: document.workingScene, identity: document.identity,
            selected: document.transformModeLayer, origin: imageOrigin, zoom: currentZoom)
    }
    func beginInteraction(_ event: NSEvent) {
        guard let document, !document.closed, !document.interactionLocked else { return }
        if window?.firstResponder !== self {
            guard window?.makeFirstResponder(self) == true else { return }
        }
        let interactionInProgress =
            pending != nil || panPoint != nil || document.canvasTransform != nil
        // A new mouse-down also ends an abandoned drag whose outside mouse-up
        // was not delivered. Space is a held key, never a latched tool choice.
        if panPoint != nil { endPan() }
        if spaceDown {
            beginPan(event)
            return
        }
        let point = surface.convert(event.locationInWindow, from: nil)
        if let paint = document.activeCanvasPaint, paint.brushEnabled {
            let scene = WSSCanvasGeometry.scenePoint(
                point, origin: imageOrigin, zoom: currentZoom, height: surface.sceneSize.height)
            _ = paint.begin(scene, erase: event.modifierFlags.contains(.option))
            window?.makeFirstResponder(self)
            surface.maskCursor = scene
            return
        }
        guard let hit = canvasHit(at: point) else {
            if event.type == .leftMouseDown, event.clickCount == 1,
                !interactionInProgress, document.transformModeLayer != nil
            {
                _ = document.cancelTransformInteraction()
                surface.update(document)
            }
            return
        }
        document.select(.layer(hit.layer))
        if event.clickCount >= 2 { document.activateTransformMode(hit.layer) }
        surface.update(document)
        guard document.transformModeLayer == hit.layer else { return }
        guard document.selection == .layer(hit.layer),
            let index = document.identity.layers.firstIndex(where: { $0.id == hit.layer }),
            let transform = document.state.workingModel.layers[index].imageTransform
        else { return }
        let kind: WSSCanvasGesture.Kind
        switch hit {
        case .image: kind = .move
        case .corner(_, let index):
            kind = .scale(index, independent: event.modifierFlags.contains(.shift))
        case .rotation: kind = .rotate
        }
        let scene = WSSCanvasGeometry.scenePoint(
            point, origin: imageOrigin, zoom: currentZoom, height: surface.sceneSize.height)
        pending = (
            WSSCanvasGesture(kind: kind, transform: transform, start: scene), hit.layer, point,
            false
        )
        surface.update(document)
    }
    func dragInteraction(_ event: NSEvent) {
        if panPoint != nil {
            dragPan(event)
            return
        }
        if let document, document.activeCanvasPaint?.isDrawing == true {
            let scene = WSSCanvasGeometry.scenePoint(
                surface.convert(event.locationInWindow, from: nil), origin: imageOrigin,
                zoom: currentZoom, height: surface.sceneSize.height)
            document.activeCanvasPaint?.append(scene)
            surface.maskCursor = scene
            return
        }
        guard let document, var value = pending else { return }
        let point = surface.convert(event.locationInWindow, from: nil)
        if !value.active {
            guard hypot(point.x - value.start.x, point.y - value.start.y) >= 3 else { return }
            guard document.beginCanvasTransform(value.layer, kind: value.gesture.kind) else {
                pending = nil
                return
            }
            value.active = true
        }
        guard document.canvasTransform?.layer == value.layer else {
            pending = nil
            return
        }
        let scene = WSSCanvasGeometry.scenePoint(
            point, origin: imageOrigin, zoom: currentZoom, height: surface.sceneSize.height)
        do {
            let transform = try value.gesture.transform(at: scene)
            try document.updateCanvasTransform(transform)
        } catch {
            // Keep the last valid transform when a drag exceeds the WSS bounds.
        }
        pending = value
        surface.update(document)
    }
    func finishTransform(cancel: Bool = false) {
        pending = nil
        document?.endCanvasTransform(cancel: cancel)
        if let document, !document.closed { surface.update(document) }
    }
    func endInteraction(_ event: NSEvent? = nil) {
        if panPoint != nil {
            finishTransform()
            endPan()
            return
        }
        if let document, document.activeCanvasPaint?.isDrawing == true, let event {
            let scene = WSSCanvasGeometry.scenePoint(
                surface.convert(event.locationInWindow, from: nil), origin: imageOrigin,
                zoom: currentZoom, height: surface.sceneSize.height)
            document.activeCanvasPaint?.finish(scene)
        }
        finishTransform()
        endPan()
    }
    func transformHelp(at point: CGPoint) -> String? {
        guard let hit = canvasHit(at: point) else { return nil }
        return document?.transformHelp(for: .layer(hit.layer))
    }
    func hover(_ event: NSEvent) {
        let scene = WSSCanvasGeometry.scenePoint(
            surface.convert(event.locationInWindow, from: nil), origin: imageOrigin,
            zoom: currentZoom, height: surface.sceneSize.height)
        surface.maskCursor = scene
        if document?.paintBrushEnabled == true {
            surface.toolTip =
                document?.directionCanvas.brushEnabled == true
                ? document?.directionCanvas.canvasHelp
                : EditorText.maskCanvas.text
            if spaceDown { NSCursor.openHand.set() } else { NSCursor.crosshair.set() }
            return
        }
        let help = transformHelp(at: surface.convert(event.locationInWindow, from: nil))
        if surface.toolTip != help { surface.toolTip = help }
        if spaceDown {
            NSCursor.openHand.set()
            return
        }
        switch canvasHit(at: surface.convert(event.locationInWindow, from: nil)) {
        case .image(let id):
            if document?.transformModeLayer == id {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        case .corner: NSCursor.crosshair.set()
        case .rotation: NSCursor.crosshair.set()
        case nil: NSCursor.arrow.set()
        }
    }

    init(document: WSSEditorDocument) {
        self.document = document
        surface = WSSStaticCanvasSurface(document: document)
        super.init(frame: .zero)
        documentView = surface
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = .windowBackgroundColor
        document.canvasPreparationTask = { [weak self] in self?.surface.preparationTask }
        document.captureCanvasPresentation = { [weak self] in
            guard let self else { return nil }
            return WSSCanvasPresentation(zoom: zoom, origin: contentView.bounds.origin)
        }
        document.restoreCanvasPresentation = { [weak self] value in
            guard let self else { return }
            pendingPresentation = value
            zoom = value.zoom
            onZoom?(value.zoom)
            resizeCanvas()
            contentView.scroll(to: value.origin)
            reflectScrolledClipView(contentView)
        }
        document.canvasSpaceChanged = { [weak self] in self?.updateSpaceCursor() }
        document.canvasZoomCommand = { [weak self] in self?.performZoom($0) ?? false }
        document.canvasZoomAvailable = { [weak self] in self?.canPerformZoom ?? false }
        document.stopCanvas = { [weak self] in self?.shutdown() }
        document.finishCanvasInteraction = { [weak self] in self?.finishTransform() }
        setAccessibilityLabel(EditorText.canvas.text)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ document: WSSEditorDocument, zoom: CGFloat?) {
        if !isTransforming {
            if let pendingPresentation {
                self.zoom = pendingPresentation.zoom
            } else {
                self.zoom = zoom
            }
        }
        surface.update(document)
        resizeCanvas()
        if let pendingPresentation {
            contentView.scroll(to: pendingPresentation.origin)
            reflectScrolledClipView(contentView)
            self.pendingPresentation = nil
        }
    }
    override func layout() {
        super.layout()
        resizeCanvas()
    }
    private func resizeCanvas() {
        let size = surface.sceneSize
        let z =
            zoom
            ?? WSSCanvasGeometry.fit(
                scene: size,
                viewport: CGSize(
                    width: max(1, contentSize.width - 56), height: max(1, contentSize.height - 56)))
        let imageSize = CGSize(width: size.width * z, height: size.height * z)
        let frameSize = CGSize(
            width: max(contentSize.width, imageSize.width + 80),
            height: max(contentSize.height, imageSize.height + 80))
        let center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        let logical = CGPoint(
            x: (center.x - imageOrigin.x) / currentZoom, y: (center.y - imageOrigin.y) / currentZoom
        )
        let changed = currentZoom != z
        if changed { cancelMaskStroke() }
        surface.configure(size: frameSize, imageSize: imageSize)
        imageOrigin = CGPoint(
            x: (frameSize.width - imageSize.width) / 2, y: (frameSize.height - imageSize.height) / 2
        )
        currentZoom = z
        if changed, zoom != nil {
            let origin = CGPoint(
                x: logical.x * z + imageOrigin.x - contentSize.width / 2,
                y: logical.y * z + imageOrigin.y - contentSize.height / 2)
            contentView.scroll(
                to: contentView.constrainBoundsRect(CGRect(origin: origin, size: contentSize))
                    .origin)
            reflectScrolledClipView(contentView)
        }
        refreshMaskCursor()
    }
    func shutdown() {
        if surface.ownsMaskSession {
            document?.canvasSpaceDown = false
            document?.canvasSpaceChanged = nil
            document?.canvasPreparationTask = nil
            document?.captureCanvasPresentation = nil
            document?.restoreCanvasPresentation = nil
            document?.canvasZoomCommand = nil
            document?.canvasZoomAvailable = nil
        }
        cancelInputForFocusLoss()
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
        focusObservers.removeAll()
        document = nil
        onZoom = nil
        surface.shutdown()
    }
}

@MainActor final class WSSStaticCanvasSurface: NSView, MTKViewDelegate {
    private let metal: WSSCanvasMetalView
    private let outline = WSSCanvasOutline()
    private let maskOutline = WSSMaskCanvasOutline()
    private let directionOutline = WSSDirectionCanvasOverlay()
    private var maskOverlay: WSSMaskCanvasOverlay?
    private weak var maskSession: WSSMaskCanvasSession?
    private let maskOwner = UUID()
    private var maskDisplayVersion: UInt64?
    var ownsMaskSession: Bool { maskSession?.canvasOwner == maskOwner }
    var maskCursor: SIMD2<Float>? {
        get {
            directionOutline.session?.brushEnabled == true
                ? directionOutline.cursor : maskOutline.cursor
        }
        set {
            maskOutline.cursor = newValue
            directionOutline.cursor = newValue
            directionOutline.needsDisplay = true
            maskOutline.needsDisplay = true
        }
    }
    func refreshDirectionOverlay() { directionOutline.needsDisplay = true }
    private(set) var resources: WSSStaticResources?
    private var resourcesModel: WSSSceneDocumentV1?
    private var tracking: NSTrackingArea?
    private var task: Task<Void, Never>?
    var preparationTask: Task<Void, Never>? { task }
    private let preparation = WSSStaticCanvasPreparation()
    private var model: WSSSceneDocumentV1?
    private(set) var stopped = false
    private let message = NSTextField(wrappingLabelWithString: "")
    private var error: String? {
        didSet {
            message.stringValue = error.map { EditorText.canvasNotCurrent.format($0) } ?? ""
            message.isHidden = error == nil
        }
    }
    var showsTransformHandles: Bool { outline.transform != nil }
    let sceneSize: CGSize
    override var isFlipped: Bool { true }
    init(document: WSSEditorDocument) {
        sceneSize = CGSize(
            width: document.project.scene.width, height: document.project.scene.height)
        metal = WSSCanvasMetalView(frame: .zero, device: document.project.resources.device)
        super.init(frame: .zero)
        metal.colorPixelFormat = .bgra8Unorm
        metal.isPaused = true
        metal.enableSetNeedsDisplay = true
        metal.autoResizeDrawable = false
        metal.delegate = self
        addSubview(metal)
        outline.wantsLayer = true
        outline.setAccessibilityIdentifier("wss.transform-outline")
        outline.sceneSize = sceneSize
        addSubview(outline)
        maskSession = document.maskCanvas
        do {
            maskOverlay = try WSSMaskCanvasOverlay(device: document.project.resources.device)
        } catch { document.maskCanvas.overlayFailed() }
        maskOutline.session = maskSession
        maskOutline.sceneSize = sceneSize
        addSubview(maskOutline)
        directionOutline.session = document.directionCanvas
        directionOutline.sceneSize = sceneSize
        addSubview(directionOutline)
        document.directionCanvas.canvasOwner = maskOwner
        document.directionCanvas.onChange = { [weak self] in
            guard let self, !stopped else { return }
            if directionOutline.session?.brushEnabled != true { directionOutline.cursor = nil }
            let enabled = directionOutline.session?.overlayVisible == true
            if maskOutline.isHidden != enabled {
                maskOutline.isHidden = enabled
                metal.setNeedsDisplay(metal.bounds)
            }
            directionOutline.needsDisplay = true
        }
        document.maskCanvas.canvasOwner = maskOwner
        document.maskCanvas.onChange = { [weak self] in
            guard let self, !stopped else { return }
            if maskDisplayVersion != maskSession?.displayVersion {
                maskDisplayVersion = maskSession?.displayVersion
                maskOverlay?.invalidate(region: maskSession?.dirtyRegion)
                metal.setNeedsDisplay(metal.bounds)
            }
            if maskSession?.brushEnabled != true && directionOutline.session?.brushEnabled != true {
                if maskOutline.cursor != nil, window?.isKeyWindow == true,
                    !(window?.firstResponder is NSTextView)
                {
                    NSCursor.arrow.set()
                }
                maskOutline.cursor = nil
            }
            maskOutline.needsDisplay = true
        }
        message.isHidden = true
        message.drawsBackground = true
        message.backgroundColor = .windowBackgroundColor
        message.setAccessibilityLabel(EditorText.canvasStatus.text)
        addSubview(message)
        update(document)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ document: WSSEditorDocument) {
        let scene = document.workingScene
        outline.transform =
            document.transformModeLayer == document.selection?.layer
                && document.transformModeLayer != nil
                && scene.layers.indices.contains(document.selectedLayer)
            ? {
                if case .image(let image) = scene.layers[document.selectedLayer],
                    image.visible
                {
                    return image.transform
                }
                return nil
            }() : nil
        outline.needsDisplay = true
        let candidate = document.canvasModel
        guard model != candidate, !stopped else { return }
        model = candidate
        // Finish the first decode once; fold any transform-only updates into it.
        if resources == nil, task != nil { return }
        task?.cancel()
        if let resources, let resourcesModel,
            let reused = try? resources.updatingTransforms(
                from: resourcesModel, to: candidate, staticCanvas: true)
        {
            self.resources = reused
            self.resourcesModel = candidate
            error = nil
            metal.setNeedsDisplay(metal.bounds)
            return
        }
        let handle = document.project.handle
        let catalog = document.state.resourceCatalog
        let sessionAssets = document.state.sessionAssets
        task = Task { [weak self, preparation] in
            do {
                let value = try await preparation.prepare(
                    candidate, handle: handle, catalog: catalog, sessionAssets: sessionAssets)
                guard let self, !Task.isCancelled, !stopped else { return }
                task = nil
                if model == candidate {
                    resources = value
                    resourcesModel = candidate
                } else if let latest = model,
                    let reused = try value.updatingTransforms(
                        from: candidate, to: latest, staticCanvas: true)
                {
                    resources = reused
                    resourcesModel = latest
                } else {
                    model = nil
                    update(document)
                    return
                }
                error = nil
                metal.setNeedsDisplay(metal.bounds)
            } catch {
                guard let self, !Task.isCancelled, !stopped else { return }
                task = nil
                if model != candidate {
                    model = nil
                    update(document)
                    return
                }
                self.error = EditorErrorPresentation.message(error)
                needsDisplay = true
            }
        }
    }
    func configure(size: CGSize, imageSize: CGSize) {
        if frame.size != size { setFrameSize(size) }
        let rect = CGRect(
            x: (size.width - imageSize.width) / 2, y: (size.height - imageSize.height) / 2,
            width: imageSize.width, height: imageSize.height)
        directionOutline.frame = CGRect(origin: .zero, size: size)
        directionOutline.imageOrigin = rect.origin
        directionOutline.zoom = rect.width / sceneSize.width
        directionOutline.needsDisplay = true
        maskOutline.frame = CGRect(origin: .zero, size: size)
        maskOutline.imageOrigin = rect.origin
        maskOutline.zoom = rect.width / sceneSize.width
        outline.frame = CGRect(origin: .zero, size: size)
        outline.imageOrigin = rect.origin
        outline.zoom = rect.width / sceneSize.width
        guard metal.frame != rect else { return }
        metal.frame = rect
        message.frame = CGRect(
            x: rect.minX + 12, y: rect.minY + 12, width: max(100, min(400, rect.width - 24)),
            height: 80)
        updateRaster()
    }
    override func mouseDown(with event: NSEvent) {
        (enclosingScrollView as? WSSCanvasScrollView)?.beginInteraction(event)
    }
    override func magnify(with event: NSEvent) {
        (enclosingScrollView as? WSSCanvasScrollView)?.magnify(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        (enclosingScrollView as? WSSCanvasScrollView)?.dragInteraction(event)
    }
    override func mouseUp(with event: NSEvent) {
        (enclosingScrollView as? WSSCanvasScrollView)?.endInteraction(event)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseExited(with event: NSEvent) {
        maskCursor = nil
        toolTip = nil
        NSCursor.arrow.set()
    }
    override func mouseMoved(with event: NSEvent) {
        (enclosingScrollView as? WSSCanvasScrollView)?.hover(event)
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateRaster()
    }
    private func updateRaster() {
        let scale = window?.backingScaleFactor ?? 1
        let width = max(1, metal.bounds.width * scale)
        let height = max(1, metal.bounds.height * scale)
        let limit = min(1, 2560 / max(width, height))
        metal.drawableSize = CGSize(width: width * limit, height: height * limit)
        metal.setNeedsDisplay(metal.bounds)
        outline.needsDisplay = true
    }
    func draw(in view: MTKView) {
        guard !stopped, let resources, let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable, let command = resources.queue.makeCommandBuffer()
        else { return }
        do {
            let color = resources.scene.background
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(
                Double(color.x), Double(color.y), Double(color.z), 1)
            try resources.encode(
                command: command, descriptor: descriptor, size: view.drawableSize,
                projection: .fullCanvas)
            if let maskSession, maskSession.overlayAvailable,
                directionOutline.session?.brushEnabled != true
            {
                try maskOverlay?.encode(
                    session: maskSession, scene: sceneSize, command: command, descriptor: descriptor
                )
            }
            command.addCompletedHandler { [resources] _ in _ = resources }
            command.present(drawable)
            command.commit()
        } catch {
            maskSession?.overlayFailed()
            self.error = EditorErrorPresentation.message(error)
            needsDisplay = true
        }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func shutdown() {
        guard !stopped else { return }
        stopped = true
        task?.cancel()
        task = nil
        resources = nil
        resourcesModel = nil
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        if ownsMaskSession {
            maskSession?.cancelStroke()
            maskSession?.canvasOwner = nil
            maskSession?.onChange = nil
        }
        if directionOutline.session?.canvasOwner == maskOwner {
            directionOutline.session?.cancelStroke()
            directionOutline.session?.canvasOwner = nil
            directionOutline.session?.onChange = nil
        }
        directionOutline.session = nil
        maskOutline.session = nil
        maskOverlay = nil
        metal.delegate = nil
        metal.releaseDrawables()
    }
}
@MainActor private final class WSSCanvasOutline: NSView {
    var sceneSize = CGSize.zero
    var imageOrigin = CGPoint.zero
    var zoom: CGFloat = 1
    var transform: WSSImageTransform?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let transform, sceneSize.width > 0 else { return }
        let path = NSBezierPath()
        let corners: [SIMD2<Float>] = [
            SIMD2(-0.5, -0.5), SIMD2(0.5, -0.5), SIMD2(0.5, 0.5), SIMD2(-0.5, 0.5),
        ]
        for (i, corner) in corners.enumerated() {
            let p = WSSCanvasGeometry.viewportPoint(
                transform.point(corner), origin: imageOrigin, zoom: zoom,
                height: sceneSize.height)
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()
        let handles = WSSCanvasInteractionGeometry.handles(
            transform: transform, origin: imageOrigin, zoom: zoom, height: sceneSize.height)
        let stem = NSBezierPath()
        stem.move(
            to: CGPoint(x: (handles[2].x + handles[3].x) / 2, y: (handles[2].y + handles[3].y) / 2))
        stem.line(to: handles[4])
        stem.stroke()
        for (index, point) in handles.enumerated() {
            let rect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            let handle = index == 4 ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
            NSColor.windowBackgroundColor.setFill()
            handle.fill()
            NSColor.controlAccentColor.setStroke()
            handle.stroke()
        }
    }
}

@MainActor private final class WSSCanvasMetalView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
