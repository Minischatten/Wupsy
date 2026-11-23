import MetalKit

@MainActor final class WSSStaticPlayer: NSObject, ScenePlaybackSession, MTKViewDelegate {
    private(set) var resources: WSSStaticResources
    let view: MTKView
    let metrics = SceneMetrics()
    let trailContext = WSSTrailRenderContext()
    let stormContext = WSSStormRenderContext()
    let lightingContext: WSSStormLightingRenderContext
    let rippleContext: WSSRippleRenderContext
    private var clock: WSSPlaybackClock
    private let scale: CGFloat
    private var maxDimension: Int
    private(set) var resolution: SceneRenderResolution
    private var stopped = false
    private var paused = true
    private let pointerProvider: (() -> SIMD2<Float>?)?
    private var projection: WSSRenderProjection
    private let inFlight = DispatchSemaphore(value: 2)
    private let onError: (String) -> Void
    private let onDiagnostic: ((RuntimeDiagnostic) -> Void)?
    private var onFirstFramePresented: (@MainActor () -> Void)?
    private var transitionStillPending = false
    private var transitionDrawRetries = 2
    var elapsed: Double { clock.time(now: ProcessInfo.processInfo.systemUptime) }
    var diagnostics: ScenePlaybackDiagnostics {
        ScenePlaybackDiagnostics(
            sourceWidth: resources.scene.width, sourceHeight: resources.scene.height,
            textureBytes: resources.textureBytes,
            intermediateTextureBytes: rippleContext.textureBytes + lightingContext.textureBytes,
            deviceName: resources.device.name,
            shader: resources.storm != nil
                ? "WSS storm v1"
                : resources.flow != nil
                    ? "WSS flow v1"
                    : resources.rain != nil
                        ? "WSS rain v1"
                        : (resources.ripple != nil
                            ? "WSS ripple v1"
                            : resources.fog != nil
                                ? "WSS fog v1"
                                : (resources.scene.isAnimated
                                    ? "WSS clouds v1" : "WSS static images")))
    }
    init(
        resources: WSSStaticResources, size: CGSize, scale: CGFloat, maxDimension: Int, fps: Int,
        resolution: SceneRenderResolution, offset: Double,
        projection: WSSRenderProjection = .cover,
        pointerProvider: (() -> SIMD2<Float>?)? = nil,
        onDiagnostic: ((RuntimeDiagnostic) -> Void)? = nil,
        onFirstFramePresented: (@MainActor () -> Void)? = nil, onError: @escaping (String) -> Void
    ) {
        self.resources = resources
        self.projection = projection
        self.pointerProvider = pointerProvider
        rippleContext = WSSRippleRenderContext(device: resources.device)
        lightingContext = WSSStormLightingRenderContext(device: resources.device)
        self.scale = scale
        self.maxDimension = maxDimension
        self.resolution = resolution
        self.clock = WSSPlaybackClock(offset: offset)
        self.onError = onError
        self.onDiagnostic = onDiagnostic
        self.onFirstFramePresented = onFirstFramePresented
        view = SceneMetalView(frame: NSRect(origin: .zero, size: size), device: resources.device)
        super.init()
        view.colorPixelFormat = .bgra8Unorm
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.preferredFramesPerSecond = fps
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = self
        (view as? SceneMetalView)?.geometryChanged = { [weak self] in self?.resize() }
        resize()
    }
    private(set) var fogDragPreview: WSSStaticResources?
    private var fogDragRedrawPending = false

    func updateFogDragPreview(_ candidate: WSSStaticResources?) {
        guard !stopped, candidate?.sharesPreparedResources(with: resources) ?? true else { return }
        fogDragPreview = candidate
        // A running view picks up the newest value at its normal draw cadence.
        // Paused/on-demand previews need one explicit redraw after input returns.
        guard view.isPaused, !fogDragRedrawPending else { return }
        fogDragRedrawPending = true
        Task { @MainActor [weak self] in
            // Match normal editor preview cadence without delaying the input.
            try? await Task.sleep(for: .milliseconds(33))
            guard let self else { return }
            fogDragRedrawPending = false
            guard !stopped, view.isPaused, view.window?.isVisible == true, !view.bounds.isEmpty
            else { return }
            view.draw()
        }
    }

