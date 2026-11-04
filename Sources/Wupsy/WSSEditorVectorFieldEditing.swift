import Foundation

enum WSSVectorFieldSlot: Equatable {
    case flow
}

struct WSSVectorFieldTarget: Equatable {
    let sessionID: UUID
    let layerID: WSSLayerID
    let effectID: WSSEffectID
    let slot: WSSVectorFieldSlot
}

struct WSSResolvedVectorFieldTarget: Equatable {
    let target: WSSVectorFieldTarget
    let definition: WSSSceneDocumentV1.Effect.FlowMap
    let fingerprint: WSSContentFingerprint
    let revision: UInt64
    let selectionRevision: UInt64
    let regionID: WSSAssetID?
    let regionFingerprint: WSSContentFingerprint?
    var path: String { definition.asset.value }
}

// Captures the exact decoded source. Callers supply only replacement vector bytes;
// dimensions and optional coverage cannot be changed through this API.
struct WSSVectorFieldEdit {
    let resolved: WSSResolvedVectorFieldTarget
    let field: WSSVectorFieldAsset
    let region: WSSFlowRegion?
    fileprivate init(
        resolved: WSSResolvedVectorFieldTarget, field: WSSVectorFieldAsset, region: WSSFlowRegion?
    ) {
        self.resolved = resolved
        self.field = field
        self.region = region
    }
}

enum WSSVectorFieldEditError: LocalizedError {
    case stale, unsupported, invalid, budget
    var errorDescription: String? {
        switch self {
        case .stale: return "The selected vector field changed. No changes were applied."
        case .unsupported: return "Select an effect with a supported PNG or native vector field."
        case .invalid: return "The replacement vector data is invalid."
        case .budget: return "The vector field edit exceeds the 128 MiB editor resource budget."
        }
    }
}

enum WSSVectorFieldEditorBudget {
    static let sessionGenerationLimit = 128 * 1024 * 1024
    static let workingDataLimit = 128 * 1024 * 1024

    // Future paint working buffers must reserve their complete footprint here.
    // 10A does not allocate a float working copy or retain pointer events.
    static func validateWorkingData(byteCount: Int) throws {
        guard byteCount >= 0, byteCount <= workingDataLimit else {
            throw WSSVectorFieldEditError.budget
        }
    }
    static func remainingGenerationBytes(assets: [String: WSSEditorAssetGeneration]) -> Int {
        let vectorBytes = assets.values.filter { $0.kind == .vectorField || $0.kind == .flowRegion }
            .reduce(0) { $0 + $1.fingerprint.byteCount }
        let allBytes = assets.values.reduce(0) { $0 + $1.fingerprint.byteCount }
        return max(
            0, min(sessionGenerationLimit - vectorBytes, WSSImageImporter.stagingLimit - allBytes))
    }
    static func validateGeneration(byteCount: Int, assets: [String: WSSEditorAssetGeneration])
        throws
    {
        guard byteCount >= 0, byteCount <= remainingGenerationBytes(assets: assets) else {
            throw WSSVectorFieldEditError.budget
        }
    }
}

extension WSSSceneDocumentV1.Effect {
    var vectorFieldSlot: WSSVectorFieldSlot? {
        switch native {
        case .flow: return .flow
        default: return nil
        }
    }
    func replacingRegion(_ id: WSSAssetID) throws -> Self {
        guard case .flow(var flow) = native, flow.edgeProtectionMode == .region else {
            throw WSSVectorFieldEditError.invalid
        }
        flow.flowRegion = id
        return Self(parameters: .flow(flow), mask: maskDefinition, field: fieldDefinition)
    }
    // Resource replacement remains distinct from the parameter-only API.
    fileprivate func replacingVectorField(
        expected: WSSResolvedVectorFieldTarget, generation: WSSEditorAssetGeneration
    ) throws -> Self {
        guard vectorFieldSlot == expected.target.slot, fieldDefinition == expected.definition,
            generation.kind == .vectorField
        else { throw WSSVectorFieldEditError.stale }
        let descriptor = try JSONDecoder().decode(
            FlowMap.self,
            from: JSONSerialization.data(withJSONObject: [
                "format": WSSVectorFieldAsset.fileFormat,
                "version": WSSVectorFieldAsset.fileVersion,
                "asset": generation.path,
            ]))
        var parameters = native
        switch parameters {
        case .flow(var effect):
            effect.flowMap = descriptor.asset
            parameters = .flow(effect)
        default: throw WSSVectorFieldEditError.unsupported
        }
        let result = Self(parameters: parameters, mask: maskDefinition, field: descriptor)
        return try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(result))
    }
}

