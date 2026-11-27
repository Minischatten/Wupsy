import MetalKit
import os

@MainActor final class WSSStaticPlayer: NSObject, ScenePlaybackSession, MTKViewDelegate {
    private(set) var resources: WSSStaticResources
    private(set) var view: MTKView
    private(set) lazy var sessionID = UUID()
    private(set) var metrics: SceneMetrics?
    var performanceInvalidated: (() -> Void)?
    private var renderFailed = false

    var rendererStatus: SceneRendererStatus {
        if renderFailed { return .failed }
        if stopped { return .stopped }
        if paused { return .paused }
        return resources.isAnimated ? .running : .onDemand
    }

    @discardableResult
    func startMeasuring() -> SceneMetrics? {
        guard !stopped else { return nil }
        if let metrics { return metrics }
        let collector = SceneMetrics()
        metrics = collector
        return collector
    }

    func stopMeasuring() {
        metrics?.deactivate()
        metrics = nil
        performanceInvalidated?()
    }

    private func resetPerformanceWindow() {
        guard let metrics else { return }
        metrics.resetFrameWindow()
        performanceInvalidated?()
    }

    func performanceSnapshot() -> ScenePerformanceSnapshot? {
        guard let metrics else { return nil }
        return ScenePerformanceSnapshot(
            sessionID: sessionID, status: rendererStatus, targetDrawableSize: view.drawableSize,
            submittedDrawableSize: metrics.submittedDrawableSize, completions: metrics.snapshot(),
            targetFPS: view.preferredFramesPerSecond,
            frameWindow: pauseSettling ? nil : metrics.takeFrameWindow())
    }

