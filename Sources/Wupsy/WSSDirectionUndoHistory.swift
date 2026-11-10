import Foundation

// Each native Undo action has its own target. Directional trimming removes an
// oldest contiguous document-history prefix; another UndoManager is never changed.
@MainActor final class WSSModelUndoEntry {
    let resources: [String: WSSImageGeneration]
    let directional: Bool
    let redo: Bool
    var consumed = false
    init(resources: [String: WSSImageGeneration], directional: Bool, redo: Bool) {
        self.resources = resources
        self.directional = directional
        self.redo = redo
    }
}

@MainActor final class WSSDirectionUndoHistory {
    static let maximumSteps = 100
    private struct Reference {
        weak var entry: WSSModelUndoEntry?
    }
    private var entries: [Reference] = []
    var live: [WSSModelUndoEntry] {
        entries = entries.filter { $0.entry.map { !$0.consumed } ?? false }
        return entries.compactMap(\.entry)
    }
    var undoDepth: Int { live.filter { $0.directional && !$0.redo }.count }
    func track(_ entry: WSSModelUndoEntry) { entries.append(Reference(entry: entry)) }

    // Compute a prospective retained set without mutating NSUndoManager. The new
    // action will discard Redo normally. A cut ends at an oldest directional
    // action. Earlier parameter snapshots must go with it: keeping those full
    // models would allow Undo to resurrect skipped field states and pin their bytes.
    func plan(
        assets: [String: WSSImageGeneration], protectedPaths: Set<String>,
        additionalBytes: Int
    ) throws -> Set<ObjectIdentifier> {
        let actions = live
        let undo = actions.filter { !$0.redo }
        let eligible = undo.indices.filter { undo[$0].directional }
        var removed: Set<ObjectIdentifier> = []
        var index = 0
        func remaining() -> [String: WSSImageGeneration] {
            var required = protectedPaths
            for action in actions where !action.redo && !removed.contains(ObjectIdentifier(action))
            {
                required.formUnion(action.resources.keys)
            }
            // PNGs keep the existing image importer ownership policy.
            return assets.filter { $0.value.kind == .png || required.contains($0.key) }
        }
        while eligible.count - index >= Self.maximumSteps
            || additionalBytes
                > WSSVectorFieldEditorBudget.remainingGenerationBytes(assets: remaining())
        {
            guard index < eligible.count else { throw WSSVectorFieldEditError.budget }
            for action in undo.prefix(through: eligible[index]) {
                removed.insert(ObjectIdentifier(action))
            }
            index += 1
        }
        return removed
    }
    func excludedPaths(
        removing: Set<ObjectIdentifier>, protectedPaths: Set<String>
    ) -> Set<String> {
        let actions = live
        var discarded: Set<String> = []
        var required = protectedPaths
        for action in actions {
            if action.redo || removing.contains(ObjectIdentifier(action)) {
                discarded.formUnion(action.resources.keys)
            } else {
                required.formUnion(action.resources.keys)
            }
        }
        return discarded.subtracting(required)
    }
    func commit(_ removed: Set<ObjectIdentifier>, manager: UndoManager) {
        for entry in live where removed.contains(ObjectIdentifier(entry)) {
            entry.consumed = true
            manager.removeAllActions(withTarget: entry)
        }
    }
}
