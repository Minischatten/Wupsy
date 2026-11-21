import AppKit
import SwiftUI

enum WSSFogText {
    static func text(_ key: String) -> String {
        Localization.string(key: "editor.fog." + key)
    }
}

extension WSSFogConfiguration {
    var driftAngle: Double? {
        guard driftX != 0 || driftY != 0 else { return nil }
        let angle = atan2(-Double(driftY), Double(driftX)) * 180 / .pi
        return angle < 0 ? angle + 360 : angle
    }

    mutating func setDriftDirection(_ direction: WSSShootingStarDirection) {
        let radians = direction.rawValue * .pi / 180
        // The compass only uses 45° steps. Snap the axes before normalization.
        let x = cos(radians).rounded()
        let y = -sin(radians).rounded()
        let startingSpeed = Double(WSSFogPreset.ground.configuration.driftX)
        setDriftSpeed(driftSpeed > 0 ? driftSpeed : startingSpeed, in: SIMD2(x, y) / hypot(x, y))
    }
}

extension WSSEditorDocument {
    func selectFogDriftDirection(_ direction: WSSShootingStarDirection, layer: WSSLayerID) throws {
        guard permitsStructureEditing, finishEditing() else { return }
        try changeFog(layer, name: WSSFogText.text("driftDirection")) {
            $0.setDriftDirection(direction)
        }
    }

    func fogSpeedDirection(_ layer: WSSLayerID) -> SIMD2<Double> {
        if let drag = fogSpeedDrag, drag.layer == layer { return drag.direction }
        return fogLayer(layer)?.fog.driftUnitDirection ?? fogStoppedDirections[layer] ?? SIMD2(1, 0)
    }

    @discardableResult
    func beginFogSpeedSlider(_ layer: WSSLayerID) -> Bool {
        guard permitsStructureEditing, finishEditing(), let fog = fogLayer(layer)?.fog else {
            return false
        }
        fogSpeedDrag = .init(
            layer: layer, direction: fogSpeedDirection(layer), original: fog, draft: fog)
        return true
    }

    func setFogSpeed(_ speed: Double, layer id: WSSLayerID) throws {
        if var drag = fogSpeedDrag, drag.layer == id {
            let previous = drag.draft
            drag.draft.setDriftSpeed(speed, in: drag.direction)
            guard drag.draft != previous else { return }
            try drag.draft.validate()
            fogSpeedDrag = drag
            if let index = identity.layers.firstIndex(where: { $0.id == id }),
                var layer = fogLayer(id)
            {
                layer.fog = drag.draft
                previewFogDrag(layer, at: index)
            }
            return
        }

        guard permitsStructureEditing, finishParameterInteractions(),
            let index = identity.layers.firstIndex(where: { $0.id == id }),
            case .fog(var layer) = state.workingModel.layers[index].content
        else { return }
        let previous = layer.fog
        layer.fog.setDriftSpeed(speed, in: fogSpeedDirection(id))
        guard layer.fog != previous else { return }
        try layer.fog.validate()
        commitFogSpeed(layer, at: index, id: id, previous: previous)
    }

    func endFogSpeedSlider() {
        guard let drag = fogSpeedDrag else { return }
        fogSpeedDrag = nil
        guard !closed, drag.draft != drag.original,
            let index = identity.layers.firstIndex(where: { $0.id == drag.layer }),
            case .fog(var layer) = state.workingModel.layers[index].content
        else {
            displayFogDrift?(nil)
            return
        }
        let previous = layer.fog
        layer.fog.driftX = drag.draft.driftX
        layer.fog.driftY = drag.draft.driftY
        guard layer.fog != previous else {
            displayFogDrift?(nil)
            return
        }
        commitFogSpeed(layer, at: index, id: drag.layer, previous: previous)
    }

    private func commitFogSpeed(
        _ layer: WSSFogLayer, at index: Int, id: WSSLayerID, previous: WSSFogConfiguration
    ) {
        if layer.fog.driftSpeed == 0, let direction = previous.driftUnitDirection {
            fogStoppedDirections[id] = direction
        }
        installFogDrift(layer, at: index, undo: true)
    }

    func fogLayer(_ id: WSSLayerID) -> WSSFogLayer? {
        guard let index = identity.layers.firstIndex(where: { $0.id == id }),
            case .fog(let layer) = state.workingModel.layers[index].content
        else { return nil }
        return layer
    }

    func addFog(_ preset: WSSFogPreset) throws {
        guard permitsStructureEditing, finishEditing(), permitsStructureEditing else { return }
        try maintenance.withMutation {
            var model = state.workingModel
            guard model.layers.count < 128 else { throw WSSImageImportError.layerLimit }
            model.layers.append(.init(content: .fog(.init(fog: preset.configuration))))
            var ids = identity
            let id = WSSLayerID()
            ids.layers.append(.init(id: id, effects: []))
            try mutate(
                model, name: WSSFogText.text(preset.rawValue), ids: ids, selected: .layer(id))
        }
    }

