import Foundation

extension WSSEditorDocument {
    var selectedMaskTarget: WSSMaskTarget? {
        guard !closed else { return nil }
        return snapshot.selectedMaskTarget
    }
    func resolveMaskTarget(_ target: WSSMaskTarget) throws -> WSSResolvedMaskTarget {
        guard !closed else { throw WSSMaskError.stale }
        let context = try snapshot.maskContext(target)
        guard let path = context.path else { throw WSSMaskError.unsupported }
        try WSSNativeAssets.validatePath(path)
        guard let fingerprint = state.resourceCatalog[path] else { throw WSSMaskError.stale }
        return WSSResolvedMaskTarget(
            target: target, path: path, fingerprint: fingerprint, definition: context.definition)
    }
    func beginMaskStroke(
        target: WSSMaskTarget, settings: WSSMaskBrushSettings, start: SIMD2<Double>
    ) async throws -> WSSMaskStrokeTransaction {
        guard !closed, !interactionLocked, !saveAsBusy, !importingImage, finishEditing() else {
            throw WSSMaskError.stale
        }
        let resolved = try resolveMaskTarget(target)
        let revision = state.workingRevision
        let bitmap = try await WSSMaskPreparation().read(
            resolved, model: state.workingModel, handle: project.handle,
            generations: state.sessionAssets, basis: state.diskBasis)
        guard !closed, !interactionLocked, state.workingRevision == revision,
            try resolveMaskTarget(target) == resolved
        else { throw WSSMaskError.stale }
        return try WSSMaskStrokeTransaction(
            resolved: resolved, revision: revision, bitmap: bitmap, settings: settings, start: start
        )
    }
    func applyMaskStroke(_ candidate: WSSMaskStrokeCandidate, inputAlreadyFinished: Bool = false)
        async throws
    {
        try await maintenance.withMutationAsync {

            guard
                !inputAlreadyFinished
                    || (maskCanvas.finalizing && !maskCanvas.isDrawing
                        && maskCanvas.loaded?.resolved == candidate.resolved)
            else { throw WSSMaskError.stale }
            guard !closed, !interactionLocked || inputAlreadyFinished, !saveAsBusy, !saving,
                !importingImage,
                state.workingRevision == candidate.revision,
                try resolveMaskTarget(candidate.resolved.target) == candidate.resolved,
                inputAlreadyFinished || finishEditing(), state.workingRevision == candidate.revision
            else { throw WSSMaskError.stale }
            beginResourceOperation()
            defer { endResourceOperation() }
            interactionLocked = true
            // Canvas owns its lock from pointer-up through the entire async follow-up.
            defer { if !inputAlreadyFinished { interactionLocked = false } }
            let worker = WSSMaskPreparation()
            let before = state.workingModel
            let original = try await worker.read(
                candidate.resolved, model: before, handle: project.handle,
                generations: state.sessionAssets, basis: state.diskBasis)
            guard original == candidate.before, candidate.result != original else {
                throw WSSMaskError.stale
            }
            let used = state.sessionAssets.values.reduce(0) { $0 + $1.fingerprint.byteCount }
            let generation = try await worker.generation(
                candidate.result, remainingBudget: WSSImageImporter.stagingLimit - used)
            let model = try snapshot.settingMask(
                candidate.result.definition(path: generation.path),
                target: candidate.resolved.target)
            var catalog = state.resourceCatalog
            catalog[generation.path] = generation.fingerprint
            var generations = state.sessionAssets
            generations[generation.path] = generation
            let basis = WSSProjectDiskBasis(
                identity: state.diskBasis.identity, manifest: state.diskBasis.manifest,
                assets: catalog)
            _ = try model.encoded()
            // Includes aggregate scalar budgets after shared-resource Copy-on-Write.
            _ = try await imagePreparation.prepare(
                model, basis: basis, handle: project.handle, sessionAssets: generations)
            guard !closed, state.workingRevision == candidate.revision,
                try resolveMaskTarget(candidate.resolved.target) == candidate.resolved
            else { throw WSSMaskError.stale }
            try retainImageGeneration(generation)
            registerModelUndo(before, name: EditorText.paintMask.text)
            installMutation(model, ids: nil, selected: nil)

        }
    }
}

extension WSSEditorDocument.Snapshot {
    var selectedMaskTarget: WSSMaskTarget? {
        guard let target = maskManagementTarget,
            let context = try? maskContext(target), context.path != nil
        else { return nil }
        return target
    }
}
