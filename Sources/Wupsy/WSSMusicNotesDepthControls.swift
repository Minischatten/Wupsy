import SwiftUI

extension WSSEditorDocument {
    func setMusicNotesDepthTarget(_ target: WSSLayerID, for source: WSSLayerID) throws {
        guard permitsStructureEditing, finishEditing(),
            let sourceIndex = identity.layers.firstIndex(where: { $0.id == source }),
            let targetIndex = identity.layers.firstIndex(where: { $0.id == target }),
            var notes = musicNotesLayer(source)
        else { return }
        var model = state.workingModel
        guard case .image(var image) = model.layers[targetIndex].content,
            image.composition == "sourceOver"
        else { return }
        let id = image.depthID ?? UUID()
        image.depthID = id
        model.layers[targetIndex].content = .image(image)
        var depth = notes.depth ?? .init(target: id)
        depth.target = id
        notes.depth = depth
        model.layers[sourceIndex].content = .musicNotes(notes)
        try mutate(model, name: WSSMusicNotesText.text("depthTarget"))
    }
}

struct WSSMusicNotesDepthControls: View {
    @ObservedObject var document: WSSEditorDocument
    let layer: WSSLayerID
    let depth: WSSMusicNotesDepth?
    @State private var error: String?

    private var targets: [(id: WSSLayerID, depthID: UUID?, title: String, visible: Bool)] {
        document.state.workingModel.layers.enumerated().compactMap { index, node in
            guard case .image(let image) = node.content, image.composition == "sourceOver"
            else { return nil }
            let title = node.name ?? URL(fileURLWithPath: image.asset).lastPathComponent
            return (
                document.identity.layers[index].id, image.depthID, "\(index + 1). \(title)",
                image.visible
            )
        }
    }

    var body: some View {
        let options = targets
        let target = depth.flatMap { depth in options.first { $0.depthID == depth.target }?.id }
        VStack(alignment: .leading, spacing: 6) {
            Text(WSSMusicNotesText.text("depthTitle")).wupsyFont(.headline)
            Picker(
                WSSMusicNotesText.text("depthTarget"),
                selection: Binding(
                    get: { target },
                    set: { id in
                        perform {
                            if let id { try document.setMusicNotesDepthTarget(id, for: layer) }
                        }
                    })
            ) {
                Text(WSSMusicNotesText.text("depthChoose")).tag(nil as WSSLayerID?).disabled(true)
                ForEach(options, id: \.id) { option in
                    Text(option.title).tag(option.id as WSSLayerID?)
                }
            }
            .disabled(options.isEmpty)
            if let depth {
                Toggle(
                    WSSMusicNotesText.text("depthEnabled"),
                    isOn: Binding(
                        get: { depth.enabled },
                        set: { value in edit("depthEnabled") { $0.enabled = value } }))
                if depth.enabled {
                    Picker(
                        WSSMusicNotesText.text("depthAppliesTo"),
                        selection: Binding(
                            get: { depth.includesStaff == true },
                            set: { enabled in
                                edit("depthAppliesTo") { $0.includesStaff = enabled ? true : nil }
                            })
                    ) {
                        Text(WSSMusicNotesText.text("depthNotesOnly")).tag(false)
                        Text(WSSMusicNotesText.text("depthNotesAndStaff")).tag(true)
                    }
                    .disabled(
                        document.musicNotesLayer(layer)?.staff?.enabled != true
                            || !options.contains { $0.id == target && $0.visible })
                    if target == nil {
                        Text(WSSMusicNotesText.text("depthUnavailable")).wupsyFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    sidePicker("depthStart", value: depth.start) { side in
                        edit("depthStart") { $0.start = side }
                    }
                    ForEach(depth.changes.indices, id: \.self) { index in
                        changeRow(depth.changes[index], index: index)
                    }
                    Button(WSSMusicNotesText.text("depthAdd")) {
                        edit("depthAdd") { value in
                            let boundaries = [Float(0)] + value.changes.map(\.position) + [100]
                            let intervals = boundaries.indices.dropLast()
                            guard
                                let i = intervals.max(by: {
                                    boundaries[$0 + 1] - boundaries[$0] < boundaries[$1 + 1]
                                        - boundaries[$1]
                                })
                            else { return }
                            let position = (boundaries[i] + boundaries[i + 1]) / 2
                            let side = i == 0 ? value.start : value.changes[i - 1].side
                            value.changes.insert(
                                .init(
                                    position: position, side: side == .inFront ? .behind : .inFront),
                                at: i)
                        }
                    }.disabled(depth.changes.count >= WSSMusicNotesDepth.maximumChanges)
                }
            }
            if let error { Text(error).wupsyFont(.caption).foregroundStyle(.red) }
        }
    }

    private func sidePicker(
        _ key: String, value: WSSMusicNotesDepth.Side,
        set: @escaping (WSSMusicNotesDepth.Side) -> Void
    ) -> some View {
        Picker(
            WSSMusicNotesText.text(key),
            selection: Binding(get: { value }, set: set)
        ) {
            ForEach(WSSMusicNotesDepth.Side.allCases, id: \.self) { side in
                Text(WSSMusicNotesText.text(side.rawValue)).tag(side)
            }
        }
    }

    private func changeRow(_ change: WSSMusicNotesDepth.Change, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(WSSMusicNotesText.text("depthPosition")).wupsyFont(.caption)
                Spacer()
                WSSParameterTextField(
                    value: change.position, range: 0...100,
                    title: WSSMusicNotesText.text("depthPosition"),
                    maximumFractionDigits: 3
                ) { position in
                    try document.changeMusicNotesPlacement(
                        layer, name: WSSMusicNotesText.text("depthPosition")
                    ) {
                        guard $0.depth?.changes.indices.contains(index) == true else { return }
                        $0.depth?.changes[index].position = position
                    }
                }.wupsyControlFrame(width: 76)
            }
            sidePicker("depthSection", value: change.side) { side in
                edit("depthSection") {
                    if $0.changes.indices.contains(index) { $0.changes[index].side = side }
                }
            }
            Button(WSSMusicNotesText.text("depthRemove")) {
                edit("depthRemove") {
                    if $0.changes.indices.contains(index) { $0.changes.remove(at: index) }
                }
            }
        }
    }

    private func edit(_ key: String, _ change: (inout WSSMusicNotesDepth) -> Void) {
        perform {
            guard document.finishEditing() else { return }
            try document.changeMusicNotesPlacement(layer, name: WSSMusicNotesText.text(key)) {
                guard var depth = $0.depth else { return }
                change(&depth)
                $0.depth = depth
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch { self.error = EditorErrorPresentation.message(error) }
    }
}