    func changeFog(
        _ id: WSSLayerID, name: String, change: (inout WSSFogConfiguration) -> Void
    ) throws {
        guard permitsStructureEditing, finishParameterInteractions(),
            let index = identity.layers.firstIndex(where: { $0.id == id }),
            case .fog(var layer) = state.workingModel.layers[index].content
        else { return }
        let previousDirection = layer.fog.driftUnitDirection
        change(&layer.fog)
        var model = state.workingModel
        model.layers[index].content = .fog(layer)
        try mutate(model, name: name)
        if layer.fog.driftUnitDirection == nil, let previousDirection {
            fogStoppedDirections[id] = previousDirection
        }
    }
}

struct WSSFogParameterControls: View {
    @ObservedObject var document: WSSEditorDocument
    let layer: WSSLayerID
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(WSSFogText.text("title")).font(.headline)
            if let value = document.fogLayer(layer)?.fog {
                ForEach(WSSFogParameter.allCases, id: \.self) { parameter in
                    if parameter == .driftX {
                        Text(WSSFogText.text("driftDirection")).font(.caption)
                        WSSDirectionGrid(
                            angle: value.driftAngle,
                            currentTitle: WSSFogText.text("driftDirection"),
                            identifierPrefix: "wss.fog.direction."
                        ) { direction in
                            perform {
                                try document.selectFogDriftDirection(direction, layer: layer)
                            }
                        }
                        speedSlider(value.driftSpeed)
                    }
                    let title = WSSFogText.text(parameter.rawValue)
                    HStack {
                        Text(title).font(.caption)
                        Spacer()
                        WSSParameterTextField(
                            value: value[keyPath: parameter.keyPath], range: parameter.range,
                            title: title, maximumFractionDigits: 3
                        ) { newValue in
                            try document.changeFog(layer, name: title) {
                                $0[keyPath: parameter.keyPath] = newValue
                            }
                        }.frame(width: 100)
                    }
                }
                HStack {
                    let title = WSSFogText.text("color")
                    Text(title).font(.caption)
                    Spacer()
                    WSSFogColorWell(color: value.color, title: title) { color in
                        perform { try document.changeFog(layer, name: title) { $0.color = color } }
                    }.frame(width: 50, height: 24)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
        .disabled(!document.permitsStructureEditing)
    }

    private func speedSlider(_ speed: Double) -> some View {
        let limit = WSSFogConfiguration.driftSpeedLimit(in: document.fogSpeedDirection(layer))
        return WSSFogSpeedSlider(
            speed: speed, logRange: log1p(limit / 0.1),
            begin: { document.beginFogSpeedSlider(layer) },
            update: { value in perform { try document.setFogSpeed(value, layer: layer) } },
            end: { document.endFogSpeedSlider() })
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            if error != nil { error = nil }
        } catch { self.error = EditorErrorPresentation.message(error) }
    }
}

// A mouse drag updates only this row and the native preview until it commits.
private struct WSSFogSpeedSlider: View {
    let speed: Double
    let logRange: Double
    let begin: () -> Bool
    let update: (Double) -> Void
    let end: () -> Void
    @State private var draftPosition: Double?

    var body: some View {
        let position = min(1, log1p(speed / 0.1) / logRange)
        let displayedSpeed = draftPosition.map(speed(at:)) ?? speed
        let formatted = displayedSpeed.formatted(.number.precision(.fractionLength(0...3)))
        HStack {
            Slider(
                value: Binding(
                    get: { draftPosition ?? position },
                    set: { value in
                        if draftPosition != nil { draftPosition = value }
                        update(speed(at: value))
                    }),
                in: 0...1, step: 0.001
            ) {
                Text(WSSFogText.text("speed")).font(.caption)
            } onEditingChanged: { active in
                if active {
                    if begin() { draftPosition = position }
                } else {
                    end()
                    draftPosition = nil
                }
            }
            .accessibilityValue(formatted)
            Text(formatted).font(.caption).monospacedDigit().frame(
                minWidth: 48, alignment: .trailing
            )
            .accessibilityHidden(true)
        }
    }

    private func speed(at position: Double) -> Double { 0.1 * expm1(position * logRange) }
}

// Use AppKit target/action for continuous delivery from the shared native color panel.
private struct WSSFogColorWell: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let color: WSSFogConfiguration.Color
    let title: String
    let change: (WSSFogConfiguration.Color) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(change: change) }

    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell()
        well.supportsAlpha = false
        well.isContinuous = true
        well.target = context.coordinator
        well.action = #selector(Coordinator.update(_:))
        return well
    }

    func updateNSView(_ well: NSColorWell, context: Context) {
        context.coordinator.change = change
        well.setAccessibilityLabel(title)
        well.isEnabled = isEnabled
        let selected = NSColor(
            srgbRed: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue),
            alpha: 1)
        if well.color != selected { well.color = selected }
    }

    static func dismantleNSView(_ well: NSColorWell, coordinator: Coordinator) {
        well.deactivate()
    }

    final class Coordinator: NSObject {
        var change: (WSSFogConfiguration.Color) -> Void
        init(change: @escaping (WSSFogConfiguration.Color) -> Void) { self.change = change }

        @objc func update(_ well: NSColorWell) {
            guard let color = well.color.usingColorSpace(.sRGB) else { return }
            change(
                .init(
                    red: Float(min(1, max(0, color.redComponent))),
                    green: Float(min(1, max(0, color.greenComponent))),
                    blue: Float(min(1, max(0, color.blueComponent)))))
        }
    }
}
