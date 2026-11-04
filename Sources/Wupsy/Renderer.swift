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
@MainActor final class Renderer: NSObject, WKNavigationDelegate {
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
    private(set) var scene: (any ScenePlaybackSession)?
    private var preparedScene: PreparedScenePlayback?
    private var sceneTime = 0.0
    private var sceneRenderResolution: SceneRenderResolution
    private let sceneFPS: Int
    private let displayScale: CGFloat
    private(set) var paused = true
    private var stopped = false
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
        onDiagnostic: ((RuntimeDiagnostic) -> Void)? = nil, onError: @escaping (String) -> Void
    ) {
        self.maintenance = maintenance ?? .shared
        self.preparedScene = scenePlayback
        self.sceneRenderResolution = sceneRenderResolution
        self.sceneFPS = sceneFPS
        self.displayScale = screen.backingScaleFactor
        self.wallpaper = wallpaper
        self.mediaURL = mediaURL ?? wallpaper.url
        self.profile = profile
        self.onError = onError
        self.onEvent = onEvent
        self.onDiagnostic = onDiagnostic
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
        if !initiallyPaused { setPaused(false) }
    }
    private func report(_ diagnostic: RuntimeDiagnostic) {
        if let onDiagnostic {
            onDiagnostic(diagnostic)
        } else {
            onError?(diagnostic.technicalDescription)
        }
    }
    private func load() {
        guard !stopped, maintenance.allowsMutation else { return }
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
            if resumeTime > .zero {
                player.seek(
                    to: resumeTime, toleranceBefore: CMTime(seconds: 0.2, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.2, preferredTimescale: 600))
            }
            player.play()
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkVideoHealth() }
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            healthTimer = timer
        case .image:
            let view = NSImageView(frame: NSRect(origin: .zero, size: window.frame.size))
            view.imageScaling = .scaleProportionallyUpOrDown
            window.contentView = view
            imageTask = Task { [weak self, weak view] in
                guard let self else { return }
                let image = await ImageLoader.shared.image(wallpaper.url, maxPixel: imagePixelLimit)
                guard !Task.isCancelled, !paused else { return }
                view?.image = image
                if image == nil { report(.imageDecode) }
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
                guard let admission = try? maintenance.beginMutation(kind: .runtime) else { return }
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
                    animation.play()
                } catch { report(.capturing(error)) }
            } else {
                loadWeb()
            }
        }
        window.orderBack(nil)
    }
    func setSceneRenderResolution(_ resolution: SceneRenderResolution) {
        sceneRenderResolution = resolution
        scene?.setRenderResolution(resolution)
    }
    private func installScene(_ prepared: PreparedScenePlayback) {
        let fps = profile == .original ? sceneFPS : min(sceneFPS, Int(profile.fps))
        let player = prepared.makePlayer(
            size: window.frame.size, scale: displayScale,
            maxDimension: profile.maxDimension, fps: fps, resolution: sceneRenderResolution,
            offset: sceneTime,
            onDiagnostic: { [weak self] diagnostic in self?.report(diagnostic) },
            onError: { [weak self] error in self?.report(.failure(error)) })
        scene = player
        window.contentView = player.view
        player.play()
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
    func setPaused(_ value: Bool) {
        guard !stopped else { return }
        if paused == value {
            if value { preparedScene = nil }
            return
        }
        paused = value
        health = VideoHealth()
        if value { releaseResources() } else { load() }
    }
    func stopAndDrainForMaintenance() async {
        stop()
        await runtimeTasks.cancelAndDrain()
    }
    func stop() {
        stopped = true
        paused = true
        releaseResources()
        onError = nil
        onEvent = nil
        onDiagnostic = nil
        window.close()
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
