import AppKit
import Combine
import SwiftUI

// One owner per Library, including across disappearing/recreated Hero views. A cancelled
// synchronous decode must finish before the replaceable latest request starts.
@MainActor final class WSSLibraryPreviewOwner: ObservableObject {
    enum State: Equatable { case loading, live, staticPreview, failed }
    @Published private(set) var state: State = .loading
    private(set) var wallpaperID: UUID?
    private(set) var projectIdentity: WSSProjectDiskBasis.Identity?
    private(set) var fingerprint: WSSContentFingerprint?
    private(set) var diagnostic: String?
    private(set) var surface: WSSPreviewSurface?
    private weak var host: WSSLibraryPreviewHost?
    private var item: Wallpaper?
    private var generation = UUID()
    private var pending: (Wallpaper, UUID, Double)?
    private var worker: Task<Void, Never>?
    private var loading: Task<WSSLoadedEditorProject, Error>?
    private let maintenance: MaintenanceCoordinator
    private let load: (Wallpaper) async throws -> WSSLoadedEditorProject
    private var subscriptions: Set<AnyCancellable> = []
    private var hidden = NSApp?.isHidden ?? false
    private var sleeping = false
    private var systemSleeping = false
    private var inactive = false
    private var frozen = false
    private var frozenTime = 0.0
    private var terminal = false
    private var fit = true
    private var policy = WSSPreviewRenderPolicy.editor

    init(
        maintenance: MaintenanceCoordinator? = nil,
        load: ((Wallpaper) async throws -> WSSLoadedEditorProject)? = nil
    ) {
        let maintenance = maintenance ?? .shared
        self.maintenance = maintenance
        let loader = WSSEditorProjectLoader()
        self.load = load ?? { try await loader.load($0) }
        maintenance.$state.sink { [weak self] state in
            self?.setFrozen(state == .restoreFreezing || state == .restartRequired)
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .wssPreviewCommitted).sink { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let id = note.object as? UUID, id == self.wallpaperID else {
                    return
                }
                self.reload()
            }
        }.store(in: &subscriptions)
        observe(NSApplication.didHideNotification) { $0.setHidden(true) }
        observe(NSApplication.didUnhideNotification) { $0.setHidden(false) }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.screensDidSleepNotification, center: workspace) { $0.setSleeping(true) }
        observe(NSWorkspace.screensDidWakeNotification, center: workspace) { $0.setSleeping(false) }
        observe(NSWorkspace.willSleepNotification, center: workspace) { $0.setSystemSleeping(true) }
        observe(NSWorkspace.didWakeNotification, center: workspace) { $0.setSystemSleeping(false) }
        observe(NSWorkspace.sessionDidResignActiveNotification, center: workspace) {
            $0.setInactive(true)
        }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, center: workspace) {
            $0.setInactive(false)
        }
    }
    private func observe(
        _ name: Notification.Name, center: NotificationCenter = .default,
        action: @escaping (WSSLibraryPreviewOwner) -> Void
    ) {
        center.publisher(for: name).sink { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }.store(in: &subscriptions)
    }
    func attach(_ host: WSSLibraryPreviewHost) {
        guard !terminal, self.host !== host else { return }
        self.host = host
        host.fit = fit
        if let surface { surface.transferPresentation { host.install(surface) } }
    }
    func detach(_ host: WSSLibraryPreviewHost) {
        guard self.host === host else { return }
        select(nil)
        self.host = nil
    }
    func select(_ value: Wallpaper?) {
        guard !terminal else { return }
        // Titles are presentation only. A commit of the same identity uses reload().
        if let value, let item, value.id == item.id, value.path == item.path,
            value.root == item.root, value.sceneSource == item.sceneSource,
            value.kind == item.kind, value.managed == item.managed
        {
            self.item = value
            return
        }
        item = value
        wallpaperID = value?.id
        request(offset: 0)
    }
    func reload() { request(offset: surface?.player?.elapsed ?? 0) }
    private func request(offset: Double) {
        generation = UUID()
        pending = nil
        loading?.cancel()
        stopSurface()
        fingerprint = nil
        projectIdentity = nil
        diagnostic = nil
        state = .loading
        guard !terminal, !frozen, let item else { return }
        guard item.kind == .scene, item.managed != nil else {
            state = .staticPreview
            return
        }
        pending = (item, generation, offset)
        startWorker()
    }
    private func startWorker() {
        guard worker == nil, pending != nil,
            let admission = try? maintenance.beginMutation(kind: .runtime)
        else { return }
        worker = Task { [self] in
            defer {
                admission.finish()
                worker = nil
            }
            while let (wallpaper, ticket, offset) = pending, !terminal, !frozen {
                pending = nil
                let task = Task { try await load(wallpaper) }
                loading = task
                do {
                    let project = try await task.value
                    guard ticket == generation, !task.isCancelled, !terminal, !frozen else {
                        continue
                    }
                    projectIdentity = project.diskBasis.identity
                    fingerprint = project.diskBasis.manifest
                    let surface = WSSPreviewSurface(
                        resources: project.resources, playing: canPlay, offset: offset,
                        policy: policy, projection: fit ? .fullCanvas : .cover,
                        onError: { [weak self] text in
                            guard let self, ticket == generation else { return }
                            fail(text)
                        })
                    surface.resetsTrailWithPointer = true
                    self.surface = surface
                    host?.install(surface)
                    state = .live
                } catch {
                    guard ticket == generation, !task.isCancelled, !terminal, !frozen else {
                        continue
                    }
                    if let error = error as? WSSEditorOpenError, case .missingProject = error {
                        state = .staticPreview
                    } else {
                        fail(String(describing: error))
                    }
                }
                loading = nil
            }
            loading = nil
        }
    }
    private func fail(_ text: String) {
        stopSurface()
        diagnostic = text
        state = .failed
    }
    private func stopSurface() {
        surface?.shutdown()
        surface?.removeFromSuperview()
        surface = nil
    }
    func configure(policy: WSSPreviewRenderPolicy, fit: Bool) {
        self.policy = policy
        self.fit = fit
        surface?.configure(policy: policy, projection: fit ? .fullCanvas : .cover)
        host?.fit = fit
        host?.needsLayout = true
    }
    private var canPlay: Bool {
        !hidden && !sleeping && !systemSleeping && !inactive && !frozen && !terminal
    }
    private func updatePlayback() {
        surface?.resetPointer()
        surface?.setPlaying(canPlay)
    }
    func setHidden(_ value: Bool) {
        hidden = value
        updatePlayback()
    }
    func setSleeping(_ value: Bool) {
        sleeping = value
        updatePlayback()
    }
    private func setSystemSleeping(_ value: Bool) {
        systemSleeping = value
        updatePlayback()
    }
    func setInactive(_ value: Bool) {
        inactive = value
        updatePlayback()
    }
    private func setFrozen(_ value: Bool) {
        guard frozen != value else { return }
        if value { frozenTime = surface?.player?.elapsed ?? 0 }
        frozen = value
        request(offset: frozenTime)
        // Published state is delivered before MaintenanceCoordinator stores its new value.
        if !value { Task { [weak self] in self?.startWorker() } }
    }
    func waitForPreparation() async { await worker?.value }
    func shutdownAndDrain() async {
        terminal = true
        generation = UUID()
        pending = nil
        loading?.cancel()
        stopSurface()
        item = nil
        wallpaperID = nil
        subscriptions.removeAll()
        await worker?.value
    }
}

