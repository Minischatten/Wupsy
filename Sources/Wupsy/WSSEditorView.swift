import SwiftUI

struct WSSEditorView: View {
    @Environment(\.wupsyMetrics) private var metrics
    @ObservedObject var document: WSSEditorDocument
    @State private var zoom: CGFloat? = nil
    @State private var effectCreationError: String?
    @State private var renameError: String?
    @FocusState private var structureFocused: Bool
    @FocusState private var canvasFocused: Bool
    init(document: WSSEditorDocument) {
        self.document = document
        _zoom = State(initialValue: document.initialCanvasZoom)
    }
    var body: some View {
        HSplitView {
            structure.frame(
                minWidth: min(205, metrics.points(180)), idealWidth: metrics.points(220),
                maxWidth: metrics.points(320))
            VStack(spacing: 0) {
                HStack {
                    Text(EditorText.canvas.text).wupsyFont(.headline)
                    Spacer()
                    if case .layer(let id) = document.selection, document.canTransform(id) {
                        Button {
                            document.activateStructureRow(.layer(id))
                        } label: {
                            Label(
                                EditorText.transform.text,
                                systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .accessibilityLabel(
                            document.transformHelp(for: .layer(id))
                                ?? EditorText.transformImage.text
                        )
                        .accessibilityIdentifier("wss.canvas.transform")
                        .disabled(
                            document.paintBrushEnabled || document.hasActivePaintInteraction
                                || document.canvasTransform != nil || document.saving
                                || document.saveAsBusy)
                    }
                    Menu(zoom.map { "\(Int($0 * 100))%" } ?? EditorText.fit.text) {
                        Button(EditorText.fit.text) { zoom = nil }
                        ForEach([25, 50, 100, 200], id: \.self) { value in
                            Button("\(value)%") { zoom = CGFloat(value) / 100 }
                        }
                    }.fixedSize().accessibilityLabel(EditorText.canvasZoom.text).disabled(
                        document.canvasTransform != nil || document.musicNotesPathGesture != nil
                            || document.hasActivePaintInteraction)
                }.wupsyPadding(.all, 10)
                WSSMaskCanvasTools(document: document)
                WSSDirectionBrushTools(document: document)
                WSSCanvasView(document: document, zoom: $zoom)
                    .id(ObjectIdentifier(document))
                    .focusable().focused($canvasFocused)
            }.frame(
                minWidth: metrics.scale == .standard ? 400 : 350, maxWidth: .infinity,
                maxHeight: .infinity)
            VSplitView {
                inspector.frame(minHeight: 280, maxHeight: .infinity)
                livePreview.frame(minHeight: 160, idealHeight: 220)
            }.frame(
                minWidth: min(360, metrics.points(300)), idealWidth: metrics.points(340),
                maxWidth: metrics.points(480))
        }
        .overlay {
            if document.saveAsBusy && document.interactionLocked {
                ProgressView(EditorText.savingCopy.text).wupsyPadding(.all, 24).background(
                    .regularMaterial
                )
                .cornerRadius(
                    10)
            }
        }
    }
    private var structure: some View {
        let rows = document.structureRows
        let renamingLayer = document.renamingLayer
        let session = document.state.sessionID
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(EditorText.layersEffects.text).wupsyFont(.headline)
                Spacer()
                Menu {
                    Button(EditorText.effectTrail.text) {
                        do {
                            try document.addTrail()
                            effectCreationError = nil
                        } catch { effectCreationError = EditorErrorPresentation.message(error) }
                    }.disabled(!document.permitsStructureEditing)
                    Button(WSSStarfieldText.title) {
                        do {
                            try document.addStarfield()
                            effectCreationError = nil
                        } catch { effectCreationError = EditorErrorPresentation.message(error) }
                    }.disabled(!document.permitsStructureEditing)
                    Button(WSSMusicNotesText.title) {
                        do {
                            try document.addMusicNotes()
                            effectCreationError = nil
                        } catch { effectCreationError = EditorErrorPresentation.message(error) }
                    }.disabled(!document.permitsStructureEditing)
                    Menu(WSSFogText.text("title")) {
                        ForEach(WSSFogPreset.allCases, id: \.self) { preset in
                            Button(WSSFogText.text(preset.rawValue)) {
                                do {
                                    try document.addFog(preset)
                                    effectCreationError = nil
                                } catch {
                                    effectCreationError = EditorErrorPresentation.message(error)
                                }
                            }
                        }
                    }.disabled(!document.permitsStructureEditing)
                    Button(WSSStormText.title) {
                        do {
                            try document.addStorm()
                            effectCreationError = nil
                        } catch { effectCreationError = EditorErrorPresentation.message(error) }
                    }.disabled(!document.permitsStructureEditing)
                    Button(EditorText.effectRain.text) {
                        do {
                            try document.addRain()
                            effectCreationError = nil
                        } catch { effectCreationError = EditorErrorPresentation.message(error) }
                    }.disabled(!document.permitsStructureEditing)
                    Divider()
                    ForEach(WSSAddableEffect.allCases, id: \.self) { kind in
                        Button(kind.title) {
                            do {
                                try document.addEffect(kind)
                                effectCreationError = nil
                            } catch {
                                effectCreationError =
                                    EditorText.effectAddError.format(
                                        EditorErrorPresentation.message(error))
                            }
                        }
                        .disabled(!document.canAddEffect(kind))
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .help(EditorText.addSceneContent.text).accessibilityLabel(
                    EditorText.addSceneContent.text
                )
                .disabled(!document.permitsStructureEditing)
            }.wupsyPadding(.all, 10)
            if let effectCreationError {
                Text(effectCreationError).wupsyFont(.caption).foregroundStyle(.secondary)
                    .wupsyPadding(.horizontal, 10)
            }
            if let renameError {
                Text(renameError).wupsyFont(.caption).foregroundStyle(.secondary)
                    .wupsyPadding(.horizontal, 10)
            }
            Text(EditorText.layerOrderHint.text).wupsyFont(.caption).foregroundStyle(
                .secondary
            ).wupsyPadding(.horizontal, 10)
            List(
                selection: Binding(
                    get: { document.selection },
                    set: {
                        if document.renamingLayer == nil || $0 != document.selection {
                            document.select($0)
                        }
                    })
            ) {
                ForEach(rows) { row in
                    let editing = row.id == renamingLayer.map { .layer($0) }
                    HStack(spacing: metrics.spacing(4)) {
                        if case .layer(let id) = row.id {
                            WSSLayerVisibilityButton(
                                symbol: row.symbol, help: document.visibilityHelp(id),
                                enabled: !document.interactionLocked,
                                action: { try? document.toggleVisibility(id) }
                            ).wupsyControlFrame(width: 26, height: 26)
                            if document.canTransform(id) {
                                Image(
                                    systemName: document.stormLayer(id) == nil
                                        ? "photo" : "bolt.fill"
                                )
                                .wupsyControlFrame(width: 26, height: 26)
                                .contentShape(Rectangle())
                                .help(
                                    document.transformHelp(for: .layer(id))
                                        ?? EditorText.transformHint.text
                                )
                                .accessibilityLabel(EditorText.transformImage.text)
                                .simultaneousGesture(
                                    TapGesture(count: 2).onEnded {
                                        document.activateStructureRow(row.id)
                                    }
                                )
                            }
                        } else {
                            Image(systemName: row.symbol)
                        }
                        structureTitle(row, editing: editing)
                    }
                    .padding(.leading, CGFloat(row.depth) * metrics.spacing(18))
                    .contentShape(Rectangle())
                    .moveDisabled(!document.permitsStructureEditing || editing)
                    .tag(row.id)
                }
                .onMove { sources, destination in
                    _ = try? document.moveStructureRows(
                        sources, to: destination, rows: rows, session: session)
                }
            }.focused($structureFocused)
                .onDeleteCommand {
                    if structureFocused { document.structureCommands.perform(.delete) }
                }
                .onKeyPress(keys: [.upArrow], phases: .down) { key in
                    guard structureFocused, key.modifiers == .option
                    else { return .ignored }
                    try? document.moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(keys: [.downArrow], phases: .down) { key in
                    guard structureFocused, key.modifiers == .option
                    else { return .ignored }
                    try? document.moveSelection(by: 1)
                    return .handled
                }
            Button(EditorText.addImageAction.text) { Task { await document.chooseImage() } }
                .disabled(
                    document.interactionLocked || document.importingImage
                        || document.identity.layers.count >= 128
                )
                .wupsyPadding(.horizontal, 10)
            HStack {
                Button {
                    try? document.moveSelection(by: -1)
                } label: {
                    Image(systemName: "arrow.up")
                }.help(document.moveEarlierHelp).accessibilityLabel(
                    document.moveEarlierHelp
                )
                .disabled(!document.canMoveSelection(by: -1))
                Button {
                    try? document.moveSelection(by: 1)
                } label: {
                    Image(systemName: "arrow.down")
                }.help(document.moveLaterHelp).accessibilityLabel(
                    document.moveLaterHelp
                )
                .disabled(!document.canMoveSelection(by: 1))
                Spacer()
                Button {
                    document.structureCommands.perform(.delete)
                } label: {
                    Image(systemName: "trash")
                }.help(document.deleteSelectionTitle).accessibilityLabel(
                    document.deleteSelectionTitle
                )
                .disabled(!document.structureCommands.canPerform(.delete))
            }.wupsyPadding(.all, 10).disabled(document.interactionLocked)
        }
    }
    @ViewBuilder
    private func structureTitle(_ row: WSSEditorStructureRow, editing: Bool) -> some View {
        if case .layer(let id) = row.id,
            let index = document.identity.layers.firstIndex(
                where: { $0.id == id })
        {
            if editing {
                WSSLayerNameField(initialName: document.layerDisplayName(at: index)) {
                    name, keyboard in
                    document.renamingLayer = nil
                    if let name {
                        do { try document.renameLayer(id, to: name) } catch {
                            renameError = EditorText.invalidLayerName.text
                        }
                    }
                    if keyboard { structureFocused = true }
                }
                .id(id)
                .frame(maxWidth: .infinity)
                .onAppear { renameError = nil }
            } else {
                structureLabel(row.title)
                    .background(WSSLayerNameHitRegion(layer: id).allowsHitTesting(false))
            }
        } else {
            structureLabel(row.title)
        }
    }

    private func structureLabel(_ title: String) -> some View {
        Text(title)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .help(title)
    }

    private var livePreview: some View {
        VStack(spacing: 6) {
            HStack {
                Text(EditorText.livePreview.text).wupsyFont(.headline)
                Spacer()
                Button {
                    document.playing.toggle()
                } label: {
                    Image(systemName: document.playing ? "pause.fill" : "play.fill")
                }.accessibilityLabel(
                    document.playing ? EditorText.pausePreview.text : EditorText.playPreview.text
                )
                .disabled(document.previewError != nil)
                Button {
                    document.togglePreviewExpansion?()
                } label: {
                    Image(
                        systemName: document.previewExpanded
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right")
                }
                .help(
                    document.previewExpanded
                        ? EditorText.returnPreview.text : EditorText.enlargePreview.text
                )
                .accessibilityLabel(
                    document.previewExpanded
                        ? EditorText.returnPreview.text : EditorText.enlargePreview.text
                )
                .disabled(document.previewError != nil)
            }.padding([.horizontal, .top], 10)
            if !document.previewIsCurrent {
                Text(
                    document.preparationError.map { EditorText.previewNotCurrentDetail.format($0) }
                        ?? EditorText.updatingPreview.text
                )
                .wupsyFont(.caption).foregroundStyle(.secondary).wupsyPadding(.horizontal, 10)
            }
            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(0.85)
                    if let error = document.previewError {
                        Text(error).wupsyFont(.caption).padding()
                    } else {
                        WSSPreviewView(document: document)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: metrics.spacing(14)) {
                Text(EditorText.inspector.text).wupsyFont(.headline)
                if document.effectAddress == nil, let id = document.selection?.layer {
                    Text(document.layerDisplayName(at: document.selectedLayer))
                        .wupsyFont(.headline)
                        .lineLimit(2)
                        .help(document.layerDisplayName(at: document.selectedLayer))
                    Toggle(
                        EditorText.visible.text,
                        isOn: Binding(
                            get: { document.workingScene.layers[document.selectedLayer].visible },
                            set: { try? document.setVisibility($0, layer: id) }))
                    if case .image(let image) = document.state.workingModel.layers[
                        document.selectedLayer
                    ].content {
                        Button(EditorText.replaceImageAction.text) {
                            Task { await document.chooseImage(replacing: id) }
                        }
                        .disabled(document.interactionLocked || document.importingImage)
                        WSSImageOpacitySlider(
                            opacity: image.opacity,
                            update: {
                                try? document.setImage(
                                    .opacity, value: $0, layer: id,
                                    undo: document.canvasImageDrag == nil)
                            },
                            editingChanged: { active in
                                if active {
                                    document.beginImageSlider(.opacity, layer: id)
                                } else {
                                    document.endImageSlider()
                                }
                            })
                        ForEach(WSSImageProperty.allCases.filter { $0 != .opacity }, id: \.self) {
                            property in
                            VStack(alignment: .leading) {
                                Text(property.title).wupsyFont(.caption).foregroundStyle(.secondary)
                                WSSParameterTextField(
                                    value: property.value(image), range: property.range,
                                    title: property.title
                                ) { try document.setImage(property, value: $0, layer: id) }
                            }
                        }
                    }
                }
                if document.effectAddress == nil, let id = document.selection?.layer,
                    document.musicNotesLayer(id) != nil
                {
                    WSSMusicNotesParameterControls(document: document, layer: id).id(id)
                }
                if document.effectAddress == nil, let id = document.selection?.layer,
                    document.fogLayer(id) != nil
                {
                    WSSFogParameterControls(document: document, layer: id).id(id)
                }
                if document.effectAddress == nil, let id = document.selection?.layer,
                    document.starfieldLayer(id) != nil
                {
                    WSSStarfieldParameterControls(document: document, layer: id)
                }
                if document.effectAddress == nil, let id = document.selection?.layer,
                    document.stormLayer(id) != nil
                {
                    WSSStormParameterControls(document: document, layer: id)
                }
                if document.effectAddress == nil, let id = document.selection?.layer,
                    document.rainLayer(id) != nil
                {
                    WSSRainParameterControls(document: document, layer: id)
                }
                if document.effectAddress == nil, let id = document.selection?.layer,
                    document.trailLayer(id) != nil
                {
                    WSSTrailParameterControls(document: document, layer: id)
                }
                ForEach(
                    Array(
                        document.inspectorSections.filter { $0.kind != .rain && $0.kind != .trail }
                            .enumerated()),
                    id: \.offset
                ) {
                    _, section in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(section.title).wupsyFont(.headline)
                        if let address = section.editableAddress,
                            document.identity.layers.indices.contains(address.layerIndex),
                            document.identity.layers[address.layerIndex].effects.indices.contains(
                                address.effectIndex)
                        {
                            WSSEditorParameterControls(
                                document: document,
                                layerID: document.identity.layers[address.layerIndex].id,
                                effectID: document.identity.layers[address.layerIndex].effects[
                                    address.effectIndex])
                        }

                    }
                    Divider()
                }
            }.wupsyPadding(.all, 14).frame(maxWidth: .infinity, alignment: .leading)
                .disabled(document.interactionLocked)
        }
    }
}

// A native button consumes its own mouse sequence independently of List row gestures.
struct WSSImageOpacitySlider: View {
    @Environment(\.wupsyMetrics) private var metrics
    let opacity: Float
    let update: (Float) -> Void
    let editingChanged: (Bool) -> Void

    var body: some View {
        let percent = Double(opacity).formatted(.percent.precision(.fractionLength(0)))
        HStack(spacing: metrics.spacing(8)) {
            Slider(
                value: Binding(get: { Double(opacity) * 100 }, set: { update(Float($0 / 100)) }),
                in: 0...100, step: 1
            ) {
                Text(EditorText.opacity.text).wupsyFont(.caption)
            } onEditingChanged: { active in
                editingChanged(active)
            }
            .accessibilityLabel(EditorText.imageOpacity.text)
            .accessibilityValue(percent)
            .accessibilityIdentifier("wss.image.opacity")
            Text(percent).wupsyFont(.caption).monospacedDigit().fixedSize()
                .accessibilityHidden(true)
        }
    }
}

struct WSSLayerVisibilityButton: NSViewRepresentable {
    @Environment(\.wupsyMetrics) private var metrics
    let symbol: String
    let help: String
    let enabled: Bool
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            image: NSImage(), target: context.coordinator, action: #selector(Coordinator.click))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryPushIn)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.image =
            metrics.scale == .standard
            ? image
            : image?.withSymbolConfiguration(
                .init(pointSize: metrics.points(13), weight: .regular))
        button.controlSize = metrics.nativeControlSize
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.isEnabled = enabled
    }
    final class Coordinator: NSObject {
        var action: () -> Void = {}
        @objc func click() { action() }
    }
}
