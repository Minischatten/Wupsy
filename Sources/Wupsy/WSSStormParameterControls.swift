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
            Text(WSSStormText.title).wupsyFont(.headline)
            if let storm = document.stormLayer(layer) {
                HStack {
                    TextField(WSSStormText.name, text: $name)
                        .onSubmit { rename() }
                    Button(WSSStormText.rename) { rename() }
                }
                Toggle(
                    WSSStormText.boltEnabled,
                    isOn: Binding(
                        get: { storm.storm.boltEnabled },
                        set: { value in
                            perform { try document.setStormBoltEnabled(value, layer: layer) }
                        }))
                colorPicker(storm.storm, role: .bolt)
                ForEach(
                    WSSStormParameter.allCases.filter { ![.red, .green, .blue].contains($0) },
                    id: \.self
                ) { parameter in
                    HStack {
                        Text(parameter.title).wupsyFont(.caption)
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
                        ).wupsyControlFrame(width: 110)
                    }
                }
                Divider()
                Toggle(
                    WSSStormText.lightEnabled,
                    isOn: Binding(
                        get: { storm.storm.illumination.enabled },
                        set: { value in
                            perform {
                                try document.setStormIlluminationEnabled(value, layer: layer)
                            }
                        }))
                colorPicker(storm.storm, role: .illumination)
                ForEach(WSSStormIlluminationParameter.allCases, id: \.self) { parameter in
                    HStack {
                        Text(parameter.title).wupsyFont(.caption)
                        Spacer()
                        WSSParameterTextField(
                            value: Float(parameter.value(storm.storm.illumination)),
                            range: Float(
                                parameter.range.lowerBound)...Float(parameter.range.upperBound),
                            title: parameter.title, maximumFractionDigits: 3,
                            exactValue: parameter.value(storm.storm.illumination),
                            exactRange: parameter.range,
                            commitExact: {
                                try document.setStormIllumination(
                                    parameter, value: $0, layer: layer)
                            },
                            commit: {
                                try document.setStormIllumination(
                                    parameter, value: Double($0), layer: layer)
                            }
                        ).wupsyControlFrame(width: 110)
                    }
                }
                Text(WSSStormText.lightHelp).wupsyFont(.caption).foregroundStyle(.secondary)
                Text(WSSStormText.help).wupsyFont(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).wupsyFont(.caption).foregroundStyle(.red) }
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
    private func perform(_ change: () throws -> Void) {
        do {
            try change()
            error = nil
        } catch { self.error = EditorErrorPresentation.message(error) }
    }
    private func colorPicker(_ c: WSSStormConfiguration, role: WSSStormColorRole) -> some View {
        let color =
            role == .bolt
            ? WSSTrailColor(r: Float(c.red), g: Float(c.green), b: Float(c.blue))
            : WSSTrailColor(
                r: Float(c.illumination.red), g: Float(c.illumination.green),
                b: Float(c.illumination.blue))
        return ColorPicker(
            role == .bolt ? WSSStormText.color : WSSStormText.lightColor,
            selection: Binding(
                get: { Color(nsColor: WSSTrailColorAdapter.system(color)) },
                set: { value in
                    guard let linear = WSSTrailColorAdapter.linear(NSColor(value)) else { return }
                    if document.stormColorDrag?.0 != layer || document.stormColorRole != role {
                        document.beginStormColorInteraction(layer, role: role)
                    }
                    perform {
                        try document.setStormColor(linear, layer: layer, role: role, undo: false)
                    }
                    colorEnd?.cancel()
                    colorEnd = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        document.endStormColorInteraction()
                    }
                }), supportsOpacity: false)
    }
    private func rename() {
        do {
            try document.renameStorm(layer, name: name)
            error = nil
        } catch { self.error = EditorErrorPresentation.message(error) }
    }
}
