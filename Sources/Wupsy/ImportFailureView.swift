import AppKit
import SwiftUI

struct ImportFailureView: View {
    @Environment(\.dismiss) private var dismiss
    let report: ImportFailureReport
    @State private var expanded: Set<UUID> = []
    @FocusState private var closeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ImportText.failures.format(Int64(report.failures.count)))
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(report.failures.enumerated()), id: \.element.id) {
                        index, failure in
                        failureView(failure, index: index)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
            }
            .frame(
                height: min(
                    380, CGFloat(report.failures.count) * 140 + (expanded.isEmpty ? 0 : 220)))
            HStack {
                Spacer()
                Button(ImportText.close.text) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .focused($closeFocused)
            }
        }
        .padding(24).frame(width: 560)
        .onAppear { closeFocused = true }
        .onExitCommand { dismiss() }
    }

    private func failureView(_ failure: ImportFailurePresentation, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                report.failures.count > 1
                    ? ImportText.sourceNumber.format(Int64(index + 1), failure.sourceName)
                    : failure.sourceName
            )
            .font(.subheadline).foregroundStyle(.secondary)
            .textSelection(.enabled)
            Text(failure.title).fontWeight(.semibold)
            Text(failure.explanation)
            ImportDetailsButton(
                sourceName: failure.sourceName,
                isExpanded: Binding(
                    get: { expanded.contains(failure.id) },
                    set: { value in
                        if value {
                            expanded.insert(failure.id)
                        } else {
                            expanded.remove(failure.id)
                        }
                    })
            ).fixedSize()
            if expanded.contains(failure.id) {
                VStack(alignment: .leading, spacing: 10) {
                    ScrollView {
                        Text(failure.technicalDetails)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 170)
                    Button(ImportText.copyDetails.text) {
                        Self.copy(failure, to: .general)
                    }
                    .accessibilityLabel(ImportText.copyAccessibility.format(failure.sourceName))
                }.padding(.top, 8)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor static func copy(_ failure: ImportFailurePresentation, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(failure.copyText, forType: .string)
    }
}

// One native button owns both the symbol and title. The default macOS
// DisclosureGroup used a separately focused chevron with a narrow hit target;
// remove that control rather than hiding its focus ring under an overlay.
struct ImportDetailsButton: NSViewRepresentable {
    let sourceName: String
    @Binding var isExpanded: Bool
    var language: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator(isExpanded: $isExpanded) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: ImportText.details.localized(language: language), target: context.coordinator,
            action: #selector(Coordinator.toggle(_:)))
        button.setButtonType(.pushOnPushOff)
        button.isBordered = false
        // Focus remains keyboard-accessible; only the native ring is disabled.
        button.focusRingType = .none
        button.imagePosition = .imageLeading
        if let cell = button.cell as? NSButtonCell {
            cell.highlightsBy = []
            cell.showsStateBy = []
        }
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.isExpanded = $isExpanded
        button.title = ImportText.details.localized(language: language)
        button.state = isExpanded ? .on : .off
        button.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil)?.withSymbolConfiguration(
                .init(pointSize: 10, weight: .semibold))
        button.setAccessibilityLabel(
            ImportText.detailsAccessibility.format(sourceName, language: language))
        button.setAccessibilityValueDescription(
            (isExpanded ? ProductText.expanded : .collapsed).localized(language: language))
        button.sizeToFit()
    }
    final class Coordinator: NSObject {
        var isExpanded: Binding<Bool>
        init(isExpanded: Binding<Bool>) { self.isExpanded = isExpanded }
        @objc func toggle(_ sender: NSButton) { isExpanded.wrappedValue = sender.state == .on }
    }
}