    @discardableResult
    func updateTransforms(_ candidate: WSSStaticResources) -> Bool {
        guard !stopped, resources.sharesPreparedResources(with: candidate) else { return false }
        fogDragPreview = nil
        resources = candidate
        if !resources.scene.hasEffectiveStormIllumination { lightingContext.discardResources() }
        if !paused {
            let onDemand = !resources.scene.isAnimated
            if view.enableSetNeedsDisplay != onDemand { view.enableSetNeedsDisplay = onDemand }
            if view.isPaused != onDemand { view.isPaused = onDemand }
        }
        view.needsDisplay = true
        if view.isPaused {
            // AppKit invalidation alone can stop delivering MTKView draw callbacks.
            // Leave the current SwiftUI update before asking for a frame explicitly.
            Task { @MainActor [weak self, weak candidate] in
                guard let self, let candidate, !stopped, resources === candidate,
                    view.isPaused, view.window?.isVisible == true, !view.bounds.isEmpty
                else { return }
                view.draw()
            }
        }
        return true
    }
    func play() {
        guard !stopped else { return }
        paused = false
        trailContext.reset()
        clock.play(now: ProcessInfo.processInfo.systemUptime)
        let onDemand = !resources.scene.isAnimated
        view.enableSetNeedsDisplay = onDemand
        view.isPaused = onDemand
        view.needsDisplay = true
    }
    func playFromStill() {
        // The still protects the first visible frame. An occluded desktop
        // drawable may never report presentation even after GPU completion.
        // Presentation must not hold the animation clock or draw loop.
        transitionStillPending = true
        play()
    }
    func pause() {
        guard !stopped, !paused else { return }
        paused = true
        clock.stop(now: ProcessInfo.processInfo.systemUptime)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.needsDisplay = true
    }
    func currentPointer() -> SIMD2<Float>? {
        if let pointerProvider { return pointerProvider() }
        return view.window?.screen.flatMap { screen in
            SceneCursor.scenePoint(
                global: NSEvent.mouseLocation, screen: screen.frame,
                canvas: CGSize(width: resources.scene.width, height: resources.scene.height))
        }
    }
    func stop() {
        trailContext.reset()
        stormContext.reset()
        lightingContext.discardResources()
        clock.stop(now: ProcessInfo.processInfo.systemUptime)
        stopped = true
        onFirstFramePresented = nil
        view.isPaused = true
        view.delegate = nil
        (view as? SceneMetalView)?.geometryChanged = nil
        view.releaseDrawables()
    }
    func setRenderResolution(_ resolution: SceneRenderResolution) {
        self.resolution = resolution
        resize()
    }
    // Presentation changes reuse the scene, clock and GPU contexts.
    func configurePreview(
        maxDimension: Int, fps: Int, resolution: SceneRenderResolution,
        projection: WSSRenderProjection
    ) {
        guard !stopped else { return }
        self.maxDimension = maxDimension
        self.projection = projection
        view.preferredFramesPerSecond = fps
        setRenderResolution(resolution)
        view.needsDisplay = true
    }
    private func resize() {
        guard !stopped else { return }
        let bounds = view.bounds.size
        let backing =
            view.window != nil
            ? view.convertToBacking(view.bounds).size
            : CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let size = resolution.drawableSize(
            bounds: bounds, backing: backing, maxDimension: maxDimension)
        guard size != view.drawableSize else { return }
        view.drawableSize = size
        view.needsDisplay = true
    }
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    nonisolated func draw(in view: MTKView) { MainActor.assumeIsolated { drawFrame() } }
    private func drawFrame() {
        resize()
        guard !stopped, inFlight.wait(timeout: .now()) == .success else { return }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
            let command = resources.queue.makeCommandBuffer()
        else {
            inFlight.signal()
            return
        }
        let frameResources = fogDragPreview ?? resources
        let background = frameResources.scene.background
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(
            Double(background.x), Double(background.y), Double(background.z), 1)
        pass.colorAttachments[0].storeAction = .store
        do {
            try frameResources.encode(
                command: command, descriptor: pass, size: view.drawableSize, time: elapsed,
                rippleContext: rippleContext, trailContext: trailContext,
                pointer: resources.trail == nil || paused
                    ? nil : currentPointer(),
                projection: projection, advanceTrail: !paused,
                stormContext: stormContext,
                lightingContext: lightingContext)
        } catch {
            inFlight.signal()
            stop()
            onError(error.localizedDescription)
            return
        }
        let semaphore = inFlight
        let retryTransitionFrame =
            transitionStillPending && !resources.scene.isAnimated && transitionDrawRetries > 0
        if retryTransitionFrame { transitionDrawRetries -= 1 }
        let complete = frameCompletionHandler(retryTransitionFrame: retryTransitionFrame) {
            semaphore.signal()
        }
        command.addCompletedHandler { [frameResources] buffer in
            _ = frameResources  // Retain the immutable scene/resources through GPU completion.
            complete(buffer)
        }
        if onFirstFramePresented != nil {
            drawable.addPresentedHandler { [weak self] drawable in
                self?.receivePresentation(at: drawable.presentedTime)
            }
        }
        command.present(drawable)
        command.commit()
    }

