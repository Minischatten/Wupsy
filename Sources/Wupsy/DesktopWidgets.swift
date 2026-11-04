import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DesktopWidgetSettings: Codable, Equatable {
    var clock = false
    var stats = false
    var scale = 1.0
    var x = 0.5
    var y = 0.18
    var allDisplays = false
}

@MainActor final class DesktopWidgets: NSObject, ObservableObject {
    @Published var settings: DesktopWidgetSettings {
        didSet {
            if revertingSettings { return }
            guard canMutate else {
                revertingSettings = true
                settings = oldValue
                revertingSettings = false
                return
            }
            persist()
            rebuild()
        }
    }
    @Published private(set) var placements: [String: WidgetPlacement]
    @Published private(set) var editing = false
    @Published private(set) var custom: CustomWidgetPackage
    @Published var error: String?
    let readings = SystemReadings()
    private let defaults: UserDefaults
    let maintenance: MaintenanceCoordinator
    private(set) var maintenanceStopped = false
    private var canMutate: Bool { !maintenanceStopped && maintenance.allowsMutation }
    private var revertingSettings = false
    private var positions: [String: WidgetPosition]
    private(set) var windows: [NSWindow] = []
    private var customHosts: [CustomWidgetHost] = []
    private struct WindowRecord {
        let kind: WidgetKind
        let key: String
        let area: NSRect
        let window: NSWindow
        let native: NSHostingView<AnyView>?
        let custom: CustomWidgetHost?
    }
    private var records: [WindowRecord] = []
    private struct EditingWindow {
        weak var window: NSWindow?
        let wasKey: Bool
        let wasMain: Bool
    }
    private var editingWindows: [EditingWindow] = []
    private var editPanel: NSPanel?
    private var timer: Timer?
    private var sleeping = false
    private var inactive = false
    var customEnabled: Bool {
        get { enabled(.custom) }
        set { setEnabled(.custom, newValue) }
    }
    var enabledCount: Int { WidgetKind.allCases.filter { enabled($0) }.count }
    func enabled(_ kind: WidgetKind) -> Bool { placements[kind.rawValue]?.enabled ?? false }
    func scale(_ kind: WidgetKind) -> Double { placements[kind.rawValue]?.scale ?? 1 }
    func setEnabled(_ kind: WidgetKind, _ value: Bool) {
        guard canMutate, let admission = try? maintenance.beginMutation() else { return }
        defer { admission.finish() }

        var placement = placements[kind.rawValue] ?? WidgetPlacement()
        placement.enabled = value
        placements[kind.rawValue] = placement
        saveLayout()
        rebuild()

    }
    func setScale(_ kind: WidgetKind, _ value: Double) {
        guard canMutate, let admission = try? maintenance.beginMutation() else { return }
        defer { admission.finish() }

        var placement = placements[kind.rawValue] ?? WidgetPlacement()
        placement.scale = value
        placements[kind.rawValue] = placement
        saveLayout()
        resize(kind)

    }
    private func resize(_ kind: WidgetKind) {
        for record in records where record.kind == kind {
            let wanted = kind.size(customHeight: custom.height)
            let scale = min(
                max(0.6, min(2.5, self.scale(kind))), record.area.width / wanted.width,
                record.area.height / wanted.height)
            let size = NSSize(width: wanted.width * scale, height: wanted.height * scale)
            let position = positions[record.key] ?? .initial(kind)
            let frame = position.frame(size: size, area: record.area)
            record.native?.rootView = AnyView(
                SingleWidgetFace(readings: readings, kind: kind, scale: scale).frame(
                    width: size.width, height: size.height))
            record.custom?.view.pageZoom = scale
            record.window.setFrame(frame, display: false)
        }
    }
    func resetLayout() {
        guard canMutate, let admission = try? maintenance.beginMutation() else { return }
        defer { admission.finish() }

        positions = [:]
        for kind in WidgetKind.allCases { placements[kind.rawValue]?.scale = 1 }
        saveLayout()
        rebuild()

    }
    init(defaults: UserDefaults = .standard, maintenance: MaintenanceCoordinator? = nil) {
        self.defaults = defaults
        self.maintenance = maintenance ?? .shared
        let old =
            defaults.data(forKey: "desktopWidgets").flatMap {
                try? JSONDecoder().decode(DesktopWidgetSettings.self, from: $0)
            } ?? DesktopWidgetSettings()
        settings = old
        let migrated: [String: WidgetPlacement] = Dictionary(
            uniqueKeysWithValues: WidgetKind.allCases.map { kind in
                let enabled: Bool
                switch kind {
                case .clock, .date: enabled = old.clock
                case .cpu, .memory: enabled = old.stats
                case .network:
                    enabled = old.stats && (defaults.object(forKey: "widgetGraph") as? Bool ?? true)
                case .custom: enabled = defaults.bool(forKey: "customWidgetEnabled")
                }
                return (kind.rawValue, WidgetPlacement(enabled: enabled, scale: 1))
            })
        placements =
            defaults.data(forKey: "independentWidgets").flatMap {
                try? JSONDecoder().decode([String: WidgetPlacement].self, from: $0)
            } ?? migrated
        positions =
            defaults.data(forKey: "widgetPositions").flatMap {
                try? JSONDecoder().decode([String: WidgetPosition].self, from: $0)
            } ?? [:]
        custom =
            defaults.data(forKey: "customWidgetPackage").flatMap {
                try? JSONDecoder().decode(CustomWidgetPackage.self, from: $0).validated()
            } ?? .starter
        super.init()
        saveLayout()
        NotificationCenter.default.addObserver(
            self, selector: #selector(rebuild),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for name in [NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(editingWindowChanged(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(discardEditingWindows),
            name: NSApplication.didHideNotification, object: NSApp)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self, selector: #selector(sleep), name: NSWorkspace.screensDidSleepNotification,
            object: nil)
        center.addObserver(
            self, selector: #selector(wake), name: NSWorkspace.screensDidWakeNotification,
            object: nil)
        center.addObserver(
            self, selector: #selector(resign), name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil)
        center.addObserver(
            self, selector: #selector(activate),
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        rebuild()
    }
    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    private func persist() {
        guard canMutate, let admission = try? maintenance.beginMutation() else { return }
        defer { admission.finish() }

        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: "desktopWidgets")
        }

    }
    private func saveLayout() {
        guard canMutate, let admission = try? maintenance.beginMutation() else { return }
        defer { admission.finish() }

        if let data = try? JSONEncoder().encode(placements) {
            defaults.set(data, forKey: "independentWidgets")
        }
        if let data = try? JSONEncoder().encode(positions) {
            defaults.set(data, forKey: "widgetPositions")
        }

    }
    func setEditing(_ value: Bool) {
        guard canMutate, let admission = try? maintenance.beginMutation() else { return }
        defer { admission.finish() }

        guard editing != value else { return }
        editing = value
        if value {
            editingWindows = NSApp.windows.filter {
                !NSApp.isHidden && $0.isVisible && $0.canBecomeMain && $0.level == .normal
                    && !$0.isMiniaturized
            }.map { EditingWindow(window: $0, wasKey: $0.isKeyWindow, wasMain: $0.isMainWindow) }
            for state in editingWindows { state.window?.miniaturize(nil) }
        }
        rebuild()
        if !value { restoreEditingWindows() }
    }
    @objc private func editingWindowChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // A window brought back by its user is no longer owned by this edit session,
        // even if the user subsequently minimizes it again.
        editingWindows.removeAll { $0.window == nil || $0.window === window }
    }
    @objc private func discardEditingWindows() { editingWindows.removeAll() }
    private func restoreEditingWindows() {
        let pending = editingWindows
        editingWindows.removeAll()
        guard !NSApp.isHidden else { return }
        let remaining = pending.filter { $0.window?.isMiniaturized == true }
        let hasVisibleWindow = NSApp.windows.contains {
            $0.isVisible && !$0.isMiniaturized && $0.canBecomeMain && $0.level == .normal
        }
        let existingFront = NSApp.keyWindow
        for state in remaining { state.window?.deminiaturize(nil) }
        // Do not take focus from another Wupsy window the user opened during editing.
        if hasVisibleWindow {
            existingFront?.makeKeyAndOrderFront(nil)
        } else if let front =
            (remaining.first { $0.wasKey } ?? remaining.first { $0.wasMain }
            ?? remaining.first)?.window
        {
            NSApp.activate(ignoringOtherApps: true)
            front.makeKeyAndOrderFront(nil)
        }
    }
    @objc private func sleep() {
        sleeping = true
        discardEditingWindows()
        editing = false
        rebuild()
    }
    @objc private func wake() {
        sleeping = false
        rebuild()
    }
    @objc private func resign() {
        inactive = true
        discardEditingWindows()
        editing = false
        rebuild()
    }
    @objc private func activate() {
        inactive = false
        rebuild()
    }
    @objc private func rebuild() {
        guard canMutate else { return }

        timer?.invalidate()
        timer = nil
        editPanel?.close()
        editPanel = nil
        for host in customHosts { host.stop() }
        customHosts.removeAll()
        for window in windows {
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
        records.removeAll()
        readings.resetBaseline()
        guard !sleeping, !inactive else { return }
        let screens = settings.allDisplays ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        for screen in screens {
            let area = screen.visibleFrame
            let display =
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .stringValue ?? "main"
            for kind in WidgetKind.allCases where enabled(kind) {
                let wanted = kind.size(customHeight: custom.height)
                let scale = min(
                    max(0.6, min(2.5, self.scale(kind))), area.width / wanted.width,
                    area.height / wanted.height)
                let size = NSSize(width: wanted.width * scale, height: wanted.height * scale)
                let key = kind.rawValue + "@" + display
                let position = positions[key] ?? .initial(kind)
                let frame = position.frame(size: size, area: area)
                let window = makeWindow(frame)
                window.title = kind.title
                window.identifier = NSUserInterfaceItemIdentifier("widget-" + key)
                let container = NSView(frame: NSRect(origin: .zero, size: size))
                let content: NSView
                var native: NSHostingView<AnyView>?
                var customHost: CustomWidgetHost?
                if kind == .custom {
                    let host = CustomWidgetHost(package: custom, size: size, scale: scale)
                    host.error = { [weak self] in self?.error = $0 }
                    customHosts.append(host)
                    customHost = host
                    content = host.view
                } else {
                    let host = NSHostingView(
                        rootView: AnyView(
                            SingleWidgetFace(readings: readings, kind: kind, scale: scale).frame(
                                width: size.width, height: size.height)))
                    host.sizingOptions = []
                    native = host
                    content = host
                }
                content.frame = container.bounds
                content.autoresizingMask = [.width, .height]
                container.addSubview(content)
                if editing {
                    let drag = WidgetDragSurface(frame: container.bounds)
                    drag.dragBounds = area
                    drag.autoresizingMask = [.width, .height]
                    drag.setAccessibilityLabel(WidgetText.dragAX.format(kind.title))
                    drag.didDrag = { [weak self, weak window] moved in
                        guard let self, let window, self.canMutate else { return }
                        let position = WidgetPosition.from(frame: moved, area: area)
                        self.positions[key] = position
                        self.saveLayout()
                        window.setFrame(
                            position.frame(size: window.frame.size, area: area), display: true)
                    }
                    container.addSubview(drag)
                }
                window.contentView = container
                window.orderFrontRegardless()
                windows.append(window)
                records.append(
                    WindowRecord(
                        kind: kind, key: key, area: area, window: window, native: native,
                        custom: customHost))
            }
        }
        if editing { showEditPanel() }
        guard enabledCount > 0 else { return }
        refresh()
        let stats = enabled(.cpu) || enabled(.memory) || enabled(.network) || customEnabled
        let interval: TimeInterval = stats ? 0.5 : 60
        let firstFire =
            stats
            ? Date().addingTimeInterval(0.5)
            : Date(timeIntervalSince1970: (floor(Date().timeIntervalSince1970 / 60) + 1) * 60)
        let timer = Timer(fire: firstFire, interval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = stats ? 0.025 : 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

    }
    func shutdownForMaintenance() {
        guard !maintenanceStopped else { return }
        maintenanceStopped = true
        discardEditingWindows()
        timer?.invalidate()
        timer = nil
        editing = false
        for host in customHosts { host.stop() }
        customHosts.removeAll()
        editPanel?.close()
        editPanel = nil
        for window in windows {
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
        records.removeAll()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    private func makeWindow(_ frame: NSRect) -> NSWindow {
        let window = DesktopWindow(
            contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(
            rawValue: editing
                ? Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
                : Int(CGWindowLevelForKey(.desktopWindow)) + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = !editing
        window.isReleasedWhenClosed = false
        return window
    }
    private func showEditPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        let panel = NSPanel(
            contentRect: NSRect(x: area.midX - 320, y: area.maxY - 82, width: 640, height: 62),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(
            rootView: HStack(spacing: 16) {
                Image(systemName: "hand.draw").foregroundStyle(WupsyTheme.lavender)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ProductText.widgetsEdit.localized()).font(.headline)
                    Text(WidgetText.editHint.localized()).font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(ProductText.widgetsFinish.localized()) { [weak self] in
                    self?.setEditing(false)
                }
                .buttonStyle(
                    VioletButtonStyle())
            }.padding(14).frame(width: 640, height: 62).background(
                WupsyTheme.surface, in: RoundedRectangle(cornerRadius: 16)
            ).preferredColorScheme(.dark))
        panel.orderFrontRegardless()
        editPanel = panel
    }
    private func refresh() {
        guard canMutate else { return }

        readings.refresh(
            stats: enabled(.cpu) || enabled(.memory) || enabled(.network) || customEnabled)
        for host in customHosts { host.update(readings) }

    }
    func applyCustom(_ package: CustomWidgetPackage) {
        guard canMutate, let admission = try? maintenance.beginMutation() else { return }
        defer { admission.finish() }

        do {
            custom = try package.validated()
            defaults.set(try JSONEncoder().encode(custom), forKey: "customWidgetPackage")
            error = nil
            rebuild()
        } catch { self.error = WidgetErrorPresentation.message(error) }

    }
    func importCustom() -> CustomWidgetPackage? {
        let panel = NSOpenPanel()
        panel.title = WidgetText.importPanel.localized()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 300_000 else {
                throw CustomWidgetError.packageTooLarge
            }
            return try JSONDecoder().decode(CustomWidgetPackage.self, from: Data(contentsOf: url))
                .validated()
        } catch {
            self.error = WidgetErrorPresentation.message(error)
            return nil
        }
    }
    func exportCustom(_ draft: CustomWidgetPackage) {
        do {
            let package = try draft.validated()
            let panel = NSSavePanel()
            panel.title = WidgetText.exportPanel.localized()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Wupsy-widget.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(package).write(to: url, options: .atomic)
        } catch { self.error = WidgetErrorPresentation.message(error) }
    }
}
