import Foundation

extension WSSEditorDocument {
    func chooseImage(replacing target: WSSLayerID? = nil) async {
        try? await maintenance.withMutationAsync {

            guard !closed, !interactionLocked, !importingImage else { return }
            // Resolve before the panel/await; never retarget to a newer selection.
            let original = target.flatMap { id in
                identity.layers.firstIndex(where: { $0.id == id }).map {
                    state.workingModel.layers[$0]
                }
            }
            importingImage = true
            defer { importingImage = false }
            guard let url = await chooseImageFile?() else { return }
            do {
                let remaining =
                    WSSImageImporter.stagingLimit
                    - state.sessionAssets.values.reduce(0) { $0 + $1.fingerprint.byteCount }
                let generation = try await imageImporter.load(url, remainingBudget: remaining)
                if let target {
                    guard let index = identity.layers.firstIndex(where: { $0.id == target }),
                        state.workingModel.layers[index] == original
                    else { throw WSSImageImportError.stale }
                }
                try await installImage(
                    generation, replacing: target, displayName: WSSImageLayerName.fromSource(url))
            } catch {
                guard !closed else { return }
                await presentMessage?(
                    EditorText.imageImportError.text, EditorErrorPresentation.message(error))
            }

        }
    }
    func installImage(
        _ generation: WSSImageGeneration, replacing target: WSSLayerID? = nil,
        displayName: String? = nil
    )
        async throws
    {
        try await maintenance.withMutationAsync {

            guard generation.kind == .png, !closed, !interactionLocked, finishEditing() else {
                throw WSSImageImportError.stale
            }
            beginResourceOperation()
            defer { endResourceOperation() }
            let revision = state.workingRevision
            let original = state.workingModel
            var model = original
            var ids = identity
            var selected = selection
            if let target {
                guard let index = ids.layers.firstIndex(where: { $0.id == target }),
                    case .image(var image) = model.layers[index].content
                else { throw WSSImageImportError.stale }
                image.asset = generation.path
                image.definition = WSSNativeImageDefinition(
                    asset: generation.path, encoding: "image", width: generation.width,
                    height: generation.height, uvScale: [1, 1],
                    filter: image.definition?.filter ?? "linear",
                    edge: image.definition?.edge ?? "clamp",
                    mipmapped: image.definition?.mipmapped ?? true)
                model.layers[index].content = .image(image)
            } else {
                guard model.layers.count < 128 else { throw WSSImageImportError.layerLimit }
                let factor = min(
                    1,
                    min(
                        Float(model.canvas.width) / Float(generation.width),
                        Float(model.canvas.height) / Float(generation.height)))
                let transform = WSSSceneDocumentV1.Transform(
                    center: [Float(model.canvas.width) / 2, Float(model.canvas.height) / 2],
                    size: [Float(generation.width) * factor, Float(generation.height) * factor])
                model.layers.append(
                    .init(
                        image: .init(
                            name: displayName ?? "Image", asset: generation.path,
                            definition: generation.definition,
                            transform: transform, opacity: 1, visible: true,
                            composition: "sourceOver",
                            effects: [])))
                let layer = WSSEditorIdentity.Layer(id: WSSLayerID(), effects: [])
                ids.layers.append(layer)
                selected = .layer(layer.id)
            }
            let used = state.sessionAssets.values.reduce(0) { $0 + $1.fingerprint.byteCount }
            guard generation.fingerprint.byteCount <= WSSImageImporter.stagingLimit - used else {
                throw WSSImageImportError.stagingBudget
            }
            var catalog = state.resourceCatalog
            guard catalog[generation.path] == nil else { throw WSSImageImportError.storage }
            catalog[generation.path] = generation.fingerprint
            var generations = state.sessionAssets
            generations[generation.path] = generation
            let basis = WSSProjectDiskBasis(
                identity: state.diskBasis.identity, manifest: state.diskBasis.manifest,
                assets: catalog)
            do {
                _ = try model.encoded()
                _ = try await imagePreparation.prepare(
                    model, basis: basis, handle: project.handle, sessionAssets: generations)
            } catch let error as WSSSaveError { throw error } catch let error as WSSSceneError {
                if error == .decodedImageBudget {
                    throw WSSImageImportError.decodedBudget
                }
                throw WSSImageImportError.incompatible
            } catch { throw WSSImageImportError.incompatible }
            guard !closed, !interactionLocked, revision == state.workingRevision else {
                throw WSSImageImportError.stale
            }
            // No catalog/model/undo mutation until the complete candidate has prepared.
            try retainImageGeneration(generation)
            registerModelUndo(
                original,
                name: target == nil ? EditorText.addImage.text : EditorText.replaceImage.text)
            leaveTransformMode()
            installMutation(model, ids: ids, selected: selected)

        }
    }
}

extension WSSSceneDocumentV1.Transform {
    init(center: [Float], size: [Float]) {
        self.center = center
        self.size = size
        scale = [1, 1]
        rotation = 0
    }
}
extension WSSSceneDocumentV1.Layer {
    init(image: WSSSceneDocumentV1.Image) { content = .image(image) }
}
