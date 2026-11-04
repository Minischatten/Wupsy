import AppKit
import SwiftUI

struct WSSEditorParameterControls: View {
    @ObservedObject var document: WSSEditorDocument
    let layerID: WSSLayerID
    let effectID: WSSEffectID
    private var address: WSSEffectAddress? { document.identity.address(layerID, effect: effectID) }
    var body: some View {
        ForEach(WSSEditorParameter.allCases.filter { !$0.isAdvancedRipple }, id: \.self) {
            parameter in
            control(parameter)
        }
        if let address,
            WSSEditorParameter.cloudsBrightness.value(in: document.state.workingModel, at: address)
                != nil
        {
            Text(EditorText.cloudsMotionToneHelp.text).font(.caption).foregroundStyle(.secondary)
        }
        if let address,
            let seed = WSSEditorParameter.rippleSeed(in: document.state.workingModel, at: address)
        {
            DisclosureGroup(EditorText.rippleAdvanced.text) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(WSSEditorParameter.allCases.filter(\.isAdvancedRipple), id: \.self) {
                        parameter in
                        control(parameter)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(EditorText.rippleSeed.text).font(.caption).foregroundStyle(.secondary)
                        WSSParameterTextField(
                            value: Float(seed), range: 0...Float(UInt32.max),
                            title: EditorText.rippleSeed.text, maximumFractionDigits: 0,
                            exactValue: Double(seed), exactRange: 0...Double(UInt32.max),
                            commitExact: { value in
                                if let current = self.address {
                                    try document.setRippleSeed(at: current, value: value)
                                }
                            },
                            commit: { _ in
                                throw WSSDocumentError.invalid("exact seed input required")
                            }
                        )
                    }
                    Text(EditorText.rippleLateralHelp.text).font(.caption).foregroundStyle(
                        .secondary)
                }.padding(.top, 6)
            }.disabled(document.interactionLocked)
        }
    }
    @ViewBuilder private func control(_ parameter: WSSEditorParameter) -> some View {
        if let address,
            let value = parameter.value(in: document.state.workingModel, at: address)
        {
            let sliderRange = parameter.sliderRange(
                in: document.state.workingModel, at: address)
            VStack(alignment: .leading, spacing: 4) {
                Text(parameter.title).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Slider(
                        value: Binding(
                            get: {
                                Double(
                                    min(
                                        max(value, sliderRange.lowerBound),
                                        sliderRange.upperBound))
                            },
                            set: {
                                if let current = self.address {
                                    try? document.updateSlider(
                                        parameter, at: current, value: Float($0))
                                }
                            }),
                        in: Double(
                            sliderRange.lowerBound)...Double(
                                max(sliderRange.lowerBound + 0.001, sliderRange.upperBound)),
                        onEditingChanged: { editing in
                            if editing {
                                if let current = self.address {
                                    document.beginSlider(parameter, at: current)
                                }
                            } else {
                                document.endSlider()
                            }
                        }
                    )
                    .disabled(sliderRange.upperBound == sliderRange.lowerBound)
                    .accessibilityLabel(parameter.title)
                    WSSParameterTextField(
                        value: value, range: parameter.validRange, title: parameter.title,
                        maximumFractionDigits: parameter.displayFractionDigits
                    ) {
                        if let current = self.address {
                            try document.setParameter(parameter, at: current, value: $0)
                        }
                    }.frame(width: 85)
                }
            }.disabled(document.interactionLocked)
        }
    }

}

extension WSSEditorParameter {
    var displayFractionDigits: Int? {
        switch self {
        case .cloudsIntensity, .cloudsDensity, .cloudsScale,
            .cloudsVelocityX, .cloudsVelocityY, .cloudsBrightness,
            .cloudsSecondaryVelocityX, .cloudsSecondaryVelocityY,
            .rippleAmplitude, .rippleWavelength, .rippleTravelSpeed,
            .rippleStretch, .rippleDirection, .rippleStructureRotation,
            .rippleEvolution, .rippleLateralDetail:
            return 2
        default: return nil
        }
    }
}

// Shared presentation policy; nil retains existing roundtrip formatting for other controls.
struct WSSParameterNumberPresentation {
    var maximumFractionDigits: Int? = nil
    var locale: Locale = .current
    func display(_ value: Float) -> String {
        guard let digits = maximumFractionDigits else { return String(value) }
        return Double(value).formatted(
            .number.grouping(.never).precision(.fractionLength(0...digits)).locale(locale))
    }
    func editing(_ value: Float) -> String {
        guard maximumFractionDigits != nil else { return String(value) }
        return String(value).replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }
}

