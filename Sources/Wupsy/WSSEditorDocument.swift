import AppKit
import Foundation
import SwiftUI

@MainActor final class WSSEditorDocument: ObservableObject {
    var maintenance: MaintenanceCoordinator = .shared
    @Published private(set) var project: WSSLoadedEditorProject
    // One publication boundary for the mutually dependent document structure.
    struct Snapshot {
        var state: WSSEditorDocumentState
        var identity: WSSEditorIdentity
        var selection: WSSEditorSelection?
    }
    @Published private(set) var snapshot: Snapshot
    private(set) var state: WSSEditorDocumentState {
        get { snapshot.state }
        set { snapshot.state = newValue }
    }
    private(set) var identity: WSSEditorIdentity {
        get { snapshot.identity }
        set { snapshot.identity = newValue }
    }
    @Published var transformModeLayer: WSSLayerID?
    // Window-level key tracking is authoritative, including key-up events that
    // AppKit does not deliver to the Canvas responder.
    var canvasSpaceDown = false {
        didSet {
            if oldValue != canvasSpaceDown { canvasSpaceChanged?() }
        }
    }
    var canvasSpaceChanged: (() -> Void)?
    var canvasPreparationTask: (() -> Task<Void, Never>?)?
    private var resourceOperations = 0
    private var resourceWaiters: [CheckedContinuation<Void, Never>] = []
    func beginResourceOperation() { resourceOperations += 1 }
    func endResourceOperation() {
        resourceOperations -= 1
        if resourceOperations == 0 {
            let waiters = resourceWaiters
            resourceWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }
    private func waitForResourceOperations() async {
        guard resourceOperations > 0 else { return }
        await withCheckedContinuation { resourceWaiters.append($0) }
    }
    var captureCanvasPresentation: (() -> WSSCanvasPresentation?)?
    var restoreCanvasPresentation: ((WSSCanvasPresentation) -> Void)?
    var canvasZoomCommand: ((WSSCanvasZoomCommand) -> Bool)?
    var canvasZoomAvailable: (() -> Bool)?
    private(set) var selectionRevision: UInt64 = 0
    var vectorFieldMutationInProgress = false
    var selection: WSSEditorSelection? {
        get { snapshot.selection }
        set {
            let changed = newValue != selection
            snapshot.selection = newValue
            if changed {
                selectionRevision &+= 1
                transformModeLayer = nil
                refreshMaskSelection(selectionChanged: true)
                directionSessionStorage?.refresh(selectionChanged: true)
            }
        }
    }
    private var savedIdentity: WSSEditorIdentity
    private var maskSessionStorage: WSSMaskCanvasSession?
    private var directionSessionStorage: WSSDirectionCanvasSession?
    var directionCanvas: WSSDirectionCanvasSession {
        if let directionSessionStorage { return directionSessionStorage }
        let session = WSSDirectionCanvasSession(document: self)
        directionSessionStorage = session
        return session
    }
    var activeCanvasPaint: (any WSSCanvasPaintInteraction)? {
        if directionSessionStorage?.brushEnabled == true { return directionSessionStorage }
        if maskSessionStorage?.brushEnabled == true { return maskSessionStorage }
        return nil
    }
    func ownsDirectionSourcePreparation(_ resolved: WSSResolvedVectorFieldTarget) -> Bool {
        directionSessionStorage?.ownsSourcePreparation(resolved) == true
    }
    var paintBrushEnabled: Bool { activeCanvasPaint?.brushEnabled == true }
    var hasActiveMaskInteraction: Bool { maskSessionStorage?.blocksDocumentActions == true }
    @discardableResult func cancelMaskInteraction() -> Bool {
        maskSessionStorage?.escape() ?? false
    }
    func ownsDirectionFinalization(_ resolved: WSSResolvedVectorFieldTarget) -> Bool {
        directionSessionStorage?.ownsFinalization(resolved) == true
    }
    var maskCanvas: WSSMaskCanvasSession {
        if let maskSessionStorage { return maskSessionStorage }
        let session = WSSMaskCanvasSession(document: self)
        maskSessionStorage = session
        session.refresh()
        return session
    }
    private func refreshMaskSelection(selectionChanged: Bool) {
        if let maskSessionStorage {
            maskSessionStorage.refresh(selectionChanged: selectionChanged)
        } else if maskManagementTarget?.slot.supportsDirectPaint == true {
            _ = maskCanvas
        }
    }
    var maskBrushEnabled: Bool { maskSessionStorage?.brushEnabled == true }
    var hasActivePaintInteraction: Bool {
        hasActiveMaskInteraction || directionSessionStorage?.blocksDocumentActions == true
    }
    @discardableResult func cancelPaintInteraction() -> Bool {
        if directionSessionStorage?.escape() == true { return true }
        return maskSessionStorage?.escape() ?? false
    }
    func cancelMaskStrokeForSelectionChange() {
        maskSessionStorage?.cancelStroke()
        directionSessionStorage?.cancelStroke()
    }
    private var savingIdentity: WSSEditorIdentity?
    var selectedLayer: Int {
        get { identity.layers.firstIndex { $0.id == selection?.layer } ?? 0 }
        set {
            if identity.layers.indices.contains(newValue) {
                selection = .layer(identity.layers[newValue].id)
            }
        }
    }
    var effectAddress: WSSEffectAddress? {
        guard case .effect(let layer, let effect) = selection else { return nil }
        return identity.address(layer, effect: effect)
    }
    var editTarget: WSSEditTarget? {
        guard let selection else { return nil }
        switch selection {
        case .layer(let id):
            guard state.workingModel.layers.indices.contains(selectedLayer),
                case .image = state.workingModel.layers[selectedLayer].content
            else { return nil }
            return WSSEditTarget(layer: id, role: .image)
        case .effect(let layer, let effect):
            guard let address = identity.address(layer, effect: effect),
                case .image(let image) = state.workingModel.layers[address.layerIndex].content
            else { return nil }
            switch image.effects[address.effectIndex].native {
            case .flow:
                return WSSEditTarget(layer: layer, effect: effect, role: .vectorField)
            case .ripple, .clouds: return WSSEditTarget(layer: layer, effect: effect, role: .mask)
            }
        }
    }
    @Published var canvasTransform: WSSCanvasTransformTransaction?
    var finishCanvasInteraction: (() -> Void)?
    private var previewModel: WSSSceneDocumentV1
    private let permitsResourceReuse: Bool
    var stopCanvas: (() -> Void)?
    @Published private(set) var canvasModel: WSSSceneDocumentV1
    var canvasImageDrag: (WSSLayerID, WSSImageProperty, Float)?

    @Published var previewExpanded = false
    var togglePreviewExpansion: (() -> Void)?
    @Published var playing = true
    @Published private(set) var previewError: String?
    private(set) var closed = false
    var stopPreview: (() -> Void)?

    typealias Save = (WSSSaveSnapshot) async throws -> WSSSaveReceipt
    typealias Prepare = (WSSSceneDocumentV1, WSSProjectDiskBasis, WSSProjectHandle) async throws ->
        WSSStaticResources
    let undoManager = WSSEditorUndoManager()
    @Published var saveAsBusy = false
    typealias PublishDraft = (WSSSaveAsSnapshot) async throws -> WSSSaveAsReceipt
    var publishDraft: PublishDraft?
    private(set) var draftPublicationReceipt: WSSSaveAsReceipt?
    private var draftCleanupTask: Task<Void, Never>?
    var requestSaveAs: (() async -> Bool)?
    var chooseFirstSaveName: ((String) async -> String?)?
    var chooseSaveAsName: ((String) async -> String?)?
    var committedCopy: (receipt: WSSSaveAsReceipt, revision: UInt64)?
    var initialCanvasZoom: CGFloat?
    var initialPreviewTime: Double = 0
    var canSaveAs: Bool {
        project.handle.origin != .draft && !closed && !interactionLocked && !saving
            && !importingImage && !isResolvingClose
            && !saveAsBusy && !hasActivePaintInteraction && requestSaveAs != nil
    }
    @Published var importingImage = false
    let imageImporter = WSSImageImporter()
    let imagePreparation = WSSEditorPreviewPreparation()
    @Published private(set) var saving = false
    @Published private(set) var operationInteractionLocked = false
    @Published var maintenanceInteractionLocked = false
    var interactionLocked: Bool {
        get { operationInteractionLocked || maintenanceInteractionLocked }
        set { operationInteractionLocked = newValue }
    }
    @Published private(set) var previewResources: WSSStaticResources
    @Published private(set) var previewRevision: UInt64 = 0
    @Published private(set) var preparationError: String?
    @Published private(set) var preparationMilliseconds: Double = 0
    enum CloseChoice { case save, discard, cancel }
    var chooseMaskFile: (() async -> URL?)?
    var chooseImageFile: (() async -> URL?)?
    var chooseClose: (() async -> CloseChoice)?
    private var closeTask: Task<Bool, Never>?
    var finishInput: (() -> Bool)?
    var presentMessage: ((String, String) async -> Void)?
    private let saveService: Save?
    private let prepare: Prepare
    private var saveTask: Task<Bool, Never>?
    private var previewTask: Task<Void, Never>?
    private var desiredPreview: UInt64?
    var trailDrag: (WSSLayerID, String, WSSSceneDocumentV1)?
    var rainDrag: (WSSLayerID, WSSRainParameter, WSSSceneDocumentV1)?
    private var drag: (WSSEffectAddress, WSSEditorParameter, Float)?

    init(project: WSSLoadedEditorProject, save: Save? = nil, prepare: Prepare? = nil) {
        let initialIDs = WSSEditorIdentity(project.document)
        snapshot = Snapshot(
            state: WSSEditorDocumentState(model: project.document, diskBasis: project.diskBasis),
            identity: initialIDs, selection: initialIDs.layers.first.map { .layer($0.id) })
        savedIdentity = initialIDs
        canvasModel = WSSStaticComposition.model(project.document)
        saveService = save
        let preparation = WSSEditorPreviewPreparation()
        self.prepare = prepare ?? { try await preparation.prepare($0, basis: $1, handle: $2) }
        previewModel = project.document
        permitsResourceReuse = prepare == nil
        previewResources = project.resources
        undoManager.groupsByEvent = false
        self.project = project
        undoManager.hasPendingInteraction = { [weak self] in
            guard let self else { return false }
            if let (_, _, original) = self.trailDrag, original != self.state.workingModel {
                return true
            }
            return self.canvasTransform.map { $0.model != self.state.workingModel } ?? false
        }
        undoManager.finishInteraction = { [weak self] in
            self?.finishCanvasInteraction?()
            self?.endCanvasTransform()
            self?.endTrailInteraction()
        }
        undoManager.permitsEditing = { [weak self] in
            self.map { !$0.closed && !$0.interactionLocked && !$0.hasActivePaintInteraction }
                ?? false
        }
    }
    func installMutation(
        _ model: WSSSceneDocumentV1, ids: WSSEditorIdentity?, selected: WSSEditorSelection?
    ) {
        let changed = model != state.workingModel
        installSnapshot(model, ids: ids ?? identity, selected: selected ?? selection)
        if changed { requestPreview() }
    }
    private func installSnapshot(
        _ model: WSSSceneDocumentV1, ids: WSSEditorIdentity, selected: WSSEditorSelection?
    ) {
        var next = snapshot
        next.state.replaceWorkingModel(model)
        next.identity = ids
        next.selection = selected
        let selectionChanged = selection != selected
        snapshot = next
        // Synchronous mask observers only run after all three values are installed.
        if selectionChanged {
            selectionRevision &+= 1
            transformModeLayer = nil
        }
        refreshMaskSelection(selectionChanged: selectionChanged)
        directionSessionStorage?.refresh(selectionChanged: selectionChanged)
    }
    func retainImageGeneration(_ generation: WSSImageGeneration) throws {
        try state.retainGeneration(generation)
    }
    func retainImageGenerations(_ generations: [WSSImageGeneration]) throws {
        try state.retainGenerations(generations)
    }
    var editorPreviewResources: WSSStaticResources {
        directionSessionStorage?.liveResources ?? previewResources
    }
    func previewFailed(_ text: String) {
        guard !closed, previewError == nil else { return }
        previewError = EditorText.errorPreview.format(text)
        playing = false
        stopPreview?()
    }
    func close() {
        guard !closed else { return }
        endCanvasTransform()
        transformModeLayer = nil
        closed = true
        maskSessionStorage?.shutdown()
        directionSessionStorage?.shutdown()
        let pendingPreview = previewTask
        let pendingCanvas = canvasPreparationTask?()
        let pendingSave = saveTask
        previewTask?.cancel()
        previewTask = nil
        desiredPreview = nil
        let owner = project.handle.draftOwner
        do {
            let masks = maskSessionStorage
            let directions = directionSessionStorage
            draftCleanupTask = Task {
                _ = await pendingSave?.value
                await pendingPreview?.value
                await pendingCanvas?.value
                await self.waitForResourceOperations()
                await masks?.waitForLoad()
                await masks?.waitForFinish()
                await masks?.waitForBrushActivation()
                await directions?.waitForLoad()
                await directions?.waitForFeedback()
                await directions?.waitForFinish()
                do { try owner?.discard() } catch {
                    NSLog("Wupsy: owned draft cleanup failed: %@", error.localizedDescription)
                }
            }
        }
        state.close()
        undoManager.removeAllActions()
        finishInput = nil
        chooseClose = nil
        chooseMaskFile = nil
        chooseImageFile = nil
        chooseSaveAsName = nil
        chooseFirstSaveName = nil
        requestSaveAs = nil
        presentMessage = nil
        stopPreview?()
        stopPreview = nil
        togglePreviewExpansion = nil
        stopCanvas?()
        stopCanvas = nil
        finishCanvasInteraction = nil
        canvasPreparationTask = nil
        captureCanvasPresentation = nil
        restoreCanvasPresentation = nil
        canvasZoomCommand = nil
        canvasZoomAvailable = nil
    }
    var isUnpublished: Bool { project.handle.origin == .draft && draftPublicationReceipt == nil }
    var isDirty: Bool { project.handle.origin == .draft || state.isDirty }
    var canRevert: Bool { project.handle.origin != .draft && isDirty && !saving }
    func closeAndDrainForMaintenance() async {
        close()
        await draftCleanupTask?.value
    }
    func waitForDraftCleanup() async { await draftCleanupTask?.value }
    var isResolvingClose: Bool { closeTask != nil }
    var canSave: Bool {
        !closed && !interactionLocked && !saving && !saveAsBusy && !hasActivePaintInteraction
            && isDirty
    }
    var workingScene: WSSScene { (try? state.workingModel.scene()) ?? project.scene }
    var previewIsCurrent: Bool {
        previewRevision == state.workingRevision && preparationError == nil
    }

    func finishEditing() -> Bool {
        guard !hasActivePaintInteraction else { return false }
        finishCanvasInteraction?()
        endCanvasTransform()
        endSlider()
        endImageSlider()
        endRainSlider()
        endTrailInteraction()
        return finishInput?() ?? true
    }
    func setParameter(
        _ parameter: WSSEditorParameter, at address: WSSEffectAddress, value: Float,
        registerUndo: Bool = true
    ) throws {
        guard !closed, !interactionLocked else { return }
        endCanvasTransform()
        let before = state.workingModel
        let model = try parameter.applying(value, to: before, at: address)
        installParameterMutation(
            model, before: before, title: parameter.title, registerUndo: registerUndo)
    }
    func setRippleSeed(at address: WSSEffectAddress, value: Double) throws {
        guard !closed, !interactionLocked else { return }
        endCanvasTransform()
        let before = state.workingModel
        let model = try WSSEditorParameter.applyingRippleSeed(value, to: before, at: address)
        installParameterMutation(
            model, before: before, title: EditorText.rippleSeed.text, registerUndo: true)
    }
    private func installParameterMutation(
        _ model: WSSSceneDocumentV1,
        before: WSSSceneDocumentV1, title: String, registerUndo: Bool
    ) {
        guard before != model else { return }
        if registerUndo {
            endSlider()
            registerModelUndo(before, name: title)
        }
        state.replaceWorkingModel(model)
        requestPreview()
    }
    func registerModelUndo(
        _ model: WSSSceneDocumentV1, name: String, ids: WSSEditorIdentity? = nil,
        selected: WSSEditorSelection? = nil
    ) {
        let undoIDs = ids ?? identity
        let undoSelection = selected ?? selection
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { target in
            target.restoreModel(model, name: name, ids: undoIDs, selected: undoSelection)
        }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
    }
    private func restoreModel(
        _ model: WSSSceneDocumentV1, name: String, ids: WSSEditorIdentity,
        selected: WSSEditorSelection?
    ) {
        endCanvasTransform()
        finishCanvasInteraction?()
        guard !closed, !interactionLocked, (try? model.scene()) != nil else { return }
        registerModelUndo(state.workingModel, name: name)
        let changed = model != state.workingModel
        installSnapshot(model, ids: ids, selected: selected)
        if changed { requestPreview() }
    }
    func updateSlider(_ parameter: WSSEditorParameter, at address: WSSEffectAddress, value: Float)
        throws
    {
        let continuous = drag.map { $0.0 == address && $0.1 == parameter } ?? false
        try setParameter(parameter, at: address, value: value, registerUndo: !continuous)
    }
    func beginSlider(_ parameter: WSSEditorParameter, at address: WSSEffectAddress) {
        endSlider()
        if let value = parameter.value(in: state.workingModel, at: address) {
            drag = (address, parameter, value)
        }
    }
    func endSlider() {
        guard let (address, parameter, original) = drag else { return }
        drag = nil
        guard parameter.value(in: state.workingModel, at: address) != original,
            let before = try? parameter.applying(original, to: state.workingModel, at: address)
        else { return }
        registerModelUndo(before, name: parameter.title)
        objectWillChange.send()
    }
    func revert() {
        guard !closed, !interactionLocked, !saving, finishEditing(), canRevert else { return }
        registerModelUndo(state.workingModel, name: EditorText.revert.text)
        var selected = selection
        if !savedIdentity.layers.contains(where: { $0.id == selected?.layer }) {
            selected = savedIdentity.layers.first.map { .layer($0.id) }
        }
        if case .effect(let layer, let effect) = selected,
            savedIdentity.address(layer, effect: effect) == nil
        {
            selected = .layer(layer)
        }
        installSnapshot(state.savedModel, ids: savedIdentity, selected: selected)
        requestPreview()
    }
    func requestPreview() {
        maskSessionStorage?.refresh()
        directionSessionStorage?.refresh()
        let staticModel = WSSStaticComposition.model(state.workingModel)
        if canvasModel != staticModel { canvasModel = staticModel }
        desiredPreview = state.workingRevision
        guard previewTask == nil, !closed else { return }
        let session = state.sessionID
        previewTask = Task { [weak self] in
            guard let self else { return }
            while let revision = desiredPreview, !closed, !Task.isCancelled {
                desiredPreview = nil
                let model = state.workingModel
                let basis = WSSProjectDiskBasis(
                    identity: state.diskBasis.identity, manifest: state.diskBasis.manifest,
                    assets: state.resourceCatalog)
                let start = ProcessInfo.processInfo.systemUptime
                do {
                    let resources: WSSStaticResources
                    if permitsResourceReuse,
                        let reused = try previewResources.updatingTransforms(
                            from: previewModel, to: model)
                    {
                        resources = reused
                    } else if permitsResourceReuse, !state.sessionAssets.isEmpty {
                        resources = try await imagePreparation.prepare(
                            model, basis: basis, handle: project.handle,
                            sessionAssets: state.sessionAssets)
                    } else {
                        resources = try await prepare(model, basis, project.handle)
                    }
                    guard !closed, session == state.sessionID else { break }
                    if revision == state.workingRevision {
                        previewModel = model
                        previewResources = resources
                        previewRevision = revision
                        preparationError = nil
                        preparationMilliseconds =
                            (ProcessInfo.processInfo.systemUptime - start) * 1000
                    }
                } catch {
                    if !closed, session == state.sessionID, revision == state.workingRevision {
                        preparationError = EditorErrorPresentation.message(error)
                    }
                }
                // Single worker and a replaceable latest request. Limit rebuilds to 10 Hz.
                let remaining = 0.1 - (ProcessInfo.processInfo.systemUptime - start)
                if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            }
            previewTask = nil
        }
    }
    func save() async -> Bool {
        guard maintenance.allowsMutation else { return false }
        return
            (try? await maintenance.withMutationAsync {

                guard !saveAsBusy else { return false }
                if let saveTask { return await saveTask.value }
                guard !closed, !importingImage, finishEditing() else { return false }
                if project.handle.origin == .draft { return await saveDraft() }
                guard isDirty else { return true }
                guard let saveService, let snapshot = state.beginSave() else { return false }
                savingIdentity = identity
                saving = true
                let task = Task { [weak self] in
                    guard let self else { return false }
                    defer {
                        saveTask = nil
                        saving = false
                        savingIdentity = nil
                    }
                    do {
                        let receipt = try await saveService(snapshot)
                        guard !closed else { return false }
                        state.accept(receipt)
                        if let savingIdentity { savedIdentity = savingIdentity }
                        if case .committed(let warnings) = receipt.outcome, !warnings.isEmpty {
                            await presentMessage?(
                                EditorText.savedWarning.text, warnings.joined(separator: "\n"))
                        }
                        return true
                    } catch {
                        state.failed(snapshot)
                        guard !closed else { return false }
                        var detail = EditorErrorPresentation.message(error)
                        if error as? WSSSaveError == .externalConflict {
                            detail = EditorText.saveConflictDetail.format(detail)
                        }
                        await presentMessage?(EditorText.saveError.text, detail)
                        return false
                    }
                }
                saveTask = task
                return await task.value

            }) ?? false
    }
    private func saveDraft() async -> Bool {
        guard let publishDraft else { return false }
        let wasLocked = operationInteractionLocked
        let canvasPresentation = captureCanvasPresentation?()
        interactionLocked = true
        saving = true
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            defer {
                saving = false
                interactionLocked = wasLocked
                saveTask = nil
            }
            do {
                let receipt: WSSSaveAsReceipt
                if let committed = draftPublicationReceipt {
                    receipt = committed
                } else {
                    guard let name = await chooseFirstSaveName?(state.workingModel.title), !closed
                    else {
                        return false
                    }
                    let title = try WSSSaveAsSnapshot.title(name)
                    let snapshot = try WSSSaveAsSnapshot(
                        document: state.workingModel, state: state,
                        source: project.handle, name: title,
                        destinationID: project.handle.id)
                    receipt = try await publishDraft(snapshot)
                    // Library commit is authoritative. Never repeat publication after this point.
                    draftPublicationReceipt = receipt
                }
                guard !closed else { return true }
                let owner = project.handle.draftOwner
                previewTask?.cancel()
                desiredPreview = nil
                await previewTask?.value
                previewTask = nil
                await maskSessionStorage?.waitForLoad()
                while let canvasTask = canvasPreparationTask?() { await canvasTask.value }
                guard !closed else { return true }
                // In-place takeover preserves the native window, pan/zoom and its player clock.
                project = receipt.project
                snapshot = Snapshot(
                    state: WSSEditorDocumentState(
                        model: receipt.project.document,
                        diskBasis: receipt.project.diskBasis), identity: identity,
                    selection: selection)
                savedIdentity = identity
                previewModel = receipt.project.document
                previewResources = receipt.project.resources
                previewRevision = state.workingRevision
                preparationError = nil
                undoManager.removeAllActions()
                maskSessionStorage?.refresh()
                directionSessionStorage?.refresh()
                if let canvasPresentation { restoreCanvasPresentation?(canvasPresentation) }
                var warnings = receipt.warnings
                do { try owner?.discard() } catch {
                    warnings.append(
                        EditorText.draftCleanupWarning.text
                    )
                }
                if !warnings.isEmpty {
                    await presentMessage?(
                        EditorText.savedWarning.text, warnings.joined(separator: "\n"))
                }
                return true
            } catch {
                guard !closed else { return false }
                await presentMessage?(
                    EditorText.saveError.text, EditorErrorPresentation.message(error))
                return false
            }
        }
        saveTask = task
        return await task.value
    }
    func waitForPreview() async { await previewTask?.value }
    func waitForSave() async -> Bool {
        if let saveTask { return await saveTask.value }
        return true
    }

