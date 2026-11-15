import AppKit
import SwiftUI

struct WSSStarfieldParameterControls: View {
    @ObservedObject var document: WSSEditorDocument
    let layer: WSSLayerID
    @State private var name = ""
    @State private var error: String?
    @State private var colorEnd: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(WSSStarfieldText.title).font(.headline)
            if let value = document.starfieldLayer(layer) {
                HStack {
                    TextField(WSSStormText.name, text: $name).onSubmit { rename() }
                    Button(WSSStormText.rename) { rename() }
                }
                ColorPicker(
                    WSSStarfieldText.text("color"),
                    selection: Binding(
                        get: {
                            Color(
                                nsColor: WSSTrailColorAdapter.system(
                                    .init(
                                        r: Float(value.starfield.red),
                                        g: Float(value.starfield.green),
                                        b: Float(value.starfield.blue))))
                        },
                        set: { color in
                            guard let rgb = WSSTrailColorAdapter.linear(NSColor(color)) else {
                                return
                            }
                            if document.starfieldColorDrag?.0 != layer {
                                document.beginStarfieldColorInteraction(layer)
                            }
                            perform {
                                try document.setStarfieldColor(rgb, layer: layer, undo: false)
                            }
                            colorEnd?.cancel()
                            colorEnd = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(400))
                                guard !Task.isCancelled else { return }
                                document.endStarfieldColorInteraction()
                            }
                        }), supportsOpacity: false)
                Toggle(
                    WSSStarfieldText.text("twinkleEnabled"),
                    isOn: Binding(
                        get: { value.starfield.twinkleEnabled },
                        set: { enabled in
                            perform {
                                try document.changeStarfield(
                                    layer, name: WSSStarfieldText.text("twinkleEnabled")
                                ) { $0.starfield.twinkleEnabled = enabled }
                            }
                        }))
                ForEach(WSSStarfieldParameter.allCases, id: \.self) { parameter in
                    HStack {
                        Text(parameter.title).font(.caption)
                        Spacer()
                        WSSParameterTextField(
                            value: Float(parameter.value(value.starfield)),
                            range: Float(
                                parameter.range.lowerBound)...Float(parameter.range.upperBound),
                            title: parameter.title,
                            maximumFractionDigits: parameter.integral ? 0 : 3,
                            exactValue: parameter.value(value.starfield),
                            exactRange: parameter.range,
                            commitExact: {
                                try document.setStarfield(parameter, value: $0, layer: layer)
                            },
                            commit: {
                                try document.setStarfield(
                                    parameter, value: Double($0), layer: layer)
                            }
                        ).frame(width: 110)
                    }
                }
                Text(WSSStarfieldText.text("help")).font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { name = document.starfieldLayer(layer)?.name ?? WSSStarfieldText.title }
        .onChange(of: layer) { _, _ in
            colorEnd?.cancel()
            document.endStarfieldColorInteraction()
            name = document.starfieldLayer(layer)?.name ?? WSSStarfieldText.title
            error = nil
        }
        .onChange(of: document.starfieldLayer(layer)?.name) { _, value in
            name = value ?? WSSStarfieldText.title
        }
        .onDisappear {
            colorEnd?.cancel()
            document.endStarfieldColorInteraction()
        }
        .disabled(document.interactionLocked)
    }
    private func perform(_ change: () throws -> Void) {
        do {
            try change()
            error = nil
        } catch { self.error = EditorErrorPresentation.message(error) }
    }
    private func rename() {
        perform {
            try document.changeStarfield(layer, name: WSSStormText.rename) {
                $0.name = try WallpaperTitle.normalized(name)
            }
        }
    }
}