struct WSSParameterTextField: NSViewRepresentable {
    let value: Float
    let range: ClosedRange<Float>
    let title: String
    var maximumFractionDigits: Int? = nil
    var locale: Locale = .current
    var presentation: WSSParameterNumberPresentation {
        .init(maximumFractionDigits: maximumFractionDigits, locale: locale)
    }
    // Exact scalar path for trail lifetime and UInt32 seeds (never round through Float).
    var exactValue: Double? = nil
    var exactRange: ClosedRange<Double>? = nil
    var commitExact: ((Double) throws -> Void)? = nil
    let commit: (Float) throws -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSStackView {
        let field = NSTextField(string: presentation.display(value))
        context.coordinator.show(value, in: field)
        field.delegate = context.coordinator
        field.setAccessibilityLabel(title)
        let hint = NSTextField(wrappingLabelWithString: "")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .systemRed
        hint.isHidden = true
        let stack = NSStackView(views: [field, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        context.coordinator.field = field
        context.coordinator.hint = hint
        return stack
    }
    func updateNSView(_ view: NSStackView, context: Context) {
        if let field = context.coordinator.field {
            context.coordinator.synchronize(self, in: field)
        }
        context.coordinator.field?.isEnabled = context.environment.isEnabled
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: WSSParameterTextField
        weak var field: NSTextField?
        weak var hint: NSTextField?
        // Keep the displayed baseline separate from the full-precision model.
        // Text edits are drafts until Return or a validated focus change.
        private var editing = false
        private var unchangedText: String?
        private var unchangedExact: Double?
        private var unchangedValue: Float
        init(_ parent: WSSParameterTextField) {
            self.parent = parent
            unchangedValue = parent.value
            unchangedExact = parent.exactValue
            if let exact = parent.exactValue {
                unchangedText = exact.formatted(
                    .number.grouping(.never).precision(
                        .fractionLength(0...(parent.maximumFractionDigits ?? 16))
                    ).locale(parent.locale))
            } else {
                unchangedText = parent.presentation.display(parent.value)
            }
        }
        private func hasDraft(in field: NSTextField) -> Bool {
            field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                != unchangedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func synchronize(_ next: WSSParameterTextField, in field: NSTextField) {
            let changed =
                parent.value.bitPattern != next.value.bitPattern
                || parent.exactValue?.bitPattern != next.exactValue?.bitPattern
            parent = next
            if editing || field.currentEditor() != nil {
                guard changed else { return }
                if hasDraft(in: field) {
                    // Preserve an active draft, but Escape/no-change confirmation
                    // must return to the latest slider/undo value, not stale data.
                    unchangedValue = next.value
                    unchangedExact = next.exactValue
                    return
                }
            }
            show(next.value, in: field)
        }
        private func restore(in field: NSTextField) {
            if let exact = unchangedExact {
                showExact(exact, in: field)
            } else {
                show(unchangedValue, in: field)
            }
        }
        func showExact(_ value: Double, in field: NSTextField) {
            let digits = parent.maximumFractionDigits ?? 16
            let text = value.formatted(
                .number.grouping(.never).precision(.fractionLength(0...digits)).locale(
                    parent.locale))
            field.stringValue = text
            field.currentEditor()?.string = text
            unchangedText = text
            unchangedExact = value
        }
        func show(_ value: Float, in field: NSTextField) {
            if let exact = parent.exactValue {
                showExact(exact, in: field)
                return
            }
            let text = parent.presentation.display(value)
            field.stringValue = text
            field.currentEditor()?.string = text
            unchangedText = text
            unchangedValue = value
            unchangedExact = nil
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            editing = true
            // AppKit can deliver this after the first deletion. Never rewrite the
            // text or capture that first keystroke as an unchanged baseline.
            if let field = notification.object as? NSTextField {
                self.field = field
                (field.currentEditor() as? NSTextView)?.allowsUndo = false
            }
        }
        func controlTextDidChange(_ notification: Notification) {
            hint?.isHidden = true
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            editing = false
        }

        func accept(_ field: NSTextField) -> Bool {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hasDraft(in: field) {
                restore(in: field)
                hint?.isHidden = true
                return true
            }
            if let commit = parent.commitExact, let range = parent.exactRange {
                guard let value = Double(text.replacingOccurrences(of: ",", with: ".")),
                    value.isFinite, range.contains(value)
                else {
                    hint?.stringValue = EditorText.numberRange.text
                    hint?.isHidden = false
                    return false
                }
                do {
                    if value != unchangedExact { try commit(value) }
                    showExact(value, in: field)
                    hint?.isHidden = true
                    return true
                } catch {
                    hint?.stringValue = EditorErrorPresentation.message(error)
                    hint?.isHidden = false
                    return false
                }
            }
            // Float's roundtrip spelling preserves untouched persisted values exactly.
            guard let value = Float(text.replacingOccurrences(of: ",", with: ".")), value.isFinite,
                parent.range.contains(value)
            else {
                hint?.stringValue = EditorText.numberRange.text
                hint?.isHidden = false
                return false
            }
            do {
                if value != unchangedValue { try parent.commit(value) }
                show(value, in: field)
                hint?.isHidden = true
                return true
            } catch {
                hint?.stringValue = EditorErrorPresentation.message(error)
                hint?.isHidden = false
                return false
            }
        }
        func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
            guard let field = control as? NSTextField else { return true }
            return accept(field)
        }
        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            guard let field = control as? NSTextField else { return false }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                restore(in: field)
                hint?.isHidden = true
                field.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if accept(field) { field.window?.makeFirstResponder(nil) }
                return true
            }
            return false
        }
    }
}
