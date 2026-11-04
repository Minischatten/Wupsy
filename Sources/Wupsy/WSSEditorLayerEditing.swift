import Foundation

extension WSSEditorDocument {
    var moveEarlierHelp: String {
        effectAddress == nil ? EditorText.moveLayerEarlier.text : EditorText.moveEffectEarlier.text
    }
    var moveLaterHelp: String {
        effectAddress == nil ? EditorText.moveLayerLater.text : EditorText.moveEffectLater.text
    }

    func select(_ target: WSSEditorSelection?) {
        guard !closed, !interactionLocked else { return }
        if target != selection { cancelMaskStrokeForSelectionChange() }
        guard finishEditing() else { return }
        guard let target else {
            selection = nil
            return
        }
        guard
            identity.layers.contains(where: { $0.id == target.layer })
        else {
            return
        }
        if case .effect(let layer, let effect) = target,
            identity.address(layer, effect: effect) == nil
        {
            return
        }
        selection = target
    }
    func visibilityHelp(_ layer: WSSLayerID) -> String {
        guard let index = identity.layers.firstIndex(where: { $0.id == layer }) else { return "" }
        return workingScene.layers[index].visible
            ? EditorText.hideLayer.text : EditorText.showLayer.text
    }
    func toggleVisibility(_ layer: WSSLayerID) throws {
        guard let index = identity.layers.firstIndex(where: { $0.id == layer }) else { return }
        try setVisibility(!workingScene.layers[index].visible, layer: layer)
    }
    func setVisibility(_ visible: Bool, layer: WSSLayerID) throws {
        guard finishEditing(), let index = identity.layers.firstIndex(where: { $0.id == layer })
        else { return }
        var model = state.workingModel
        switch model.layers[index].content {
        case .image(var image):
            image.visible = visible
            model.layers[index].content = .image(image)
        case .rain(var rain):
            rain.visible = visible
            model.layers[index].content = .rain(rain)
        case .trail(let config, _): model.layers[index].content = .trail(config, visible: visible)
        }
        try mutate(model, name: EditorText.layerVisibility.text)
        if !visible, transformModeLayer == layer { leaveTransformMode() }
    }
    func setImage(_ property: WSSImageProperty, value: Float, layer: WSSLayerID, undo: Bool = true)
        throws
    {
        if undo {
            endCanvasTransform()
            endSlider()
            endImageSlider()
        }
        guard let index = identity.layers.firstIndex(where: { $0.id == layer }),
            case .image(var image) = state.workingModel.layers[index].content
        else { return }
        // Preserve untouched native radians exactly when ending an unchanged text edit.
        guard property.value(image) != value else { return }
        try property.apply(value, to: &image)
        var model = state.workingModel
        model.layers[index].content = .image(image)
        try mutate(model, name: property.title, undo: undo)
    }
    func beginImageSlider(_ property: WSSImageProperty, layer: WSSLayerID) {
        endImageSlider()
        guard let index = identity.layers.firstIndex(where: { $0.id == layer }),
            case .image(let image) = state.workingModel.layers[index].content
        else { return }
        canvasImageDrag = (layer, property, property.value(image))
    }
    func endImageSlider() {
        guard let (layer, property, original) = canvasImageDrag else { return }
        canvasImageDrag = nil
        guard let index = identity.layers.firstIndex(where: { $0.id == layer }),
            case .image(var image) = state.workingModel.layers[index].content,
            property.value(image) != original
        else { return }
        try? property.apply(original, to: &image)
        var before = state.workingModel
        before.layers[index].content = .image(image)
        registerModelUndo(before, name: property.title)
        objectWillChange.send()
    }
    func moveLayer(_ id: WSSLayerID, by offset: Int) throws {
        guard let from = identity.layers.firstIndex(where: { $0.id == id }) else { return }
        try moveLayer(id, to: from + offset)
    }
    func moveLayer(_ id: WSSLayerID, to destination: Int) throws {
        guard permitsStructureEditing,
            let from = identity.layers.firstIndex(where: { $0.id == id }),
            destination != from, identity.layers.indices.contains(destination), finishEditing(),
            permitsStructureEditing,
            let current = identity.layers.firstIndex(where: { $0.id == id }),
            destination != current, identity.layers.indices.contains(destination)
        else { return }
        var model = state.workingModel
        var ids = identity
        model.layers.insert(model.layers.remove(at: current), at: destination)
        ids.layers.insert(ids.layers.remove(at: current), at: destination)
        try mutate(model, name: EditorText.moveLayer.text, ids: ids)
    }
    var currentDeletableSelection: WSSDeletableTarget? {
        guard permitsStructureEditing, let selection,
            let index = identity.layers.firstIndex(where: { $0.id == selection.layer }),
            state.workingModel.layers.indices.contains(index)
        else { return nil }
        switch selection {
        case .layer(let id):
            return identity.layers.count > 1 ? .layer(id) : nil
        case .effect(let layer, let effect):
            guard let address = identity.address(layer, effect: effect),
                case .image(let image) = state.workingModel.layers[index].content,
                image.effects.indices.contains(address.effectIndex)
            else { return nil }
            return .effect(layer, effect)
        }
    }
    var deleteSelectionTitle: String { currentDeletableSelection?.title ?? ProductText.delete.text }
    func deleteSelection() throws {
        guard let target = currentDeletableSelection else { return }
        switch target {
        case .layer(let id): try deleteLayer(id)
        case .effect: try deleteEffect(target)
        }
    }
    func deleteLayer(_ id: WSSLayerID) throws {
        guard currentDeletableSelection == .layer(id), finishEditing(),
            currentDeletableSelection == .layer(id),
            let index = identity.layers.firstIndex(where: { $0.id == id })
        else { return }
        var model = state.workingModel
        var ids = identity
        model.layers.remove(at: index)
        ids.layers.remove(at: index)
        let next =
            selection?.layer == id
            ? WSSEditorSelection.layer(ids.layers[min(index, ids.layers.count - 1)].id) : selection
        try mutate(model, name: EditorText.deleteLayer.text, ids: ids, selected: next)
    }
    func mutate(
        _ model: WSSSceneDocumentV1, name: String, undo: Bool = true, ids: WSSEditorIdentity? = nil,
        selected: WSSEditorSelection? = nil
    ) throws {
        guard !closed, !interactionLocked,
            model != state.workingModel || (ids != nil && ids != identity)
        else { return }
        _ = try model.scene()
        if undo { registerModelUndo(state.workingModel, name: name) }
        installMutation(model, ids: ids, selected: selected)
    }
}
