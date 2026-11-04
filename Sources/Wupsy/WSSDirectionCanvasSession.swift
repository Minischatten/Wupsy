import Foundation
import SwiftUI

// Only the actual pointer lifecycle is shared. Scalar and vector paint math stay separate.
@MainActor protocol WSSCanvasPaintInteraction: AnyObject {
    var brushEnabled: Bool { get }
    var isDrawing: Bool { get }
    var blocksDocumentActions: Bool { get }
    @discardableResult func begin(_ scene: SIMD2<Float>, erase: Bool) -> Bool
    func append(_ scene: SIMD2<Float>)
    func finish(_ scene: SIMD2<Float>)
    func cancelStroke()
}
extension WSSMaskCanvasSession: WSSCanvasPaintInteraction {}

struct WSSDirectionCanvasGeometry {
    let transform: WSSImageTransform
    var imageSize: SIMD2<Double> {
        SIMD2(Double(transform.localSize.x), Double(transform.localSize.y))
    }
    func uv(_ scene: SIMD2<Float>) -> SIMD2<Double>? {
        guard let uv = unboundedUV(scene), Self.contains(uv)
        else { return nil }
        return uv
    }
    func unboundedUV(_ scene: SIMD2<Float>) -> SIMD2<Double>? {
        guard let uv = WSSCanvasGeometry.uv(scene, transform: transform),
            uv.x.isFinite, uv.y.isFinite
        else { return nil }
        // Field UV covers the whole local quad; never use the image asset's uvScale.
        return SIMD2(Double(uv.x), Double(uv.y))
    }
    static func contains(_ uv: SIMD2<Double>) -> Bool {
        (0...1).contains(uv.x) && (0...1).contains(uv.y)
    }
    // Liang–Barsky: intersect the segment's parameter interval with the four UV half-planes.
    static func clip(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> (SIMD2<Double>, SIMD2<Double>)? {
        guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { return nil }
        let delta = b - a
        var low = 0.0
        var high = 1.0
        for axis in 0..<2 {
            if delta[axis] == 0 {
                guard (0...1).contains(a[axis]) else { return nil }
            } else {
                let t0 = -a[axis] / delta[axis]
                let t1 = (1 - a[axis]) / delta[axis]
                low = max(low, min(t0, t1))
                high = min(high, max(t0, t1))
                guard low <= high else { return nil }
            }
        }
        // Only snap roundoff of the computed intersection; never clamp raw pointer positions.
        func intersection(_ t: Double) -> SIMD2<Double> {
            if t == 0 { return a }
            if t == 1 { return b }
            let value = a + delta * t
            return SIMD2(min(1, max(0, value.x)), min(1, max(0, value.y)))
        }
        return (intersection(low), intersection(high))
    }
    func scene(_ uv: SIMD2<Double>) -> SIMD2<Float> {
        transform.point(SIMD2(Float(uv.x) - 0.5, 0.5 - Float(uv.y)))
    }
    func sceneVector(_ vector: SIMD2<Float>) -> SIMD2<Float> {
        transform.axisX * (vector.x / transform.localSize.x)
            - transform.axisY * (vector.y / transform.localSize.y)
    }
    func footprint(_ uv: SIMD2<Double>, diameter: Double) -> [SIMD2<Float>] {
        (0..<64).map {
            let angle = Double($0) * 2 * .pi / 64
            return scene(uv + SIMD2(cos(angle), sin(angle)) * (diameter / 2) / imageSize)
        }
    }
}

struct WSSDirectionSample: Equatable {
    let uv: SIMD2<Double>
    let vector: SIMD2<Float>
    let coverage: Float
}
enum WSSDirectionSampling {
    static let maximumSamples = 4096
    static func samples(
        _ field: WSSVectorFieldAsset, at queries: [SIMD2<Double>], region: WSSFlowRegion? = nil
    )
        -> [WSSDirectionSample]
    {
        // Fields have already passed the native loader/paint validation. Read only four taps per arrow.
        field.vectors.withUnsafeBytes { raw in
            queries.prefix(maximumSamples).compactMap { uv in
                if let region {
                    let x = min(region.width - 1, max(0, Int(uv.x * Double(region.width))))
                    let y = min(region.height - 1, max(0, Int(uv.y * Double(region.height))))
                    guard region.pixels[y * region.width + x] == 255 else { return nil }
                }
                let p =
                    uv * SIMD2(Double(field.width), Double(field.height)) - SIMD2(repeating: 0.5)
                let xx = Int(floor(p.x))
                let yy = Int(floor(p.y))
                let fx = Float(p.x - Double(xx))
                let fy = Float(p.y - Double(yy))
                func tap(_ x: Int, _ y: Int) -> SIMD3<Float> {
                    let index =
                        max(0, min(field.height - 1, y)) * field.width
                        + max(0, min(field.width - 1, x))
                    func component(_ axis: Int) -> Float {
                        Float(
                            Float16(
                                bitPattern: UInt16(
                                    littleEndian: raw.loadUnaligned(
                                        fromByteOffset: index * 4 + axis * 2, as: UInt16.self))))
                    }
                    return SIMD3(
                        component(0), component(1), Float(field.coverage?[index] ?? 255) / 255)
                }
                let a = tap(xx, yy) * (1 - fx) + tap(xx + 1, yy) * fx
                let b = tap(xx, yy + 1) * (1 - fx) + tap(xx + 1, yy + 1) * fx
                let value = a * (1 - fy) + b * fy
                return WSSDirectionSample(
                    uv: uv, vector: SIMD2(value.x, value.y), coverage: value.z)
            }
        }
    }
}

struct WSSDirectionPaintState {
    let field: WSSVectorFieldAsset
    let region: WSSFlowRegion?
}
private struct WSSDirectionFeedback {
    let state: WSSDirectionPaintState
    let samples: [WSSDirectionSample]
    let area: WSSDirectionArea
    let flowGlyphs: [WSSDirectionSample]
    let glyphLayout: WSSFlowGlyphLayout?
}
// Internal stage/cause evidence; the localized user-facing message stays unchanged.
struct WSSDirectionPaintFailure: Error {
    enum Stage { case fieldPaint, regionPaint, livePreview, overlay, feedback }
    let stage: Stage
    let cause: Error
    static func at<T>(_ stage: Stage, _ work: () throws -> T) throws -> T {
        do { return try work() } catch { throw Self(stage: stage, cause: error) }
    }
}

private actor WSSDirectionPaintWorker {
    func area(_ field: WSSVectorFieldAsset, region: WSSFlowRegion?, flow: Bool) throws
        -> WSSDirectionArea
    {
        try WSSDirectionArea.make(field, region: region, flowGlyphs: flow)
    }
    func feedback(
        edit: WSSVectorFieldEdit, geometry: WSSDirectionCanvasGeometry,
        points: [SIMD2<Double>], subpathStarts: [Int], brush: WSSVectorBrush,
        queries: [SIMD2<Double>], glyphLayout: WSSFlowGlyphLayout?
    ) throws -> WSSDirectionFeedback {
        let (width, height) = WSSDirectionArea.dimensions(edit.field)
        var touches = [UInt8](repeating: 0, count: width * height)
        let result = try paint(
            edit: edit, geometry: geometry, points: points, subpathStarts: subpathStarts,
            brush: brush,
            visit: { index, weight in
                let target =
                    (index / edit.field.width * height / edit.field.height) * width
                    + (index % edit.field.width * width / edit.field.width)
                touches[target] = max(touches[target], UInt8((weight * 255).rounded()))
            })
        let area = try WSSDirectionPaintFailure.at(.overlay) {
            try WSSDirectionArea.make(
                result.field, region: result.region,
                touches: brush.operation == .erase && result.region != nil ? nil : touches,
                flowGlyphs: edit.resolved.target.slot == .flow)
        }
        return WSSDirectionFeedback(
            state: result,
            samples: WSSDirectionSampling.samples(result.field, at: queries, region: result.region),
            area: area,
            flowGlyphs: WSSFlowGlyphSelection.samples(
                result.field, region: result.region, area: area, layout: glyphLayout),
            glyphLayout: glyphLayout)
    }
    func resample(
        _ feedback: WSSDirectionFeedback, queries: [SIMD2<Double>], glyphLayout: WSSFlowGlyphLayout?
    )
        -> WSSDirectionFeedback
    {
        WSSDirectionFeedback(
            state: feedback.state,
            samples: WSSDirectionSampling.samples(
                feedback.state.field, at: queries, region: feedback.state.region),
            area: feedback.area,
            flowGlyphs: feedback.glyphLayout == glyphLayout
                ? feedback.flowGlyphs
                : WSSFlowGlyphSelection.samples(
                    feedback.state.field, region: feedback.state.region, area: feedback.area,
                    layout: glyphLayout),
            glyphLayout: glyphLayout)
    }
    func paint(
        edit: WSSVectorFieldEdit, geometry: WSSDirectionCanvasGeometry,
        points: [SIMD2<Double>], subpathStarts: [Int], brush: WSSVectorBrush,
        visit: ((Int, Float) -> Void)? = nil
    ) throws -> WSSDirectionPaintState {
        try Task.checkCancellation()
        // Reserve the bounded sparse overlay/query data in addition to the 10B footprint.
        let result = try WSSDirectionPaintFailure.at(.fieldPaint) {
            try WSSVectorFieldPaint.paint(
                edit.field, imageSize: geometry.imageSize,
                uvPoints: points, brush: brush, subpathStarts: subpathStarts,
                workingByteLimit: WSSVectorFieldEditorBudget.workingDataLimit - WSSDirectionSampling
                    .maximumSamples * 64 - WSSDirectionArea.reservedBytes
                    - (edit.region?.pixels.count ?? 0) * 2
                    - edit.field.vectors.count, visit: visit)
        }
        let field: WSSVectorFieldAsset
        switch result {
        case .unchanged: field = edit.field
        case .changed(let value): field = value
        }
        let region = try WSSDirectionPaintFailure.at(.regionPaint) {
            try edit.region?.painted(
                imageSize: geometry.imageSize, points: points, subpaths: subpathStarts,
                brush: brush,
                retainedBytes: edit.field.vectors.count * 2 + field.vectors.count
                    + (field.coverage?.count ?? 0) + WSSDirectionArea.reservedBytes)
        }
        return WSSDirectionPaintState(field: field, region: region)
    }
}

// Keep optional GPU preparation off the CPU-authoring worker's serial queue.
// The session retains at most one active and one latest pending preview request.
private actor WSSDirectionPreviewWorker {
    func make(_ request: WSSDirectionPreviewRequest) throws -> WSSStaticResources {
        try request.resources.previewDirection(at: request.address, state: request.state)
    }
}
private struct WSSDirectionPreviewRequest {
    let strokeID: UUID
    let revision: UInt64
    let state: WSSDirectionPaintState
    let resources: WSSStaticResources
    let address: WSSEffectAddress
}

@MainActor final class WSSDirectionCanvasSession: ObservableObject, WSSCanvasPaintInteraction {
    private final class Stroke {
        let id: UUID
        var edit: WSSVectorFieldEdit?
        let resolved: WSSResolvedVectorFieldTarget
        let geometry: WSSDirectionCanvasGeometry
        let brush: WSSVectorBrush
        var points: [SIMD2<Double>]
        var subpathStarts: [Int] = []
        var lastPointer: SIMD2<Double>
        var revision: UInt64 = 0
        var previewBudgetLimited = false
        var feedbackRevision: UInt64?
        var feedback: WSSDirectionFeedback?
        init(
            id: UUID, edit: WSSVectorFieldEdit?, resolved: WSSResolvedVectorFieldTarget,
            geometry: WSSDirectionCanvasGeometry,
            brush: WSSVectorBrush, pointer: SIMD2<Double>
        ) {
            self.id = id
            self.edit = edit
            self.resolved = resolved
            self.geometry = geometry
            self.brush = brush
            self.points = WSSDirectionCanvasGeometry.contains(pointer) ? [pointer] : []
            self.lastPointer = pointer
        }
    }
    private weak var document: WSSEditorDocument?
    private let worker = WSSDirectionPaintWorker()
    @Published private var explicitBrushEnabled = false
    // Flow editability is a property of selection, never a second user mode.
    var brushEnabled: Bool { (selectionIsFlow && geometry != nil) || explicitBrushEnabled }
    var selectionIsFlow: Bool {
        document?.closed == false && document?.selectedVectorFieldTarget?.slot == .flow
            && document?.directionAvailability != .unavailable
    }
    var requiresExplicitActivation: Bool { !selectionIsFlow }
    @Published private(set) var loaded: WSSVectorFieldEdit?
    private(set) var liveResources: WSSStaticResources?
    @Published private(set) var transientState: WSSDirectionPaintState?
    @Published private(set) var finalizing = false
    @Published private(set) var diameter: Double = 100
    @Published private(set) var magnitude: Float = 1
    @Published private(set) var operation: WSSVectorBrush.Operation = .direction
    @Published private(set) var samples: [WSSDirectionSample] = []
    @Published private(set) var flowGlyphs: [WSSDirectionSample] = []
    private var glyphLayout: WSSFlowGlyphLayout?
    @Published private(set) var area: WSSDirectionArea?
    private var baseArea: WSSDirectionArea?
    @Published private(set) var error: String?
    private(set) var feedbackFailure: WSSDirectionPaintFailure?
    private(set) var livePreviewBudgetLimited = false
    private(set) var livePreviewAttemptCount = 0
    private(set) var feedbackPaintPassCount = 0
    private var queries: [SIMD2<Double>] = []
    private var stroke: Stroke?
    // Pointer capture may precede async decoding. Retain the bounded path through
    // mouse-up; only this exact capture may read its source while actions are locked.
    private var loadingStroke: Stroke?
    private var loadTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private let previewWorker = WSSDirectionPreviewWorker()
    private var previewTask: Task<Void, Never>?
    private var pendingPreview: WSSDirectionPreviewRequest?
    private var finishTask: Task<Void, Never>?
    private var token = UUID()
    var canvasOwner: UUID?
    var onChange: (() -> Void)?
    var isDrawing: Bool { stroke != nil }
    var blocksDocumentActions: Bool { isDrawing || finalizing }
    var pointCount: Int { stroke?.points.count ?? 0 }
    var geometry: WSSDirectionCanvasGeometry? {
        guard let document, let target = document.selectedVectorFieldTarget,
            let address = document.identity.checkedAddress(
                in: document.state.workingModel,
                layer: target.layerID, effect: target.effectID),
            case .image(let image) = document.state.workingModel.layers[address.layerIndex].content,
            image.visible, let transform = try? image.transform.native()
        else { return nil }
        return WSSDirectionCanvasGeometry(transform: transform)
    }
    var maximumDiameter: Double { geometry.map { 2 * max($0.imageSize.x, $0.imageSize.y) } ?? 1 }
    var minimumDiameter: Double { min(1, maximumDiameter) }
    var overlayVisible: Bool { loaded != nil && geometry != nil && wantsOverlay }
    private var wantsOverlay: Bool {
        brushEnabled || document?.selectedVectorFieldTarget?.slot == .flow
    }
    var canvasHelp: String {
        EditorText.directionCanvasHelp(hasRegion: loaded?.region != nil, operation: operation)
    }
    var optionHelp: String {
        (loaded?.region != nil ? EditorText.flowRegionOption : .vectorOption).text
    }
    var dragHelp: String {
        (operation == .neutralize ? EditorText.neutralizeDrag : .directionDrag).text
    }
    init(document: WSSEditorDocument) {
        self.document = document
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        guard !finalizing, let document, !document.closed, !document.interactionLocked else {
            return
        }
        if enabled {
            guard document.directionAvailability != .unavailable else { return }
            guard geometry != nil else {
                error = EditorText.directionLayerHidden.text
                onChange?()
                return
            }
            document.maskCanvas.setBrush(false)
            guard document.finishEditing() else { return }
            document.leaveTransformMode()
            operation = .direction
            error = nil
        }
        cancelStroke()
        token = UUID()
        loadTask?.cancel()
        explicitBrushEnabled = enabled && requiresExplicitActivation
        if !enabled && !wantsOverlay {
            loaded = nil
            samples = []
            flowGlyphs = []
            area = nil
            baseArea = nil
            transientState = nil
            liveResources = nil
            error = nil
        }
        refresh()
        onChange?()
    }
    func setDiameter(_ value: Double) {
        guard value.isFinite, !blocksDocumentActions else { return }
        diameter = min(maximumDiameter, max(minimumDiameter, value))
        onChange?()
    }
    func setMagnitude(_ value: Float) {
        guard value.isFinite, !blocksDocumentActions else { return }
        magnitude = min(1, max(0, value))
        onChange?()
    }
    func setOperation(_ value: WSSVectorBrush.Operation) {
        guard !blocksDocumentActions else { return }
        operation = value
        onChange?()
    }
    func refresh(selectionChanged: Bool = false) {
        if selectionChanged {
            if selectionIsFlow { operation = .direction }
            token = UUID()
            loadTask?.cancel()
            finishTask?.cancel()
            cancelStroke()
            explicitBrushEnabled = false
            loaded = nil
            samples = []
            flowGlyphs = []
            area = nil
            baseArea = nil
            transientState = nil
            liveResources = nil
            onChange?()
        }
        guard !finalizing else { return }
        guard wantsOverlay, let document, !document.closed,
            let target = document.selectedVectorFieldTarget,
            let resolved = try? document.resolveVectorFieldTarget(target), geometry != nil
        else {
            cancelStroke()
            loaded = nil
            samples = []
            flowGlyphs = []
            area = nil
            baseArea = nil
            transientState = nil
            liveResources = nil
            explicitBrushEnabled = false
            onChange?()
            return
        }
        if loaded?.resolved == resolved { return }
        token = UUID()
        let current = token
        let previousLoad = loadTask
        previousLoad?.cancel()
        cancelStroke()
        loaded = nil
        samples = []
        flowGlyphs = []
        area = nil
        baseArea = nil
        transientState = nil
        liveResources = nil
        let previousFeedback = feedbackTask
        loadTask = Task { [weak self, weak document] in
            guard let self, let document else { return }
            defer { if token == current { loadTask = nil } }
            await previousLoad?.value
            await previousFeedback?.value
            guard !Task.isCancelled, token == current, wantsOverlay else { return }
            do {
                let edit = try await document.loadVectorField(
                    target, finishControls: explicitBrushEnabled, capturedInput: true)
                guard !Task.isCancelled, token == current, wantsOverlay,
                    try document.resolveVectorFieldTarget(target) == edit.resolved
                else { return }
                let initialArea = try await worker.area(
                    edit.field, region: edit.region, flow: edit.resolved.target.slot == .flow)
                guard !Task.isCancelled, token == current, wantsOverlay else { return }
                loaded = edit
                if let capture = loadingStroke, capture.resolved == edit.resolved {
                    capture.edit = edit
                    loadingStroke = nil
                }
                baseArea = initialArea
                area = initialArea
                diameter = min(maximumDiameter, max(minimumDiameter, diameter))
                samples = WSSDirectionSampling.samples(edit.field, at: queries, region: edit.region)
                flowGlyphs = WSSFlowGlyphSelection.samples(
                    edit.field, region: edit.region, area: initialArea, layout: glyphLayout)
                onChange?()
            } catch {
                guard !Task.isCancelled, token == current else { return }
                cancelStroke()
                self.error = EditorText.directionLoadError.text
                loaded = nil
                samples = []
                flowGlyphs = []
                area = nil
                baseArea = nil
                transientState = nil
                liveResources = nil
                onChange?()
            }
        }
        onChange?()
    }
    func updateQueries(_ value: [SIMD2<Double>]) {
        let safe = Array(
            value.prefix(WSSDirectionSampling.maximumSamples).filter {
                $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
            })
        guard safe != queries else { return }
        queries = safe
        if isDrawing {
            requestFeedback()
        } else if let loaded {
            samples = WSSDirectionSampling.samples(loaded.field, at: queries, region: loaded.region)
        }
    }
    func updateFlowGlyphLayout(_ layout: WSSFlowGlyphLayout) {
        guard selectionIsFlow, layout != glyphLayout else { return }
        glyphLayout = layout
        if isDrawing {
            requestFeedback()
        } else if let loaded, let area {
            flowGlyphs = WSSFlowGlyphSelection.samples(
                loaded.field, region: loaded.region, area: area, layout: layout)
        }
    }
    @discardableResult func begin(_ scene: SIMD2<Float>, erase: Bool) -> Bool {
        guard brushEnabled, !blocksDocumentActions,
            let document, !document.closed, !document.interactionLocked,
            !document.saving, !document.saveAsBusy, !document.importingImage,
            document.finishEditing(), let geometry,
            let uv = geometry.unboundedUV(scene), let target = document.selectedVectorFieldTarget,
            let resolved = try? document.resolveVectorFieldTarget(target),
            loaded == nil || loaded?.resolved == resolved,
            loaded != nil || loadTask != nil,
            let brush = try? WSSVectorBrush(
                diameter: diameter, magnitude: magnitude,
                operation: erase ? (resolved.regionID == nil ? .neutralize : .erase) : operation)
        else { return false }
        error = nil
        feedbackFailure = nil
        livePreviewBudgetLimited = false
        livePreviewAttemptCount = 0
        feedbackPaintPassCount = 0
        let capture = Stroke(
            id: UUID(), edit: loaded, resolved: resolved, geometry: geometry, brush: brush,
            pointer: uv)
        stroke = capture
        if loaded == nil { loadingStroke = capture }
        document.objectWillChange.send()
        requestFeedback()
        onChange?()
        return true
    }
    func append(_ scene: SIMD2<Float>) {
        guard let stroke else { return }
        guard let document,
            (try? document.resolveVectorFieldTarget(stroke.resolved.target))
                == stroke.resolved
        else {
            cancelStroke()
            error = EditorText.directionTargetChanged.text
            return
        }
        guard let uv = stroke.geometry.unboundedUV(scene) else {
            cancelStroke()
            error = EditorText.directionGeometryError.text
            return
        }
        let previous = stroke.lastPointer
        guard previous != uv else { return }
        stroke.lastPointer = uv
        guard let (entry, exit) = WSSDirectionCanvasGeometry.clip(previous, uv) else { return }
        let connected = WSSDirectionCanvasGeometry.contains(previous) && stroke.points.last == entry
        let added = (connected ? 0 : 1) + (entry == exit ? 0 : 1)
        guard stroke.points.count + added <= WSSVectorFieldPaint.maximumPoints else {
            cancelStroke()
            error = EditorText.directionTooLong.text
            return
        }
        if !connected {
            if !stroke.points.isEmpty { stroke.subpathStarts.append(stroke.points.count) }
            stroke.points.append(entry)
        }
        if entry != exit { stroke.points.append(exit) }
        guard added > 0 else { return }
        stroke.revision &+= 1
        requestFeedback()
        onChange?()
    }
    private func requestFeedback() {
        guard feedbackTask == nil else { return }
        feedbackTask = Task { [weak self] in
            guard let self else { return }
            while let current = stroke, !Task.isCancelled {
                let currentQueries = queries
                let currentLayout = selectionIsFlow ? glyphLayout : nil
                let revision = current.revision
                do {
                    guard let document else { break }
                    if current.edit == nil { await loadTask?.value }
                    guard stroke?.id == current.id, let edit = current.edit else { break }
                    if !document.previewIsCurrent { await document.waitForPreview() }
                    guard document.previewIsCurrent, let address = document.effectAddress else {
                        throw WSSVectorFieldEditError.stale
                    }
                    let value: WSSDirectionFeedback
                    let repainted = current.feedbackRevision != revision || current.feedback == nil
                    if !repainted, let cached = current.feedback {
                        value = await worker.resample(
                            cached, queries: currentQueries, glyphLayout: currentLayout)
                    } else {
                        value = try await worker.feedback(
                            edit: edit, geometry: current.geometry,
                            points: current.points, subpathStarts: current.subpathStarts,
                            brush: current.brush, queries: currentQueries,
                            glyphLayout: currentLayout)
                        feedbackPaintPassCount += 1
                        current.feedbackRevision = revision
                    }
                    current.feedback = value
                    guard let latest = stroke else { break }
                    if latest.id != current.id { continue }
                    guard
                        (try? document.resolveVectorFieldTarget(current.resolved.target))
                            == current.resolved
                    else {
                        cancelStroke()
                        break
                    }
                    // Publish authoring feedback before optional GPU preparation.
                    if repainted {
                        transientState = value.state
                        // Keep the last complete immutable effect preview while the next
                        // one prepares; authoring feedback must not flash back to the base.
                        area = value.area
                        document.objectWillChange.send()
                    }
                    samples = value.samples
                    if current.resolved.target.slot == .flow { flowGlyphs = value.flowGlyphs }
                    onChange?()
                    if repainted, current.resolved.target.slot == .flow,
                        !current.previewBudgetLimited
                    {
                        requestLivePreview(
                            WSSDirectionPreviewRequest(
                                strokeID: current.id, revision: revision, state: value.state,
                                resources: document.previewResources, address: address))
                    }
                    if latest.revision == revision && queries == currentQueries
                        && (selectionIsFlow ? glyphLayout : nil) == currentLayout
                    {
                        break
                    }
                } catch {
                    guard stroke?.id == current.id else { break }
                    feedbackFailure =
                        error as? WSSDirectionPaintFailure
                        ?? WSSDirectionPaintFailure(stage: .feedback, cause: error)
                    cancelStroke()
                    self.error =
                        EditorText.directionComputeError.text
                    onChange?()
                    break
                }
            }
            feedbackTask = nil
        }
    }
    private func requestLivePreview(_ request: WSSDirectionPreviewRequest) {
        pendingPreview = request
        guard previewTask == nil else { return }
        previewTask = Task { [weak self] in
            guard let self else { return }
            defer { previewTask = nil }
            while let request = pendingPreview {
                pendingPreview = nil
                guard let current = stroke, current.id == request.strokeID,
                    !current.previewBudgetLimited, !Task.isCancelled
                else { continue }
                livePreviewAttemptCount += 1
                do {
                    let resources = try await previewWorker.make(request)
                    guard stroke?.id == request.strokeID,
                        stroke?.revision == request.revision, !Task.isCancelled
                    else { continue }
                    liveResources = resources
                    document?.objectWillChange.send()
                    onChange?()
                } catch WSSVectorFieldEditError.budget {
                    guard stroke?.id == request.strokeID else { continue }
                    // Resource dimensions/coverage and base resources are fixed for this
                    // capture. Retry only in the next stroke, never for each new sample.
                    current.previewBudgetLimited = true
                    livePreviewBudgetLimited = true
                    pendingPreview = nil
                } catch {
                    guard stroke?.id == request.strokeID else { continue }
                    feedbackFailure = WSSDirectionPaintFailure(stage: .livePreview, cause: error)
                    cancelStroke()
                    self.error = EditorText.directionComputeError.text
                    onChange?()
                }
            }
        }
    }
    func finish(_ scene: SIMD2<Float>) {
        append(scene)
        guard let current = stroke, let document else { return }
        stroke = nil
        finalizing = true
        document.interactionLocked = true
        document.objectWillChange.send()
        onChange?()
        let feedback = feedbackTask
        finishTask = Task { [weak self, weak document] in
            guard let self, let document else { return }
            defer {
                document.interactionLocked = false
                finalizing = false
                loaded = nil
                transientState = nil
                liveResources = nil
                loadingStroke = nil
                livePreviewBudgetLimited = false
                refresh()
                document.objectWillChange.send()
                onChange?()
            }
            await feedback?.value
            await previewTask?.value
            if current.edit == nil { await loadTask?.value }
            do {
                try Task.checkCancellation()
                guard let edit = current.edit else { throw WSSVectorFieldEditError.stale }
                guard brushEnabled, !document.closed else { throw WSSVectorFieldEditError.stale }
                let value = try await worker.paint(
                    edit: edit, geometry: current.geometry,
                    points: current.points, subpathStarts: current.subpathStarts,
                    brush: current.brush)
                try Task.checkCancellation()
                _ = try await document.replaceVectorField(
                    edit, vectors: value.field.vectors, region: value.region,
                    inputAlreadyFinished: true)
                await document.waitForPreview()
            } catch {
                if !document.closed {
                    self.error =
                        EditorText.directionCommitError.text
                }
            }
        }
    }
    func ownsSourcePreparation(_ resolved: WSSResolvedVectorFieldTarget) -> Bool {
        loadingStroke?.resolved == resolved
    }
    func ownsFinalization(_ resolved: WSSResolvedVectorFieldTarget) -> Bool {
        finalizing && !isDrawing && brushEnabled && loaded?.resolved == resolved
    }
    func cancelStroke() {
        guard stroke != nil else { return }
        stroke = nil
        pendingPreview = nil
        loadingStroke = nil
        livePreviewBudgetLimited = false
        transientState = nil
        liveResources = nil
        area = baseArea
        if let loaded {
            samples = WSSDirectionSampling.samples(loaded.field, at: queries, region: loaded.region)
            if let area {
                flowGlyphs = WSSFlowGlyphSelection.samples(
                    loaded.field, region: loaded.region, area: area, layout: glyphLayout)
            }
        }
        document?.objectWillChange.send()
        onChange?()
    }
    @discardableResult func escape() -> Bool {
        if isDrawing {
            cancelStroke()
            return true
        }
        if requiresExplicitActivation && brushEnabled && !finalizing {
            setEnabled(false)
            return true
        }
        return false
    }
    func waitForLoad() async { await loadTask?.value }
    func waitForAuthoringFeedback() async { await feedbackTask?.value }
    func waitForFeedback() async {
        await feedbackTask?.value
        await previewTask?.value
    }
    func waitForFinish() async { await finishTask?.value }
    func shutdown() {
        token = UUID()
        loadTask?.cancel()
        finishTask?.cancel()
        feedbackTask?.cancel()
        previewTask?.cancel()
        pendingPreview = nil
        cancelStroke()
        explicitBrushEnabled = false
        loaded = nil
        samples = []
        flowGlyphs = []
        area = nil
        baseArea = nil
        transientState = nil
        liveResources = nil
        document = nil
        canvasOwner = nil
        onChange = nil
    }
}

enum WSSDirectionAvailability { case unavailable, legacy, native }
extension WSSEditorDocument {
    var directionAvailability: WSSDirectionAvailability {
        guard let target = selectedVectorFieldTarget,
            let address = identity.checkedAddress(
                in: state.workingModel, layer: target.layerID, effect: target.effectID),
            case .image(let image) = state.workingModel.layers[address.layerIndex].content,
            let field = image.effects[address.effectIndex].fieldDefinition
        else { return .unavailable }
        return field.format == WSSVectorFieldAsset.fileFormat ? .native : .legacy
    }
}
