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
            Text(WSSStarfieldText.title).wupsyFont(.headline)
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
                            if document.starfieldColorDrag?.0 != layer
                                || document.starfieldColorRole != .stars
                            {
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
                        Text(parameter.title).wupsyFont(.caption)
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
                        ).wupsyControlFrame(width: 110)
                    }
                }
                Text(WSSStarfieldText.text("help")).wupsyFont(.caption).foregroundStyle(.secondary)
                WSSMilkyWayParameterControls(document: document, layer: layer)
                Divider()
                Text(WSSStarfieldText.text("shootingStars.title")).wupsyFont(.headline)
                Toggle(
                    WSSStarfieldText.text("shootingStars.enabled"),
                    isOn: Binding(
                        get: { value.starfield.shootingStars.enabled },
                        set: { enabled in
                            perform { try document.setShootingStarsEnabled(enabled, layer: layer) }
                        }))
                Text(WSSStarfieldText.text("shootingStars.color.help")).wupsyFont(.caption)
                    .foregroundStyle(.secondary)
                ForEach(WSSShootingStarParameter.allCases, id: \.self) { parameter in
                    if parameter == .direction {
                        WSSShootingStarDirectionPicker(
                            angle: value.starfield.shootingStars.direction
                        ) { direction in
                            perform {
                                try document.selectShootingStarDirection(direction, layer: layer)
                            }
                        }
                    }
                    HStack {
                        Text(parameter.title).wupsyFont(.caption)
                        Spacer()
                        WSSParameterTextField(
                            value: Float(parameter.displayValue(value.starfield.shootingStars)),
                            range: Float(
                                parameter.displayRange.lowerBound)...Float(
                                    parameter.displayRange.upperBound),
                            title: parameter.title, maximumFractionDigits: 3,
                            exactValue: parameter.displayValue(value.starfield.shootingStars),
                            exactRange: parameter.displayRange,
                            commitExact: {
                                try document.setShootingStarsDisplayValue(
                                    parameter, value: $0, layer: layer)
                            },
                            commit: {
                                try document.setShootingStarsDisplayValue(
                                    parameter, value: Double($0), layer: layer)
                            }
                        ).wupsyControlFrame(width: 110)
                    }
                    if parameter == .frequency {
                        Text(WSSStarfieldText.text("shootingStars.frequency.help")).wupsyFont(
                            .caption
                        )
                        .foregroundStyle(.secondary)
                    }
                    if parameter == .direction {
                        Text(WSSStarfieldText.text("shootingStars.direction.help")).wupsyFont(
                            .caption
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                Text(WSSStarfieldText.text("shootingStars.drift.help")).wupsyFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error { Text(error).wupsyFont(.caption).foregroundStyle(.red) }
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
        perform { try document.renameLayer(layer, to: name) }
    }
}
