import AppKit
import MetalKit
import SwiftUI

@MainActor final class PerformanceDiagnosis: ObservableObject {
    struct Details {
        let counts: SceneContentCounts?
        let footprint: UInt64?
        let cpuFraction: Double?
        let metal: UInt64?
    }

    private let defaults: UserDefaults
    private let detailsKey: String
    private let resourceConsumer = NSObject()
    private let resourceSampler: PerformanceResourceSampler
    private weak var player: WSSStaticPlayer?
    private var sampling: Task<Void, Never>?
    private var publicationScheduled = false
    private(set) var active = false
    private(set) var snapshot: ScenePerformanceSnapshot?
    private(set) var details: Details?
    private var fallbackStatus: String?

    @Published var showsDetails = false {
        didSet {
            guard showsDetails != oldValue else { return }
            if defaults.bool(forKey: detailsKey) != showsDetails {
                defaults.set(showsDetails, forKey: detailsKey)
            }
            details = nil
            updateResourceDemand()
        }
    }

    init(
        defaults: UserDefaults, detailsKey: String,
        resourceSampler: PerformanceResourceSampler? = nil
    ) {
        self.resourceSampler = resourceSampler ?? .shared
        self.defaults = defaults
        self.detailsKey = detailsKey
    }

    deinit {
        sampling?.cancel()
    }

    var status: String? {
        guard let player else { return fallbackStatus }
        switch player.rendererStatus {
        case .paused: return ProductText.performancePaused.text
        case .onDemand: return ProductText.performanceOnDemand.text
        case .running: return ProductText.performanceRunning.text
        case .stopped: return ProductText.playbackStopped.text
        case .failed: return ProductText.performanceFailed.text
        }
    }

    var targetFPS: Int? { player?.view.preferredFramesPerSecond }

    func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        if value {
            showsDetails = defaults.bool(forKey: detailsKey)
            sampling = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    self?.sample()
                }
            }
        } else {
            sampling?.cancel()
            sampling = nil
            bind(nil)
            invalidate()
        }
        updateResourceDemand()
        publish()
    }

    private func updateResourceDemand() {
        resourceSampler.setDemand(active && showsDetails, for: resourceConsumer)
    }

    func bind(_ candidate: WSSStaticPlayer?, fallback: String? = nil) {
        let next = active ? candidate : nil
        if player !== next {
            player?.performanceInvalidated = nil
            player?.stopMeasuring()
            player = next
            if let next {
                next.startMeasuring()
                next.performanceInvalidated = { [weak self] in self?.invalidate() }
            }
            invalidate()
        }
        if fallbackStatus != fallback {
            fallbackStatus = fallback
            publish()
        }
    }

    private func invalidate() {
        snapshot = nil
        details = nil
        publish()
    }

    // Player installation can occur during an NSViewRepresentable update or layout.
    private func publish() {
        guard !publicationScheduled else { return }
        publicationScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.publicationScheduled = false
            self?.objectWillChange.send()
        }
    }

    func sample() {
        guard active else { return }
        snapshot = player?.performanceSnapshot()
        if showsDetails {
            let process = resourceSampler.processReading()
            let metal = player.flatMap { player in
                resourceSampler.metalBytes(registryID: player.resources.device.registryID) {
                    player.metalAllocation()?.bytes
                }
            }
            details = Details(
                counts: player.map { ($0.fogDragPreview ?? $0.resources).performanceContentCounts },
                footprint: process?.footprint, cpuFraction: process?.cpuFraction, metal: metal)
        }
        publish()
    }
}

struct PerformanceValueFormat {
    var locale: Locale = Locale(
        identifier: Localization.bundle.preferredLocalizations.first ?? "en")
    static let missing = "—"

    func number(_ value: Double?, digits: Int) -> String {
        guard let value, value.isFinite else { return Self.missing }
        return value.formatted(.number.precision(.fractionLength(digits)).locale(locale))
    }

    func integer(_ value: Int?) -> String {
        value?.formatted(.number.locale(locale)) ?? Self.missing
    }

    func milliseconds(_ value: Double?) -> String {
        guard let value, value.isFinite else { return Self.missing }
        return Measurement(value: value, unit: UnitDuration.milliseconds).formatted(
            .measurement(
                width: .abbreviated, usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(3))
            ).locale(locale))
    }

    func pixels(_ width: Int?, _ height: Int?) -> String {
        guard let width, let height else { return Self.missing }
        return "\(integer(width)) × \(integer(height))"
    }

    func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return Self.missing }
        return value.formatted(.percent.precision(.fractionLength(1)).locale(locale))
    }

    func memory(_ bytes: UInt64?) -> String {
        guard let bytes else { return Self.missing }
        return "\(number(Double(bytes) / 1_048_576, digits: 1)) MiB"
    }
}

