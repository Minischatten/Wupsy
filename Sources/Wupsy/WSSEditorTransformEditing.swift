import Foundation

struct WSSCanvasTransformTransaction {
    let layer: WSSLayerID
    let kind: WSSCanvasGesture.Kind
    let model: WSSSceneDocumentV1
    let identity: WSSEditorIdentity
    let selection: WSSEditorSelection?
}
extension WSSEditorDocument {
    func canTransform(_ layer: WSSLayerID) -> Bool {
        guard !closed, !interactionLocked,
            let index = identity.layers.firstIndex(where: { $0.id == layer }),
            case .image(let image) = state.workingModel.layers[index].content
        else { return false }
        return image.visible
    }
    func transformHelp(for target: WSSEditorSelection) -> String? {
        guard case .layer(let id) = target, canTransform(id) else { return nil }
        return EditorText.transformHint.text
    }
    @discardableResult
    func activateStructureRow(_ target: WSSEditorSelection) -> Bool {
        let wasPainting = paintBrushEnabled
        select(target)
        guard !wasPainting, selection == target, case .layer(let id) = target else { return false }
        return activateTransformMode(id)
    }
    // Called by the native responder chain. Text-field Escape remains owned by
    // its field editor; only an actual transform interaction/mode is consumed.
    @discardableResult
    func cancelTransformInteraction() -> Bool {
        guard !closed, !interactionLocked else { return false }
        if canvasTransform != nil {
            endCanvasTransform(cancel: true)
            finishCanvasInteraction?()
            return true
        }
        guard transformModeLayer != nil else { return false }
        leaveTransformMode()
        return true
    }

    @discardableResult
    func activateTransformMode(_ layer: WSSLayerID) -> Bool {
        guard !closed, !interactionLocked, finishEditing(), selection == .layer(layer),
            canTransform(layer)
        else { return false }
        directionCanvas.setEnabled(false)
        maskCanvas.setBrush(false)
        transformModeLayer = layer
        return true
    }
    func leaveTransformMode() {
        endCanvasTransform()
        transformModeLayer = nil
        finishCanvasInteraction?()
    }

    @discardableResult
    func beginCanvasTransform(_ layer: WSSLayerID, kind: WSSCanvasGesture.Kind) -> Bool {
        guard finishEditing(), !closed, !interactionLocked,
            let index = identity.layers.firstIndex(where: { $0.id == layer }),
            case .image = state.workingModel.layers[index].content
        else { return false }
        canvasTransform = WSSCanvasTransformTransaction(
            layer: layer, kind: kind, model: state.workingModel, identity: identity,
            selection: selection)
        return true
    }
    func updateCanvasTransform(_ transform: WSSSceneDocumentV1.Transform) throws {
        guard let transaction = canvasTransform, !closed, !interactionLocked,
            let index = identity.layers.firstIndex(where: { $0.id == transaction.layer }),
            case .image(var image) = state.workingModel.layers[index].content
        else { return }
        _ = try transform.native()
        image.transform = transform
        var model = state.workingModel
        model.layers[index].content = .image(image)
        _ = try model.scene()
        installMutation(model, ids: nil, selected: nil)
    }
    func endCanvasTransform(cancel: Bool = false) {
        guard let transaction = canvasTransform else { return }
        canvasTransform = nil
        guard state.workingModel != transaction.model else { return }
        if cancel {
            installMutation(
                transaction.model, ids: transaction.identity, selected: transaction.selection)
        } else {
            let name: String
            switch transaction.kind {
            case .move: name = EditorText.moveImage.text
            case .scale: name = EditorText.scaleImage.text
            case .rotate: name = EditorText.rotateImage.text
            }
            registerModelUndo(
                transaction.model, name: name, ids: transaction.identity,
                selected: transaction.selection)
        }
    }
}