    func metalAllocation() -> PerformanceMemory.DeviceAllocation? {
        guard metrics != nil else { return nil }
        return PerformanceMemory.metalAllocation(for: resources.device)
    }
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
    private let desktopPlayback: Bool
    private(set) var desktopFrozen = false
    private var pauseSettling = false
    private var resumeAtFrozenFrame = false
    private(set) var resumeAtEditorStep = false
    private let editorSlotWakeup = OSAllocatedUnfairLock(initialState: false)
    private struct EditorFrameRequest {
        var attemptsRemaining = 3
        var waitingForSlot = false
        var submission: UUID?
    }
    private var editorFrameRequest: EditorFrameRequest?
    var hasPendingEditorFrame: Bool { editorFrameRequest != nil }
    private var hasEditorStep = false
    // Captures the encoded time and optionally reads back the drawable in integration tests.
    var onFrameEncoded: ((Double, MTLCommandBuffer, MTLTexture) -> Void)?
    private var editorDrawTask: Task<Void, Never>?
    private let editorFrameStepping: Bool
    private var editorSurfaceAvailable = true
    private var resumeNeedsTrailAnchor = false
    private var presentationHistory = WSSDesktopFrameHistory()
    private let desktopGPU = OSAllocatedUnfairLock(initialState: (count: 0, draining: false))
    private var settleTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryNeeded = false
    private var recoveryAllowed = true
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
                                : (resources.isAnimated
                                    ? "WSS clouds v1" : "WSS static images")))
    }
    init(
        resources: WSSStaticResources, size: CGSize, scale: CGFloat, maxDimension: Int, fps: Int,
        resolution: SceneRenderResolution, offset: Double,
        projection: WSSRenderProjection = .cover,
        metalView: MTKView? = nil,
        pointerProvider: (() -> SIMD2<Float>?)? = nil,
        desktopPlayback: Bool = false,
        editorFrameStepping: Bool = false,
        onDiagnostic: ((RuntimeDiagnostic) -> Void)? = nil,
        onFirstFramePresented: (@MainActor () -> Void)? = nil, onError: @escaping (String) -> Void
    ) {
        self.resources = resources
        self.projection = projection
        self.pointerProvider = pointerProvider
        self.desktopPlayback = desktopPlayback
        self.editorFrameStepping = editorFrameStepping && !desktopPlayback
        rippleContext = WSSRippleRenderContext(device: resources.device)
        lightingContext = WSSStormLightingRenderContext(device: resources.device)
        self.scale = scale
        self.maxDimension = maxDimension
        self.resolution = resolution
        self.clock = WSSPlaybackClock(offset: offset)
        self.onError = onError
        self.onDiagnostic = onDiagnostic
        self.onFirstFramePresented = onFirstFramePresented
        view =
            metalView
            ?? SceneMetalView(frame: NSRect(origin: .zero, size: size), device: resources.device)
        super.init()
        configureMetalView(fps: fps)
    }

    private func configureMetalView(fps: Int) {
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

    func renewPausedEditorMetalView() {
        // A reparented paused drawable can complete on the GPU but never present.
        // Recreate only the view; the playhead, contexts and resources stay with this player.
        guard editorFrameStepping, paused, !stopped, let surface = view.superview else { return }
        let previous = view
        let fps = previous.preferredFramesPerSecond
        previous.delegate = nil
        (previous as? SceneMetalView)?.geometryChanged = nil
        view = SceneMetalView(frame: previous.frame, device: resources.device)
        configureMetalView(fps: fps)
        surface.addSubview(view, positioned: .above, relativeTo: previous)
        previous.removeFromSuperview()
        previous.releaseDrawables()
        editorFrameRequest = EditorFrameRequest()
        scheduleEditorDraw()
    }

    private var canDrawEditorFrame: Bool {
        guard editorSurfaceAvailable, let window = view.window else { return false }
        return window.isVisible && !window.isMiniaturized && !view.bounds.isEmpty
    }

    var canStepEditorFrame: Bool {
        editorFrameStepping && paused && !stopped && !renderFailed && canDrawEditorFrame
    }

    func stepEditorFrame(to time: Double, resetTrail: Bool) {
        guard editorFrameStepping, paused, !stopped, !renderFailed,
            time.isFinite, time >= 0
        else { return }
        if resetTrail { trailContext.reset() }
        clock.freeze(at: time)
        hasEditorStep = true
        editorFrameRequest = EditorFrameRequest()
        scheduleEditorDraw()
    }

    func setEditorSurfaceAvailable(_ available: Bool) {
        guard editorFrameStepping, available != editorSurfaceAvailable else { return }
        editorSurfaceAvailable = available
        refreshEditorFrame()
    }

    func editorSurfaceRevealed() {
        guard let request = editorFrameRequest,
            request.attemptsRemaining == 0, request.submission == nil
        else { return }
        refreshEditorFrame()
    }

    private func refreshEditorFrame() {
        guard hasEditorStep || editorFrameRequest != nil else { return }
        editorFrameRequest = EditorFrameRequest()
        scheduleEditorDraw()
    }

    private func cancelEditorDraw() {
        editorDrawTask?.cancel()
        editorDrawTask = nil
        editorFrameRequest = nil
        editorSlotWakeup.withLock { $0 = false }
    }

    private func scheduleEditorDraw(delay: Duration = .zero) {
        editorDrawTask?.cancel()
        editorDrawTask = nil
        guard canDrawEditorFrame, let request = editorFrameRequest,
            request.attemptsRemaining > 0, request.submission == nil, !request.waitingForSlot
        else { return }
        editorDrawTask = Task { @MainActor [weak self] in
            if delay != .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            editorDrawTask = nil
            guard canDrawEditorFrame else { return }
            view.draw()
        }
    }

    private func editorFramePresented(_ id: UUID, at time: Double) {
        guard editorFrameRequest?.submission == id else { return }
        if time.isFinite, time > 0 {
            cancelEditorDraw()
        } else {
            editorFrameRequest?.submission = nil
            scheduleEditorDraw(delay: .milliseconds(30))
        }
    }

    private func watchEditorPresentation(_ id: UUID) {
        editorDrawTask?.cancel()
        editorDrawTask = Task { @MainActor [weak self] in
            // Some invalidated drawables never call their presentation handler.
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, editorFrameRequest?.submission == id else { return }
            editorDrawTask = nil
            editorFramePresented(id, at: 0)
        }
    }

    private func editorDrawableUnavailable() {
        guard editorFrameRequest != nil else { return }
        editorFrameRequest?.attemptsRemaining -= 1
        scheduleEditorDraw(delay: .milliseconds(30))
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
            if editorFrameRequest != nil {
                refreshEditorFrame()
            } else {
                view.draw()
            }
        }
    }

    @discardableResult
    func updateTransforms(_ candidate: WSSStaticResources) -> Bool {
        guard !stopped, resources.sharesPreparedResources(with: candidate) else { return false }
        fogDragPreview = nil
        if resources !== candidate { resetPerformanceWindow() }
        resources = candidate
        if !resources.scene.hasEffectiveStormIllumination { lightingContext.discardResources() }
        if !paused {
            let onDemand = !resources.isAnimated
            if view.enableSetNeedsDisplay != onDemand { view.enableSetNeedsDisplay = onDemand }
            if view.isPaused != onDemand { view.isPaused = onDemand }
        }
        view.needsDisplay = true
        if editorFrameRequest != nil {
            refreshEditorFrame()
        } else if view.isPaused {
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
    func play() { play(fromEditorStep: false) }

    func play(fromEditorStep: Bool) {
        guard !stopped else { return }
        cancelEditorDraw()
        hasEditorStep = false
        resumeAtEditorStep = fromEditorStep && editorFrameStepping
        let wasPaused = paused
        paused = false
        if desktopFrozen {
            finishDesktopPause()
            desktopFrozen = false
            cancelRecovery()
            presentationHistory.discardPending()
            resumeAtFrozenFrame = true
            resumeNeedsTrailAnchor = true
        } else {
            trailContext.reset()
            if !resumeAtEditorStep { clock.play(now: ProcessInfo.processInfo.systemUptime) }
        }
        if wasPaused { resetPerformanceWindow() }
        let onDemand = !resources.isAnimated
        view.enableSetNeedsDisplay = onDemand
        view.isPaused = onDemand
        view.needsDisplay = true
        if resumeAtEditorStep, onDemand {
            editorFrameRequest = EditorFrameRequest()
            scheduleEditorDraw()
        }
        if resumeAtFrozenFrame {
            Task { @MainActor [weak self] in
                guard let self, !stopped, !desktopFrozen, resumeAtFrozenFrame,
                    view.window?.isVisible == true
                else { return }
                view.draw()
            }
        }
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
        resetPerformanceWindow()
        paused = true
        resumeAtEditorStep = false
        cancelEditorDraw()
        clock.stop(now: ProcessInfo.processInfo.systemUptime)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.needsDisplay = true
    }
    func pauseDesktop() {
        guard desktopPlayback, !stopped, !desktopFrozen else { return }
        desktopFrozen = true
        paused = true
        resumeAtFrozenFrame = false
        clock.freeze(at: presentationHistory.confirmed?.time ?? elapsed)
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        pauseSettling = true
        let gpuIdle = desktopGPU.withLock { state in
            state.draining = true
            return state.count == 0
        }
        if gpuIdle, !presentationHistory.hasPending {
            finishDesktopPause()
        } else {
            // Hidden or invalidated drawables need not report presentation.
            settleTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self else { return }
                presentationHistory.discardPending()
                settleDesktopPauseIfReady()
            }
        }
        performanceInvalidated?()
    }

    private func finishDesktopPause() {
        guard pauseSettling else { return }
        pauseSettling = false
        desktopGPU.withLock { $0.draining = false }
        settleTask?.cancel()
        settleTask = nil
        presentationHistory.discardPending()
        if let frame = presentationHistory.confirmed {
            clock.freeze(at: frame.time)
            if let trail = frame.trail { trailContext.restore(trail) }
        }
        resetPerformanceWindow()
        scheduleRecovery()
    }

    private func settleDesktopPauseIfReady() {
        if pauseSettling, !presentationHistory.hasPending,
            desktopGPU.withLock({ $0.count == 0 })
        {
            finishDesktopPause()
        }
    }

    private func desktopFramePresented(_ id: UInt64, at hostTime: Double) {
        guard !stopped else { return }
        if presentationHistory.presented(id, at: hostTime) { confirmFirstPresentation() }
        settleDesktopPauseIfReady()
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
        hasEditorStep = false
        cancelEditorDraw()
        onFrameEncoded = nil
        cancelRecovery()
        settleTask?.cancel()
        settleTask = nil
        presentationHistory = WSSDesktopFrameHistory()
        trailContext.reset()
        stormContext.reset()
        lightingContext.discardResources()
        clock.stop(now: ProcessInfo.processInfo.systemUptime)
        stopped = true
        stopMeasuring()
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
        resetPerformanceWindow()
        self.maxDimension = maxDimension
        self.projection = projection
        view.preferredFramesPerSecond = fps
        setRenderResolution(resolution)
        view.needsDisplay = true
    }
    func setDesktopSurfaceAvailable(_ available: Bool) {
        recoveryAllowed = available
        if available {
            scheduleRecovery()
        } else {
            recoveryTask?.cancel()
            recoveryTask = nil
        }
    }

    func requestDesktopRecovery() {
        guard desktopFrozen, !stopped else { return }
        recoveryNeeded = true
        scheduleRecovery()
    }

    func desktopVisibilityChanged() { scheduleRecovery() }

    func desktopGeometryChanged() { resize() }

    private func cancelRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryNeeded = false
    }

    private func scheduleRecovery() {
        guard recoveryNeeded, recoveryAllowed, desktopFrozen, !stopped, !pauseSettling,
            recoveryTask == nil, view.window?.isVisible == true
        else { return }
        recoveryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(35)) } catch { return }
            guard let self else { return }
            recoveryTask = nil
            guard desktopFrozen, !stopped, recoveryAllowed,
                view.window?.isVisible == true
            else { return }
            recoveryNeeded = !drawFrame(recovery: true)
        }
    }

    private func desiredDrawableSize() -> CGSize {
        let bounds = view.bounds.size
        let backing =
            view.window != nil
            ? view.convertToBacking(view.bounds).size
            : CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return resolution.drawableSize(bounds: bounds, backing: backing, maxDimension: maxDimension)
    }

    private func resize(recovery: Bool = false) {
        guard !stopped else { return }
        let size = desiredDrawableSize()
        guard size != view.drawableSize else { return }
        if desktopFrozen, !recovery {
            requestDesktopRecovery()
            return
        }
        resetPerformanceWindow()
        view.drawableSize = size
        if !recovery {
            view.needsDisplay = true
            refreshEditorFrame()
        }
    }
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    nonisolated func draw(in view: MTKView) { MainActor.assumeIsolated { _ = drawFrame() } }
    private func drawFrame(recovery: Bool = false) -> Bool {
        guard !stopped, desktopFrozen == recovery else { return false }
        resize(recovery: recovery)
        if let request = editorFrameRequest {
            guard canDrawEditorFrame, request.attemptsRemaining > 0,
                request.submission == nil, !request.waitingForSlot
            else { return false }
        }
        if editorFrameRequest != nil { editorSlotWakeup.withLock { $0 = true } }
        guard inFlight.wait(timeout: .now()) == .success else {
            editorFrameRequest?.waitingForSlot = true
            return false
        }
        if editorFrameRequest != nil { editorSlotWakeup.withLock { $0 = false } }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
            let command = resources.queue.makeCommandBuffer()
        else {
            inFlight.signal()
            editorDrawableUnavailable()
            return false
        }
        let frameResources = fogDragPreview ?? resources
        let background = frameResources.scene.background
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(
            Double(background.x), Double(background.y), Double(background.z), 1)
        pass.colorAttachments[0].storeAction = .store
        let firstResumeFrame = resumeAtFrozenFrame
        let time = elapsed
        let pointer = resources.trail == nil || paused ? nil : currentPointer()
        if resumeNeedsTrailAnchor, !paused {
            trailContext.rebase(time: time, pointer: pointer)
            resumeNeedsTrailAnchor = false
        }
        let metrics = metrics
        let encoding = metrics?.beginEncoding()
        do {
            try frameResources.encode(
                command: command, descriptor: pass, size: view.drawableSize, time: time,
                rippleContext: rippleContext, trailContext: trailContext,
                pointer: pointer,
                projection: projection,
                advanceTrail: !paused && !firstResumeFrame,
                stormContext: stormContext,
                lightingContext: lightingContext)
        } catch {
            inFlight.signal()
            renderFailed = true
            stop()
            onError(error.localizedDescription)
            return false
        }
        onFrameEncoded?(time, command, drawable.texture)
        if firstResumeFrame || resumeAtEditorStep {
            resumeAtFrozenFrame = false
            resumeAtEditorStep = false
            cancelEditorDraw()
            clock.play(now: ProcessInfo.processInfo.systemUptime)
        }
        if let encoding { metrics?.encoded(encoding) }
        let desktopFrameID: UInt64?
        if desktopPlayback && !recovery {
            desktopFrameID = presentationHistory.submit(
                .init(
                    time: time, trail: frameResources.trail == nil ? nil : trailContext.snapshot()))
        } else {
            desktopFrameID = nil
        }
        if desktopPlayback { desktopGPU.withLock { $0.count += 1 } }
        let semaphore = inFlight
        let retryTransitionFrame =
            !recovery && transitionStillPending && !resources.isAnimated
            && transitionDrawRetries > 0
        if retryTransitionFrame { transitionDrawRetries -= 1 }
        let complete = frameCompletionHandler(
            retryTransitionFrame: retryTransitionFrame, encoding: encoding
        ) {
            semaphore.signal()
        }
        let desktopGPU = desktopGPU
        let tracksGPU = desktopPlayback
        let slotWakeup = editorFrameStepping ? editorSlotWakeup : nil
        command.addCompletedHandler { [weak self, frameResources] buffer in
            _ = frameResources  // Retain the immutable scene/resources through GPU completion.
            complete(buffer)
            if slotWakeup?.withLock({ waiting in
                let notify = waiting
                waiting = false
                return notify
            }) == true {
                Task { @MainActor [weak self] in
                    guard let self, editorFrameRequest?.waitingForSlot == true else { return }
                    editorFrameRequest?.waitingForSlot = false
                    scheduleEditorDraw()
                }
            }
            if tracksGPU {
                let drained = desktopGPU.withLock { state in
                    state.count -= 1
                    return state.draining && state.count == 0
                }
                if drained {
                    Task { @MainActor [weak self] in self?.settleDesktopPauseIfReady() }
                }
            }
        }
        if let desktopFrameID {
            drawable.addPresentedHandler { [weak self] drawable in
                let time = drawable.presentedTime
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    desktopFramePresented(desktopFrameID, at: time)
                }
            }
        } else if !recovery, onFirstFramePresented != nil {
            drawable.addPresentedHandler { [weak self] drawable in
                self?.receivePresentation(at: drawable.presentedTime)
            }
        }
        if let metrics, let encoding {
            if recovery {
                let delivered = OSAllocatedUnfairLock(initialState: false)
                let record: @Sendable (Double) -> Void = { [weak metrics] time in
                    let first = delivered.withLock { recorded in
                        defer { recorded = true }
                        return !recorded
                    }
                    if first { metrics?.presented(encoding, at: time) }
                }
                drawable.addPresentedHandler { record($0.presentedTime) }
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    record(0)
                }
            } else {
                drawable.addPresentedHandler { [weak metrics] drawable in
                    metrics?.presented(encoding, at: drawable.presentedTime)
                }
            }
        }
        if paused, editorFrameRequest != nil {
            let id = UUID()
            editorFrameRequest?.attemptsRemaining -= 1
            editorFrameRequest?.submission = id
            drawable.addPresentedHandler { [weak self] drawable in
                let time = drawable.presentedTime
                Task { @MainActor [weak self] in self?.editorFramePresented(id, at: time) }
            }
            watchEditorPresentation(id)
        }
        command.present(drawable)
        command.commit()
        if let metrics {
            metrics.submitted(width: drawable.texture.width, height: drawable.texture.height)
        }
        return true
    }

    func frameCompletionHandler(
        retryTransitionFrame: Bool, encoding: SceneMetrics.Encoding? = nil,
        releaseSlot: @escaping @Sendable () -> Void
    ) -> @Sendable (MTLCommandBuffer) -> Void {
        let metrics = metrics
        return { [weak self, weak metrics] buffer in
            metrics?.completed(buffer, encoding: encoding)
            releaseSlot()
            if buffer.status == .error {
                Task { @MainActor in
                    guard let self, !self.stopped else { return }
                    self.resetPerformanceWindow()
                    self.renderFailed = true
                    if let onDiagnostic = self.onDiagnostic {
                        onDiagnostic(.wssGPU)
                    } else {
                        self.onError(RuntimeDiagnostic.wssGPU.technicalDescription)
                    }
                }
            } else if retryTransitionFrame {
                Task { @MainActor in
                    guard let self, !self.stopped, !self.desktopFrozen, self.transitionStillPending
                    else { return }
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
            self?.confirmFirstPresentation()
        }
    }

    private func confirmFirstPresentation() {
        guard !stopped else { return }
        let callback = onFirstFramePresented
        onFirstFramePresented = nil
        transitionStillPending = false
        callback?()
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
                throw WSSSceneError.metalUnavailable
            }
            return try WSSStaticResources.prepareWallpaper(
                scene: document.scene(), assets: document.assetSource(root: root), device: device)
        }
        throw SceneError.unsupported("Only native Wupsy projects can be played")
    }

}
