import Foundation
import simd

extension WSSMusicNotesPath {
    enum EditorTemplate: String, CaseIterable {
        case straightPath, ellipsePath

        func makePath(direction: Direction) -> WSSMusicNotesPath {
            switch self {
            case .straightPath:
                return .init(
                    enabled: true, closed: false, direction: direction,
                    anchors: [
                        .init(
                            position: .init(0.15, 0.5), incoming: .init(0.15, 0.5),
                            outgoing: .init(0.38, 0.5)),
                        .init(
                            position: .init(0.85, 0.5), incoming: .init(0.62, 0.5),
                            outgoing: .init(0.85, 0.5)),
                    ])
            case .ellipsePath:
                let k = 4 * (sqrt(2.0) - 1) / 3
                let directions: [SIMD2<Double>] = [
                    .init(1, 0), .init(0, 1), .init(-1, 0), .init(0, -1),
                ]
                let radii = SIMD2(0.35, 0.32)
                let anchors: [Anchor] = directions.map { radial in
                    let point = SIMD2<Double>(repeating: 0.5) + radial * radii
                    let tangent = SIMD2(-radial.y, radial.x) * radii * k
                    return .init(
                        position: point, incoming: point - tangent, outgoing: point + tangent)
                }
                return .init(enabled: true, closed: true, direction: direction, anchors: anchors)
            }
        }
    }

    static var editorDefault: Self { EditorTemplate.straightPath.makePath(direction: .forward) }

    var segmentCount: Int { closed ? anchors.count : anchors.count - 1 }
    var canRemoveAnchor: Bool { anchors.count > Self.minimumAnchors }

    struct EditorSegment {
        let start, outgoing, incoming, end: SIMD2<Double>

        func split(at t: Double) -> (Self, Self) {
            func mix(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> SIMD2<Double> { a + (b - a) * t }
            let a = mix(start, outgoing)
            let b = mix(outgoing, incoming)
            let c = mix(incoming, end)
            let d = mix(a, b)
            let e = mix(b, c)
            let point = mix(d, e)
            return (
                Self(start: start, outgoing: a, incoming: d, end: point),
                Self(start: point, outgoing: e, incoming: c, end: end)
            )
        }

        func point(at t: Double) -> SIMD2<Double> {
            let u = 1 - t
            return start * (u * u * u) + outgoing * (3 * u * u * t)
                + incoming * (3 * u * t * t) + end * (t * t * t)
        }
    }

    func editorSegment(_ index: Int) -> EditorSegment {
        let a = anchors[index]
        let b = anchors[(index + 1) % anchors.count]
        return .init(start: a.position, outgoing: a.outgoing, incoming: b.incoming, end: b.position)
    }

    @discardableResult
    mutating func insertAnchor(in segment: Int, at fraction: Double) throws -> Int {
        guard anchors.count < Self.maximumAnchors, (0..<segmentCount).contains(segment),
            fraction > 0, fraction < 1
        else { throw WSSSceneError.invalid("musicNotes path anchor insertion") }
        let (first, second) = editorSegment(segment).split(at: fraction)
        anchors[segment].outgoing = first.outgoing
        anchors[(segment + 1) % anchors.count].incoming = second.incoming
        anchors.insert(
            .init(position: first.end, incoming: first.incoming, outgoing: second.outgoing),
            at: segment + 1)
        return segment + 1
    }

    mutating func setClosed(_ value: Bool, in region: WSSSceneDocumentV1.Region) throws {
        guard value != closed else { return }
        var candidate = self
        candidate.closed = value
        _ = try candidate.prepare(in: region)
        self = candidate
    }

    enum Handle: Equatable {
        case anchor(Int)
        case incoming(Int)
        case outgoing(Int)

        var index: Int {
            switch self {
            case .anchor(let index), .incoming(let index), .outgoing(let index): return index
            }
        }
    }

