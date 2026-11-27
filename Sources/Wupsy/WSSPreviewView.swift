import AppKit
import MetalKit
import SwiftUI

// Geometry stays in view points/logical canvas units, never backing pixels.
enum WSSPreviewGeometry {
    static func fit(canvas: CGSize, available: CGSize) -> CGSize {
        guard canvas.width > 0, canvas.height > 0 else { return .zero }
        let factor = max(0, min(available.width / canvas.width, available.height / canvas.height))
        return CGSize(width: canvas.width * factor, height: canvas.height * factor)
    }
    static func point(
        _ point: CGPoint, bounds: CGRect, canvas: CGSize, flipped: Bool,
        projection: WSSRenderProjection = .fullCanvas
    ) -> SIMD2<
        Float
    >? {
        guard bounds.width > 0, bounds.height > 0, bounds.contains(point) else { return nil }
        let y = (point.y - bounds.minY) / bounds.height
        let uv = CGPoint(x: (point.x - bounds.minX) / bounds.width, y: flipped ? 1 - y : y)
        if projection == .cover {
            return SceneCursor.scenePoint(
                global: CGPoint(x: uv.x * bounds.width, y: uv.y * bounds.height),
                screen: CGRect(origin: .zero, size: bounds.size), canvas: canvas)
        }
        return SIMD2(Float(uv.x * canvas.width), Float(uv.y * canvas.height))
    }
}

struct WSSPreviewRenderPolicy: Equatable {
    var maxDimension: Int
    var fps: Int
    var resolution: SceneRenderResolution
    static let editor = Self(maxDimension: 2560, fps: 30, resolution: .hiDPI)
    static func library(profile: QualityProfile, resolution: SceneRenderResolution, fps: Int)
        -> Self
    {
        Self(
            maxDimension: profile.maxDimension,
            fps: profile == .original ? fps : min(fps, Int(profile.fps)), resolution: resolution)
    }
}

enum WSSPreviewFrameDirection: Int {
    case backward = -1
    case forward = 1

    var title: EditorText { self == .backward ? .previousFrame : .nextFrame }
    var symbol: String { self == .backward ? "backward.frame.fill" : "forward.frame.fill" }
}

struct WSSPreviewFramePosition {
    private var anchor: Double
    private var index = 0

    init(anchor: Double) { self.anchor = anchor }

    mutating func step(_ direction: WSSPreviewFrameDirection, fps: Int) -> Double {
        index += direction.rawValue
        let time = anchor + Double(index) / Double(fps)
        if time <= 0 {
            self = Self(anchor: 0)
            return 0
        }
        return time
    }
}

struct WSSPreviewFrameControls: Equatable {
    var backward = false
    var forward = false
}

@MainActor final class WSSPreviewSurface: NSView {
    // Local safety limit, intentionally not a product/format contract or preference.
    static let drawableLimit = 2560
    private(set) var player: WSSStaticPlayer? {
        didSet { performancePlayerChanged?() }
    }
    var performancePlayerChanged: (() -> Void)?
    var measuresPerformance = false {
        didSet {
            if measuresPerformance {
                player?.startMeasuring()
            } else {
                player?.stopMeasuring()
            }
        }
    }
    private var tracking: NSTrackingArea?
    private var pointer: SIMD2<Float>?
    var resetsTrailWithPointer = false
    private let canvas: CGSize
    private var wantsPlayback = true
    private var onError: ((String) -> Void)?
    private let editorPlayback: Bool
    private var policy: WSSPreviewRenderPolicy
    private var projection: WSSRenderProjection
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var playbackBlocks: Set<String> = []
    // Local presentation gates; no new shared runtime owner.
    func setPlaybackBlocked(_ blocked: Bool, reason: String) {
        if blocked { playbackBlocks.insert(reason) } else { playbackBlocks.remove(reason) }
        resetPointer()
        player?.trailContext.reset()
        updatePlayback()
    }
    private var presentationTask: Task<Void, Never>?
    private var framePosition: WSSPreviewFramePosition?
    private var frameControlsTask: Task<Void, Never>?
    private var publishedFrameControls: WSSPreviewFrameControls?
    var frameControlsChanged: ((WSSPreviewFrameControls) -> Void)? {
        didSet {
            publishedFrameControls = nil
            publishFrameControls()
        }
    }

    var frameControls: WSSPreviewFrameControls {
        guard !wantsPlayback, !movingPresentation, playbackBlocks.isEmpty, policy.fps > 0,
            let player, player.canStepEditorFrame
        else { return .init() }
        return .init(backward: player.elapsed > 0, forward: true)
    }

    func stepFrame(_ direction: WSSPreviewFrameDirection) {
        updateEditorSurfaceAvailability()
        let controls = frameControls
        guard direction == .backward ? controls.backward : controls.forward, let player else {
            return
        }
        let first = framePosition == nil
        var position = framePosition ?? WSSPreviewFramePosition(anchor: player.elapsed)
        let time = position.step(direction, fps: policy.fps)
        framePosition = position
        player.stepEditorFrame(to: time, resetTrail: first)
        publishFrameControls()
    }