struct PerformanceReadout: View {
    @ObservedObject var diagnosis: PerformanceDiagnosis
    private let format = PerformanceValueFormat()

    var body: some View {
        let snapshot = diagnosis.snapshot
        let frames = snapshot?.frameWindow
        VStack(alignment: .leading, spacing: 5) {
            row(.performanceStatus, diagnosis.status ?? PerformanceValueFormat.missing)
            row(.performanceTargetFPS, format.integer(diagnosis.targetFPS), .performanceTargetHelp)
            row(
                .performancePresentedFPS, format.number(frames?.presentedFPS, digits: 1),
                .performancePresentedHelp)
            row(
                .performanceGPUCompletions,
                format.number(frames?.gpuCompletionsPerSecond, digits: 1),
                .performanceCompletionsHelp)
            row(
                .performanceCPUEncoding, format.milliseconds(frames?.averageCPUMilliseconds),
                .performanceCPUHelp)
            row(
                .performanceGPUTime, format.milliseconds(frames?.averageGPUMilliseconds),
                .performanceGPUHelp)

            DisclosureGroup(
                ProductText.performanceDetails.text, isExpanded: $diagnosis.showsDetails
            ) {
                VStack(alignment: .leading, spacing: 5) {
                    let actual = snapshot?.submittedDrawableSize
                    let target = snapshot?.targetDrawableSize
                    let details = diagnosis.details
                    row(
                        .performanceDrawable, format.pixels(actual?.width, actual?.height),
                        .performanceDrawableHelp)
                    row(
                        .performanceTargetSize,
                        format.pixels(target.map { Int($0.width) }, target.map { Int($0.height) }))
                    row(.performanceLayers, format.integer(details?.counts?.visibleLayers))
                    row(
                        .performanceEffects, format.integer(details?.counts?.effectiveEffects),
                        .performanceEffectsHelp)
                    Divider().padding(.vertical, 2)
                    Text(ProductText.performanceMemoryScope.text)
                        .wupsyFont(.caption2).foregroundStyle(.secondary)
                    row(
                        .performanceFootprint, format.memory(details?.footprint),
                        .performanceFootprintHelp)
                    row(.performanceMetal, format.memory(details?.metal), .performanceMetalHelp)
                    row(
                        .performanceProcessCPU, format.percent(details?.cpuFraction),
                        .performanceProcessCPUHelp)
                }.padding(.top, 5)
            }.disclosureGroupStyle(PerformanceDisclosureStyle()).padding(.top, 5)
        }.wupsyFont(.caption)
    }

    private func row(_ label: ProductText, _ value: String, _ help: ProductText? = nil) -> some View
    {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label.text).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .help(help?.text ?? label.text)
    }
}

private struct PerformanceDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.wupsyMetrics) private var metrics

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(minHeight: metrics.target(24))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("performance-details-toggle")
            .accessibilityValue(
                configuration.isExpanded
                    ? ProductText.performanceShown.text : ProductText.performanceHidden.text)
            if configuration.isExpanded { configuration.content }
        }
    }
}

struct EditorPerformanceOverlay: View {
    @ObservedObject var diagnosis: PerformanceDiagnosis
    let toggle: () -> Void
    var metrics: WupsyMetrics
    var availableSize: CGSize = .zero

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Button(action: toggle) {
                Label(ProductText.performanceTitle.text, systemImage: "gauge")
                    .wupsyFont(.caption)
                    .foregroundStyle(diagnosis.active ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 7)
                    .frame(minHeight: metrics.target(24))
                    .contentShape(Rectangle())
            }
            .help(ProductText.performanceTitle.text)
            .accessibilityLabel(ProductText.performanceTitle.text)
            .accessibilityValue(
                diagnosis.active
                    ? ProductText.performanceShown.text : ProductText.performanceHidden.text
            )
            .accessibilityIdentifier("wss-performance-toggle")
            if diagnosis.active {
                ScrollView {
                    PerformanceReadout(diagnosis: diagnosis)
                        .padding(10)
                }
                .frame(
                    width: min(metrics.points(286), availableSize.width),
                    height: min(
                        metrics.points(diagnosis.showsDetails ? 330 : 163),
                        max(0, availableSize.height - metrics.points(36)))
                )
                .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .fixedSize()
        .environment(\.wupsyMetrics, metrics)
        .environment(\.colorScheme, .dark)
    }
}
