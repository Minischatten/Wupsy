import Foundation

// Every item is an independent native List row, including effects. IDs come from
// the session identity map, never from the rendered row's index or its title.
struct WSSEditorStructureRow: Identifiable {
    let id: WSSEditorSelection
    let title: String
    let depth: Int
    let symbol: String
}

extension WSSEditorDocument {
    var structureRows: [WSSEditorStructureRow] {
        var rows: [WSSEditorStructureRow] = []
        for (index, layer) in state.workingModel.layers.enumerated() {
            guard identity.layers.indices.contains(index) else { continue }
            let ids = identity.layers[index]
            rows.append(
                WSSEditorStructureRow(
                    id: .layer(ids.id), title: layerNames[index],
                    depth: 0, symbol: workingScene.layers[index].visible ? "eye" : "eye.slash"))
            guard case .image(let image) = layer.content else { continue }
            for (effectIndex, effect) in image.effects.enumerated() {
                guard ids.effects.indices.contains(effectIndex) else { continue }
                let name = effect.native.editorTitle()
                rows.append(
                    WSSEditorStructureRow(
                        id: .effect(ids.id, ids.effects[effectIndex]),
                        title: EditorText.effectOrdinal.format(effectIndex + 1, name), depth: 1,
                        symbol: "fx"))
            }
        }
        return rows
    }

    // Selection and summary dispatch never inspect translated presentation text.
    var inspectorSections: [WSSInspectionSection] {
        WSSInspectionSection.summaries(selectedInspection)
    }

    var selectedInspection: [WSSInspectionSection] {
        WSSInspectionSection.selected(inspection, effectIndex: effectAddress?.effectIndex)
    }
}
