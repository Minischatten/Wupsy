import AppKit
import Foundation

enum WSSAddableEffect: String, CaseIterable {
    case ripple = "Ripple"
    case clouds = "Clouds"
    case flow = "Flow"
    var title: String { localizedTitle() }
    func localizedTitle(language: String? = nil) -> String {
        switch self {
        case .ripple: return EditorText.effectRipple.localized(language: language)
        case .clouds: return EditorText.effectClouds.localized(language: language)
        case .flow: return EditorText.effectFlow.localized(language: language)
        }
    }
    var requiresVectorField: Bool { self == .flow }
    func definition(field: WSSAssetID? = nil, region: WSSAssetID? = nil) throws
        -> WSSSceneDocumentV1.Effect
    {
        let native: WSSImageEffect
        switch self {
        case .ripple: native = .ripple(WSSRippleEffect())
        case .clouds: native = .clouds(WSSCloudsEffect())
        case .flow:
            guard let field else { throw WSSVectorFieldEditError.invalid }
            native = .flow(
                WSSFlowEffect(
                    flowMap: field, speed: 40, strength: 12,
                    edgeProtectionMode: region == nil ? .imageBounds : .region, flowRegion: region))

        }
        let descriptor: WSSSceneDocumentV1.Effect.FlowMap?
        if requiresVectorField, let field {
            descriptor = try JSONDecoder().decode(
                WSSSceneDocumentV1.Effect.FlowMap.self,
                from: JSONSerialization.data(withJSONObject: [
                    "format": WSSVectorFieldAsset.fileFormat, "version": 1, "asset": field.value,
                ]))
        } else {
            descriptor = nil
        }
        return WSSSceneDocumentV1.Effect(parameters: native, mask: nil, field: descriptor)
    }
}

enum WSSNewVectorField {
    // Local image dimensions only; floor scaled axes, never upscale, clamp thin axes to one.
    static func dimensions(_ size: SIMD2<Float>) throws -> (width: Int, height: Int) {
        guard size.x.isFinite, size.y.isFinite, size.x > 0, size.y > 0,
            size.x <= 8192, size.y <= 8192
        else { throw WSSVectorFieldEditError.invalid }
        let scale = min(1, 512 / max(Double(size.x), Double(size.y)))
        return (
            max(1, Int(floor(Double(size.x) * scale))), max(1, Int(floor(Double(size.y) * scale)))
        )
    }
    static func byteCount(_ size: SIMD2<Float>) throws -> Int {
        let dimensions = try dimensions(size)
        return WSSVectorFieldAsset.fileHeaderBytes + dimensions.width * dimensions.height * 4
    }
    static func generation(_ size: SIMD2<Float>, remainingBudget: Int) throws
        -> WSSEditorAssetGeneration
    {
        let dimensions = try dimensions(size)
        let count = try byteCount(size)
        guard count <= remainingBudget else { throw WSSVectorFieldEditError.budget }
        try WSSVectorFieldEditorBudget.validateWorkingData(byteCount: count * 4)
        let field = WSSVectorFieldAsset(
            width: dimensions.width, height: dimensions.height,
            vectors: Data(repeating: 0, count: dimensions.width * dimensions.height * 4),
            coverage: nil, isNeutral: true)
        return try WSSEditorAssetGeneration.vectorField(field, remainingBudget: remainingBudget)
    }
}