actor WSSVectorFieldPreparation {
    // The runtime PNG decoder already produces the canonical native Float16 representation.
    // Reserve encoded bytes, provider/cache/RGBA, both native sources and replacement data,
    // plus fixed overlay/polyline/row-alignment headroom before ImageIO allocates pixels.
    static func validatePNGWorkingData(_ data: Data) throws {
        guard data.count >= 33, data.count <= WSSVectorFieldAsset.byteLimit,
            data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
            Array(data[12..<16]) == Array("IHDR".utf8)
        else { throw WSSVectorFieldEditError.invalid }
        func word(_ offset: Int) -> UInt64 {
            data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        let width = word(16)
        let height = word(20)
        guard (1...8192).contains(width), (1...8192).contains(height),
            width * height <= UInt64(WSSVectorFieldAsset.byteLimit / 5)
        else { throw WSSVectorFieldEditError.invalid }
        let bytes = UInt64(data.count) + width * height * 32 + 4 * 1024 * 1024
        guard bytes <= UInt64(WSSVectorFieldEditorBudget.workingDataLimit) else {
            throw WSSVectorFieldEditError.budget
        }
    }
    func read(
        _ resolved: WSSResolvedVectorFieldTarget, model: WSSSceneDocumentV1,
        handle: WSSProjectHandle, generations: [String: WSSEditorAssetGeneration],
        basis: WSSProjectDiskBasis
    ) throws -> WSSVectorFieldAsset {
        try Task.checkCancellation()
        try basis.verify(handle)
        var assets = try model.assetSource(root: handle.root)
        assets.sessionAssets = generations
        let bytes = try assets.read(
            resolved.path,
            limit: min(
                resolved.fingerprint.byteCount,
                WSSVectorFieldAsset.byteLimit + WSSVectorFieldAsset.fileHeaderBytes))
        guard WSSContentFingerprint(bytes) == resolved.fingerprint else {
            throw WSSVectorFieldEditError.stale
        }
        let field: WSSVectorFieldAsset
        if resolved.definition.format == WSSVectorFieldAsset.fileFormat {
            field = try WSSVectorFieldAsset.decodeNative(bytes)
        } else if resolved.definition.format == "wss-flow-rgba8" {
            try Self.validatePNGWorkingData(bytes)
            field = try WSSVectorFieldAsset.decode(bytes)
        } else {
            throw WSSVectorFieldEditError.unsupported
        }
        try basis.verify(handle)
        try Task.checkCancellation()
        return field
    }
    func readRegion(
        _ resolved: WSSResolvedVectorFieldTarget, model: WSSSceneDocumentV1,
        handle: WSSProjectHandle, generations: [String: WSSEditorAssetGeneration],
        basis: WSSProjectDiskBasis
    ) throws -> WSSFlowRegion? {
        guard let id = resolved.regionID else { return nil }
        try Task.checkCancellation()
        try basis.verify(handle)
        var assets = try model.assetSource(root: handle.root)
        assets.sessionAssets = generations
        let bytes = try assets.read(id.value, limit: WSSFlowRegion.byteLimit + 20)
        guard WSSContentFingerprint(bytes) == resolved.regionFingerprint else {
            throw WSSVectorFieldEditError.stale
        }
        let region = try WSSFlowRegion.decode(bytes)
        try basis.verify(handle)
        return region
    }
    func regionGeneration(_ region: WSSFlowRegion, remainingBudget: Int) throws
        -> WSSEditorAssetGeneration
    {
        try Task.checkCancellation()
        return try .flowRegion(region, remainingBudget: remainingBudget)
    }
    func generation(_ field: WSSVectorFieldAsset, remainingBudget: Int) throws
        -> WSSEditorAssetGeneration
    {
        try Task.checkCancellation()
        let generation = try WSSEditorAssetGeneration.vectorField(
            field, remainingBudget: remainingBudget)
        let bytes = try generation.read()
        guard try WSSVectorFieldAsset.decodeNative(bytes).encodedNative() == bytes else {
            throw WSSVectorFieldEditError.invalid
        }
        try Task.checkCancellation()
        return generation
    }
}

extension WSSEditorDocument {
    var selectedVectorFieldTarget: WSSVectorFieldTarget? {
        guard !closed, case .effect(let layer, let effect) = selection,
            let address = identity.checkedAddress(
                in: state.workingModel, layer: layer, effect: effect),
            case .image(let image) = state.workingModel.layers[address.layerIndex].content,
            let slot = image.effects[address.effectIndex].vectorFieldSlot
        else { return nil }
        return WSSVectorFieldTarget(
            sessionID: state.sessionID, layerID: layer, effectID: effect, slot: slot)
    }
    func resolveVectorFieldTarget(_ target: WSSVectorFieldTarget) throws
        -> WSSResolvedVectorFieldTarget
    {
        guard !closed, selectedVectorFieldTarget == target,
            let address = identity.checkedAddress(
                in: state.workingModel, layer: target.layerID, effect: target.effectID),
            case .image(let image) = state.workingModel.layers[address.layerIndex].content
        else { throw WSSVectorFieldEditError.stale }
        let effect = image.effects[address.effectIndex]
        guard effect.vectorFieldSlot == target.slot, let definition = effect.fieldDefinition,
            [WSSVectorFieldAsset.fileFormat, "wss-flow-rgba8"].contains(definition.format),
            definition.version == WSSVectorFieldAsset.fileVersion
        else { throw WSSVectorFieldEditError.unsupported }
        try WSSNativeAssets.validatePath(definition.asset.value)
        guard let fingerprint = state.resourceCatalog[definition.asset.value] else {
            throw WSSVectorFieldEditError.stale
        }
        return WSSResolvedVectorFieldTarget(
            target: target, definition: definition, fingerprint: fingerprint,
            revision: state.workingRevision, selectionRevision: selectionRevision,
            regionID: effect.flowRegionID,
            regionFingerprint: effect.flowRegionID.flatMap { state.resourceCatalog[$0.value] })
    }
    private func checkVectorFieldEdit(
        _ resolved: WSSResolvedVectorFieldTarget,
        inputAlreadyFinished: Bool = false, capturedInput: Bool = false
    ) throws {
        let ownsCapture = capturedInput && ownsDirectionSourcePreparation(resolved)
        let ownsLock = (inputAlreadyFinished && ownsDirectionFinalization(resolved)) || ownsCapture
        guard !inputAlreadyFinished || ownsLock,
            !closed, !interactionLocked || ownsLock, !saveAsBusy, !saving, !importingImage,
            !hasActivePaintInteraction || ownsLock,
            try resolveVectorFieldTarget(resolved.target) == resolved
        else { throw WSSVectorFieldEditError.stale }
        try Task.checkCancellation()
    }
    func loadVectorField(
        _ target: WSSVectorFieldTarget, finishControls: Bool = true, capturedInput: Bool = false
    ) async throws
        -> WSSVectorFieldEdit
    {
        let capturedSource = capturedInput ? try? resolveVectorFieldTarget(target) : nil
        let ownsCapture = capturedSource.map(ownsDirectionSourcePreparation) ?? false
        guard !finishControls || ownsCapture || finishEditing() else {
            throw WSSVectorFieldEditError.stale
        }
        // Finishing a numeric edit can change the revision. Resolve normal reads afterwards.
        let resolved = try resolveVectorFieldTarget(target)
        try checkVectorFieldEdit(resolved, capturedInput: capturedInput)
        beginResourceOperation()
        defer { endResourceOperation() }
        let field = try await WSSVectorFieldPreparation().read(
            resolved, model: state.workingModel, handle: project.handle,
            generations: state.sessionAssets, basis: state.diskBasis)
        try checkVectorFieldEdit(resolved, capturedInput: capturedInput)
        let region = try await WSSVectorFieldPreparation().readRegion(
            resolved, model: state.workingModel, handle: project.handle,
            generations: state.sessionAssets, basis: state.diskBasis)
        try checkVectorFieldEdit(resolved, capturedInput: capturedInput)
        return WSSVectorFieldEdit(resolved: resolved, field: field, region: region)
    }
    @discardableResult
    func replaceVectorField(
        _ edit: WSSVectorFieldEdit, vectors: Data, region: WSSFlowRegion? = nil,
        inputAlreadyFinished: Bool = false
    ) async throws -> Bool {
        try await maintenance.withMutationAsync {
            guard !vectorFieldMutationInProgress else { throw WSSVectorFieldEditError.stale }
            vectorFieldMutationInProgress = true
            defer { vectorFieldMutationInProgress = false }
            try checkVectorFieldEdit(edit.resolved, inputAlreadyFinished: inputAlreadyFinished)
            guard inputAlreadyFinished || finishEditing() else {
                throw WSSVectorFieldEditError.stale
            }
            try checkVectorFieldEdit(edit.resolved, inputAlreadyFinished: inputAlreadyFinished)
            beginResourceOperation()
            defer { endResourceOperation() }
            let worker = WSSVectorFieldPreparation()
            let before = state.workingModel
            let original = try await worker.read(
                edit.resolved, model: before, handle: project.handle,
                generations: state.sessionAssets, basis: state.diskBasis)
            try checkVectorFieldEdit(edit.resolved, inputAlreadyFinished: inputAlreadyFinished)
            guard original.vectors == edit.field.vectors, original.coverage == edit.field.coverage,
                original.width == edit.field.width, original.height == edit.field.height
            else { throw WSSVectorFieldEditError.stale }
            let originalRegion = try await worker.readRegion(
                edit.resolved, model: before, handle: project.handle,
                generations: state.sessionAssets, basis: state.diskBasis)
            try checkVectorFieldEdit(edit.resolved, inputAlreadyFinished: inputAlreadyFinished)
            guard originalRegion == edit.region else { throw WSSVectorFieldEditError.stale }
            let replacementRegion = region ?? originalRegion
            if let region {
                try region.validate()
                guard let originalRegion, originalRegion.width == region.width,
                    originalRegion.height == region.height
                else { throw WSSVectorFieldEditError.invalid }
            }
            let vectorChanged = vectors != original.vectors
            let regionChanged = replacementRegion != originalRegion
            let candidate = WSSVectorFieldAsset(
                width: original.width, height: original.height, vectors: vectors,
                coverage: original.coverage, isNeutral: false)
            let neutral = try candidate.validatedNeutrality()
            // Both runtime decoders return canonical RG16F: a no-op must retain PNG references too.
            guard vectorChanged || regionChanged else { return false }
            let result = WSSVectorFieldAsset(
                width: original.width, height: original.height, vectors: vectors,
                coverage: original.coverage, isNeutral: neutral)
            let count =
                WSSVectorFieldAsset.fileHeaderBytes + vectors.count
                + (original.coverage?.count ?? 0)
            try WSSVectorFieldEditorBudget.validateGeneration(
                byteCount: (vectorChanged ? count : 0)
                    + (regionChanged ? (replacementRegion?.pixels.count ?? 0) + 20 : 0),
                assets: state.sessionAssets)
            try checkVectorFieldEdit(edit.resolved, inputAlreadyFinished: inputAlreadyFinished)
            let generation =
                try await vectorChanged
                ? worker.generation(
                    result,
                    remainingBudget: WSSVectorFieldEditorBudget.remainingGenerationBytes(
                        assets: state.sessionAssets)) : nil
            let regionGeneration =
                try await regionChanged
                ? worker.regionGeneration(
                    replacementRegion!,
                    remainingBudget: WSSVectorFieldEditorBudget.remainingGenerationBytes(
                        assets: state.sessionAssets)) : nil
            try checkVectorFieldEdit(edit.resolved, inputAlreadyFinished: inputAlreadyFinished)
            guard
                let address = identity.checkedAddress(
                    in: before, layer: edit.resolved.target.layerID,
                    effect: edit.resolved.target.effectID),
                case .image(var image) = before.layers[address.layerIndex].content
            else { throw WSSVectorFieldEditError.stale }
            if let generation {
                image.effects[address.effectIndex] = try image.effects[address.effectIndex]
                    .replacingVectorField(expected: edit.resolved, generation: generation)
            }
            if let regionGeneration {
                image.effects[address.effectIndex] = try image.effects[address.effectIndex]
                    .replacingRegion(WSSAssetID(value: regionGeneration.path))
            }
            var model = before
            model.layers[address.layerIndex].content = .image(image)
            var catalog = state.resourceCatalog
            let replacements = [generation, regionGeneration].compactMap { $0 }
            var generations = state.sessionAssets
            for replacement in replacements {
                catalog[replacement.path] = replacement.fingerprint
                generations[replacement.path] = replacement
            }
            let basis = WSSProjectDiskBasis(
                identity: state.diskBasis.identity, manifest: state.diskBasis.manifest,
                assets: catalog)
            _ = try model.encoded()
            _ = try await imagePreparation.prepare(
                model, basis: basis, handle: project.handle, sessionAssets: generations)
            try checkVectorFieldEdit(edit.resolved, inputAlreadyFinished: inputAlreadyFinished)
            // Recheck the source after async preflight, including external file changes.
            _ = try await worker.read(
                edit.resolved, model: before, handle: project.handle,
                generations: state.sessionAssets, basis: state.diskBasis)
            try checkVectorFieldEdit(edit.resolved, inputAlreadyFinished: inputAlreadyFinished)
            _ = try await worker.readRegion(
                edit.resolved, model: before, handle: project.handle,
                generations: state.sessionAssets, basis: state.diskBasis)
            try checkVectorFieldEdit(edit.resolved, inputAlreadyFinished: inputAlreadyFinished)
            try retainImageGenerations(replacements)
            registerModelUndo(before, name: EditorText.replaceVector.text)
            installMutation(model, ids: nil, selected: nil)
            return true
        }
    }
}