    func frameCompletionHandler(
        retryTransitionFrame: Bool, releaseSlot: @escaping @Sendable () -> Void
    ) -> @Sendable (MTLCommandBuffer) -> Void {
        let metrics = metrics
        return { [weak self] buffer in
            metrics.completed(buffer)
            releaseSlot()
            if buffer.status == .error {
                Task { @MainActor in
                    guard let self, !self.stopped else { return }
                    if let onDiagnostic = self.onDiagnostic {
                        onDiagnostic(.wssGPU)
                    } else {
                        self.onError(RuntimeDiagnostic.wssGPU.technicalDescription)
                    }
                }
            } else if retryTransitionFrame {
                Task { @MainActor in
                    guard let self, !self.stopped, self.transitionStillPending else { return }
                    self.view.draw()
                }
            }
        }
    }

    @discardableResult
    nonisolated func receivePresentation(at presentedTime: CFTimeInterval) -> Task<Void, Never>? {
        // Zero also covers dropped frames. GPU completion alone is insufficient.
        guard presentedTime > 0 else { return nil }
        return Task { @MainActor [weak self] in
            guard let self, !stopped else { return }
            let callback = onFirstFramePresented
            onFirstFramePresented = nil
            transitionStillPending = false
            callback?()
        }
    }
}

// Preparation has its own resource path and no compatibility cache or external provider.
actor WSSStaticPreparation {
    static let shared = WSSStaticPreparation()
    func renderDesktopFrame(_ resources: WSSStaticResources, size: CGSize) throws -> NSImage {
        try Task.checkCancellation()
        return try WSSLibraryThumbnail.renderFrame(
            resources, width: Int(size.width), height: Int(size.height), projection: .cover)
    }

    func prepare(_ wallpaper: Wallpaper) async throws -> WSSStaticResources {
        if wallpaper.sceneSource == .nativeWSS {
            let root = URL(fileURLWithPath: wallpaper.root)
            let document = try WSSSceneDocumentV1.load(entry: wallpaper.url, root: root)
            try Task.checkCancellation()
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw WSSSceneError.invalid("Metal unavailable")
            }
            return try WSSStaticResources(
                scene: document.scene(), assets: document.assetSource(root: root), device: device)
        }
        throw SceneError.unsupported("Only native Wupsy projects can be played")
    }

}
