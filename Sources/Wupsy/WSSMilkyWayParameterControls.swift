import AppKit
import SwiftUI

struct WSSMilkyWayParameterControls: View {
    @ObservedObject var document: WSSEditorDocument
    let layer: WSSLayerID
    @State private var error: String?
    @State private var colorEnd: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(WSSStarfieldText.text("milkyWay.title")).font(.headline)
            if let m = document.starfieldLayer(layer)?.starfield.milkyWay {
                Toggle(
                    WSSStarfieldText.text("milkyWay.enabled"),
                    isOn: Binding(
                        get: { m.enabled },
                        set: { enabled in
                            perform {
                                try document.changeStarfield(
                                    layer, name: WSSStarfieldText.text("milkyWay.enabled")
                                ) { $0.starfield.milkyWay.enabled = enabled }
                            }
                        }))
                ColorPicker(
                    WSSStarfieldText.text("milkyWay.color"),
                    selection: Binding(
                        get: {
                            Color(
                                nsColor: WSSTrailColorAdapter.system(
                                    .init(r: Float(m.red), g: Float(m.green), b: Float(m.blue))))
                        },
                        set: { color in
                            guard let rgb = WSSTrailColorAdapter.linear(NSColor(color)) else {
                                return
                            }
                            if document.starfieldColorDrag?.0 != layer
                                || document.starfieldColorRole != .milkyWay
                            {
                                document.beginStarfieldColorInteraction(layer, role: .milkyWay)
                            }
                            perform {
                                try document.setStarfieldColor(
                                    rgb, layer: layer, role: .milkyWay, undo: false)
                            }
                            colorEnd?.cancel()
                            colorEnd = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(400))
                                guard !Task.isCancelled else { return }
                                document.endStarfieldColorInteraction()
                            }
                        }), supportsOpacity: false)
                ForEach(WSSMilkyWayParameter.allCases, id: \.self) { parameter in
                    HStack {
                        Text(parameter.title).font(.caption)
                        Spacer()
                        WSSParameterTextField(
                            value: Float(parameter.value(m)),
                            range: Float(
                                parameter.range.lowerBound)...Float(parameter.range.upperBound),
                            title: parameter.title,
                            maximumFractionDigits: parameter == .seed ? 0 : 3,
                            exactValue: parameter.value(m), exactRange: parameter.range,
                            commitExact: {
                                try document.setMilkyWay(parameter, value: $0, layer: layer)
                            },
                            commit: {
                                try document.setMilkyWay(parameter, value: Double($0), layer: layer)
                            }
                        ).frame(width: 110)
                    }
                }
                Text(WSSStarfieldText.text("milkyWay.help")).font(.caption).foregroundStyle(
                    .secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onDisappear {
            colorEnd?.cancel()
            document.endStarfieldColorInteraction()
        }
        .onChange(of: layer) { _, _ in
            colorEnd?.cancel()
            document.endStarfieldColorInteraction()
            error = nil
        }
        .disabled(document.interactionLocked)
    }
    private func perform(_ change: () throws -> Void) {
        do {
            try change()
            error = nil
        } catch { self.error = EditorErrorPresentation.message(error) }
    }
}
extension WSSEditorDocument {
    func setMilkyWay(_ parameter: WSSMilkyWayParameter, value: Double, layer: WSSLayerID) throws {
        try changeStarfield(layer, name: parameter.title) {
            try parameter.apply(value, to: &$0.starfield.milkyWay)
        }
    }
}
