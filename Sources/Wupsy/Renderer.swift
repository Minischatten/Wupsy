import AVFoundation
import AppKit
import WebKit

final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class VideoView: NSView {
    let video = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(video)
        video.videoGravity = .resizeAspectFill
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.frame = bounds
        CATransaction.commit()
    }
}
enum RendererReadiness: Equatable {
    case ready
    case failed(RuntimeDiagnostic)
    case cancelled
    case unsupported
}

@MainActor final class Renderer: NSObject, WKNavigationDelegate {
    private(set) var screen: NSScreen
    var desktopSlotID: DesktopPerformancePanel.DisplayID
    let wallpaper: Wallpaper
    let window: DesktopWindow
    let mediaURL: URL
    let profile: QualityProfile
    private let maintenance: MaintenanceCoordinator
    private let imagePixelLimit: Int
    private(set) var player: AVQueuePlayer?
    private(set) var looper: AVPlayerLooper?
    private(set) var web: WKWebView?
    private(set) var gif: GIFPlayer?
    private(set) var scene: (any ScenePlaybackSession)? {
        didSet { performanceSceneChanged?() }
    }
    var performanceSceneChanged: (() -> Void)?
    private(set) var occlusionNotificationCount = 0
    var measuresPerformance = false {
        didSet {
            if measuresPerformance {
                scene?.startMeasuring()
            } else {
                scene?.stopMeasuring()
            }
        }
    }
    private var preparedScene: PreparedScenePlayback?
    private var sceneTime = 0.0
    private var sceneRenderResolution: SceneRenderResolution
    private let sceneFPS: Int
    private let displayScale: CGFloat
    private(set) var paused = true
    private(set) var stopped = false
    private var presentationDeferred = false
    private var transitionPrepared = false
    private var transitionStill: NSImage?
    private weak var transitionStillView: NSImageView?
    var hasTransitionStill: Bool { transitionStill != nil }
    private var resumeTime = CMTime.zero
    private let runtimeTasks = RuntimeTaskDrain()
    private var imageTask: Task<Void, Never>? {
        didSet { if let imageTask { runtimeTasks.track(imageTask) } }
    }
    private var onError: ((String) -> Void)?
    private var observation: NSKeyValueObservation?
    private var healthTimer: Timer?
    private var health = VideoHealth()
    private var onEvent: ((RuntimeDiagnostic) -> Void)?
    private var onDiagnostic: ((RuntimeDiagnostic) -> Void)?
    private var onReadiness: ((RendererReadiness) -> Void)?
    var hasLiveResources: Bool {
        player != nil || web != nil || gif != nil || scene != nil || preparedScene != nil
            || window.contentView != nil
    }
    init(
        maintenance: MaintenanceCoordinator? = nil,
        wallpaper: Wallpaper, screen: NSScreen, mediaURL: URL? = nil,
        profile: QualityProfile = .balanced, initiallyPaused: Bool = false,
        scenePlayback: PreparedScenePlayback? = nil, sceneFPS: Int = 30,
        sceneRenderResolution: SceneRenderResolution = .hiDPI,
        onEvent: ((RuntimeDiagnostic) -> Void)? = nil,
        onDiagnostic: ((RuntimeDiagnostic) -> Void)? = nil,
        onReadiness: ((RendererReadiness) -> Void)? = nil, onError: @escaping (String) -> Void
    ) {
        self.desktopSlotID = DesktopPerformancePanel.DisplayID(screen)
        self.maintenance = maintenance ?? .shared
        self.preparedScene = scenePlayback
        self.sceneRenderResolution = sceneRenderResolution
        self.sceneFPS = sceneFPS
        self.displayScale = screen.backingScaleFactor
        self.screen = screen
        self.wallpaper = wallpaper
        self.mediaURL = mediaURL ?? wallpaper.url
        self.profile = profile
        self.onError = onError
        self.onEvent = onEvent
        self.onDiagnostic = onDiagnostic
        self.onReadiness = onReadiness
        imagePixelLimit = min(
            profile.maxDimension,
            Int(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor))
        window = DesktopWindow(
            contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.backgroundColor = .black
        window.contentView = nil
        window.setFrame(screen.frame, display: true)
        NotificationCenter.default.addObserver(
            self, selector: #selector(desktopOcclusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
        if !initiallyPaused { setPaused(false) }
    }
    private func report(_ diagnostic: RuntimeDiagnostic) {
        if let transitionStill {
            scene?.stop()
            scene = nil
            window.contentView = imageView(transitionStill, scaling: .scaleAxesIndependently)
        }
        finishReadiness(.failed(diagnostic))
        if let onDiagnostic {
            onDiagnostic(diagnostic)
        } else {
            onError?(diagnostic.technicalDescription)
        }
    }
    // One result for this renderer's first start. An occluded scene may stay pending
    // until it presents or its owner pauses or stops it. No task waits for a drawable.
    private func finishReadiness(_ result: RendererReadiness) {
        let callback = onReadiness
        onReadiness = nil
        callback?(result)
    }

    private func load() {
        guard !stopped, maintenance.allowsMutation else {
            finishReadiness(.cancelled)
            return
        }
        switch wallpaper.kind {
        case .video:
            let view = VideoView(frame: NSRect(origin: .zero, size: window.frame.size))
            let player = AVQueuePlayer()
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            let item = AVPlayerItem(url: mediaURL)
            item.preferredForwardBufferDuration = 1
            let looper = AVPlayerLooper(player: player, templateItem: item)
            self.looper = looper
            observation = looper.observe(\.status, options: [.new]) { [weak self] looper, _ in
                if looper.status == .failed { Task { @MainActor in self?.checkVideoHealth() } }
            }
            self.player = player
            view.video.player = player
            window.contentView = view
            // A new paused slot needs a frame without starting the playback clock.
            if paused {
                player.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero)
            } else if resumeTime > .zero {
                player.seek(
                    to: resumeTime, toleranceBefore: CMTime(seconds: 0.2, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.2, preferredTimescale: 600))
            }
            if !paused { playVideo(player) }
        case .image:
            let view = NSImageView(frame: NSRect(origin: .zero, size: window.frame.size))
            view.imageScaling = .scaleProportionallyUpOrDown
            window.contentView = view
            imageTask = Task { [weak self, weak view] in
                guard let self else { return }
                let image = await ImageLoader.shared.image(wallpaper.url, maxPixel: imagePixelLimit)
                guard !Task.isCancelled, let view, window.contentView === view else {
                    return
                }
                guard let image else {
                    report(.imageDecode)
                    return
                }
                view.image = image
                finishReadiness(.ready)
            }
        case .scene:
            // Both pre-prepared and resumed scenes use the same WSS-only boundary.
            do { try ScenePlayback.requireAvailableBackend(for: wallpaper) } catch {
                preparedScene = nil
                report(.capturing(error))
                return
            }
            if let resources = preparedScene {
                preparedScene = nil
                do { try resources.validate(for: wallpaper) } catch {
                    report(.capturing(error))
                    return
                }
                installScene(resources)
            } else {
                guard let admission = try? maintenance.beginMutation(kind: .runtime) else {
                    finishReadiness(.cancelled)
                    return
                }
                imageTask = Task { [weak self] in
                    defer { admission.finish() }
                    await MaintenanceOperation.$id.withValue(admission.id) {
                        guard let wallpaper = self?.wallpaper else { return }
                        do {
                            let resources = try await ScenePlayback.prepare(for: wallpaper)
                            guard let self, !Task.isCancelled, !self.paused else { return }
                            self.installScene(resources)
                        } catch {
                            if !Task.isCancelled {
                                self?.report(.capturing(error))
                            }
                        }
                    }
                }
            }
        case .web:
            if wallpaper.url.pathExtension.lowercased() == "gif" {
                do {
                    let animation = try GIFPlayer(
                        url: wallpaper.url, size: window.frame.size, maxPixel: imagePixelLimit,
                        fps: profile.fps)
                    gif = animation
                    window.contentView = animation.view
                    if paused { animation.pause() } else { animation.play() }
                } catch { report(.capturing(error)) }
            } else {
                loadWeb()
            }
        }
        if !stopped && !paused && !presentationDeferred { window.orderBack(nil) }
        if wallpaper.kind != .image && wallpaper.kind != .scene { finishReadiness(.unsupported) }
    }
    // Refresh candidates load through the normal player path while the old window
    // remains visible. Showing the candidate is a separate, synchronous handoff.
    func deferPresentation() { presentationDeferred = true }
    func presentPreparedContent() {
        presentationDeferred = false
        if !paused && !stopped { window.orderBack(nil) }
    }

    private func imageView(_ image: NSImage, scaling: NSImageScaling) -> NSImageView {
        let view = NSImageView(frame: NSRect(origin: .zero, size: window.frame.size))
        view.autoresizingMask = [.width, .height]
        view.imageScaling = scaling
        view.image = image
        return view
    }

    var transitionRasterSize: CGSize {
        let bounds = window.frame.size
        return sceneRenderResolution.drawableSize(
            bounds: bounds,
            backing: CGSize(
                width: bounds.width * displayScale, height: bounds.height * displayScale),
            maxDimension: profile.maxDimension)
    }

    func prepareTransition() async throws {
        if let preparedScene {
            let size = transitionRasterSize
            let still = try await WSSStaticPreparation.shared.renderDesktopFrame(
                preparedScene.resources, size: size)
            try Task.checkCancellation()
            transitionStill = still
            window.contentView = imageView(still, scaling: .scaleAxesIndependently)
        } else {
            let image = await ImageLoader.shared.image(wallpaper.url, maxPixel: imagePixelLimit)
            try Task.checkCancellation()
            guard let image else { throw RuntimeDiagnostic.imageDecode }
            window.contentView = imageView(image, scaling: .scaleProportionallyUpOrDown)
        }
        transitionPrepared = true
    }

    func presentTransition(above previous: Renderer?) {
        transitionPrepared = false
        paused = false
        if let previous {
            window.order(.above, relativeTo: previous.window.windowNumber)
        } else {
            window.orderBack(nil)
        }
        if let preparedScene {
            self.preparedScene = nil
            installScene(preparedScene)
        } else {
            finishReadiness(.ready)
        }
    }

    private func drawTransitionFrame() {
        guard transitionStillView != nil, let scene, scene.view.isPaused
        else { return }
        scene.view.draw()
    }
    func setSceneRenderResolution(_ resolution: SceneRenderResolution) {
        sceneRenderResolution = resolution
        scene?.setRenderResolution(resolution)
    }
    private func installScene(_ prepared: PreparedScenePlayback, initiallyFrozen: Bool = false) {
        let fps = profile == .original ? sceneFPS : min(sceneFPS, Int(profile.fps))
        let onFirstFramePresented: (@MainActor () -> Void)?
        if onReadiness != nil || transitionStill != nil {
            onFirstFramePresented = { [weak self] in
                guard let self else { return }
                self.transitionStillView?.removeFromSuperview()
                self.transitionStillView = nil
                self.finishReadiness(.ready)
            }
        } else {
            onFirstFramePresented = nil
        }
        let player = prepared.makePlayer(
            size: window.frame.size, scale: displayScale,
            maxDimension: profile.maxDimension, fps: fps, resolution: sceneRenderResolution,
            offset: sceneTime, desktopPlayback: true,
            onDiagnostic: { [weak self] diagnostic in self?.report(diagnostic) },
            onFirstFramePresented: onFirstFramePresented,
            onError: { [weak self] error in self?.report(.failure(error)) })
        if measuresPerformance { player.startMeasuring() }
        scene = player
        if let transitionStill, let player = player as? WSSStaticPlayer {
            let container = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
            let stillView = imageView(transitionStill, scaling: .scaleAxesIndependently)
            transitionStillView = stillView
            container.addSubview(stillView)
            player.view.autoresizingMask = [.width, .height]
            container.addSubview(player.view)
            window.contentView = container
            player.playFromStill()
            Task { @MainActor [weak self] in self?.drawTransitionFrame() }
        } else {
            window.contentView = player.view
            if initiallyFrozen, let native = player as? WSSStaticPlayer {
                native.setDesktopSurfaceAvailable(surfaceAvailable)
                native.pauseDesktop()
            } else {
                player.play()
            }
        }
    }
    private func loadWeb() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(
            frame: NSRect(origin: .zero, size: window.frame.size), configuration: configuration)
        view.navigationDelegate = self
        web = view
        window.contentView = view
        view.loadFileURL(
            wallpaper.url,
            allowingReadAccessTo: URL(fileURLWithPath: wallpaper.root, isDirectory: true))
    }
    private func playVideo(_ player: AVQueuePlayer) {
        player.play()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkVideoHealth() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    func checkVideoHealth() {
        guard !paused, !stopped, let player else { return }
        let failed =
            player.status == .failed || player.currentItem?.status == .failed
            || looper?.status == .failed
        switch health.inspect(
            position: player.currentTime().seconds,
            item: player.currentItem.map(ObjectIdentifier.init), failed: failed)
        {
        case .none: break
        case .resume:
            onEvent?(.videoResuming)
            player.playImmediately(atRate: 1)
        case .rebuild:
            onEvent?(.decoderRebuilding)
            releaseResources()
            load()
        case .failed:
            report(.videoRecoveryFailed)
        }
    }
    private func releaseResources() {
        transitionStill = nil
        transitionStillView = nil
        transitionPrepared = false
        healthTimer?.invalidate()
        healthTimer = nil
        if let time = player?.currentTime(), time.isNumeric { resumeTime = time }
        imageTask?.cancel()
        imageTask = nil
        player?.pause()
        observation = nil
        looper?.disableLooping()
        looper = nil
        (window.contentView as? VideoView)?.video.player = nil
        player?.removeAllItems()
        player = nil
        gif?.stop()
        gif = nil
        if let scene {
            sceneTime = scene.elapsed
            scene.stop()
        }
        scene = nil
        preparedScene = nil
        web?.navigationDelegate = nil
        web?.stopLoading()
        web?.removeFromSuperview()
        web = nil
        window.contentView = nil
        window.orderOut(nil)
    }
    private(set) var globalPauseReasons: Set<PauseReason> = []
    private(set) var displayPauseReasons: Set<PauseReason> = []
    var effectivePauseReason: PauseReason? {
        PauseReason.allCases.first {
            globalPauseReasons.contains($0) || displayPauseReasons.contains($0)
        }
    }
    private var surfaceAvailable = true

    func applyPauseReasons(_ reasons: Set<PauseReason>, surfaceAvailable: Bool) {
        let before = effectivePauseReason
        globalPauseReasons = reasons
        let recovered = !self.surfaceAvailable && surfaceAvailable
        self.surfaceAvailable = surfaceAvailable
        let effective = globalPauseReasons.union(displayPauseReasons)
        setPaused(!effective.isEmpty, retainingScene: Self.canRetainScene(for: effective))
        if let player = scene as? WSSStaticPlayer {
            player.setDesktopSurfaceAvailable(surfaceAvailable)
            if recovered { player.requestDesktopRecovery() }
        }
        if before != effectivePauseReason { performanceSceneChanged?() }
    }

    func setDisplayPauseReasons(_ reasons: Set<PauseReason>) {
        displayPauseReasons = reasons
        applyPauseReasons(globalPauseReasons, surfaceAvailable: surfaceAvailable)
        performanceSceneChanged?()
    }

    static func canRetainScene(for reasons: Set<PauseReason>) -> Bool {
        reasons.isSubset(of: [.manual, .sleep, .session])
    }

    func hideDesktopSlot() { window.orderOut(nil) }

    func showDesktopSlot() {
        if !stopped, window.contentView != nil { window.orderBack(nil) }
    }

    func updateScreen(_ screen: NSScreen) {
        self.screen = screen
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
        (scene as? WSSStaticPlayer)?.desktopGeometryChanged()
    }

    func startDesktopSlot(
        offset: Double, reasons: Set<PauseReason>, surfaceAvailable: Bool
    ) {
        sceneTime = offset
        globalPauseReasons = reasons
        self.surfaceAvailable = surfaceAvailable
        if !reasons.isEmpty, let preparedScene {
            self.preparedScene = nil
            installScene(preparedScene, initiallyFrozen: true)
            window.orderBack(nil)
            (scene as? WSSStaticPlayer)?.requestDesktopRecovery()
        } else if !reasons.isEmpty {
            load()
            if !stopped, window.contentView != nil { window.orderBack(nil) }
        } else {
            setPaused(false)
        }
    }

    // The only occlusion observer lasts until stop. A transition draws only while
    // its still view is installed.
    @objc private func desktopOcclusionChanged() {
        occlusionNotificationCount += 1
        (scene as? WSSStaticPlayer)?.desktopVisibilityChanged()
        if window.occlusionState.contains(.visible) { drawTransitionFrame() }
    }

    var hasFrozenScene: Bool { (scene as? WSSStaticPlayer)?.desktopFrozen == true }

    var hasFrozenDesktop: Bool {
        hasFrozenScene
            || (paused && hasRetainedMedia)
    }

    private var hasRetainedMedia: Bool {
        player != nil || gif != nil || (wallpaper.kind == .image && window.contentView != nil)
    }

    func setPaused(_ value: Bool, retainingScene: Bool = false) {
        guard !stopped else { return }
        if transitionPrepared && !value { return }
        if paused == value {
            if value {
                preparedScene = nil
                if hasFrozenDesktop, !retainingScene {
                    releaseResources()
                    finishReadiness(.cancelled)
                }
            }
            return
        }
        paused = value
        health = VideoHealth()
        if value {
            if retainingScene, let player = scene as? WSSStaticPlayer,
                player.rendererStatus != .failed, player.rendererStatus != .stopped
            {
                player.pauseDesktop()
            } else if retainingScene, hasRetainedMedia {
                player?.pause()
                healthTimer?.invalidate()
                healthTimer = nil
                gif?.pause()
            } else {
                releaseResources()
                finishReadiness(.cancelled)
            }
        } else if let scene {
            scene.play()
        } else if let player {
            playVideo(player)
        } else if let gif {
            gif.play()
        } else if !hasRetainedMedia {
            load()
        }
    }
    func stopAndDrainForMaintenance() async {
        stop()
        await runtimeTasks.cancelAndDrain()
    }
    func stop() {
        NotificationCenter.default.removeObserver(self)
        stopped = true
        paused = true
        releaseResources()
        onError = nil
        onEvent = nil
        onDiagnostic = nil
        window.close()
        finishReadiness(.cancelled)
    }
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let allowed =
            url?.isFileURL == true
            && url!.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: wallpaper.root).standardizedFileURL.resolvingSymlinksInPath()
                    .path + "/")
        decisionHandler(
            navigationAction.navigationType != .linkActivated && allowed ? .allow : .cancel)
    }
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        if (error as NSError).code != NSURLErrorCancelled {
            report(.capturing(error))
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        report(.webStopped)
    }
}
