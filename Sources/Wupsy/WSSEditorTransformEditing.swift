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
            state.workingModel.layers[index].canvasTransform != nil
        else { return false }
        return workingScene.layers[index].visible
    }
    func transformHelp(for target: WSSEditorSelection) -> String? {
        guard case .layer(let id) = target, canTransform(id) else { return nil }
        if let notes = musicNotesLayer(id) {
            return WSSMusicNotesText.text(
                notes.placementMode == .freeSingle ? "freeDragHelp" : "regionHelp")
        }
        if slimeLayer(id) != nil { return WSSSlimeText.text("transformHelp") }
        if starfieldLayer(id) != nil { return WSSStarfieldText.text("help") }
        return stormLayer(id) == nil ? EditorText.transformHint.text : WSSStormText.transformHelp
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
        if musicNotesPathEditLayer != nil {
            if !finishMusicNotesPathGesture(cancel: true) {
                leaveMusicNotesPathEditing(restoreTransform: true)
            }
            finishCanvasInteraction?()
            return true
        }
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
        leaveMusicNotesPathEditing(restoreTransform: false)
        directionCanvas.setEnabled(false)
        maskCanvas.setBrush(false)
        transformModeLayer = layer
        return true
    }
    func leaveTransformMode() {
        leaveMusicNotesPathEditing(restoreTransform: false)
        endCanvasTransform()
        transformModeLayer = nil
        finishCanvasInteraction?()
    }

    @discardableResult
    func beginCanvasTransform(_ layer: WSSLayerID, kind: WSSCanvasGesture.Kind) -> Bool {
        guard musicNotesPathEditLayer == nil, finishEditing(), !closed, !interactionLocked,
            let index = identity.layers.firstIndex(where: { $0.id == layer }),
            state.workingModel.layers[index].canvasTransform != nil,
            kind != .rotate || workingScene.layers[index].allowsCanvasRotation
        else { return false }
        if workingScene.layers[index].isFreeMusicSymbol && kind != .move { return false }
        if case .scaleEdge = kind, !workingScene.layers[index].allowsCanvasEdgeScaling {
            return false
        }
        canvasTransform = WSSCanvasTransformTransaction(
            layer: layer, kind: kind, model: state.workingModel, identity: identity,
            selection: selection)
        return true
    }
    func updateCanvasTransform(_ transform: WSSSceneDocumentV1.Transform) throws {
        guard let transaction = canvasTransform, !closed, !interactionLocked,
            let index = identity.layers.firstIndex(where: { $0.id == transaction.layer })
        else { return }
        _ = try transform.native()
        var model = state.workingModel
        switch model.layers[index].content {
        case .slime(var layer):
            layer.transform = transform
            model.layers[index].content = .slime(layer)
        case .image(var image):
            image.transform = transform
            model.layers[index].content = .image(image)
        case .musicNotes(var layer):
            if layer.placementMode == .freeSingle {
                layer.freePosition = SIMD2(transform.center[0], transform.center[1])
                model.layers[index].content = .musicNotes(layer)
                break
            }
            let width = transform.size[0] * transform.scale[0]
            let height = transform.size[1] * transform.scale[1]
            layer.region = .init(
                x: transform.center[0] - width / 2, y: transform.center[1] - height / 2,
                width: width, height: height)
            model.layers[index].content = .musicNotes(layer)
        case .starfield(var layer):
            guard
                let originalIndex = transaction.identity.layers.firstIndex(where: {
                    $0.id == transaction.layer
                }),
                case .starfield(let original) = transaction.model.layers[originalIndex].content
            else { return }
            if case .move = transaction.kind {
                let baseline = original.starfield.canvasTransform
                layer.starfield = original.starfield
                layer.starfield.x += Double(transform.center[0] - baseline.center[0])
                layer.starfield.y += Double(transform.center[1] - baseline.center[1])
                try layer.validate()
            } else {
                layer.starfield = try original.starfield.applying(transform)
            }
            model.layers[index].content = .starfield(layer)
        case .storm(var layer):
            guard
                let originalIndex = transaction.identity.layers.firstIndex(where: {
                    $0.id == transaction.layer
                }),
                case .storm(let original) = transaction.model.layers[originalIndex].content
            else { return }
            layer.storm = try WSSStormCanvas.applying(
                transform, original: original.storm, kind: transaction.kind)
            model.layers[index].content = .storm(layer)
        default: return
        }
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
            case .scale, .scaleEdge: name = EditorText.scaleImage.text
            case .rotate: name = EditorText.rotateImage.text
            }
            let undoName =
                starfieldLayer(transaction.layer) != nil
                ? WSSStarfieldText.title
                : stormLayer(transaction.layer) == nil
                    ? name : WSSStormText.transformUndo(transaction.kind)
            registerModelUndo(
                transaction.model, name: undoName, ids: transaction.identity,
                selected: transaction.selection)
        }
    }
}