extension WSSEditorDocument {
    var permitsStructureEditing: Bool {
        structureCommands.permitsDocumentCommands
    }
    var structureCommands: WSSEditorCommands {
        let window = NSApp?.windows.first { WSSEditorCoordinator.document(in: $0) === self }
        return WSSEditorCommands(document: self, window: window)
    }
    private var effectInsertionLayer: Int? {
        guard permitsStructureEditing, let selection,
            let index = identity.layers.firstIndex(where: { $0.id == selection.layer }),
            state.workingModel.layers.indices.contains(index),
            case .image(let image) = state.workingModel.layers[index].content,
            image.effects.count == identity.layers[index].effects.count
        else { return nil }
        if case .effect(let layer, let effect) = selection,
            identity.address(layer, effect: effect) == nil
        {
            return nil
        }
        return index
    }
    func canAddEffect(_ kind: WSSAddableEffect) -> Bool {
        guard let index = effectInsertionLayer,
            case .image(var image) = state.workingModel.layers[index].content
        else { return false }
        guard
            let definition = try? kind.definition(
                field: kind.requiresVectorField
                    ? WSSAssetID(value: "assets/editor-candidate.wssvf") : nil)
        else { return false }
        image.effects.append(definition)
        var model = state.workingModel
        model.layers[index].content = .image(image)
        return (try? model.scene()) != nil
    }
    func addEffect(_ kind: WSSAddableEffect) throws {
        guard canAddEffect(kind) else { return }
        try maintenance.withMutation {
            guard canAddEffect(kind), finishEditing(), canAddEffect(kind),
                let index = effectInsertionLayer,
                case .image(var image) = state.workingModel.layers[index].content
            else { return }
            let before = state.workingModel
            let generation: WSSEditorAssetGeneration?
            var regionGeneration: WSSEditorAssetGeneration?
            var initialMask: WSSNativeImageDefinition?
            if kind.requiresVectorField {
                let size = try image.transform.native().localSize
                try WSSVectorFieldEditorBudget.validateGeneration(
                    byteCount: WSSNewVectorField.byteCount(size), assets: state.sessionAssets)
                let region = try WSSFlowRegion.empty(size: size)
                try WSSVectorFieldEditorBudget.validateGeneration(
                    byteCount: WSSNewVectorField.byteCount(size) + region.pixels.count + 20,
                    assets: state.sessionAssets)
                regionGeneration = try .flowRegion(
                    region,
                    remainingBudget: WSSVectorFieldEditorBudget.remainingGenerationBytes(
                        assets: state.sessionAssets))
                generation = try WSSNewVectorField.generation(
                    size,
                    remainingBudget: WSSVectorFieldEditorBudget.remainingGenerationBytes(
                        assets: state.sessionAssets))
            } else if kind == .clouds {
                // Authoring only: legacy nil Clouds remain unmasked Full Image.
                // Prepare and preflight before installing the single Add mutation.
                let bitmap = try WSSMaskPreparation.blackMaskBitmap(size: image.transform.size)
                let used = state.sessionAssets.values.reduce(0) { $0 + $1.fingerprint.byteCount }
                let mask = try WSSMaskPreparation.prepareGeneration(
                    bitmap, remainingBudget: WSSImageImporter.stagingLimit - used)
                generation = mask
                initialMask = bitmap.definition(path: mask.path)
            } else {
                generation = nil
            }
            var definition = try kind.definition(
                field: kind.requiresVectorField
                    ? generation.map { WSSAssetID(value: $0.path) } : nil,
                region: regionGeneration.map { WSSAssetID(value: $0.path) })
            if let initialMask {
                definition = try definition.settingMask(slot: .clouds, definition: initialMask)
            }
            image.effects.append(definition)
            var model = before
            model.layers[index].content = .image(image)
            let scene = try model.scene()
            _ = try model.encoded()
            if let generation {
                try state.diskBasis.verify(project.handle)
                var assets = try model.assetSource(root: project.handle.root)
                assets.sessionAssets = state.sessionAssets
                assets.sessionAssets[generation.path] = generation
                if let regionGeneration {
                    assets.sessionAssets[regionGeneration.path] = regionGeneration
                }
                // Preflight the real resource/aggregate limits before retaining or installing anything.
                _ = try WSSStaticResources(
                    scene: scene, assets: assets, device: previewResources.device)
                try state.diskBasis.verify(project.handle)
                try retainImageGenerations([generation] + (regionGeneration.map { [$0] } ?? []))
            }
            let id = WSSEffectID()
            var ids = identity
            ids.layers[index].effects.append(id)
            registerModelUndo(before, name: EditorText.addEffectUndo.format(kind.title))
            installMutation(model, ids: ids, selected: .effect(ids.layers[index].id, id))
            if kind == .flow { directionCanvas.setEnabled(true) }
        }
    }
    // Destination is the final array index, not an insertion boundary.
    func canMoveEffect(_ layer: WSSLayerID, effect: WSSEffectID, to destination: Int) -> Bool {
        guard permitsStructureEditing,
            let address = identity.checkedAddress(
                in: state.workingModel, layer: layer, effect: effect),
            destination != address.effectIndex,
            identity.layers[address.layerIndex].effects.indices.contains(destination)
        else { return false }
        return true
    }
    func moveEffect(_ layer: WSSLayerID, effect: WSSEffectID, to destination: Int) throws {
        guard canMoveEffect(layer, effect: effect, to: destination), finishEditing(),
            canMoveEffect(layer, effect: effect, to: destination),
            let address = identity.checkedAddress(
                in: state.workingModel, layer: layer, effect: effect),
            case .image(var image) = state.workingModel.layers[address.layerIndex].content
        else { return }
        image.effects.insert(image.effects.remove(at: address.effectIndex), at: destination)
        var model = state.workingModel
        model.layers[address.layerIndex].content = .image(image)
        var ids = identity
        ids.layers[address.layerIndex].effects.insert(
            ids.layers[address.layerIndex].effects.remove(at: address.effectIndex), at: destination)
        try mutate(model, name: EditorText.moveEffect.text, ids: ids)
    }
    var moveSelectionTitle: String { effectAddress == nil ? "layer" : "effect" }
    func canMoveSelection(by offset: Int) -> Bool {
        guard permitsStructureEditing, let selection else { return false }
        switch selection {
        case .effect(let layer, let effect):
            guard
                let address = identity.checkedAddress(
                    in: state.workingModel, layer: layer, effect: effect)
            else { return false }
            return canMoveEffect(layer, effect: effect, to: address.effectIndex + offset)
        case .layer(let layer):
            guard let index = identity.layers.firstIndex(where: { $0.id == layer }) else {
                return false
            }
            return offset != 0 && identity.layers.indices.contains(index + offset)
        }
    }
    func moveSelection(by offset: Int) throws {
        guard canMoveSelection(by: offset), let selection else { return }
        switch selection {
        case .effect(let layer, let effect):
            guard let address = identity.address(layer, effect: effect) else { return }
            try moveEffect(layer, effect: effect, to: address.effectIndex + offset)
        case .layer(let layer): try moveLayer(layer, by: offset)
        }
    }
    func deleteEffect(_ target: WSSDeletableTarget) throws {
        guard currentDeletableSelection == target, finishEditing(),
            currentDeletableSelection == target,
            case .effect(let layer, let effect) = target,
            let address = identity.address(layer, effect: effect),
            case .image(var image) = state.workingModel.layers[address.layerIndex].content
        else { return }
        image.effects.remove(at: address.effectIndex)
        var model = state.workingModel
        model.layers[address.layerIndex].content = .image(image)
        var ids = identity
        ids.layers[address.layerIndex].effects.remove(at: address.effectIndex)
        let remaining = ids.layers[address.layerIndex].effects
        let next: WSSEditorSelection =
            remaining.isEmpty
            ? .layer(layer)
            : .effect(layer, remaining[min(address.effectIndex, remaining.count - 1)])
        try mutate(model, name: EditorText.deleteEffect.text, ids: ids, selected: next)
    }
}