    func moving(_ handle: Handle, by delta: SIMD2<Double>) -> Self {
        guard delta.x.isFinite, delta.y.isFinite, anchors.indices.contains(handle.index) else {
            return self
        }
        var result = self
        let index = handle.index
        let original = anchors[index]
        switch handle {
        case .anchor:
            let position = Self.clamp(original.position + delta)
            let displacement = position - original.position
            result.anchors[index] = .init(
                position: position, incoming: Self.clamp(original.incoming + displacement),
                outgoing: Self.clamp(original.outgoing + displacement))
        case .incoming:
            result.anchors[index].incoming = Self.clamp(original.incoming + delta)
        case .outgoing:
            result.anchors[index].outgoing = Self.clamp(original.outgoing + delta)
        }
        guard result.anchors != anchors else { return self }
        // Each draft gets its own preparation so background validation cannot
        // hold the cache lock for the currently displayed curve.
        return Self(enabled: enabled, closed: closed, direction: direction, anchors: result.anchors)
    }

    private static func clamp(_ point: SIMD2<Double>) -> SIMD2<Double> {
        simd_clamp(point, .zero, SIMD2(repeating: 1))
    }
}

extension WSSMusicNotesLayer {
    var hasShortOpenPathFade: Bool {
        guard let path, path.enabled, !path.closed, notes.speed > 0,
            let table = try? path.prepare(in: region)
        else { return false }
        let seconds = table.length / Double(notes.speed) * 0.2
        return seconds < 2 / Double(WSSPreviewRenderPolicy.editor.fps)
    }
}

struct WSSMusicNotesPathGesture {
    let id = UUID()
    let layer: WSSLayerID
    let original: WSSSceneDocumentV1
    let start: WSSMusicNotesPath
    let region: WSSSceneDocumentV1.Region
    let handle: WSSMusicNotesPath.Handle
    var draft: WSSMusicNotesPath
    var lastChecked: WSSMusicNotesPath
}

extension WSSEditorDocument {
    func changeMusicNotesPath(
        _ id: WSSLayerID, name: String, change: (inout WSSMusicNotesPath?) throws -> Void
    ) throws {
        guard permitsStructureEditing, finishEditing(),
            let index = identity.layers.firstIndex(where: { $0.id == id }),
            var layer = musicNotesLayer(id)
        else { return }
        try change(&layer.path)
        var model = state.workingModel
        model.layers[index].content = .musicNotes(layer)
        try mutate(model, name: name)
    }

    func setMusicNotesPathEnabled(_ enabled: Bool, layer id: WSSLayerID) throws {
        try changeMusicNotesPath(id, name: WSSMusicNotesText.text("motionMode")) {
            if enabled && $0 == nil { $0 = .editorDefault }
            $0?.enabled = enabled
        }
    }

    func applyMusicNotesPathTemplate(
        _ template: WSSMusicNotesPath.EditorTemplate, layer id: WSSLayerID
    ) throws {
        try changeMusicNotesPath(id, name: WSSMusicNotesText.text(template.rawValue)) {
            $0 = template.makePath(direction: $0?.direction ?? .forward)
        }
        if musicNotesPathEditLayer == id { musicNotesPathAnchor = nil }
    }

    func beginMusicNotesPathEditing(_ id: WSSLayerID) {
        guard permitsStructureEditing, finishEditing(), selection == .layer(id),
            let layer = musicNotesLayer(id), layer.visible, layer.usesActivePath
        else { return }
        directionCanvas.setEnabled(false)
        maskCanvas.setBrush(false)
        transformModeLayer = nil
        musicNotesPathAnchor = nil
        musicNotesPathEditLayer = id
    }

    func leaveMusicNotesPathEditing(restoreTransform: Bool) {
        finishMusicNotesPathGesture()
        guard let id = musicNotesPathEditLayer else { return }
        musicNotesPathEditLayer = nil
        musicNotesPathAnchor = nil
        if restoreTransform, selection == .layer(id), canTransform(id) { transformModeLayer = id }
    }

    func reconcileMusicNotesPathEditing() {
        guard let id = musicNotesPathEditLayer else { return }
        if selection != .layer(id) || musicNotesLayer(id)?.visible != true
            || musicNotesLayer(id)?.usesActivePath != true
        {
            leaveMusicNotesPathEditing(restoreTransform: true)
        } else if let selected = musicNotesPathAnchor,
            musicNotesLayer(id)?.path?.anchors.indices.contains(selected) != true
        {
            musicNotesPathAnchor = nil
        }
    }

