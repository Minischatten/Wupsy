import Foundation

extension WSSEditorDocument {
    func starfieldLayer(_ id: WSSLayerID) -> WSSStarfieldLayer? {
        guard let index = identity.layers.firstIndex(where: { $0.id == id }),
            case .starfield(let layer) = state.workingModel.layers[index].content
        else { return nil }
        return layer
    }
    func addStarfield() throws {
        guard permitsStructureEditing, finishEditing(), permitsStructureEditing else { return }
        try maintenance.withMutation {
            var model = state.workingModel
            guard model.layers.count < 128 else { throw WSSImageImportError.layerLimit }
            var c = WSSStarfieldConfiguration()
            c.width = Double(model.canvas.width)
            c.height = Double(model.canvas.height)
            model.layers.append(.init(content: .starfield(.init(starfield: c))))
            _ = try model.encoded()
            var ids = identity
            let id = WSSLayerID()
            ids.layers.append(.init(id: id, effects: []))
            try mutate(model, name: WSSStarfieldText.title, ids: ids, selected: .layer(id))
            _ = activateTransformMode(id)
        }
    }
    func changeStarfield(
        _ id: WSSLayerID, name: String, undo: Bool = true,
        change: (inout WSSStarfieldLayer) throws -> Void
    ) throws {
        guard permitsStructureEditing else { return }
        if undo { guard finishParameterInteractions() else { return } }
        guard let index = identity.layers.firstIndex(where: { $0.id == id }),
            case .starfield(var layer) = state.workingModel.layers[index].content
        else { return }
        try change(&layer)
        try layer.validate()
        var model = state.workingModel
        model.layers[index].content = .starfield(layer)
        if model != state.workingModel { try mutate(model, name: name, undo: undo) }
    }
    func setStarfield(_ parameter: WSSStarfieldParameter, value: Double, layer: WSSLayerID) throws {
        try changeStarfield(layer, name: parameter.title) {
            try parameter.apply(value, to: &$0.starfield)
        }
    }
    func beginStarfieldColorInteraction(_ layer: WSSLayerID) {
        guard finishEditing() else { return }
        starfieldColorDrag = (layer, state.workingModel)
    }
    func endStarfieldColorInteraction() {
        guard let (_, before) = starfieldColorDrag else { return }
        starfieldColorDrag = nil
        if before != state.workingModel {
            registerModelUndo(before, name: WSSStarfieldText.text("color"))
        }
    }
    func setStarfieldColor(_ color: WSSTrailColor, layer: WSSLayerID, undo: Bool = true) throws {
        try changeStarfield(layer, name: WSSStarfieldText.text("color"), undo: undo) {
            $0.starfield.red = Double(color.r)
            $0.starfield.green = Double(color.g)
            $0.starfield.blue = Double(color.b)
        }
    }
}

extension WSSEditorDocument {
    func setShootingStars(_ parameter: WSSShootingStarParameter, value: Double, layer: WSSLayerID)
        throws
    {
        try changeStarfield(layer, name: parameter.title) {
            try parameter.apply(value, to: &$0.starfield.shootingStars)
        }
    }
    func setShootingStarsEnabled(_ enabled: Bool, layer: WSSLayerID) throws {
        try changeStarfield(layer, name: WSSStarfieldText.text("shootingStars.enabled")) {
            $0.starfield.shootingStars.enabled = enabled
        }
    }
}

extension WSSEditorDocument {
    func setShootingStarsDisplayValue(
        _ parameter: WSSShootingStarParameter, value: Double, layer: WSSLayerID
    ) throws {
        try changeStarfield(layer, name: parameter.title) {
            try parameter.applyDisplayValue(value, to: &$0.starfield.shootingStars)
        }
    }
    func selectShootingStarDirection(_ direction: WSSShootingStarDirection, layer: WSSLayerID)
        throws
    {
        // This is an explicit button action, unlike a numeric field's commit.
        // Validate/resign any draft first so it cannot overwrite the chosen arrow later.
        guard permitsStructureEditing, finishEditing() else { return }
        try setShootingStars(.direction, value: direction.rawValue, layer: layer)
    }
}
