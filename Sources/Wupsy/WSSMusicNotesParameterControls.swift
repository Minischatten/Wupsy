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
        layer.staff = nil
        layer.depth = nil
        layer.perspective = nil
        layer.placement = nil
        layer.freeSymbol = nil
        layer.anchoredSymbol = nil
        layer.freePosition = nil
        layer.anchorPosition = nil
        layer.alignToPath = nil
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
    func changeMusicNotesPlacement(
        _ id: WSSLayerID, name: String, change: (inout WSSMusicNotesLayer) -> Void
    ) throws {
        guard permitsStructureEditing, finishParameterInteractions(),
            let index = identity.layers.firstIndex(where: { $0.id == id }),
            var layer = musicNotesLayer(id)
        else { return }
        change(&layer)
        var model = state.workingModel
        model.layers[index].content = .musicNotes(layer)
        try mutate(model, name: name)
    }

    func setMusicNoteSymbol(_ symbol: WSSMusicNoteSymbol, enabled: Bool, layer: WSSLayerID) throws {
        guard finishEditing() else { return }
        try changeMusicNotes(layer, name: WSSMusicNotesText.text(symbol.rawValue)) { notes in
            if enabled, !notes.symbols.contains(symbol) {
                notes.symbols.append(symbol)
            } else if !enabled, notes.symbols.count > 1 {
                notes.symbols.removeAll { $0 == symbol }
            }
        }
    }

    func setMusicNotesMotion(
        _ parameter: WSSMusicNotesLayer.MotionParameter, value: Double, layer id: WSSLayerID
    ) throws {
        guard parameter.range.contains(value) else {
            throw WSSSceneError.invalid("musicNotes motion parameters")
        }
        let editing =
            musicNotesMotionDrag?.layer == id && musicNotesMotionDrag?.parameter == parameter
        guard permitsStructureEditing, editing || finishParameterInteractions(),
            let index = identity.layers.firstIndex(where: { $0.id == id }),
            var layer = musicNotesLayer(id), parameter.value(in: layer.notes) != value
        else { return }
        let original = editing ? musicNotesMotionDrag?.original : parameter.stored(in: layer.notes)
        let stored = value == parameter.defaultValue ? (original == value ? original : nil) : value
        parameter.set(stored, in: &layer.notes)
        var model = state.workingModel
        model.layers[index].content = .musicNotes(layer)
        try mutate(model, name: WSSMusicNotesText.text(parameter.rawValue), undo: !editing)
    }

    func beginMusicNotesMotion(
        _ parameter: WSSMusicNotesLayer.MotionParameter, layer id: WSSLayerID
    ) -> Bool {
        guard permitsStructureEditing, finishEditing(), let layer = musicNotesLayer(id) else {
            return false
        }
        musicNotesMotionDrag = (id, parameter, parameter.stored(in: layer.notes))
        return true
    }

    func endMusicNotesMotion() {
        guard let drag = musicNotesMotionDrag else { return }
        musicNotesMotionDrag = nil
        guard let index = identity.layers.firstIndex(where: { $0.id == drag.layer }),
            var layer = musicNotesLayer(drag.layer),
            drag.parameter.stored(in: layer.notes) != drag.original
        else { return }
        drag.parameter.set(drag.original, in: &layer.notes)
        var before = state.workingModel
        before.layers[index].content = .musicNotes(layer)
        registerModelUndo(before, name: WSSMusicNotesText.text(drag.parameter.rawValue))
        objectWillChange.send()
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
                placementPicker(value)
                if value.placementMode == .animatedPath {
                    pathControls(value)
                    perspectiveControls(value)
                    if value.usesActivePath {
                        WSSMusicNotesDepthControls(
                            document: document, layer: layer, depth: value.depth
                        )
                        .id(layer)
                    }
                    WSSMusicNotesStaffControls(document: document, layer: layer, value: value)
                        .id(layer)
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
                                try document.changeMusicNotes(layer, name: title) {
                                    $0.color = color
                                }
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
                                        try document.setMusicNoteSymbol(
                                            symbol, enabled: enabled, layer: layer)
                                    }
                                })
                        )
                        .disabled(selected && notes.symbols.count == 1)
                        .accessibilityIdentifier("wss.musicNotes.symbol.\(symbol.rawValue)")
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
                        field("direction", value: notes.direction, range: 0...360) {
                            $0.direction = $1
                        }
                    }
                    WSSMusicNotesSpeedSlider(speed: notes.speed, begin: document.finishEditing) {
                        speed in
                        perform {
                            try document.changeMusicNotes(
                                layer, name: WSSMusicNotesText.text("speed")
                            ) {
                                $0.speed = speed
                            }
                        }
                    }
                    field("speed", value: notes.speed, range: WSSMusicNotesLayer.speedRange) {
                        $0.speed = $1
                    }
                } else {
                    if value.placementMode == .anchoredSingle { pathControls(value) }
                    singleControls(value)
                }
                Text(WSSMusicNotesText.text("gentleMotion")).wupsyFont(.headline)
                toggle("hover", notes: notes, property: \.hover)
                motionControls(.hoverStrength, .hoverFrequency, notes: notes)
                if let single = value.singleSymbol {
                    singleRotationControls(single, value: value)
                } else {
                    toggle("rotation", notes: notes, property: \.rotation)
                    motionControls(.rotationStrength, .rotationFrequency, notes: notes)
                }
                Button(WSSEffectReset.title) { perform { try document.resetMusicNotes(layer) } }
                if let error { Text(error).wupsyFont(.caption).foregroundStyle(.red) }
            }
        }
        .disabled(!document.permitsStructureEditing)
    }

    @ViewBuilder private func perspectiveControls(_ value: WSSMusicNotesLayer) -> some View {
        let perspective = value.perspective ?? .init()
        let title = WSSMusicNotesText.text("perspectiveTitle")
        VStack(alignment: .leading, spacing: 6) {
            Text(title).wupsyFont(.headline)
            if value.supportsPerspective {
                Toggle(
                    title,
                    isOn: Binding(
                        get: { perspective.enabled },
                        set: { enabled in
                            perform {
                                guard document.finishEditing() else { return }
                                try changePerspective("perspectiveTitle") { $0.enabled = enabled }
                            }
                        })
                )
                .accessibilityIdentifier("wss.musicNotes.perspective.enabled")
                if perspective.enabled {
                    singleField(
                        "perspectiveStart", value: perspective.start,
                        range: WSSMusicNotesPerspective.percentRange
                    ) { next in
                        try changePerspective("perspectiveStart") { $0.start = next }
                    }
                    singleField(
                        "perspectiveEnd", value: perspective.end,
                        range: WSSMusicNotesPerspective.percentRange
                    ) { next in
                        try changePerspective("perspectiveEnd") { $0.end = next }
                    }
                    Button(WSSMusicNotesText.text("perspectiveSwap")) {
                        perform {
                            guard document.finishEditing() else { return }
                            try changePerspective("perspectiveSwap") {
                                ($0.start, $0.end) = ($0.end, $0.start)
                            }
                        }
                    }
                }
            } else {
                Text(
                    WSSMusicNotesText.text(
                        value.usesActivePath ? "perspectiveClosed" : "perspectiveNeedsPath")
                )
                .wupsyFont(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func changePerspective(
        _ key: String, change: (inout WSSMusicNotesPerspective) -> Void
    ) throws {
        try document.changeMusicNotesPlacement(layer, name: WSSMusicNotesText.text(key)) { layer in
            var perspective = layer.perspective ?? .init()
            change(&perspective)
            layer.perspective = perspective
        }
    }

    private func placementPicker(_ value: WSSMusicNotesLayer) -> some View {
        Picker(
            WSSMusicNotesText.text("placement"),
            selection: Binding(
                get: { value.placementMode },
                set: { mode in
                    perform {
                        guard document.finishEditing() else { return }
                        if mode == .freeSingle && document.musicNotesPathEditLayer == layer {
                            document.leaveMusicNotesPathEditing(restoreTransform: true)
                        }
                        try document.changeMusicNotesPlacement(
                            layer, name: WSSMusicNotesText.text("placement")
                        ) { $0.placement = mode == .animatedPath ? nil : mode }
                    }
                })
        ) {
            ForEach(WSSMusicNotesLayer.Placement.allCases, id: \.self) { mode in
                Text(WSSMusicNotesText.text(mode.rawValue)).tag(mode)
            }
        }
        .accessibilityIdentifier("wss.musicNotes.placement")
    }

    @ViewBuilder private func singleControls(_ value: WSSMusicNotesLayer) -> some View {
        if let symbol = value.singleSymbol {
            let free = value.placementMode == .freeSingle
            Picker(
                WSSMusicNotesText.text("singleSymbol"),
                selection: Binding(
                    get: { symbol.symbol },
                    set: { next in
                        perform {
                            try changeSingle("singleSymbol", free: free) { $0.symbol = next }
                        }
                    })
            ) {
                ForEach(WSSMusicNoteSymbol.allCases, id: \.self) { note in
                    Text(WSSMusicNotesText.text(note.rawValue)).tag(note)
                }
            }
            singleField("size", value: symbol.size, range: WSSMusicNotesLayer.sizeRange) { next in
                try changeSingle("size", free: free) { $0.size = next }
            }
            singleField("opacity", value: symbol.opacity, range: 0...1) { next in
                try changeSingle("opacity", free: free) { $0.opacity = next }
            }
            HStack {
                let title = WSSMusicNotesText.text("color")
                Text(title).wupsyFont(.caption)
                Spacer()
                WSSNativeSDRColorWell(color: symbol.color, title: title) { color in
                    perform { try changeSingle("color", free: free) { $0.color = color } }
                }.wupsyControlFrame(width: 50, height: 24)
            }
            if free {
                singleField(
                    "positionX", value: value.singleCenter.x,
                    range: WSSMusicNotesLayer.singlePositionRange
                ) { next in
                    try document.changeMusicNotesPlacement(
                        layer, name: WSSMusicNotesText.text("positionX")
                    ) {
                        $0.freePosition = SIMD2(next, $0.singleCenter.y)
                    }
                }
                singleField(
                    "positionY", value: value.singleCenter.y,
                    range: WSSMusicNotesLayer.singlePositionRange
                ) { next in
                    try document.changeMusicNotesPlacement(
                        layer, name: WSSMusicNotesText.text("positionY")
                    ) {
                        $0.freePosition = SIMD2($0.singleCenter.x, next)
                    }
                }
            } else if value.usesActivePath {
                singleField("anchorPosition", value: value.anchorPosition ?? 50, range: 0...100) {
                    next in
                    try document.changeMusicNotesPlacement(
                        layer, name: WSSMusicNotesText.text("anchorPosition")
                    ) {
                        $0.anchorPosition = next
                    }
                }
                Toggle(
                    WSSMusicNotesText.text("alignToPath"),
                    isOn: Binding(
                        get: { value.alignToPath ?? false },
                        set: { align in
                            perform {
                                guard document.finishEditing() else { return }
                                try document.changeMusicNotesPlacement(
                                    layer, name: WSSMusicNotesText.text("alignToPath")
                                ) { $0.alignToPath = align }
                            }
                        }))
            } else {
                Text(WSSMusicNotesText.text("anchorNeedsPath"))
                    .wupsyFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func singleRotationControls(
        _ single: WSSMusicNotesLayer.SingleSymbol, value: WSSMusicNotesLayer
    ) -> some View {
        let free = value.placementMode == .freeSingle
        let mode = single.effectiveRotationMode(legacyRocking: value.notes.rotation)
        Picker(
            WSSMusicNotesText.text("rotationMode"),
            selection: Binding(
                get: { mode },
                set: { next in
                    perform {
                        guard document.finishEditing() else { return }
                        try changeSingle("rotationMode", free: free) { $0.rotationMode = next }
                    }
                })
        ) {
            Text(WSSMusicNotesText.text("rotationNone")).tag(
                WSSMusicNotesLayer.SingleRotationMode.none)
            Text(WSSMusicNotesText.text("rotation")).tag(
                WSSMusicNotesLayer.SingleRotationMode.rocking)
            Text(WSSMusicNotesText.text("rotationContinuous")).tag(
                WSSMusicNotesLayer.SingleRotationMode.continuous)
        }
        .accessibilityIdentifier("wss.musicNotes.rotationMode")

        if mode == .rocking {
            motionControls(.rotationStrength, .rotationFrequency, notes: value.notes)
        } else if mode == .continuous {
            Picker(
                WSSMusicNotesText.text("spinAxis"),
                selection: Binding(
                    get: { single.spinAxis ?? .imagePlane },
                    set: { axis in
                        perform {
                            guard document.finishEditing() else { return }
                            try changeSingle("spinAxis", free: free) { $0.spinAxis = axis }
                        }
                    })
            ) {
                ForEach(WSSMusicNotesLayer.SpinAxis.allCases, id: \.self) { axis in
                    Text(WSSMusicNotesText.text(axis.rawValue)).tag(axis)
                }
            }
            .accessibilityIdentifier("wss.musicNotes.spinAxis")
            let period = single.spinPeriod ?? WSSMusicNotesLayer.SingleSymbol.defaultSpinPeriod
            let range = WSSMusicNotesLayer.SingleSymbol.spinPeriodRange
            let title = WSSMusicNotesText.text("spinPeriod")
            HStack {
                VStack(alignment: .leading) {
                    Text(title).wupsyFont(.caption)
                    Text("5–300 s").wupsyFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                WSSParameterTextField(
                    value: Float(period), range: Float(range.lowerBound)...Float(range.upperBound),
                    title: title, maximumFractionDigits: 3, exactValue: period, exactRange: range,
                    commitExact: { next in
                        try changeSingle("spinPeriod", free: free) { $0.spinPeriod = next }
                    },
                    commit: { _ in }
                ).wupsyControlFrame(width: 85)
            }
            Picker(
                WSSMusicNotesText.text("spinDirection"),
                selection: Binding(
                    get: {
                        single.spinDirection ?? WSSMusicNotesLayer.SingleSymbol.defaultSpinDirection
                    },
                    set: { direction in
                        perform {
                            guard document.finishEditing() else { return }
                            try changeSingle("spinDirection", free: free) {
                                $0.spinDirection = direction
                            }
                        }
                    })
            ) {
                ForEach(WSSMusicNotesLayer.SpinDirection.allCases, id: \.self) { direction in
                    Text(WSSMusicNotesText.text(direction.rawValue)).tag(direction)
                }
            }
        }
    }

    private func changeSingle(
        _ key: String, free: Bool, change: (inout WSSMusicNotesLayer.SingleSymbol) -> Void
    ) throws {
        try document.changeMusicNotesPlacement(layer, name: WSSMusicNotesText.text(key)) { layer in
            var symbol = (free ? layer.freeSymbol : layer.anchoredSymbol) ?? .init()
            change(&symbol)
            if free { layer.freeSymbol = symbol } else { layer.anchoredSymbol = symbol }
        }
    }

    private func singleField(
        _ key: String, value: Float, range: ClosedRange<Float>,
        commit: @escaping (Float) throws -> Void
    ) -> some View {
        let title = WSSMusicNotesText.text(key)
        return HStack {
            Text(title).wupsyFont(.caption)
            Spacer()
            WSSParameterTextField(
                value: value, range: range, title: title, maximumFractionDigits: 3, commit: commit
            ).wupsyControlFrame(width: 100)
        }
    }

    private func motionControls(
        _ strength: WSSMusicNotesLayer.MotionParameter,
        _ frequency: WSSMusicNotesLayer.MotionParameter,
        notes: WSSMusicNotesLayer.Configuration
    ) -> some View {
        ForEach([strength, frequency], id: \.self) { parameter in
            WSSMusicNotesMotionControl(
                document: document, layer: layer, parameter: parameter,
                value: parameter.value(in: notes), perform: perform)
        }
        .id(layer)
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
                        get: { document.musicNotesLayer(layer)?.path?.closed ?? path.closed },
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
                if value.placementMode == .animatedPath {
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
                        Text(WSSMusicNotesText.text("forward")).tag(
                            WSSMusicNotesPath.Direction.forward)
                        Text(WSSMusicNotesText.text("reverse")).tag(
                            WSSMusicNotesPath.Direction.reverse)
                    }.pickerStyle(.segmented)
                }
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
                if value.placementMode == .animatedPath && value.hasShortOpenPathFade {
                    Text(WSSMusicNotesText.text("shortPath")).wupsyFont(.caption).foregroundStyle(
                        .secondary)
                }
            }
            if enabled {
                Menu(WSSMusicNotesText.text("pathTemplates")) {
                    ForEach(WSSMusicNotesPath.EditorTemplate.allCases, id: \.self) { template in
                        Button(WSSMusicNotesText.text(template.rawValue)) {
                            perform {
                                try document.applyMusicNotesPathTemplate(template, layer: layer)
                            }
                        }
                    }
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

private struct WSSMusicNotesMotionControl: View {
    let document: WSSEditorDocument
    let layer: WSSLayerID
    let parameter: WSSMusicNotesLayer.MotionParameter
    let value: Double
    let perform: (() throws -> Void) -> Void
    @State private var rejectsDrag = false

    var body: some View {
        let title = WSSMusicNotesText.text(parameter.rawValue)
        let range = parameter.range
        let unit = parameter.isStrength ? "%" : "Hz"
        let bounds = "\(range.lowerBound.formatted())–\(range.upperBound.formatted()) \(unit)"
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading) {
                    Text(title).wupsyFont(.caption)
                    Text(bounds).wupsyFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                WSSParameterTextField(
                    value: Float(value), range: Float(range.lowerBound)...Float(range.upperBound),
                    title: "\(title) (\(bounds))", maximumFractionDigits: 3,
                    exactValue: value, exactRange: range,
                    commitExact: {
                        try document.setMusicNotesMotion(parameter, value: $0, layer: layer)
                    },
                    commit: { _ in }
                ).wupsyControlFrame(width: 85)
            }
            Slider(
                value: Binding(
                    get: { value },
                    set: { next in
                        guard !rejectsDrag else { return }
                        if document.musicNotesMotionDrag == nil, !document.finishEditing() {
                            return
                        }
                        perform {
                            try document.setMusicNotesMotion(parameter, value: next, layer: layer)
                        }
                    }),
                in: range,
                onEditingChanged: { editing in
                    if editing {
                        rejectsDrag = !document.beginMusicNotesMotion(parameter, layer: layer)
                    } else {
                        if document.musicNotesMotionDrag?.parameter == parameter {
                            document.endMusicNotesMotion()
                        }
                        rejectsDrag = false
                    }
                }
            )
            .accessibilityLabel(title)
            .accessibilityValue(
                "\(value.formatted(.number.precision(.fractionLength(0...3)))) \(unit)")
        }
    }
}