    @discardableResult
    func beginMusicNotesPathGesture(_ handle: WSSMusicNotesPath.Handle) -> Bool {
        guard let id = musicNotesPathEditLayer, permitsStructureEditing,
            let layer = musicNotesLayer(id), let path = layer.path,
            path.anchors.indices.contains(handle.index)
        else { return false }
        finishMusicNotesPathGesture()
        musicNotesPathAnchor = handle.index
        musicNotesPathGesture = .init(
            layer: id, original: state.workingModel, start: path, region: layer.region,
            handle: handle, draft: path, lastChecked: path)
        return true
    }

    func dragMusicNotesPath(by delta: SIMD2<Double>) {
        guard var gesture = musicNotesPathGesture, permitsStructureEditing else { return }
        gesture.draft = gesture.start.moving(gesture.handle, by: delta)
        musicNotesPathGesture = gesture
        guard musicNotesPathPreviewTask == nil, gesture.draft != gesture.lastChecked else { return }
        let token = gesture.id
        musicNotesPathPreviewTask = Task { [weak self] in
            defer {
                if self?.musicNotesPathGesture?.id == token {
                    self?.musicNotesPathPreviewTask = nil
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled, let self,
                    var next = musicNotesPathGesture, next.id == token,
                    next.draft != next.lastChecked
                else { return }
                let candidate = next.draft
                let region = next.region
                next.lastChecked = candidate
                musicNotesPathGesture = next
                let valid = await Task.detached(priority: .userInitiated) {
                    (try? candidate.prepare(in: region)) != nil
                }.value
                guard !Task.isCancelled, musicNotesPathGesture?.id == token else { return }
                if valid { installMusicNotesPathDraft(candidate, layer: next.layer) }
            }
        }
    }

    private func installMusicNotesPathDraft(_ path: WSSMusicNotesPath, layer id: WSSLayerID) {
        guard permitsStructureEditing, musicNotesPathEditLayer == id,
            let index = identity.layers.firstIndex(where: { $0.id == id }),
            var layer = musicNotesLayer(id), layer.path != path
        else { return }
        layer.path = path
        var model = state.workingModel
        model.layers[index].content = .musicNotes(layer)
        installMutation(model, ids: nil, selected: nil)
    }

    @discardableResult
    func finishMusicNotesPathGesture(cancel: Bool = false) -> Bool {
        guard let gesture = musicNotesPathGesture else { return false }
        musicNotesPathPreviewTask?.cancel()
        musicNotesPathPreviewTask = nil
        musicNotesPathGesture = nil
        if cancel {
            if gesture.original != state.workingModel {
                installMutation(gesture.original, ids: nil, selected: nil)
            }
        } else {
            if (try? gesture.draft.prepare(in: gesture.region)) != nil {
                installMusicNotesPathDraft(gesture.draft, layer: gesture.layer)
            }
            if gesture.original != state.workingModel {
                registerModelUndo(gesture.original, name: WSSMusicNotesText.text("editPath"))
            }
        }
        return true
    }

    func insertMusicNotesPathAnchor(segment: Int, fraction: Double) throws {
        guard let id = musicNotesPathEditLayer else { return }
        var inserted: Int?
        try changeMusicNotesPath(id, name: WSSMusicNotesText.text("insertAnchor")) {
            inserted = try $0?.insertAnchor(in: segment, at: fraction)
        }
        if let inserted { musicNotesPathAnchor = inserted }
    }

    func removeMusicNotesPathAnchor() throws {
        guard let id = musicNotesPathEditLayer, let index = musicNotesPathAnchor,
            let path = musicNotesLayer(id)?.path, path.canRemoveAnchor,
            path.anchors.indices.contains(index)
        else { return }
        try changeMusicNotesPath(id, name: WSSMusicNotesText.text("removeAnchor")) {
            _ = $0?.anchors.remove(at: index)
        }
        musicNotesPathAnchor = nil
    }
}
