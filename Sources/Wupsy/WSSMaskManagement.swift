import Foundation
import ImageIO
import UniformTypeIdentifiers

enum WSSMaskAction: String, CaseIterable {
    case create = "Create Mask"
    case replace = "Import Mask…"
    case remove = "Remove Mask"
    case clear = "Clear Mask"
    case fill = "Fill Mask"
    var title: String { localizedTitle() }
    func localizedTitle(language: String? = nil) -> String {
        switch self {
        case .create: return EditorText.maskCreate.localized(language: language)
        case .replace: return EditorText.maskImport.localized(language: language)
        case .remove: return EditorText.maskRemove.localized(language: language)
        case .clear: return EditorText.maskClear.localized(language: language)
        case .fill: return EditorText.maskFill.localized(language: language)
        }
    }
}

extension WSSEditorDocument {
    var maskManagementTarget: WSSMaskTarget? {
        guard !closed else { return nil }
        return snapshot.maskManagementTarget
    }
    func canManageMask(_ action: WSSMaskAction) -> Bool {
        guard permitsStructureEditing, !saving, maskManagementTarget != nil else { return false }
        switch action {
        case .create: return selectedMaskTarget == nil
        case .replace: return true
        case .remove, .clear, .fill: return selectedMaskTarget != nil
        }
    }
    func performMaskAction(_ action: WSSMaskAction) async {
        do {
            if action == .replace {
                await chooseMaskReplacement()
            } else {
                try await manageMask(action)
            }
        } catch {
            guard !closed else { return }
            await presentMessage?(
                EditorText.maskChangeError.text, EditorErrorPresentation.message(error))
        }
    }
    func chooseMaskReplacement() async {
        try? await maintenance.withMutationAsync {

            guard canManageMask(.replace), finishEditing(), let target = maskManagementTarget else {
                return
            }
            let revision = state.workingRevision
            // Use the same import exclusion as the image picker and native commands.
            importingImage = true
            let url = await chooseMaskFile?()
            importingImage = false
            guard let url else { return }
            do {
                guard revision == state.workingRevision, maskManagementTarget == target else {
                    throw WSSMaskError.stale
                }
                try await manageMask(.replace, file: url)
            } catch {
                guard !closed else { return }
                await presentMessage?(
                    EditorText.maskImportError.text, EditorErrorPresentation.message(error))
            }

        }
    }
    func manageMask(_ action: WSSMaskAction, file: URL? = nil, capturedInput: Bool = false)
        async throws
    {
        try await maintenance.withMutationAsync {

            let ownedPreparation =
                capturedInput && action == .create && !closed
                && !interactionLocked && !saving && !saveAsBusy && !importingImage
                && selectedMaskTarget == nil
                && maskManagementTarget.map {
                    maskCanvas.ownsSourcePreparation($0, revision: state.workingRevision)
                } == true
            guard
                ownedPreparation
                    || (!capturedInput && canManageMask(action) && finishEditing()
                        && canManageMask(action)),
                let target = maskManagementTarget
            else { throw WSSMaskError.stale }
            beginResourceOperation()
            defer { endResourceOperation() }
            try Task.checkCancellation()
            let context = try snapshot.maskContext(target)
            let before = state.workingModel
            let revision = state.workingRevision
            let worker = WSSMaskPreparation()
            interactionLocked = true
            defer { interactionLocked = false }
            let bitmap: WSSMaskBitmap?
            switch action {
            case .remove: bitmap = nil
            case .replace:
                guard let file else { throw WSSMaskError.invalid }
                bitmap = try await worker.importMask(file)
            case .create:
                bitmap = try await worker.blackMask(size: context.size)
            case .clear, .fill:
                let resolved = try resolveMaskTarget(target)
                let current = try await worker.read(
                    resolved, model: before, handle: project.handle,
                    generations: state.sessionAssets, basis: state.diskBasis)
                let value: UInt8 = action == .clear ? 0 : 255
                guard !current.pixels.allSatisfy({ $0 == value }) else { return }
                bitmap = try WSSMaskBitmap(
                    width: current.width, height: current.height,
                    uvScale: current.uvScale,
                    pixels: Data(repeating: value, count: current.pixels.count))
            }
            var generation: WSSImageGeneration?
            if let bitmap {
                let used = state.sessionAssets.values.reduce(0) { $0 + $1.fingerprint.byteCount }
                generation = try await worker.generation(
                    bitmap, remainingBudget: WSSImageImporter.stagingLimit - used)
            }
            let model = try snapshot.settingMask(
                generation.flatMap { bitmap?.definition(path: $0.path) }, target: target)
            var catalog = state.resourceCatalog
            var generations = state.sessionAssets
            if let generation {
                catalog[generation.path] = generation.fingerprint
                generations[generation.path] = generation
            }
            let basis = WSSProjectDiskBasis(
                identity: state.diskBasis.identity,
                manifest: state.diskBasis.manifest, assets: catalog)
            _ = try model.encoded()
            _ = try await imagePreparation.prepare(
                model, basis: basis, handle: project.handle, sessionAssets: generations)
            try Task.checkCancellation()
            guard !closed, revision == state.workingRevision, maskManagementTarget == target,
                !capturedInput || maskCanvas.ownsSourcePreparation(target, revision: revision)
            else { throw WSSMaskError.stale }
            if let generation { try retainImageGeneration(generation) }
            registerModelUndo(before, name: action.title)
            installMutation(model, ids: nil, selected: nil)

        }
    }
}

