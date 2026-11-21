import SwiftUI

enum WSSMusicNotesText {
    static var title: String { text("title") }

    static func text(_ key: String) -> String {
        Localization.string(key: "editor.musicNotes." + key)
    }
}

extension WSSEditorDocument {
    func musicNotesLayer(_ id: WSSLayerID) -> WSSMusicNotesLayer? {
        guard let index = identity.layers.firstIndex(where: { $0.id == id }),
            case .musicNotes(let layer) = state.workingModel.layers[index].content
        else { return nil }
        return layer
    }

    func addMusicNotes() throws {
        guard permitsStructureEditing, finishEditing(), permitsStructureEditing else { return }
        try maintenance.withMutation {
            var model = state.workingModel
            guard model.layers.count < 128 else { throw WSSImageImportError.layerLimit }
            let region = WSSSceneDocumentV1.Region(
                x: 0, y: 0, width: Float(model.canvas.width), height: Float(model.canvas.height))
            model.layers.append(.init(content: .musicNotes(.init(region: region))))
            var ids = identity
            let id = WSSLayerID()
            ids.layers.append(.init(id: id, effects: []))
            try mutate(model, name: WSSMusicNotesText.title, ids: ids, selected: .layer(id))
            _ = activateTransformMode(id)
        }
    }

    func resetMusicNotes(_ id: WSSLayerID) throws {
        guard permitsStructureEditing, finishEditing(),
            let index = identity.layers.firstIndex(where: { $0.id == id }),
            var layer = musicNotesLayer(id)
        else { return }
        layer.notes = .init()
        layer.path?.enabled = false
        var model = state.workingModel
        model.layers[index].content = .musicNotes(layer)
        try mutate(model, name: WSSEffectReset.title)
    }

    func changeMusicNotes(
        _ id: WSSLayerID, name: String,
        change: (inout WSSMusicNotesLayer.Configuration) throws -> Void
    ) throws {
        guard permitsStructureEditing, finishParameterInteractions(),
            let index = identity.layers.firstIndex(where: { $0.id == id }),
            case .musicNotes(var layer) = state.workingModel.layers[index].content
        else { return }
        try change(&layer.notes)
        var model = state.workingModel
        model.layers[index].content = .musicNotes(layer)
        try mutate(model, name: name)
    }
}

