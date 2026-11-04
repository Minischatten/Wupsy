import AppKit
import SwiftUI

struct WSSTrailParameterControls: View {
    @ObservedObject var document: WSSEditorDocument
    let layer: WSSLayerID
    @State private var error: String?
    @State private var colorEnd: Task<Void, Never>?
    @State private var activeColor: Int?
    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch { self.error = EditorErrorPresentation.message(error) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(EditorText.effectTrail.text).font(.headline)
            if let configuration = document.trailLayer(layer) {
                if configuration.colorMode == .ageGradient && configuration.colors.count == 2 {
                    ForEach(0..<2, id: \.self) { index in
                        ColorPicker(
                            index == 0 ? EditorText.trailColor1.text : EditorText.trailColor2.text,
                            selection: Binding(
                                get: {
                                    Color(
                                        nsColor: WSSTrailColorAdapter.system(
                                            configuration.colors[index]))
                                },
                                set: { color in
                                    guard let linear = WSSTrailColorAdapter.linear(NSColor(color))
                                    else { return }
                                    if activeColor != index || document.trailDrag?.0 != layer {
                                        document.beginTrailInteraction(
                                            layer,
                                            name: index == 0
                                                ? EditorText.trailColor1.text
                                                : EditorText.trailColor2.text)
                                        activeColor = index
                                    }
                                    perform {
                                        try document.setTrailColor(
                                            linear, index: index, layer: layer, undo: false)
                                    }
                                    colorEnd?.cancel()
                                    colorEnd = Task { @MainActor in
                                        try? await Task.sleep(for: .milliseconds(400))
                                        guard !Task.isCancelled else { return }
                                        document.endTrailInteraction()
                                        activeColor = nil
                                    }
                                }), supportsOpacity: false)
                    }
                } else {
                    Text(EditorText.trailLegacy.text).font(.caption)
                    Button(EditorText.trailConvert.text) {
                        perform { try document.convertTrailColors(layer) }
                    }
                }
                ForEach(WSSTrailParameter.allCases, id: \.self) { parameter in
                    VStack(alignment: .leading, spacing: 4) {
                        if parameter == .curveSmoothing {
                            Text(EditorText.trailCurveHelp.text).font(.caption)
                                .foregroundStyle(.secondary)
                            Button(EditorText.trailCurveReset.text) {
                                perform {
                                    try document.setTrail(
                                        .curveSmoothing,
                                        value: WSSTrailConfiguration.defaultCurveSmoothing,
                                        layer: layer)
                                }
                            }.disabled(
                                configuration.curveSmoothing
                                    == WSSTrailConfiguration.defaultCurveSmoothing
                            )
                            .accessibilityIdentifier("wss.trail.curve-reset")
                        }
                        Text(parameter.title).font(.caption).foregroundStyle(.secondary)
                        if let value = parameter.value(configuration) {
                            let range = parameter.slider(canvas: document.state.workingModel)
                            HStack {
                                Slider(
                                    value: Binding(
                                        get: {
                                            Double(
                                                min(range.upperBound, max(range.lowerBound, value)))
                                        },
                                        set: { newValue in
                                            perform {
                                                try document.setTrail(
                                                    parameter, value: Float(newValue), layer: layer,
                                                    undo: document.trailDrag == nil)
                                            }
                                        }), in: Double(range.lowerBound)...Double(range.upperBound),
                                    onEditingChanged: { active in
                                        colorEnd?.cancel()
                                        activeColor = nil
                                        if active {
                                            document.beginTrailInteraction(
                                                layer, name: parameter.title)
                                        } else {
                                            document.endTrailInteraction()
                                        }
                                    }
                                ).accessibilityLabel(parameter.title)
                                WSSParameterTextField(
                                    value: value, range: parameter.range, title: parameter.title,
                                    maximumFractionDigits: parameter == .length ? 1 : 2,
                                    exactValue: parameter == .lifetime
                                        ? configuration.lifetime : nil,
                                    exactRange: parameter == .lifetime
                                        ? Double.leastNonzeroMagnitude...10 : nil,
                                    commitExact: parameter == .lifetime
                                        ? { try document.setTrailLifetime($0, layer: layer) } : nil
                                ) {
                                    try document.setTrail(parameter, value: $0, layer: layer)
                                }.frame(width: 85)
                            }
                        } else {
                            Text(EditorText.trailUnlimited.text).font(.caption)
                            Button(EditorText.trailLimit.text) {
                                perform {
                                    try document.setTrail(
                                        .length,
                                        value: min(
                                            4096,
                                            max(
                                                1,
                                                Float(
                                                    min(
                                                        document.state.workingModel.canvas.width,
                                                        document.state.workingModel.canvas.height))
                                                    * 0.25)), layer: layer)
                                }
                            }
                        }
                    }
                }
            }
            Text(EditorText.trailPreviewHelp.text).font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.disabled(document.interactionLocked)
            .onDisappear {
                colorEnd?.cancel()
                document.endTrailInteraction()
            }
    }
}
