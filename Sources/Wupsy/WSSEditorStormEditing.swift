import Foundation

extension WSSEditorDocument {
    func stormLayer(_ id: WSSLayerID) -> WSSStormLayer? {
        guard let index = identity.layers.firstIndex(where: { $0.id == id }),
            case .storm(let layer) = state.workingModel.layers[index].content
        else { return nil }
        return layer
    }
    func addStorm() throws {
        guard permitsStructureEditing, finishEditing(), permitsStructureEditing else { return }
        try maintenance.withMutation {
            var model = state.workingModel
            guard model.layers.count < 128 else { throw WSSImageImportError.layerLimit }
            var configuration = WSSStormConfiguration()
            configuration.x = Double(model.canvas.width) * 0.5
            configuration.y = Double(model.canvas.height) * 0.95
            configuration.length = max(1, Double(model.canvas.height) * 0.8)
            configuration.spread = min(120, Double(model.canvas.width) * 0.1)
            model.layers.append(.init(content: .storm(.init(storm: configuration))))
            _ = try model.encoded()
            var ids = identity
            let id = WSSLayerID()
            ids.layers.append(.init(id: id, effects: []))
            try mutate(model, name: WSSStormText.title, ids: ids, selected: .layer(id))
            _ = activateTransformMode(id)
        }
    }
    func setStorm(_ parameter: WSSStormParameter, value: Double, layer id: WSSLayerID) throws {
        guard permitsStructureEditing,
            let index = identity.layers.firstIndex(where: { $0.id == id }),
            case .storm(var layer) = state.workingModel.layers[index].content,
            parameter.value(layer.storm) != value
        else { return }
        endStormColorInteraction()
        endCanvasTransform()
        try parameter.apply(value, to: &layer.storm)
        var model = state.workingModel
        model.layers[index].content = .storm(layer)
        try mutate(model, name: parameter.title)
    }
    func renameStorm(_ id: WSSLayerID, name: String) throws {
        guard permitsStructureEditing,
            let index = identity.layers.firstIndex(where: { $0.id == id }),
            case .storm(var layer) = state.workingModel.layers[index].content
        else { return }
        layer.name = try WallpaperTitle.normalized(name)
        var model = state.workingModel
        model.layers[index].content = .storm(layer)
        try mutate(model, name: WSSStormText.rename)
    }
    func beginStormColorInteraction(_ layer: WSSLayerID) {
        endStormColorInteraction()
        endCanvasTransform()
        stormColorDrag = (layer, state.workingModel)
    }
    func endStormColorInteraction() {
        guard let (_, before) = stormColorDrag else { return }
        stormColorDrag = nil
        if before != state.workingModel { registerModelUndo(before, name: WSSStormText.color) }
    }
    func setStormColor(_ color: WSSTrailColor, layer id: WSSLayerID, undo: Bool = true) throws {
        guard permitsStructureEditing,
            let index = identity.layers.firstIndex(where: { $0.id == id }),
            case .storm(var layer) = state.workingModel.layers[index].content
        else { return }
        if undo {
            endStormColorInteraction()
            endCanvasTransform()
        }
        layer.storm.red = Double(color.r)
        layer.storm.green = Double(color.g)
        layer.storm.blue = Double(color.b)
        try layer.validate()
        var model = state.workingModel
        model.layers[index].content = .storm(layer)
        try mutate(model, name: WSSStormText.color, undo: undo)
    }

}