    private func publishFrameControls() {
        guard frameControlsChanged != nil, frameControlsTask == nil,
            publishedFrameControls != frameControls
        else { return }
        // A host update can be inside SwiftUI's representable update.
        frameControlsTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            frameControlsTask = nil
            let controls = frameControls
            guard publishedFrameControls != controls else { return }
            publishedFrameControls = controls
            frameControlsChanged?(controls)
        }
    }

    private func updateEditorSurfaceAvailability() {
        let available =
            !movingPresentation && playbackBlocks.isEmpty
            && window?.isVisible == true && window?.isMiniaturized == false
        player?.setEditorSurfaceAvailable(available)
    }

    init(
        resources: WSSStaticResources, playing: Bool = true, offset: Double = 0,
        policy: WSSPreviewRenderPolicy = .editor,
        projection: WSSRenderProjection = .fullCanvas, editorPlayback: Bool = false,
        onError: @escaping (String) -> Void
    ) {
        canvas = CGSize(width: resources.scene.width, height: resources.scene.height)
        self.policy = policy
        self.projection = projection
        self.editorPlayback = editorPlayback
        self.onError = onError
        super.init(frame: .zero)
        wantsPlayback = playing
        install(resources, offset: offset)
        observeWorkspace()
    }
    private func observeWorkspace() {
        let workspace = NSWorkspace.shared.notificationCenter
        for (start, end, reason) in [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "systemSleep"),
            (
                NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                "displaySleep"
            ),
            (
                NSWorkspace.sessionDidResignActiveNotification,
                NSWorkspace.sessionDidBecomeActiveNotification, "session"
            ),
        ] {
            for (name, blocked) in [(start, true), (end, false)] {
                workspaceObservers.append(
                    workspace.addObserver(forName: name, object: nil, queue: .main) {
                        [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.setPlaybackBlocked(blocked, reason: reason)
                        }
                    })
            }
        }
    }
    private var pausedAfterAnimatedPlayback = false
    private var resourcesID: ObjectIdentifier?
    private func install(_ resources: WSSStaticResources, offset: Double) {
        pausedAfterAnimatedPlayback = false
        resourcesID = ObjectIdentifier(resources)
        let player = WSSStaticPlayer(
            resources: resources, size: .zero, scale: 1,
            maxDimension: policy.maxDimension, fps: policy.fps, resolution: policy.resolution,
            offset: offset,
            projection: projection, pointerProvider: { [weak self] in self?.pointer },
            editorFrameStepping: editorPlayback,
            onError: { [weak self] text in self?.onError?(text) })
        if measuresPerformance { player.startMeasuring() }
        self.player = player
        addSubview(player.view)
        player.view.frame = bounds
        if !wantsPlayback, framePosition != nil {
            updateEditorSurfaceAvailability()
            player.stepEditorFrame(to: offset, resetTrail: false)
        }
        running = false
        updatePlayback()
        player.view.needsDisplay = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        resetPointer()
        player?.view.frame = bounds
        updateEditorSurfaceAvailability()
        publishFrameControls()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseMoved(with event: NSEvent) { updatePointer(event) }
    override func mouseEntered(with event: NSEvent) { updatePointer(event) }
    override func mouseDragged(with event: NSEvent) { updatePointer(event) }
    override func mouseExited(with event: NSEvent) { resetPointer() }
    private func updatePointer(_ event: NSEvent) {
        pointer = WSSPreviewGeometry.point(
            convert(event.locationInWindow, from: nil),
            bounds: bounds, canvas: canvas, flipped: isFlipped, projection: projection)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resetPointer()
        removeObservers()
        presentationTask?.cancel()
        guard let window else {
            updatePlayback()
            return
        }
        for name in [
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.didResignKeyNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification,
        ] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main)
                {
                    [weak self] _ in
                    MainActor.assumeIsolated {
                        if name != NSWindow.didUpdateNotification { self?.resetPointer() }
                        self?.updatePlayback()
                        if name == NSWindow.didChangeOcclusionStateNotification,
                            self?.window?.occlusionState.contains(.visible) == true
                        {
                            self?.player?.editorSurfaceRevealed()
                        }
                    }
                })
        }
        updatePlayback()
        // NSHostingView may attach us before its window is ordered on screen.
        // Reconcile once after presentation, even when no document edit follows.
        presentationTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.updatePlayback()
        }
    }
    func update(resources: WSSStaticResources, playing: Bool) {
        wantsPlayback = playing
        if resourcesID != ObjectIdentifier(resources) {
            // A previously paused MetalKit view can fail to restart its timer
            // even with both mode flags set correctly. Begin this transition
            // with a new view, keeping the prepared resources and playhead.
            let renewPlayer =
                player?.resources.isAnimated == false
                && renewsProceduralPlayer(for: resources)
            if !renewPlayer, player?.updateTransforms(resources) == true {
                resourcesID = ObjectIdentifier(resources)
                updatePlayback()
                return
            }
            replacePlayer(with: resources)
        }
        updatePlayback()
    }
    private func renewsProceduralPlayer(for resources: WSSStaticResources) -> Bool {
        editorPlayback
            && resources.scene.layers.contains {
                switch $0 {
                case .starfield(let layer): return layer.visible && layer.starfield.isAnimated
                case .slime(let layer): return layer.isAnimated
                case .fog(let layer):
                    return resources.hasEffectiveFog(layer) && layer.fog.isAnimated
                case .musicNotes(let layer): return layer.isAnimated
                case .storm(let layer): return layer.isAnimated
                default: return false
                }
            }
    }

    private func renewsPlayerAfterTransfer(for resources: WSSStaticResources) -> Bool {
        editorPlayback
            && resources.scene.layers.contains {
                switch $0 {
                case .starfield(let layer): return layer.visible && layer.starfield.isAnimated
                case .slime(let layer): return layer.isAnimated
                case .musicNotes(let layer): return layer.isAnimated
                default: return false
                }
            }
    }
    private func replacePlayer(with resources: WSSStaticResources) {
        let offset = player?.elapsed ?? 0
        if player?.resumeAtEditorStep == true, framePosition == nil {
            framePosition = WSSPreviewFramePosition(anchor: offset)
        }
        player?.stop()
        player?.view.removeFromSuperview()
        pointer = nil
        install(resources, offset: offset)
    }
    func setPlaying(_ value: Bool) {
        wantsPlayback = value
        updatePlayback()
    }
    func configure(policy: WSSPreviewRenderPolicy, projection: WSSRenderProjection) {
        guard policy != self.policy || projection != self.projection else { return }
        resetPointer()
        self.policy = policy
        self.projection = projection
        player?.configurePreview(
            maxDimension: policy.maxDimension, fps: policy.fps,
            resolution: policy.resolution, projection: projection)
    }
    func resetPointer() {
        if resetsTrailWithPointer { player?.trailContext.reset() }
        pointer = nil
    }
    private var movingPresentation = false
    func transferPresentation(_ move: () -> Void) {
        let sourceWindow = window
        let wasDrawingContinuously = running && player?.view.isPaused == false
        resetPointer()
        movingPresentation = true
        updateEditorSurfaceAvailability()
        defer {
            movingPresentation = false
            let changedWindow = sourceWindow != nil && window != nil && sourceWindow !== window
            if wasDrawingContinuously, changedWindow, let resources = player?.resources,
                renewsPlayerAfterTransfer(for: resources)
            {
                // A running MTKView can stop receiving draw callbacks after reparenting.
                replacePlayer(with: resources)
            } else {
                if changedWindow, !wantsPlayback { player?.renewPausedEditorMetalView() }
                updatePlayback()
            }
        }
        move()
    }
    private var running = false
    private func updatePlayback() {
        defer { publishFrameControls() }
        updateEditorSurfaceAvailability()
        guard !movingPresentation else { return }
        // A hosted preview can receive a non-visible occlusion state even after
        // its editor is ordered on screen. Do not use that optimization as a
        // playback gate: read-only projects have no edit-triggered player rebuild.
        let visible = window.map { $0.isVisible && !$0.isMiniaturized } ?? false
        let shouldRun = wantsPlayback && visible && playbackBlocks.isEmpty
        guard shouldRun != running else { return }
        if shouldRun, pausedAfterAnimatedPlayback, let resources = player?.resources,
            renewsProceduralPlayer(for: resources)
        {
            // Starting a new view avoids resuming a stalled MetalKit draw timer.
            replacePlayer(with: resources)
            return
        }
        running = shouldRun
        if shouldRun {
            pausedAfterAnimatedPlayback = false
            player?.play(fromEditorStep: framePosition != nil)
            framePosition = nil
        } else {
            if resetsTrailWithPointer { resetPointer() }
            pausedAfterAnimatedPlayback = player?.view.isPaused == false
            if let player, player.resumeAtEditorStep {
                framePosition = WSSPreviewFramePosition(anchor: player.elapsed)
            }
            player?.pause()
        }
    }
    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
    func shutdown() {
        presentationTask?.cancel()
        presentationTask = nil
        frameControlsTask?.cancel()
        frameControlsTask = nil
        frameControlsChanged = nil
        removeObservers()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        pointer = nil
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        player?.stop()
        player?.view.removeFromSuperview()
        player = nil
        onError = nil
    }
}

struct WSSPreviewView: NSViewRepresentable {
    @Environment(\.wupsyMetrics) private var metrics
    @ObservedObject var document: WSSEditorDocument
    func makeNSView(context: Context) -> WSSPreviewHost { WSSPreviewHost(document: document) }
    func updateNSView(_ view: WSSPreviewHost, context: Context) {
        view.interfaceMetrics = metrics
        view.update(document)
    }
    static func dismantleNSView(_ view: WSSPreviewHost, coordinator: ()) { view.shutdown() }
}