    func resolveChanges() async -> Bool {
        guard !saveAsBusy else { return false }
        if let closeTask { return await closeTask.value }
        guard !closed, finishEditing() else { return false }
        let wasLocked = operationInteractionLocked
        interactionLocked = true
        let task = Task { [weak self] in
            guard let self else { return false }
            guard await waitForSave() else { return false }
            guard isDirty else { return true }
            switch await chooseClose?() ?? .cancel {
            case .cancel: return false
            case .discard: return true
            case .save: return await save() && !isDirty
            }
        }
        closeTask = task
        let result = await task.value
        closeTask = nil
        interactionLocked = wasLocked
        return result
    }

    var layerNames: [String] {
        workingScene.layers.enumerated().map { index, node in
            let name: String
            switch node {
            case .image(let image):
                if case .image(let dto) = state.workingModel.layers[index].content,
                    let displayName = dto.name
                {
                    name = displayName
                } else {
                    name = EditorText.imageFilename.format(
                        URL(fileURLWithPath: image.asset.value).lastPathComponent)
                }
            case .rain: name = EditorText.effectRain.text
            case .trail: name = EditorText.effectTrail.text
            }
            return EditorText.layerOrdinal.format(index + 1, name)
        }
    }
    var inspection: [WSSInspectionSection] {
        var sections: [WSSInspectionSection] = []
        guard state.workingModel.layers.indices.contains(selectedLayer) else { return sections }
        let dto = state.workingModel.layers[selectedLayer]
        func section(_ kind: WSSInspectionSection.Kind, _ title: String, _ rows: [WSSInspectionRow])
        {
            sections.append(WSSInspectionSection(kind: kind, title: title, entries: rows))
        }
        switch workingScene.layers[selectedLayer] {
        case .image(let image):
            var rows: [WSSInspectionRow] = [
                .init(.visible, String(image.visible)), .init(.opacity, Self.n(image.opacity)),
                .init(.composition, image.composition == .replace ? "replace" : "sourceOver"),
            ]
            if let transform = dto.imageTransform {
                rows += [
                    .init(.center, Self.pair(transform.center)),
                    .init(.size, Self.pair(transform.size)),
                    .init(.scale, Self.pair(transform.scale)),
                    .init(
                        .rotation,
                        "\(Self.n(transform.rotation * 180 / .pi))° (\(Self.n(transform.rotation)) rad)"
                    ),
                ]
            }
            section(.image, EditorText.imageSection.text, rows)
            section(
                .imageAsset, "Image asset", Self.assetRows(image.asset.value, dto.imageDefinition))
            for (index, effect) in image.effects.enumerated() {
                var effectSections = Self.effectSections(
                    effect, index: index, masks: dto.maskDefinitions)
                let address = WSSEffectAddress(layerIndex: selectedLayer, effectIndex: index)
                let parameters = WSSEditorParameter.allCases.filter {
                    $0.value(in: state.workingModel, at: address) != nil
                }
                if !parameters.isEmpty {
                    effectSections[0].editableAddress = address
                    effectSections[0].entries.removeAll { row in
                        parameters.contains { $0.inspectionRowKind == row.kind }
                    }
                }
                for i in effectSections.indices {
                    effectSections[i].target = .effect(index)
                }
                sections += effectSections
            }
            if image.effects.isEmpty { section(.effects, "Effects", [.init(.count, "0")]) }
        case .rain(let layer):
            let r = layer.rain
            section(
                .rain, EditorText.effectRain.text,
                [
                    .init(.visible, String(layer.visible)),
                    .init(.composition, layer.composition == .additive ? "additive" : "sourceOver"),
                    .init(.regionOrigin, "\(Self.n(layer.region.x)), \(Self.n(layer.region.y))"),
                    .init(
                        .regionSize,
                        "\(Self.n(layer.region.width)) × \(Self.n(layer.region.height))"
                    ),
                    .init(.direction, "\(Self.n(r.direction))°"), .init(.speed, Self.n(r.speed)),
                    .init(.density, Self.n(r.density)), .init(.length, Self.n(r.length)),
                    .init(.width, Self.n(r.width)), .init(.opacityMin, Self.n(r.opacity.min)),
                    .init(.opacityMax, Self.n(r.opacity.max)), .init(.seed, String(r.seed)),
                ])
        case .trail(let layer):
            let t = layer.configuration
            section(
                .trail, EditorText.effectTrail.text,
                [
                    .init(.visible, String(layer.visible)), .init(.colorMode, t.colorMode.rawValue),
                    .init(.width, Self.n(t.width)), .init(.lifetime, String(t.lifetime)),
                    .init(.emissionS, String(t.emissionRate)), .init(.fadeIn, String(t.fadeIn)),
                    .init(.fadeOut, String(t.fadeOut)), .init(.opacity, Self.n(t.opacity)),
                    .init(.edgeSoftness, Self.n(t.edgeSoftness)),
                    .init(.curveSmoothing, Self.n(t.curveSmoothing)), .init(.seed, String(t.seed)),
                ]
                    + t.colors.enumerated().map {
                        .init(
                            .color($0.offset + 1),
                            "\(Self.n($0.element.r)), \(Self.n($0.element.g)), \(Self.n($0.element.b))"
                        )
                    })
        }
        for index in sections.indices {
            let paths = sections[index].assetPaths
            for path in paths {
                let owners = state.workingModel.layers.enumerated().compactMap {
                    l, node -> String? in
                    guard case .image(let image) = node.content else { return nil }
                    if image.asset == path
                        || image.effects.contains(where: {
                            $0.maskPath == path || $0.fieldDefinition?.asset.value == path
                        })
                    {
                        return layerNames[l]
                    }
                    return nil
                }
                sections[index].entries.append(.init(.usedBy, owners.joined(separator: "; ")))
            }
        }
        return sections
    }
    private static func n(_ value: Float) -> String { String(value) }
    private static func pair(_ values: [Float]) -> String { values.map(n).joined(separator: ", ") }
    private static func assetRows(_ path: String, _ definition: WSSNativeImageDefinition?)
        -> [WSSInspectionRow]
    {
        var rows: [WSSInspectionRow] = [.init(.asset, path)]
        guard let d = definition else {
            return rows + [.init(.contract, "PNG · standard native sampling")]
        }
        rows += [
            .init(.encoding, d.encoding), .init(.dimensions, "\(d.width) × \(d.height)"),
            .init(.uvScale, pair(d.uvScale)), .init(.filter, d.filter), .init(.edge, d.edge),
            .init(.mipmapped, String(d.mipmapped)),
        ]
        return rows
    }
    private static func fieldRows(_ id: WSSAssetID) -> [WSSInspectionRow] {
        [
            .init(.fieldAsset, id.value),
            .init(
                .fieldFormat,
                id.value.hasSuffix(".wssvf") ? "wss-vector-field-f16 · v1" : "wss-flow-rgba8 · v1"
            ),
        ]
    }
    private static func effectSections(
        _ effect: WSSImageEffect, index: Int,
        masks: [WSSNativeImageDefinition]
    ) -> [WSSInspectionSection] {
        var sections: [WSSInspectionSection] = []
        func add(
            _ name: String, _ rows: [WSSInspectionRow], kind: WSSInspectionSection.Kind = .effect
        ) {
            sections.append(
                WSSInspectionSection(
                    kind: kind,
                    title: EditorText.effectHeading(index: index, name: name),
                    entries: rows))
        }
        func mask(_ mask: WSSImageMask?) {
            if let id = mask?.asset {
                sections.append(
                    WSSInspectionSection(
                        kind: .mask,
                        title: EditorText.effectHeading(
                            index: index, name: EditorText.mask.text),
                        entries: assetRows(id.value, masks.first { $0.asset == id.value })))
            } else {
                add(EditorText.mask.text, [.init(.coverage, "Full · no mask")], kind: .mask)
            }
        }
        switch effect {
        case .ripple(let r):
            add(
                EditorText.effectRipple.text,
                [
                    .init(.amplitude, n(r.amplitude)), .init(.wavelength, n(r.wavelength)),
                    .init(.stretch, n(r.stretch)), .init(.direction, "\(n(r.direction))°"),
                    .init(.travelSpeed, n(r.travelSpeed)),
                    .init(.evolutionRate, n(r.evolutionRate)),
                    .init(.structureRotation, "\(n(r.structureRotation))°"),
                    .init(.lateralDetail, n(r.lateralDetail)), .init(.seed, String(r.seed)),
                ])
            mask(r.mask)
        case .flow(let f):
            add(
                EditorText.effectFlow.text,
                [
                    .init(.speed, n(f.speed)), .init(.strength, n(f.strength)),
                    .init(.flowEdgeProtection, n(f.edgeProtectionPixels)),
                ] + fieldRows(f.flowMap))
        case .clouds(let c):
            var rows: [WSSInspectionRow] = [
                .init(.primaryVelocity, pair([c.velocity.x, c.velocity.y])),
                .init(.primaryScale, n(c.scale)),
                .init(.intensity, n(c.intensity)), .init(.density, n(c.density)),
                .init(.seed, String(c.seed)),
                .init(.secondaryInfluence, n(c.secondaryInfluence)),
                .init(.softness, n(c.softness)),
                .init(.brightness, n(c.brightness)), .init(.shadingAmount, n(c.shadingAmount)),
                .init(.shadingDirection, "\(n(c.shadingDirection))°"),
            ]
            if let field = c.secondaryField {
                rows += [
                    .init(.secondaryVelocity, pair([field.velocity.x, field.velocity.y])),
                    .init(.secondaryScale, n(field.scale)),
                ]
            } else {
                rows += [.init(.secondaryField, "None")]
            }
            add(EditorText.effectClouds.text, rows)
            mask(c.mask)
        }
        return sections
    }
}

// Keep native responder-chain undo while lifecycle sheets temporarily lock editing.
final class WSSEditorUndoManager: UndoManager {
    var hasPendingInteraction: () -> Bool = { false }
    var finishInteraction: () -> Void = {}
    var permitsEditing: () -> Bool = { true }
    override var canUndo: Bool { permitsEditing() && (hasPendingInteraction() || super.canUndo) }
    override var canRedo: Bool { permitsEditing() && super.canRedo }
    override func undo() {
        if permitsEditing() {
            finishInteraction()
            if super.canUndo { super.undo() }
        }
    }
    override func redo() {
        if permitsEditing() {
            finishInteraction()
            if super.canRedo { super.redo() }
        }
    }
}
