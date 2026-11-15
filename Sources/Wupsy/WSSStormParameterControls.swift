import AppKit
import SwiftUI

struct WSSStormParameterControls: View {
    @ObservedObject var document: WSSEditorDocument
    let layer: WSSLayerID
    @State private var name = ""
    @State private var error: String?
    @State private var colorEnd: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(WSSStormText.title).font(.headline)
            if let storm = document.stormLayer(layer) {
                HStack {
                    TextField(WSSStormText.name, text: $name)
                        .onSubmit { rename() }
                    Button(WSSStormText.rename) { rename() }
                }
                ColorPicker(
                    WSSStormText.color,
                    selection: Binding(
                        get: {
                            Color(
                                nsColor: WSSTrailColorAdapter.system(
                                    .init(
                                        r: Float(storm.storm.red), g: Float(storm.storm.green),
                                        b: Float(storm.storm.blue))))
                        },
                        set: { color in
                            guard let linear = WSSTrailColorAdapter.linear(NSColor(color)) else {
                                return
                            }
                            if document.stormColorDrag?.0 != layer {
                                document.beginStormColorInteraction(layer)
                            }
                            do {
                                try document.setStormColor(linear, layer: layer, undo: false)
                                error = nil
                            } catch { self.error = EditorErrorPresentation.message(error) }
                            colorEnd?.cancel()
                            colorEnd = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(400))
                                guard !Task.isCancelled else { return }
                                document.endStormColorInteraction()
                            }
                        }), supportsOpacity: false)
                ForEach(
                    WSSStormParameter.allCases.filter { ![.red, .green, .blue].contains($0) },
                    id: \.self
                ) { parameter in
                    HStack {
                        Text(parameter.title).font(.caption)
                        Spacer()
                        WSSParameterTextField(
                            value: Float(parameter.value(storm.storm)),
                            range: Float(
                                parameter.range.lowerBound)...Float(parameter.range.upperBound),
                            title: parameter.title,
                            maximumFractionDigits: parameter.integral ? 0 : 3,
                            exactValue: parameter.value(storm.storm), exactRange: parameter.range,
                            commitExact: {
                                try document.setStorm(parameter, value: $0, layer: layer)
                            },
                            commit: {
                                try document.setStorm(parameter, value: Double($0), layer: layer)
                            }
                        ).frame(width: 110)
                    }
                }
                Text(WSSStormText.help).font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { name = document.stormLayer(layer)?.name ?? WSSStormText.title }
        .onDisappear {
            colorEnd?.cancel()
            document.endStormColorInteraction()
        }
        .onChange(of: layer) { _, _ in
            colorEnd?.cancel()
            document.endStormColorInteraction()
            name = document.stormLayer(layer)?.name ?? WSSStormText.title
            error = nil
        }
        .onChange(of: document.stormLayer(layer)?.name) { _, value in
            name = value ?? WSSStormText.title
        }
        .disabled(document.interactionLocked)
    }
    private func rename() {
        do {
            try document.renameStorm(layer, name: name)
            error = nil
        } catch { self.error = EditorErrorPresentation.message(error) }
    }
}
