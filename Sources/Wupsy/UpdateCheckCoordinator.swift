import AppKit
import Combine

enum UpdateCheckResult: Equatable {
    case available(installed: ReleaseVersion, release: GitHubRelease, skipped: Bool)
    case current(ReleaseVersion)
    case noStableRelease
    case failed(UpdateCheckFailure)
}
enum UpdateCheckAction { case open, skip, close }

@MainActor protocol UpdatePresenting: AnyObject {
    var canPresent: Bool { get }
    func present(
        _ result: UpdateCheckResult, manual: Bool, completion: @escaping (UpdateCheckAction) -> Void
    )
    func dismiss()
}

@MainActor protocol UpdateScheduling {
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void)
        -> AnyCancellable
}

@MainActor struct UpdateTimerScheduler: UpdateScheduling {
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void)
        -> AnyCancellable
    {
        let timer = Timer(timeInterval: max(1, seconds), repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return AnyCancellable { timer.invalidate() }
    }
}

@MainActor final class UpdateCheckCoordinator: ObservableObject {
    enum Key {
        static let automatic = "updates.automaticEnabled"
        static let attempt = "updates.lastAttemptAt"
        static let skipped = "updates.skippedVersion"
        static let retry = "updates.retryNotBefore"
    }
    static let interval: TimeInterval = 24 * 60 * 60
    @Published private(set) var automaticEnabled: Bool
    @Published private(set) var checking = false
    private let defaults: UserDefaults
    private let client: any ReleaseChecking
    private let version: () throws -> ReleaseVersion
    private let now: () -> Date
    private let scheduler: any UpdateScheduling
    private let presenter: any UpdatePresenting
    private let canOperate: () -> Bool
    private let openURL: (URL) -> Void
    private var task: Task<Void, Never>?
    private var alarm: AnyCancellable?
    private var lifecycle: [AnyCancellable] = []
    private var manualRequested = false
    private var stopped = false
    private var suspended = false
    private var started = false
    private var generation = UUID()
    private var pending: (UpdateCheckResult, Bool)?

