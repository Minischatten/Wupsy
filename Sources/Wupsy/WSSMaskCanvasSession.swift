import Foundation
import SwiftUI

struct WSSMaskCanvasGeometry {
    let transform: WSSImageTransform
    let width: Int
    let height: Int
    let uvScale: SIMD2<Float>
    init(transform: WSSImageTransform, bitmap: WSSMaskBitmap) {
        self.init(
            transform: transform, width: bitmap.width, height: bitmap.height,
            uvScale: bitmap.uvScale)
    }
    init(transform: WSSImageTransform, width: Int, height: Int, uvScale: SIMD2<Float> = SIMD2(1, 1))
    {
        self.transform = transform
        self.width = width
        self.height = height
        self.uvScale = uvScale
    }
    func texel(_ scene: SIMD2<Float>) -> SIMD2<Double>? {
        guard let uv = WSSCanvasGeometry.uv(scene, transform: transform),
            uv.x >= 0, uv.x <= 1, uv.y >= 0, uv.y <= 1
        else { return nil }
        let value = WSSCanvasGeometry.texel(
            uv: uv, scale: uvScale,
            dimensions: SIMD2(Float(width), Float(height)))
        return SIMD2(Double(value.x), Double(value.y))
    }
    func scene(_ texel: SIMD2<Double>) -> SIMD2<Float> {
        WSSCanvasGeometry.scenePoint(
            texel: SIMD2(Float(texel.x), Float(texel.y)), scale: uvScale,
            dimensions: SIMD2(Float(width), Float(height)), transform: transform)
    }
    func footprint(center: SIMD2<Float>, diameter: Double) -> [SIMD2<Float>] {
        guard let texel = texel(center) else { return [] }
        return (0..<64).map { index in
            let angle = Double(index) * 2 * .pi / 64
            return scene(texel + SIMD2(cos(angle), sin(angle)) * (diameter / 2))
        }
    }
}

