import SwiftUI

struct WSSRainParameterControls: View {
    @ObservedObject var document: WSSEditorDocument
    let layer: WSSLayerID
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(EditorText.effectRain.text).font(.headline)
            ForEach(WSSRainParameter.allCases, id: \.self) { parameter in
                if let rain = document.rainLayer(layer) {
                    let value = parameter.value(rain.rain.effect)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(parameter.title).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Slider(
                                value: Binding(
                                    get: {
                                        Double(
                                            min(
                                                parameter.sliderRange.upperBound,
                                                max(parameter.sliderRange.lowerBound, value)))
                                    },
                                    set: {
                                        do {
                                            try document.setRain(
                                                parameter, value: Float($0), layer: layer,
                                                undo: document.rainDrag == nil)
                                            error = nil
                                        } catch {
                                            self.error = EditorErrorPresentation.message(error)
                                        }
                                    }),
                                in: Double(
                                    parameter.sliderRange.lowerBound)...Double(
                                        parameter.sliderRange.upperBound),
                                onEditingChanged: { active in
                                    if active {
                                        document.beginRainSlider(parameter, layer: layer)
                                    } else {
                                        document.endRainSlider()
                                    }
                                }
                            )
                            .accessibilityLabel(parameter.title)
                            WSSParameterTextField(
                                value: value, range: parameter.range, title: parameter.title,
                                maximumFractionDigits: parameter.displayFractionDigits
                            ) {
                                try document.setRain(parameter, value: $0, layer: layer)
                            }.frame(width: 85)
                        }
                    }
                }
            }
            Text(EditorText.rainLayerHelp.text).font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.disabled(document.interactionLocked)
    }
}

// Display policy only. Persisted parameter ranges and values remain untouched.
extension WSSRainParameter {
    var displayFractionDigits: Int {
        if case .width = self { return 2 }
        return 1
    }
}
