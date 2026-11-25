import AppKit
import SwiftUI

@MainActor final class DesktopPerformancePanel: NSObject, ObservableObject, NSWindowDelegate {
    enum DisplayID: Hashable {
        case number(UInt32)
        case screen(ObjectIdentifier)

        @MainActor init(_ screen: NSScreen) {
            self =
                WSSDesktopRefreshTargets.number(screen).map(Self.number)
                ?? .screen(ObjectIdentifier(screen))
        }
    }

    struct Choice: Equatable, Identifiable {
        let id: DisplayID
        let name: String
    }

    let diagnosis: PerformanceDiagnosis
    private let defaults: UserDefaults
    private let targets: () -> [(Choice, Renderer)]
    private let status: () -> String?
    private weak var observedRenderer: Renderer?
    private(set) var panel: NSPanel?
    @Published private(set) var choices: [Choice] = []
    @Published private(set) var selection: DisplayID?

    init(
        defaults: UserDefaults, targets: @escaping () -> [(Choice, Renderer)],
        status: @escaping () -> String?
    ) {
        self.defaults = defaults
        self.targets = targets
        self.status = status
        diagnosis = PerformanceDiagnosis(
            defaults: defaults, detailsKey: "performance.desktop.details")
        super.init()
    }

    func open() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 310, height: 200),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = ProductText.performanceTitle.text
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = NSColor(white: 0.10, alpha: 0.95)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self
        self.panel = panel
        diagnosis.setActive(true)
        reconcile()
        panel.contentView = NSHostingView(rootView: DesktopPerformanceContent(controller: self))
        resize()
        placePanel()
        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        panel.orderFrontRegardless()
    }

    func close() { panel?.close() }

    func select(_ id: DisplayID?) {
        guard panel != nil else { return }
        selection = id
        reconcile()
    }

    func reconcile() {
        guard panel != nil else { return }
        let candidates = targets()
        let available = candidates.map(\.0)
        if available != choices { choices = available }
        let current = candidates.first { $0.0.id == selection } ?? candidates.first
        if selection != current?.0.id { selection = current?.0.id }
        let renderer = current?.1
        if observedRenderer !== renderer {
            observedRenderer?.performanceSceneChanged = nil
            observedRenderer = renderer
            renderer?.performanceSceneChanged = { [weak self] in self?.reconcile() }
        }
        diagnosis.bind(
            renderer?.scene as? WSSStaticPlayer,
            fallback: renderer?.effectivePauseReason?.title ?? status(),
            pauseDetail: renderer?.effectivePauseReason?.title)
    }

    func resize() {
        guard let panel, let content = panel.contentView else { return }
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        guard size.width > 0, size.height > 0, panel.contentLayoutRect.size != size else { return }
        panel.setContentSize(size)
        panel.setFrameTopLeftPoint(topLeft)
        if panel.isVisible { placePanel(origin: panel.frame.origin) }
    }

    @objc private func displaysChanged() {
        reconcile()
        placePanel()
    }

    private func placePanel(origin current: NSPoint? = nil) {
        guard let panel else { return }
        let saved = defaults.array(forKey: "performance.desktop.origin") as? [Double]
        let origin = saved.flatMap { value in
            value.count == 2 && value.allSatisfy(\.isFinite)
                ? NSPoint(x: value[0], y: value[1]) : nil
        }
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let fallback = NSScreen.main?.visibleFrame ?? screens.first else { return }
        let frame = Self.restoredFrame(
            size: panel.frame.size, origin: current ?? origin, screens: screens, fallback: fallback)
        panel.setFrameOrigin(frame.origin)
    }

    static func restoredFrame(
        size: NSSize, origin: NSPoint?, screens: [NSRect], fallback: NSRect
    ) -> NSRect {
        let saved = origin.map { NSRect(origin: $0, size: size) }
        func overlap(_ area: NSRect) -> CGFloat {
            guard let saved else { return 0 }
            let intersection = area.intersection(saved)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        let matched = screens.max { overlap($0) < overlap($1) }.flatMap {
            overlap($0) > 0 ? $0 : nil
        }
        let area = matched ?? fallback
        let desired = matched == nil ? nil : origin
        let x = desired?.x ?? area.midX - size.width / 2
        let y = desired?.y ?? area.midY - size.height / 2
        return NSRect(
            x: max(area.minX, min(x, area.maxX - size.width)),
            y: max(area.minY, min(y, area.maxY - size.height)),
            width: size.width, height: size.height)
    }

    func windowDidMove(_ notification: Notification) {
        if panel?.isVisible == true { savePosition() }
    }

    private func savePosition() {
        guard let origin = panel?.frame.origin else { return }
        defaults.set([Double(origin.x), Double(origin.y)], forKey: "performance.desktop.origin")
    }

    func windowWillClose(_ notification: Notification) {
        savePosition()
        observedRenderer?.performanceSceneChanged = nil
        observedRenderer = nil
        diagnosis.setActive(false)
        panel?.delegate = nil
        panel = nil
        choices = []
        selection = nil
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
}

private struct DesktopPerformanceContent: View {
    @ObservedObject var controller: DesktopPerformancePanel

    var body: some View {
        WupsyAppearanceScope(.shared) {
            DesktopPerformanceRows(
                controller: controller, diagnosis: controller.diagnosis)
        }
    }
}

private struct DesktopPerformanceRows: View {
    @ObservedObject var controller: DesktopPerformancePanel
    @ObservedObject var diagnosis: PerformanceDiagnosis
    @Environment(\.wupsyMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if controller.choices.isEmpty {
                Text(ProductText.performanceNoDisplay.text)
                    .foregroundStyle(.secondary)
            } else {
                Picker(
                    ProductText.performanceDisplay.text,
                    selection: Binding(get: { controller.selection }, set: controller.select)
                ) {
                    ForEach(controller.choices) { choice in
                        Text(choice.name).tag(Optional(choice.id))
                    }
                }
            }
            Divider()
            PerformanceReadout(diagnosis: diagnosis)
        }
        .wupsyFont(.caption)
        .padding(12)
        .frame(width: metrics.points(310))
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: diagnosis.showsDetails) { _, _ in resize() }
        .onChange(of: controller.choices.isEmpty) { _, _ in resize() }
        .onChange(of: metrics) { _, _ in resize() }
    }

    private func resize() {
        Task { @MainActor [weak controller] in controller?.resize() }
    }
}