@MainActor final class WSSLibraryPreviewHost: NSView {
    let owner: WSSLibraryPreviewOwner
    var fit = true
    init(owner: WSSLibraryPreviewOwner) {
        self.owner = owner
        super.init(frame: .zero)
        owner.attach(self)
    }
    required init?(coder: NSCoder) { fatalError() }
    func install(_ surface: WSSPreviewSurface) {
        addSubview(surface)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }
    override func layout() {
        super.layout()
        guard let surface = owner.surface, let scene = surface.player?.resources.scene else {
            return
        }
        let size =
            fit
            ? WSSPreviewGeometry.fit(
                canvas: CGSize(width: scene.width, height: scene.height), available: bounds.size)
            : bounds.size
        surface.frame = CGRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
            width: size.width, height: size.height)
    }
    func shutdown() { owner.detach(self) }
}

private struct WSSLibraryNativePreview: NSViewRepresentable {
    let owner: WSSLibraryPreviewOwner
    func makeNSView(context: Context) -> WSSLibraryPreviewHost {
        WSSLibraryPreviewHost(owner: owner)
    }
    func updateNSView(_ view: WSSLibraryPreviewHost, context: Context) {}
    static func dismantleNSView(_ view: WSSLibraryPreviewHost, coordinator: ()) { view.shutdown() }
}

struct WSSLibraryLivePreview: View {
    let item: Wallpaper
    let fit: Bool
    let policy: WSSPreviewRenderPolicy
    @ObservedObject var owner: WSSLibraryPreviewOwner
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.25, green: 0.13, blue: 0.4),
                    Color(red: 0.12, green: 0.1, blue: 0.22), .black,
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            if owner.wallpaperID == item.id && owner.state == .staticPreview {
                WallpaperPreview(item: item, maxPixel: 1280, fit: fit)
            } else if owner.wallpaperID != item.id || owner.state != .live {
                Image(systemName: "photo").font(.system(size: 38, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.5))
            }
            WSSLibraryNativePreview(owner: owner)
                .opacity(owner.wallpaperID == item.id && owner.state == .live ? 1 : 0)
        }
        .clipped()
        .onAppear { update() }
        .onChange(of: item) { _, _ in update() }
        .onChange(of: policy) { _, _ in update() }
        .onChange(of: fit) { _, _ in update() }
    }
    private func update() {
        owner.configure(policy: policy, fit: fit)
        owner.select(item)
    }
}