extension WSSMaskPreparation {
    // Local logical dimensions, independent of window zoom, screen density and layer scale.
    // Proportional downscaling only when the existing scalar limits require it.
    static func blackMaskDimensions(size: [Float]) throws -> (width: Int, height: Int) {
        guard size.count == 2, size.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw WSSMaskError.invalid
        }
        let w = ceil(Double(size[0]))
        let h = ceil(Double(size[1]))
        let factor = min(1, 8192 / max(w, h), sqrt(Double(32 * 1024 * 1024) / (w * h)))
        let width = max(1, Int(floor(w * factor)))
        let height = max(1, Int(floor(h * factor)))
        return (width, height)
    }
    func blackMask(size: [Float]) throws -> WSSMaskBitmap {
        try Self.blackMaskBitmap(size: size)
    }
    static func blackMaskBitmap(size: [Float]) throws -> WSSMaskBitmap {
        let dimensions = try Self.blackMaskDimensions(size: size)
        return try WSSMaskBitmap(
            width: dimensions.width, height: dimensions.height, uvScale: SIMD2(1, 1),
            pixels: Data(repeating: 0, count: dimensions.width * dimensions.height))
    }
    func importMask(_ url: URL) throws -> WSSMaskBitmap {
        try Task.checkCancellation()
        let bytes = try WSSAssetIO.read(
            root: url.deletingLastPathComponent(), path: url.lastPathComponent,
            limit: WSSImageImporter.inputLimit)
        let ext = url.pathExtension.lowercased()
        guard
            let source = CGImageSourceCreateWithData(
                bytes as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
            let type = CGImageSourceGetType(source) as String?,
            (type == UTType.png.identifier && ext == "png")
                || (type == UTType.jpeg.identifier && ["jpg", "jpeg"].contains(ext)),
            CGImageSourceGetCount(source) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            CGImageSourceGetStatus(source) == .statusComplete
        else { throw WSSMaskError.invalid }
        try WSSImageImporter.validateDimensions(width, height)
        return try WSSMaskBitmap(
            WSSMaskAsset.decode(bytes, width: width, height: height, uvScale: SIMD2(1, 1)))
    }
}

extension WSSEditorDocument.Snapshot {
    var maskManagementTarget: WSSMaskTarget? {
        if case .layer(let layer) = selection,
            identity.layers.count == state.workingModel.layers.count,
            let index = identity.layers.firstIndex(where: { $0.id == layer }),
            case .rain = state.workingModel.layers[index].content
        {
            return WSSMaskTarget(sessionID: state.sessionID, layerID: layer, slot: .rain)
        }
        guard case .effect(let layer, let effect) = selection,
            let address = identity.checkedAddress(
                in: state.workingModel, layer: layer, effect: effect),
            case .image(let image) = state.workingModel.layers[address.layerIndex].content,
            let slot = image.effects[address.effectIndex].scalarMaskSlot
        else { return nil }
        return WSSMaskTarget(
            sessionID: state.sessionID, layerID: layer, effectID: effect, slot: slot)
    }
}
