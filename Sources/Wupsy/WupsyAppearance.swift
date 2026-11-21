import AppKit
import Combine
import SwiftUI

enum WupsyInterfaceScale: Int, CaseIterable {
    case standard = 100
    case large = 125
    case largest = 150

    var factor: CGFloat { CGFloat(rawValue) / 100 }
    var title: String { (Double(rawValue) / 100).formatted(.percent) }
}

@MainActor final class WupsyAppearance: ObservableObject {
    static let key = "interfaceScale"
    static let shared = WupsyAppearance(
        defaults:
            CommandLine.arguments.contains("--benchmark")
            ? UserDefaults(suiteName: ProductIdentity.benchmarkDomain)! : .standard)

    private let defaults: UserDefaults
    @Published var scale: WupsyInterfaceScale {
        didSet {
            if oldValue != scale { defaults.set(scale.rawValue, forKey: Self.key) }
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let value = defaults.object(forKey: Self.key) as? Int,
            let stored = WupsyInterfaceScale(rawValue: value)
        {
            scale = stored
        } else {
            scale = .standard
            if defaults.object(forKey: Self.key) != nil {
                defaults.set(scale.rawValue, forKey: Self.key)
            }
        }
    }
}

struct WupsyMetrics: Equatable {
    var scale: WupsyInterfaceScale = .standard
    func points(_ value: CGFloat) -> CGFloat { value * scale.factor }
    func spacing(_ value: CGFloat) -> CGFloat { points(value) }
    func target(_ value: CGFloat) -> CGFloat { points(value) }
    var controlSize: ControlSize {
        switch scale {
        case .standard: return .regular
        case .large: return .large
        case .largest: return .extraLarge
        }
    }
    var nativeControlSize: NSControl.ControlSize { scale == .standard ? .regular : .large }
}

private struct WupsyMetricsKey: EnvironmentKey {
    static let defaultValue = WupsyMetrics()
}
extension EnvironmentValues {
    var wupsyMetrics: WupsyMetrics {
        get { self[WupsyMetricsKey.self] }
        set { self[WupsyMetricsKey.self] = newValue }
    }
}

struct WupsyAppearanceScope<Content: View>: View {
    @ObservedObject var appearance: WupsyAppearance
    let content: Content

    init(_ appearance: WupsyAppearance, @ViewBuilder content: () -> Content) {
        self.appearance = appearance
        self.content = content()
    }

    var body: some View {
        let metrics = WupsyMetrics(scale: appearance.scale)
        content.environment(\.wupsyMetrics, metrics)
            .font(appearance.scale == .standard ? nil : .system(size: metrics.points(13)))
            .controlSize(metrics.controlSize)
    }
}

enum WupsyTextRole {
    case body, headline, subheadline, callout, caption, caption2, footnote, title, title2, title3,
        largeTitle

    var native: Font {
        switch self {
        case .body: return .body
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .caption: return .caption
        case .caption2: return .caption2
        case .footnote: return .footnote
        case .title: return .title
        case .title2: return .title2
        case .title3: return .title3
        case .largeTitle: return .largeTitle
        }
    }

    var points: CGFloat {
        switch self {
        case .body, .headline: return 13
        case .subheadline: return 11
        case .callout: return 12
        case .caption, .footnote: return 10
        case .caption2: return 9
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .largeTitle: return 26
        }
    }
}

private struct WupsyFont: ViewModifier {
    @Environment(\.wupsyMetrics) private var metrics
    var role: WupsyTextRole?
    var size: CGFloat
    var weight: Font.Weight?
    var design: Font.Design?

    func body(content: Content) -> some View {
        if let role, metrics.scale == .standard {
            content.font(role.native)
        } else {
            content.font(.system(size: metrics.points(size), weight: weight, design: design))
        }
    }
}

extension View {
    func wupsyFont(_ role: WupsyTextRole) -> some View {
        modifier(
            WupsyFont(
                role: role, size: role.points, weight: role == .headline ? .semibold : nil,
                design: nil))
    }

    func wupsyFont(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil)
        -> some View
    {
        modifier(WupsyFont(role: nil, size: size, weight: weight, design: design))
    }
}

struct WupsyAppearanceSettings: View {
    @ObservedObject var appearance: WupsyAppearance
    @Environment(\.wupsyMetrics) private var metrics

    var body: some View {
        Form {
            Section(WupsyAppearanceText.text("title")) {
                Picker(WupsyAppearanceText.text("scale"), selection: $appearance.scale) {
                    ForEach(WupsyInterfaceScale.allCases, id: \.self) { scale in
                        Text(scale.title).tag(scale)
                    }
                }
                Text(WupsyAppearanceText.text("detail"))
                    .wupsyFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: metrics.points(330), minHeight: metrics.points(166))
    }
}

enum WupsyAppearanceText {
    static func text(_ key: String) -> String { Localization.string(key: "appearance." + key) }
}

private struct WupsyControlSizing: ViewModifier {
    @Environment(\.wupsyMetrics) private var metrics
    let base: ControlSize
    func body(content: Content) -> some View {
        content.controlSize(metrics.scale == .standard ? base : metrics.controlSize)
    }
}

private struct WupsySpacing: ViewModifier {
    @Environment(\.wupsyMetrics) private var metrics
    let edges: Edge.Set
    let amount: CGFloat
    func body(content: Content) -> some View {
        content.padding(edges, metrics.spacing(amount))
    }
}

private struct WupsyControlFrame: ViewModifier {
    @Environment(\.wupsyMetrics) private var metrics
    let width: CGFloat?
    let height: CGFloat?
    func body(content: Content) -> some View {
        content.frame(width: width.map(metrics.target), height: height.map(metrics.target))
    }
}

extension View {
    func wupsyControlSize(_ base: ControlSize) -> some View {
        modifier(WupsyControlSizing(base: base))
    }

    func wupsyPadding(_ edges: Edge.Set = .all, _ amount: CGFloat) -> some View {
        modifier(WupsySpacing(edges: edges, amount: amount))
    }

    func wupsyControlFrame(width: CGFloat? = nil, height: CGFloat? = nil) -> some View {
        modifier(WupsyControlFrame(width: width, height: height))
    }
}

// Standalone Wupsy panels do not inherit the Library window's SwiftUI environment.
@MainActor
final class WupsyPanelHostingView<Content: View>: NSHostingView<WupsyAppearanceScope<Content>> {
    private var scaleObservation: AnyCancellable?

    init(appearance: WupsyAppearance, root: Content) {
        super.init(rootView: WupsyAppearanceScope(appearance) { root })
        scaleObservation = appearance.$scale.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.fitWindow()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @available(*, unavailable)
    required init(rootView: WupsyAppearanceScope<Content>) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fitWindow()
    }

    private func fitWindow() {
        guard let window else { return }
        layoutSubtreeIfNeeded()
        let proposed = fittingSize
        guard proposed.width > 0, proposed.height > 0 else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        guard let visible else {
            window.setContentSize(proposed)
            return
        }
        let available = window.contentRect(forFrameRect: visible).size
        let size = NSSize(
            width: min(proposed.width, available.width),
            height: min(proposed.height, available.height))
        let previous = window.frame
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        let frame = NSRect(
            x: min(max(previous.minX, visible.minX), visible.maxX - frameSize.width),
            y: max(visible.minY, min(previous.maxY, visible.maxY) - frameSize.height),
            width: frameSize.width, height: frameSize.height)
        window.setFrame(frame, display: window.isVisible)
    }
}
