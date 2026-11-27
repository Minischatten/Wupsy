import SwiftUI

enum WSSSlimeText {
    static func text(_ key: String) -> String {
        Localization.string(key: "editor.slime." + key)
    }
}

extension WSSEditorDocument {
    func slimeLayer(_ id: WSSLayerID) -> WSSSlimeLayer? {
        guard let index = identity.layers.firstIndex(where: { $0.id == id }),
            case .slime(let layer) = state.workingModel.layers[index].content
        else { return nil }
        return layer
    }

    func addSlime() throws {
        guard permitsStructureEditing, finishEditing(), permitsStructureEditing else { return }
        try maintenance.withMutation {
            var model = state.workingModel
            guard model.layers.count < 128 else { throw WSSImageImportError.layerLimit }
            let size = WSSSlimeLayer.referenceSize
            let transform = WSSSceneDocumentV1.Transform(
                center: [
                    Float(model.canvas.width) * 0.5,
                    Float(model.canvas.height) * (1 - 83.0 / 360.0),
                ],
                size: [size, size])
            let phases = model.layers.compactMap { node -> Float? in
                guard case .slime(let layer) = node.content else { return nil }
                return layer.configuration.cycleOffset
            }
            var configuration = WSSSlimeConfiguration()
            configuration.cycleOffset = WSSSlimeConfiguration.nextCycleOffset(occupied: phases)
            model.layers.append(
                .init(
                    content: .slime(
                        .init(
                            transform: transform, configuration: configuration))))

            var ids = identity
            let id = WSSLayerID()
            ids.layers.append(.init(id: id, effects: []))
            try mutate(model, name: WSSSlimeText.text("title"), ids: ids, selected: .layer(id))
            _ = activateTransformMode(id)
        }
    }

    func changeSlime(_ id: WSSLayerID, name: String, change: (inout WSSSlimeLayer) -> Void) throws {
        guard permitsStructureEditing, finishParameterInteractions(),
            let index = identity.layers.firstIndex(where: { $0.id == id }),
            case .slime(var layer) = state.workingModel.layers[index].content
        else { return }
        change(&layer)
        var model = state.workingModel
        model.layers[index].content = .slime(layer)
        try mutate(model, name: name)
    }
}

struct WSSSlimeParameterControls: View {
    @ObservedObject var document: WSSEditorDocument
    let layer: WSSLayerID
    @State private var colorError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let slime = document.slimeLayer(layer) {
                Text(WSSSlimeText.text("title")).wupsyFont(.headline)
                colorField("color", slime.configuration.color, property: \.color)
                colorField(
                    "reflectionColor", slime.configuration.reflectionColor,
                    property: \.reflectionColor)
                field("anchorX", slime.transform.center[0], -1_000_000...1_000_000) {
                    $0.transform.center[0] = $1
                }
                field("anchorY", slime.transform.center[1], -1_000_000...1_000_000) {
                    $0.transform.center[1] = $1
                }
                ForEach(0..<2, id: \.self) { axis in
                    let size = slime.transform.size[axis] * slime.transform.scale[axis]
                    field(axis == 0 ? "sizeX" : "sizeY", size, WSSSlimeLayer.sizeRange) {
                        $0.transform.size[axis] = $1
                        $0.transform.scale[axis] = 1
                    }
                }
                ForEach(WSSSlimeConfiguration.Value.numeric, id: \.self) { parameter in
                    field(
                        parameter.rawValue, slime.configuration[keyPath: parameter.keyPath],
                        parameter == .distance
                            ? parameter.range
                                .lowerBound...slime.distanceInspectorLimit(
                                    canvas: document.state.workingModel.canvas)
                            : parameter.range
                    ) {
                        $0.configuration[keyPath: parameter.keyPath] = $1
                    }
                }
                Text(WSSSlimeText.text("spatialHelp"))
                    .wupsyFont(.caption)
                    .foregroundStyle(.secondary)
                field(
                    "cycleOffset", min(99, slime.configuration.cycleOffset * 100), 0...99, unit: "%"
                ) {
                    $0.configuration.cycleOffset = $1 / 100
                }
                if let colorError { Text(colorError).wupsyFont(.caption).foregroundStyle(.red) }
            }
        }
        .disabled(!document.permitsStructureEditing)
    }

    private func colorField(
        _ key: String, _ color: WSSFogConfiguration.Color,
        property: WritableKeyPath<WSSSlimeConfiguration, WSSFogConfiguration.Color>
    ) -> some View {
        let title = WSSSlimeText.text(key)
        return HStack {
            Text(title).wupsyFont(.caption)
            Spacer()
            WSSNativeSDRColorWell(color: color, title: title) { value in
                do {
                    try document.changeSlime(layer, name: title) {
                        $0.configuration[keyPath: property] = value
                    }
                    colorError = nil
                } catch {
                    colorError = EditorErrorPresentation.message(error)
                }
            }.wupsyControlFrame(width: 50, height: 24)
        }
    }

    private func field(
        _ key: String, _ value: Float, _ range: ClosedRange<Float>, unit: String? = nil,
        change: @escaping (inout WSSSlimeLayer, Float) -> Void
    ) -> some View {
        let title = WSSSlimeText.text(key)
        return HStack {
            Text(title).wupsyFont(.caption)
            Spacer()
            WSSParameterTextField(
                value: value, range: range, title: title, maximumFractionDigits: 3
            ) {
                newValue in
                try document.changeSlime(layer, name: title) { change(&$0, newValue) }
            }.wupsyControlFrame(width: 100)
            if let unit { Text(unit).wupsyFont(.caption) }
        }
    }
}