@MainActor final class WSSMaskCanvasSession: ObservableObject {
    struct Loaded {
        let resolved: WSSResolvedMaskTarget
        let bitmap: WSSMaskBitmap
    }
    private final class Stroke {
        var transaction: WSSMaskStrokeTransaction
        let geometry: WSSMaskCanvasGeometry
        init(_ transaction: WSSMaskStrokeTransaction, geometry: WSSMaskCanvasGeometry) {
            self.transaction = transaction
            self.geometry = geometry
        }
    }
    private final class PendingStroke {
        let target: WSSMaskTarget
        let revision: UInt64
        let selectionRevision: UInt64
        let transform: WSSImageTransform
        let diameter: Double
        let opacity: Double
        let erase: Bool
        var points: [SIMD2<Float>]
        var ended = false
        init(
            target: WSSMaskTarget, revision: UInt64, selectionRevision: UInt64,
            transform: WSSImageTransform, diameter: Double, opacity: Double,
            erase: Bool, start: SIMD2<Float>
        ) {
            self.target = target
            self.revision = revision
            self.selectionRevision = selectionRevision
            self.transform = transform
            self.diameter = diameter
            self.opacity = opacity
            self.erase = erase
            points = [start]
        }
    }
    // Only pre-read/pre-create input is buffered. Ready scalar strokes keep streaming.
    static let maximumPendingPoints = 65_536
    private var pendingStroke: PendingStroke?
    private var selectionTarget: WSSMaskTarget?
    private var automaticBrushTarget: WSSMaskTarget?
    private var activationID = UUID()
    private var activationTasks: [UUID: Task<Void, Never>] = [:]
    private weak var document: WSSEditorDocument?
    @Published private(set) var loaded: Loaded?
    @Published private(set) var brushEnabled = false
    @Published private(set) var diameter: Double = 100
    @Published private(set) var opacity: Double = 1
    @Published private(set) var finalizing = false
    @Published private(set) var overlayAvailable = true
    @Published private(set) var error: String?
    private var stroke: Stroke?
    private var loadTask: Task<Void, Never>?
    private var brushActivationTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var token = UUID()
    private var recent: [Loaded] = []
    private func remember(_ value: Loaded) {
        recent.removeAll { $0.resolved.path == value.resolved.path }
        recent.insert(value, at: 0)
        while recent.count > 2
            || recent.reduce(0, { $0 + $1.bitmap.pixels.count }) > 32 * 1024 * 1024
        {
            recent.removeLast()
        }
    }
    var onChange: (() -> Void)?
    var canvasOwner: UUID?
    private(set) var dirtyRegion: CGRect?
    private(set) var displayVersion: UInt64 = 0
    private func changed(_ region: CGRect? = nil) {
        dirtyRegion = region
        displayVersion &+= 1
    }
    var isDrawing: Bool { stroke != nil || (pendingStroke != nil && !finalizing) }
    var blocksDocumentActions: Bool { isDrawing || finalizing }
    var pixels: Data? { stroke?.transaction.pixels ?? loaded?.bitmap.pixels }
    var maximumDiameter: Double {
        if let loaded {
            return WSSMaskBrushSettings.maximumDiameter(
                width: loaded.bitmap.width, height: loaded.bitmap.height)
        }
        // Size controls are already available before a direct effect has a mask.
        // Predict only dimensions with the exact lazy-create rule; never allocate pixels.
        guard let document, let target = document.maskManagementTarget,
            target.slot.supportsDirectPaint,
            let context = try? document.snapshot.maskContext(target)
        else { return 1 }
        if let definition = context.definition {
            return WSSMaskBrushSettings.maximumDiameter(
                width: definition.width, height: definition.height)
        }
        if let effect = context.effectIndex, context.path != nil, document.previewIsCurrent,
            let texture = document.previewResources.effectPlans[context.layerIndex]?.stages
                .first(where: { $0.manifestIndex == effect })?.binding.mask
        {
            return WSSMaskBrushSettings.maximumDiameter(
                width: texture.width, height: texture.height)
        }
        guard let dimensions = try? WSSMaskPreparation.blackMaskDimensions(size: context.size)
        else { return 1 }
        return WSSMaskBrushSettings.maximumDiameter(
            width: dimensions.width, height: dimensions.height)
    }
    var geometry: WSSMaskCanvasGeometry? {
        guard let document else { return nil }
        if let loaded {
            guard let context = try? document.snapshot.maskContext(loaded.resolved.target) else {
                return nil
            }
            return WSSMaskCanvasGeometry(transform: context.transform, bitmap: loaded.bitmap)
        }
        guard let target = document.maskManagementTarget, target.slot.supportsDirectPaint,
            document.selectedMaskTarget == nil,
            let context = try? document.snapshot.maskContext(target),
            let dimensions = try? WSSMaskPreparation.blackMaskDimensions(size: context.size)
        else { return nil }
        return WSSMaskCanvasGeometry(
            transform: context.transform, width: dimensions.width, height: dimensions.height)
    }
    func brushFootprint(at scene: SIMD2<Float>) -> [SIMD2<Float>] {
        guard brushEnabled, let geometry else { return [] }
        var size = diameter
        if document?.maskManagementTarget?.slot.supportsDirectPaint == true {
            guard let canvas = document?.state.workingModel.canvas,
                scene.x.isFinite, scene.y.isFinite,
                (0...Float(canvas.width)).contains(scene.x),
                (0...Float(canvas.height)).contains(scene.y)
            else { return [] }
            size = min(maximumDiameter, max(1, diameter))
        }
        return geometry.footprint(center: scene, diameter: size)
    }
    init(document: WSSEditorDocument) { self.document = document }
    func refresh(selectionChanged: Bool = false) {
        if selectionChanged, pendingStroke != nil { cancelStroke() }
        guard !finalizing else { return }
        if let pendingStroke, !selectionChanged,
            document?.maskManagementTarget == pendingStroke.target
        {
            return
        }
        if selectionChanged {
            brushActivationTask?.cancel()
            cancelStroke()
        }
        let managementTarget = document?.maskManagementTarget
        if selectionChanged || selectionTarget != managementTarget {
            if automaticBrushTarget != nil { brushEnabled = false }
            automaticBrushTarget = nil
            selectionTarget = managementTarget
            if let target = managementTarget, target.slot.supportsDirectPaint {
                automaticBrushTarget = target
                brushEnabled = overlayAvailable
            }
        }
        guard let document, !document.closed, let target = document.selectedMaskTarget,
            let resolved = try? document.resolveMaskTarget(target)
        else {
            token = UUID()
            loadTask?.cancel()
            loadTask = nil
            cancelStroke()
            loaded = nil
            brushEnabled =
                automaticBrushTarget != nil && automaticBrushTarget == managementTarget
                && overlayAvailable
            changed()
            onChange?()
            return
        }
        if loaded?.resolved == resolved {
            onChange?()
            return
        }
        let keepBrush = brushEnabled
        cancelStroke()
        loaded = nil
        loadTask?.cancel()
        let current = UUID()
        token = current
        if let cached = recent.first(where: {
            $0.resolved.path == resolved.path && $0.resolved.fingerprint == resolved.fingerprint
                && $0.resolved.definition == resolved.definition
        }) {
            loaded = Loaded(resolved: resolved, bitmap: cached.bitmap)
            loadTask = nil
            brushEnabled = keepBrush
            diameter = min(maximumDiameter, max(1, diameter))
            remember(loaded!)
            changed()
            onChange?()
            return
        }
        changed()
        onChange?()
        let model = document.state.workingModel
        let handle = document.project.handle
        let assets = document.state.sessionAssets
        let basis = document.state.diskBasis
        loadTask = Task { [weak self] in
            do {
                let bitmap = try await WSSMaskPreparation().read(
                    resolved, model: model, handle: handle, generations: assets, basis: basis)
                guard let self, !Task.isCancelled, token == current,
                    let document = self.document, !document.closed,
                    document.selectedMaskTarget == target,
                    try document.resolveMaskTarget(target) == resolved
                else { return }
                loaded = Loaded(resolved: resolved, bitmap: bitmap)
                remember(loaded!)
                brushEnabled = brushEnabled && overlayAvailable
                diameter = min(maximumDiameter, max(1, diameter))
                if overlayAvailable { error = nil }
                changed()
                onChange?()
            } catch {
                guard let self, !Task.isCancelled, token == current else { return }
                loaded = nil
                brushEnabled = false
                self.error = EditorText.maskLoadError.text
                changed()
                onChange?()
            }
        }
    }
    func waitForLoad() async { await loadTask?.value }
    func waitForFinish() async {
        await waitForBrushActivation()
        await finishTask?.value
    }
    func waitForBrushActivation() async {
        await brushActivationTask?.value
        while !activationTasks.isEmpty {
            for task in Array(activationTasks.values) { await task.value }
        }
    }
    func setBrush(_ enabled: Bool) {
        guard !finalizing, !enabled || overlayAvailable else { return }
        if let target = document?.maskManagementTarget, target.slot == .rain {
            automaticBrushTarget = enabled ? target : nil
            cancelStroke()
            brushEnabled = enabled && overlayAvailable && document?.interactionLocked == false
            if brushEnabled {
                document?.directionCanvas.setEnabled(false)
                document?.leaveTransformMode()
            }
            onChange?()
            return
        }
        automaticBrushTarget = nil
        if enabled, loaded == nil, let document,
            let target = document.maskManagementTarget
        {
            guard brushActivationTask == nil else { return }
            let id = UUID()
            activationID = id
            brushActivationTask = Task { [weak self, weak document] in
                guard let self, let document else { return }
                defer {
                    activationTasks[id] = nil
                    if activationID == id { brushActivationTask = nil }
                }
                do {
                    if document.selectedMaskTarget == nil { try await document.manageMask(.create) }
                    guard !Task.isCancelled, document.maskManagementTarget == target else { return }
                    await waitForLoad()
                    guard !Task.isCancelled, document.maskManagementTarget == target,
                        loaded?.resolved.target == target
                    else { return }
                    setBrush(true)
                } catch {
                    if !document.closed && !Task.isCancelled {
                        self.error =
                            EditorText.maskCreateError.format(
                                EditorErrorPresentation.message(error))
                        onChange?()
                    }
                }
            }
            activationTasks[id] = brushActivationTask
            return
        }
        if !enabled { brushActivationTask?.cancel() }
        cancelStroke()
        brushEnabled =
            enabled && overlayAvailable && loaded != nil && document?.interactionLocked == false
        if brushEnabled {
            document?.directionCanvas.setEnabled(false)
            document?.leaveTransformMode()
        }
        onChange?()
    }
    func setDiameter(_ value: Double) {
        guard value.isFinite, !blocksDocumentActions else { return }
        diameter = min(maximumDiameter, max(1, value))
        onChange?()
    }
    func setOpacity(_ value: Double) {
        guard value.isFinite, !blocksDocumentActions else { return }
        opacity = min(1, max(0, value))
        onChange?()
    }
    @discardableResult
    func begin(_ scene: SIMD2<Float>, erase: Bool) -> Bool {
        if loaded == nil, automaticBrushTarget != nil {
            return beginPending(scene, erase: erase)
        }
        guard brushEnabled, overlayAvailable, !blocksDocumentActions, let document,
            !document.closed, !document.interactionLocked, !document.saveAsBusy,
            !document.saving, !document.importingImage, document.finishEditing(),
            let loaded, document.selectedMaskTarget == loaded.resolved.target,
            (try? document.resolveMaskTarget(loaded.resolved.target)) == loaded.resolved,
            let geometry, let point = geometry.texel(scene)
        else { return false }
        do {
            let value = try WSSMaskStrokeTransaction(
                resolved: loaded.resolved, revision: document.state.workingRevision,
                bitmap: loaded.bitmap,
                settings: .init(
                    diameter: diameter, opacity: opacity, mode: erase ? .erase : .paint),
                start: point)
            objectWillChange.send()
            document.objectWillChange.send()
            stroke = Stroke(value, geometry: geometry)
            if let region = value.dirtyRegion { changed(region) }
            onChange?()
            return true
        } catch { return false }
    }
    func ownsSourcePreparation(_ target: WSSMaskTarget, revision: UInt64) -> Bool {
        guard let pendingStroke, let document else { return false }
        return pendingStroke.target == target && pendingStroke.revision == revision
            && pendingStroke.selectionRevision == document.selectionRevision
            && document.maskManagementTarget == target
    }
    private func beginPending(_ scene: SIMD2<Float>, erase: Bool) -> Bool {
        guard brushEnabled, overlayAvailable, !blocksDocumentActions,
            let document, !document.closed, !document.interactionLocked,
            !document.saveAsBusy, !document.saving, !document.importingImage,
            document.finishEditing(), let target = document.maskManagementTarget,
            !(erase && target.slot == .rain && document.selectedMaskTarget == nil),
            target == automaticBrushTarget, target.slot.supportsDirectPaint,
            let context = try? document.snapshot.maskContext(target),
            let uv = WSSCanvasGeometry.uv(scene, transform: context.transform),
            (0...1).contains(uv.x), (0...1).contains(uv.y)
        else { return false }
        let capture = PendingStroke(
            target: target, revision: document.state.workingRevision,
            selectionRevision: document.selectionRevision, transform: context.transform,
            diameter: diameter, opacity: opacity, erase: erase, start: scene)
        pendingStroke = capture
        document.objectWillChange.send()
        let id = UUID()
        activationID = id
        brushActivationTask?.cancel()
        brushActivationTask = Task { [weak self, weak document] in
            guard let self, let document else { return }
            defer {
                activationTasks[id] = nil
                if activationID == id { brushActivationTask = nil }
            }
            do {
                if document.selectedMaskTarget == nil {
                    try await document.manageMask(.create, capturedInput: true)
                } else {
                    await loadTask?.value
                }
                try Task.checkCancellation()
                guard pendingStroke === capture, !document.closed else { return }
                guard document.maskManagementTarget == capture.target,
                    document.selectionRevision == capture.selectionRevision
                else { throw WSSMaskError.stale }
                let resolved = try document.resolveMaskTarget(capture.target)
                let revision = document.state.workingRevision
                let bitmap: WSSMaskBitmap
                if let loaded, loaded.resolved == resolved {
                    bitmap = loaded.bitmap
                } else {
                    bitmap = try await WSSMaskPreparation().read(
                        resolved,
                        model: document.state.workingModel, handle: document.project.handle,
                        generations: document.state.sessionAssets, basis: document.state.diskBasis)
                }
                try Task.checkCancellation()
                guard pendingStroke === capture, !document.closed else { return }
                guard revision == document.state.workingRevision,
                    capture.selectionRevision == document.selectionRevision,
                    try document.resolveMaskTarget(capture.target) == resolved
                else { throw WSSMaskError.stale }
                let geometry = WSSMaskCanvasGeometry(transform: capture.transform, bitmap: bitmap)
                guard let start = geometry.texel(capture.points[0]) else {
                    throw WSSMaskError.invalid
                }
                var transaction = try WSSMaskStrokeTransaction(
                    resolved: resolved, revision: revision,
                    bitmap: bitmap,
                    settings: .init(
                        diameter: min(
                            capture.diameter,
                            WSSMaskBrushSettings.maximumDiameter(
                                width: bitmap.width, height: bitmap.height)),
                        opacity: capture.opacity, mode: capture.erase ? .erase : .paint),
                    start: start)
                for scene in capture.points.dropFirst() {
                    if let point = geometry.texel(scene) {
                        try transaction.append(point)
                    } else {
                        try transaction.breakSegment()
                    }
                }
                loaded = Loaded(resolved: resolved, bitmap: bitmap)
                remember(loaded!)
                pendingStroke = nil
                stroke = Stroke(transaction, geometry: geometry)
                finalizing = false
                changed(transaction.dirtyRegion)
                onChange?()
                if capture.ended { finish(capture.points.last!) }
            } catch {
                guard pendingStroke === capture else { return }
                cancelStroke()
                if !document.closed {
                    self.error = EditorText.maskStrokeError.text
                    onChange?()
                }
            }
        }
        activationTasks[id] = brushActivationTask
        onChange?()
        return true
    }
    func append(_ scene: SIMD2<Float>) {
        if let pendingStroke {
            guard let document, document.maskManagementTarget == pendingStroke.target,
                document.selectionRevision == pendingStroke.selectionRevision,
                scene.x.isFinite, scene.y.isFinite,
                pendingStroke.points.count < Self.maximumPendingPoints
            else {
                cancelStroke()
                error = EditorText.maskStrokeError.text
                return
            }
            pendingStroke.points.append(scene)
            return
        }
        guard let stroke else { return }
        do {
            if let point = stroke.geometry.texel(scene) {
                try stroke.transaction.append(point)
            } else {
                try stroke.transaction.breakSegment()
            }
            if let region = stroke.transaction.dirtyRegion { changed(region) }
            onChange?()
        } catch { cancelStroke() }
    }
    func finish(_ scene: SIMD2<Float>) {
        if let capture = pendingStroke {
            append(scene)
            guard pendingStroke === capture else { return }
            capture.ended = true
            finalizing = true
            document?.objectWillChange.send()
            onChange?()
            return
        }
        guard let stroke, let document else { return }
        append(scene)
        do {
            let candidate = try stroke.transaction.finish()
            if let region = stroke.transaction.dirtyRegion { changed(region) }
            self.stroke = nil
            objectWillChange.send()
            document.objectWillChange.send()
            guard let candidate else {
                changed()
                onChange?()
                return
            }
            // Keep the final transient pixels visible until the validated generation is adopted.
            loaded = Loaded(resolved: candidate.resolved, bitmap: candidate.result)
            finalizing = true
            document.interactionLocked = true
            onChange?()
            finishTask = Task { [weak self, weak document] in
                guard let self, let document else { return }
                do {
                    try await document.applyMaskStroke(candidate, inputAlreadyFinished: true)
                    if let resolved = try? document.resolveMaskTarget(candidate.resolved.target) {
                        remember(Loaded(resolved: resolved, bitmap: candidate.result))
                    }
                } catch {
                    self.error =
                        EditorText.maskStrokeError.text
                    await document.presentMessage?(EditorText.maskStrokeTitle.text, self.error!)
                }
                document.interactionLocked = false
                finalizing = false
                document.objectWillChange.send()
                loaded = nil
                refresh()
            }
        } catch { cancelStroke() }
    }
    func cancelStroke() {
        guard stroke != nil || pendingStroke != nil else { return }
        objectWillChange.send()
        document?.objectWillChange.send()
        if pendingStroke != nil {
            pendingStroke = nil
            brushActivationTask?.cancel()
            brushActivationTask = nil
            activationID = UUID()
            finalizing = false
        }
        stroke?.transaction.cancel()
        self.stroke = nil
        changed()
        onChange?()
    }
    @discardableResult func escape() -> Bool {
        if isDrawing {
            cancelStroke()
            return true
        }
        if brushEnabled && !finalizing {
            setBrush(false)
            return true
        }
        return false
    }
    func overlayFailed() {
        guard overlayAvailable else { return }
        cancelStroke()
        overlayAvailable = false
        brushEnabled = false
        error = EditorText.maskOverlayError.text
        changed()
        onChange?()
    }
    func shutdown() {
        for task in activationTasks.values { task.cancel() }
        token = UUID()
        loadTask?.cancel()
        finishTask?.cancel()
        brushActivationTask?.cancel()
        cancelStroke()
        loaded = nil
        recent.removeAll()
        brushEnabled = false
        document = nil
        canvasOwner = nil
        onChange = nil
    }
}
