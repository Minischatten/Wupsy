import Foundation

// Typed, session-local identity for native List moves. No pasteboard serialization.
struct WSSStructureDragPayload: Equatable {
    enum Kind: String { case layer, effect }
    let session: UUID
    let kind: Kind
    let layer: UUID
    let effect: UUID?
    init(session: UUID, source: WSSEditorSelection) {
        self.session = session
        layer = source.layer.rawValue
        switch source {
        case .layer:
            kind = .layer
            effect = nil
        case .effect(_, let id):
            kind = .effect
            effect = id.rawValue
        }
    }

}

struct WSSStructureDropTarget: Equatable {
    let row: WSSEditorSelection
    let after: Bool
}

extension WSSEditorDocument {
    func structureDragSource(_ payload: WSSStructureDragPayload) -> WSSEditorSelection? {
        guard permitsStructureEditing, payload.session == state.sessionID,
            let layer = identity.layers.first(where: { $0.id.rawValue == payload.layer })
        else { return nil }
        switch payload.kind {
        case .layer:
            return payload.effect == nil ? .layer(layer.id) : nil
        case .effect:
            guard let effect = layer.effects.first(where: { $0.rawValue == payload.effect }),
                identity.checkedAddress(in: state.workingModel, layer: layer.id, effect: effect)
                    != nil
            else { return nil }
            return .effect(layer.id, effect)
        }
    }
    func beginStructureDrag(_ source: WSSEditorSelection) -> WSSStructureDragPayload? {
        let payload = WSSStructureDragPayload(session: state.sessionID, source: source)
        guard structureDragSource(payload) == source, finishEditing() else { return nil }
        select(source)
        return selection == source ? payload : nil
    }
    // Convert a before/after insertion boundary to the final index AFTER removal.
    func structureDropDestination(
        _ payload: WSSStructureDragPayload, target: WSSStructureDropTarget
    ) -> Int? {
        guard let source = structureDragSource(payload) else { return nil }
        let from: Int
        let targetIndex: Int
        switch (source, target.row) {
        case (.layer(let sourceLayer), .layer(let targetLayer)):
            guard identity.layers.count == state.workingModel.layers.count,
                let a = identity.layers.firstIndex(where: { $0.id == sourceLayer }),
                let b = identity.layers.firstIndex(where: { $0.id == targetLayer })
            else { return nil }
            from = a
            targetIndex = b
        case (
            .effect(let sourceLayer, let sourceEffect), .effect(let targetLayer, let targetEffect)
        ):
            guard sourceLayer == targetLayer,
                let a = identity.checkedAddress(
                    in: state.workingModel, layer: sourceLayer, effect: sourceEffect),
                let b = identity.checkedAddress(
                    in: state.workingModel, layer: targetLayer, effect: targetEffect)
            else { return nil }
            from = a.effectIndex
            targetIndex = b.effectIndex
        default: return nil
        }
        let boundary = targetIndex + (target.after ? 1 : 0)
        return boundary - (from < boundary ? 1 : 0)
    }
    @discardableResult func performStructureDrop(
        _ payload: WSSStructureDragPayload, target: WSSStructureDropTarget
    ) throws -> Bool {
        guard let destination = structureDropDestination(payload, target: target),
            let source = structureDragSource(payload)
        else { return false }
        switch source {
        case .layer(let layer):
            guard let from = identity.layers.firstIndex(where: { $0.id == layer }) else {
                return false
            }
            if from == destination { return true }
            select(source)
            guard selection == source else { return false }
            try moveLayer(layer, to: destination)
        case .effect(let layer, let effect):
            guard let from = identity.address(layer, effect: effect)?.effectIndex else {
                return false
            }
            if from == destination { return true }
            select(source)
            guard selection == source else { return false }
            try moveEffect(layer, effect: effect, to: destination)
        }
        return true
    }
    // onMove offsets belong to this exact rendered ForEach snapshot. Resolve its
    // stable IDs first; never use an offset against the current model array.
    @discardableResult func moveStructureRows(
        _ sources: IndexSet, to boundary: Int, rows: [WSSEditorStructureRow], session: UUID
    ) throws -> Bool {
        guard session == state.sessionID, sources.count == 1, let source = sources.first,
            rows.indices.contains(source), (0...rows.count).contains(boundary)
        else { return false }
        let payload = WSSStructureDragPayload(session: session, source: rows[source].id)
        let target: WSSStructureDropTarget
        switch rows[source].id {
        case .layer:
            if boundary == rows.count {
                guard let last = rows.last(where: { $0.depth == 0 }) else { return false }
                target = .init(row: last.id, after: true)
            } else {
                guard case .layer = rows[boundary].id else { return false }
                target = .init(row: rows[boundary].id, after: false)
            }
        case .effect(let layer, _):
            guard let start = rows.firstIndex(where: { $0.id == .layer(layer) }) else {
                return false
            }
            let end = rows[(start + 1)...].firstIndex(where: { $0.depth == 0 }) ?? rows.endIndex
            guard boundary > start, boundary <= end else { return false }
            if boundary == end {
                target = .init(row: rows[end - 1].id, after: true)
            } else {
                guard case .effect(let owner, _) = rows[boundary].id, owner == layer else {
                    return false
                }
                target = .init(row: rows[boundary].id, after: false)
            }
        }
        return try performStructureDrop(payload, target: target)
    }
}