    init(
        defaults: UserDefaults, client: any ReleaseChecking,
        version: @escaping () throws -> ReleaseVersion,
        now: @escaping () -> Date = Date.init,
        scheduler: (any UpdateScheduling)? = nil,
        presenter: any UpdatePresenting, canOperate: @escaping () -> Bool = { true },
        openURL: @escaping (URL) -> Void = { _ in }
    ) {
        self.defaults = defaults
        self.client = client
        self.version = version
        self.now = now
        self.scheduler = scheduler ?? UpdateTimerScheduler()
        self.presenter = presenter
        self.canOperate = canOperate
        self.openURL = openURL
        automaticEnabled = defaults.bool(forKey: Key.automatic)
    }
    static func live(defaults: UserDefaults) -> UpdateCheckCoordinator {
        let maintenance = MaintenanceCoordinator.shared
        let coordinator = UpdateCheckCoordinator(
            defaults: defaults, client: GitHubReleaseClient(),
            version: { try ReleaseVersion.installed() }, presenter: UpdateCheckPresentation(),
            canOperate: { maintenance.state == .normal },
            openURL: { NSWorkspace.shared.open($0) })
        // Events only wake the same due-date check; menus never start requests.
        let workspace = NSWorkspace.shared.notificationCenter
        coordinator.observe(workspace, NSWorkspace.didWakeNotification)
        coordinator.observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification)
        coordinator.observe(.default, NSApplication.didBecomeActiveNotification)
        coordinator.observe(.default, NSWindow.didEndSheetNotification, checkDue: false)
        coordinator.observe(.default, NSMenu.didEndTrackingNotification, checkDue: false)
        maintenance.$state.sink { [weak coordinator] _ in
            Task { @MainActor in coordinator?.resumeIfDue() }
        }.store(in: &coordinator.lifecycle)
        return coordinator
    }
    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name, checkDue: Bool = true
    ) {
        center.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
            if checkDue { self?.resumeIfDue() } else { self?.flushPresentation() }
        }.store(in: &lifecycle)
    }
    func start() {
        guard !started, !stopped else { return }
        started = true
        resumeIfDue()
    }
    func setAutomatic(_ enabled: Bool) {
        guard !stopped else { return }
        automaticEnabled = enabled
        defaults.set(enabled, forKey: Key.automatic)
        if !enabled, pending?.1 == false { pending = nil }
        resumeIfDue()
    }
    private func date(_ key: String) -> Date? {
        guard let value = defaults.object(forKey: key) as? Date,
            value.timeIntervalSince1970.isFinite
        else { return nil }
        return value
    }
    func resumeIfDue() {
        guard started, !stopped, !suspended else { return }
        flushPresentation()
        alarm = nil
        if !canOperate() { presenter.dismiss() }
        guard automaticEnabled, !checking, canOperate() else { return }
        let time = now()
        // A backwards clock is rebased once, conservatively waiting another day.
        if let last = date(Key.attempt), last > time {
            defaults.set(time, forKey: Key.attempt)
        }
        let due = max(
            date(Key.attempt)?.addingTimeInterval(Self.interval) ?? time,
            date(Key.retry) ?? time)
        if due <= time {
            begin(manual: false)
        } else {
            alarm = scheduler.schedule(after: due.timeIntervalSince(time)) { [weak self] in
                self?.resumeIfDue()
            }
        }
    }
    func checkNow() {
        guard !stopped, !suspended, canOperate() else { return }
        if checking {
            manualRequested = true
            return
        }
        if let retry = date(Key.retry), retry > now() {
            pending = (.failed(.rateLimited(until: retry)), true)
            flushPresentation()
            return
        }
        begin(manual: true)
    }
    private func begin(manual: Bool) {
        guard !checking else { return }
        checking = true
        manualRequested = manual
        alarm = nil
        defaults.set(now(), forKey: Key.attempt)
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            let result: UpdateCheckResult
            do {
                let installed = try version()
                if let release = try await client.latest() {
                    result =
                        release.version > installed
                        ? .available(
                            installed: installed, release: release,
                            skipped: defaults.string(forKey: Key.skipped)
                                == release.version.description)
                        : .current(installed)
                } else {
                    result = .noStableRelease
                }
            } catch let failure as UpdateCheckFailure {
                result = .failed(failure)
            } catch is CancellationError { result = .failed(.cancelled) } catch {
                result = .failed(.network)
            }
            guard !stopped, generation == token else { return }
            task = nil
            checking = false
            if case .failed(.rateLimited(let until)) = result {
                defaults.set(until, forKey: Key.retry)
            }
            let manual = manualRequested
            if manual {
                pending = (result, true)
            } else if automaticEnabled, case .available(_, _, false) = result {
                pending = (result, false)
            }
            flushPresentation()
            resumeIfDue()
        }
    }
    func flushPresentation() {
        guard !stopped, !suspended, canOperate(), presenter.canPresent,
            let (result, manual) = pending
        else { return }
        pending = nil
        var current = result
        if case .available(let installed, let release, _) = result {
            let skipped = defaults.string(forKey: Key.skipped) == release.version.description
            guard manual || (automaticEnabled && !skipped) else { return }
            current = .available(installed: installed, release: release, skipped: skipped)
        }
        presenter.present(current, manual: manual) { [weak self] action in
            guard let self, !stopped, !suspended, canOperate() else { return }
            if case .available(_, let release, _) = result {
                switch action {
                case .open: openURL(release.url)
                case .skip: defaults.set(release.version.description, forKey: Key.skipped)
                case .close: break
                }
            }
            flushPresentation()
        }
    }
    func suspendForTermination() {
        suspended = true
        alarm = nil
        pending = nil
        presenter.dismiss()
    }
    func cancelTermination() {
        suspended = false
        resumeIfDue()
    }
    func shutdown() {
        stopped = true
        generation = UUID()
        task?.cancel()
        task = nil
        alarm = nil
        pending = nil
        lifecycle.removeAll()
        presenter.dismiss()
    }
}
