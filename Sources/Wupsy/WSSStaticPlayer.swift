import MetalKit

@MainActor final class WSSStaticPlayer: NSObject, ScenePlaybackSession, MTKViewDelegate {
    private(set) var resources: WSSStaticResources
    let view: MTKView
    let metrics = SceneMetrics()
    let trailContext = WSSTrailRenderContext()
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
    var elapsed: Double { clock.time(now: ProcessInfo.processInfo.systemUptime) }
    var diagnostics: ScenePlaybackDiagnostics {
        ScenePlaybackDiagnostics(
            sourceWidth: resources.scene.width, sourceHeight: resources.scene.height,
            textureBytes: resources.textureBytes,
            intermediateTextureBytes: rippleContext.textureBytes,
            deviceName: resources.device.name,
            shader: resources.flow != nil
                ? "WSS flow v1"
                : resources.rain != nil
                    ? "WSS rain v1"
                    : (resources.ripple != nil
                        ? "WSS ripple v1"
                        : (resources.scene.isAnimated ? "WSS clouds v1" : "WSS static images")))
    }
    init(
        resources: WSSStaticResources, size: CGSize, scale: CGFloat, maxDimension: Int, fps: Int,
        resolution: SceneRenderResolution, offset: Double,
        projection: WSSRenderProjection = .cover,
        pointerProvider: (() -> SIMD2<Float>?)? = nil,
        onDiagnostic: ((RuntimeDiagnostic) -> Void)? = nil, onError: @escaping (String) -> Void
    ) {
        self.resources = resources
        self.projection = projection
        self.pointerProvider = pointerProvider
        rippleContext = WSSRippleRenderContext(device: resources.device)
        self.scale = scale
        self.maxDimension = maxDimension
        self.resolution = resolution
        self.clock = WSSPlaybackClock(offset: offset)
        self.onError = onError
        self.onDiagnostic = onDiagnostic
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
    @discardableResult
    func updateTransforms(_ candidate: WSSStaticResources) -> Bool {
        guard !stopped, resources.sharesPreparedResources(with: candidate) else { return false }
        resources = candidate
        view.needsDisplay = true
        return true
    }
    func play() {
        guard !stopped else { return }
        paused = false
        trailContext.reset()
        clock.play(now: ProcessInfo.processInfo.systemUptime)
        view.enableSetNeedsDisplay = !resources.scene.isAnimated
        view.isPaused = !resources.scene.isAnimated
        view.needsDisplay = true
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
        clock.stop(now: ProcessInfo.processInfo.systemUptime)
        stopped = true
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
        let frameResources = resources
        let background = frameResources.scene.background
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(
            Double(background.x), Double(background.y), Double(background.z), 1)
        pass.colorAttachments[0].storeAction = .store
        do {
            try frameResources.encode(
                command: command, descriptor: pass, size: view.drawableSize, time: elapsed,
                rippleContext: rippleContext, trailContext: trailContext,
                pointer: resources.trail == nil || paused ? nil : currentPointer(),
                projection: projection, advanceTrail: !paused)
        } catch {
            inFlight.signal()
            stop()
            onError(error.localizedDescription)
            return
        }
        let semaphore = inFlight
        let metrics = metrics
        command.addCompletedHandler { [weak self, frameResources] buffer in
            _ = frameResources  // Retain the immutable scene/resources through GPU completion.
            metrics.completed(buffer)
            semaphore.signal()
            if buffer.status == .error {
                Task { @MainActor in
                    guard let self, !self.stopped else { return }
                    if let onDiagnostic = self.onDiagnostic {
                        onDiagnostic(.wssGPU)
                    } else {
                        self.onError(RuntimeDiagnostic.wssGPU.technicalDescription)
                    }
                }
            }
        }
        command.present(drawable)
        command.commit()
    }
}

// Preparation has its own resource path and no compatibility cache or external provider.
actor WSSStaticPreparation {
    static let shared = WSSStaticPreparation()
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