struct WSSMusicNotesParameterControls: View {
    @ObservedObject var document: WSSEditorDocument
    let layer: WSSLayerID
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(WSSMusicNotesText.title).wupsyFont(.headline)
            if let value = document.musicNotesLayer(layer) {
                let notes = value.notes
                pathControls(value)
                field(
                    "count", value: Float(notes.count),
                    range: 0...Float(WSSMusicNotesLayer.maximumCount), digits: 0
                ) { notes, value in
                    guard value.rounded() == value else {
                        throw WSSSceneError.invalid("musicNotes count")
                    }
                    notes.count = Int(value)
                }
                field("size", value: notes.size, range: WSSMusicNotesLayer.sizeRange) {
                    $0.size = $1
                }
                field("opacity", value: notes.opacity, range: 0...1) { $0.opacity = $1 }
                HStack {
                    let title = WSSMusicNotesText.text("color")
                    Text(title).wupsyFont(.caption)
                    Spacer()
                    WSSNativeSDRColorWell(color: notes.color, title: title) { color in
                        perform {
                            try document.changeMusicNotes(layer, name: title) { $0.color = color }
                        }
                    }.wupsyControlFrame(width: 50, height: 24)
                }
                ForEach(WSSMusicNoteSymbol.allCases, id: \.self) { symbol in
                    let selected = notes.symbols.contains(symbol)
                    let title = WSSMusicNotesText.text(symbol.rawValue)
                    Toggle(
                        title,
                        isOn: Binding(
                            get: { selected },
                            set: { enabled in
                                perform {
                                    guard document.finishEditing() else { return }
                                    try document.changeMusicNotes(layer, name: title) {
                                        if enabled {
                                            if !$0.symbols.contains(symbol) {
                                                $0.symbols.append(symbol)
                                            }
                                        } else {
                                            $0.symbols.removeAll { $0 == symbol }
                                        }
                                    }
                                }
                            })
                    ).disabled(selected && notes.symbols.count == 1)
                }
                if value.path?.enabled != true {
                    let direction = WSSMusicNotesText.text("direction")
                    Text(direction).wupsyFont(.caption)
                    WSSDirectionGrid(
                        angle: Double(notes.direction), currentTitle: direction,
                        identifierPrefix: "wss.musicNotes.direction."
                    ) { arrow in
                        perform {
                            guard document.finishEditing() else { return }
                            try document.changeMusicNotes(layer, name: direction) {
                                $0.direction = Float(arrow.rawValue)
                            }
                        }
                    }
                    field("direction", value: notes.direction, range: 0...360) { $0.direction = $1 }
                }
                WSSMusicNotesSpeedSlider(speed: notes.speed, begin: document.finishEditing) {
                    speed in
                    perform {
                        try document.changeMusicNotes(layer, name: WSSMusicNotesText.text("speed"))
                        {
                            $0.speed = speed
                        }
                    }
                }
                field("speed", value: notes.speed, range: WSSMusicNotesLayer.speedRange) {
                    $0.speed = $1
                }
                toggle("hover", notes: notes, property: \.hover)
                toggle("rotation", notes: notes, property: \.rotation)
                Button(WSSEffectReset.title) { perform { try document.resetMusicNotes(layer) } }
                if let error { Text(error).wupsyFont(.caption).foregroundStyle(.red) }
            }
        }
        .disabled(!document.permitsStructureEditing)
    }

    private func pathControls(_ value: WSSMusicNotesLayer) -> some View {
        let path = value.path
        let enabled = path?.enabled == true
        let editing = document.musicNotesPathEditLayer == layer
        return VStack(alignment: .leading, spacing: 6) {
            Picker(
                WSSMusicNotesText.text("motionMode"),
                selection: Binding(
                    get: { enabled },
                    set: { enabled in
                        perform { try document.setMusicNotesPathEnabled(enabled, layer: layer) }
                    }
                )
            ) {
                Text(WSSMusicNotesText.text("linear")).tag(false)
                Text(WSSMusicNotesText.text("path")).tag(true)
            }.pickerStyle(.segmented)
            if let path, enabled {
                Picker(
                    WSSMusicNotesText.text("pathType"),
                    selection: Binding(
                        get: { path.closed },
                        set: { closed in
                            perform {
                                try document.changeMusicNotesPath(
                                    layer, name: WSSMusicNotesText.text("pathType")
                                ) {
                                    try $0?.setClosed(closed, in: value.region)
                                }
                            }
                        }
                    )
                ) {
                    Text(WSSMusicNotesText.text("open")).tag(false)
                    Text(WSSMusicNotesText.text("closed")).tag(true)
                }.pickerStyle(.segmented)
                Picker(
                    WSSMusicNotesText.text("pathDirection"),
                    selection: Binding(
                        get: { path.direction },
                        set: { direction in
                            perform {
                                try document.changeMusicNotesPath(
                                    layer, name: WSSMusicNotesText.text("pathDirection")
                                ) {
                                    $0?.direction = direction
                                }
                            }
                        }
                    )
                ) {
                    Text(WSSMusicNotesText.text("forward")).tag(WSSMusicNotesPath.Direction.forward)
                    Text(WSSMusicNotesText.text("reverse")).tag(WSSMusicNotesPath.Direction.reverse)
                }.pickerStyle(.segmented)
                Button(WSSMusicNotesText.text(editing ? "finishPath" : "editPath")) {
                    if editing {
                        document.leaveMusicNotesPathEditing(restoreTransform: true)
                    } else {
                        document.beginMusicNotesPathEditing(layer)
                    }
                }.disabled(!value.visible)
                if editing {
                    Text(WSSMusicNotesText.text("pathHelp"))
                        .wupsyFont(size: 14)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if value.hasShortOpenPathFade {
                    Text(WSSMusicNotesText.text("shortPath")).wupsyFont(.caption).foregroundStyle(
                        .secondary)
                }
            }
            if path != nil {
                Button(WSSMusicNotesText.text("deletePath")) {
                    perform {
                        try document.changeMusicNotesPath(
                            layer, name: WSSMusicNotesText.text("deletePath")
                        ) {
                            $0 = nil
                        }
                    }
                }
            }
        }
    }

    private func field(
        _ key: String, value: Float, range: ClosedRange<Float>, digits: Int = 3,
        apply: @escaping (inout WSSMusicNotesLayer.Configuration, Float) throws -> Void
    ) -> some View {
        let title = WSSMusicNotesText.text(key)
        return HStack {
            Text(title).wupsyFont(.caption)
            Spacer()
            WSSParameterTextField(
                value: value, range: range, title: title, maximumFractionDigits: digits
            ) { value in
                try document.changeMusicNotes(layer, name: title) { try apply(&$0, value) }
            }.wupsyControlFrame(width: 100)
        }
    }

    private func toggle(
        _ key: String, notes: WSSMusicNotesLayer.Configuration,
        property: WritableKeyPath<WSSMusicNotesLayer.Configuration, Bool>
    ) -> some View {
        let title = WSSMusicNotesText.text(key)
        return Toggle(
            title,
            isOn: Binding(
                get: { notes[keyPath: property] },
                set: { enabled in
                    perform {
                        guard document.finishEditing() else { return }
                        try document.changeMusicNotes(layer, name: title) {
                            $0[keyPath: property] = enabled
                        }
                    }
                }))
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            if error != nil { error = nil }
        } catch { self.error = EditorErrorPresentation.message(error) }
    }
}

private struct WSSMusicNotesSpeedSlider: View {
    let speed: Float
    let begin: () -> Bool
    let commit: (Float) -> Void
    @State private var dragging = false
    @State private var draft: Double?
    private let logRange = log1p(Double(WSSMusicNotesLayer.speedRange.upperBound) / 0.1)

    var body: some View {
        let position = log1p(Double(speed) / 0.1) / logRange
        let formatted = (draft.map(speed(at:)) ?? speed).formatted(
            .number.precision(.fractionLength(0...3)))
        HStack {
            Slider(
                value: Binding(
                    get: { draft ?? position },
                    set: { value in
                        if dragging {
                            if draft != nil { draft = value }
                        } else if begin() {
                            commit(speed(at: value))
                        }
                    }),
                in: 0...1, step: 0.001
            ) {
                Text(WSSMusicNotesText.text("speed")).wupsyFont(.caption)
            } onEditingChanged: { active in
                dragging = active
                if active {
                    if begin() { draft = position }
                } else {
                    if let draft, draft != position { commit(speed(at: draft)) }
                    draft = nil
                }
            }
            .accessibilityValue(formatted)
            Text(formatted).wupsyFont(.caption).monospacedDigit().frame(
                minWidth: 48, alignment: .trailing
            )
            .accessibilityHidden(true)
        }
    }

    private func speed(at position: Double) -> Float {
        min(WSSMusicNotesLayer.speedRange.upperBound, Float(0.1 * expm1(position * logRange)))
    }
}
