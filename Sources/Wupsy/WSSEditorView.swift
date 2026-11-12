import SwiftUI

struct WSSEditorView: View {
    @ObservedObject var document: WSSEditorDocument
    @State private var zoom: CGFloat? = nil
    @State private var effectCreationError: String?
    @FocusState private var structureFocused: Bool
    @FocusState private var canvasFocused: Bool
    init(document: WSSEditorDocument) {
        self.document = document
        _zoom = State(initialValue: document.initialCanvasZoom)
    }
    var body: some View {
        HSplitView {
            structure.frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            VStack(spacing: 0) {
                HStack {
                    Text(EditorText.canvas.text).font(.headline)
                    Spacer()
                    if case .layer(let id) = document.selection, document.canTransform(id) {
                        Button {
                            document.activateStructureRow(.layer(id))
                        } label: {
                            Label(
                                EditorText.transform.text,
                                systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .accessibilityLabel(EditorText.transformImage.text)
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
                        document.canvasTransform != nil || document.hasActivePaintInteraction)
                }.padding(10)
                WSSMaskCanvasTools(document: document)
                WSSDirectionBrushTools(document: document)
                WSSCanvasView(document: document, zoom: $zoom)
                    .focusable().focused($canvasFocused)
            }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            VSplitView {
                inspector.frame(minHeight: 280, maxHeight: .infinity)
                livePreview.frame(minHeight: 160, idealHeight: 220)
            }.frame(minWidth: 300, idealWidth: 340, maxWidth: 480)
        }
        .overlay {
            if document.saveAsBusy && document.interactionLocked {
                ProgressView(EditorText.savingCopy.text).padding(24).background(.regularMaterial)
                    .cornerRadius(
                        10)
            }
        }
    }
    private var structure: some View {
        let rows = document.structureRows
        let session = document.state.sessionID
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(EditorText.layersEffects.text).font(.headline)
                Spacer()
                Menu {
                    Button(EditorText.effectTrail.text) {
                        do {
                            try document.addTrail()
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
            }.padding(10)
            if let effectCreationError {
                Text(effectCreationError).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }
            Text(EditorText.layerOrderHint.text).font(.caption).foregroundStyle(
                .secondary
            ).padding(.horizontal, 10)
            List(
                selection: Binding(
                    get: { document.selection },
                    set: { document.select($0) })
            ) {
                ForEach(rows) { row in
                    HStack(spacing: 4) {
                        if case .layer(let id) = row.id {
                            WSSLayerVisibilityButton(
                                symbol: row.symbol, help: document.visibilityHelp(id),
                                enabled: !document.interactionLocked,
                                action: { try? document.toggleVisibility(id) }
                            ).frame(width: 26, height: 26)
                            if document.canTransform(id) {
                                Image(systemName: "photo")
                                    .frame(width: 26, height: 26)
                                    .contentShape(Rectangle())
                                    .help(EditorText.transformHint.text)
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
                        Text(row.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .padding(.leading, CGFloat(row.depth) * 18)
                    .contentShape(Rectangle())
                    .moveDisabled(!document.permitsStructureEditing)
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
                .padding(.horizontal, 10)
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
            }.padding(10).disabled(document.interactionLocked)
        }
    }
    private var livePreview: some View {
        VStack(spacing: 6) {
            HStack {
                Text(EditorText.livePreview.text).font(.headline)
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
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            }
            GeometryReader { geometry in
                let fitted = WSSPreviewGeometry.fit(
                    canvas: CGSize(
                        width: document.project.scene.width, height: document.project.scene.height),
                    available: geometry.size)
                ZStack {
                    Color.black.opacity(0.85)
                    if let error = document.previewError {
                        Text(error).font(.caption).padding()
                    } else {
                        WSSPreviewView(document: document).frame(
                            width: fitted.width, height: fitted.height)
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(EditorText.inspector.text).font(.headline)
                if document.effectAddress == nil, let id = document.selection?.layer {
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
                        ForEach(WSSImageProperty.allCases, id: \.self) { property in
                            VStack(alignment: .leading) {
                                Text(property.title).font(.caption).foregroundStyle(.secondary)
                                if property == .opacity {
                                    Slider(
                                        value: Binding(
                                            get: { Double(image.opacity) },
                                            set: {
                                                try? document.setImage(
                                                    .opacity, value: Float($0), layer: id,
                                                    undo: document.canvasImageDrag == nil)
                                            }), in: 0...1,
                                        onEditingChanged: { active in
                                            if active {
                                                document.beginImageSlider(.opacity, layer: id)
                                            } else {
                                                document.endImageSlider()
                                            }
                                        }
                                    ).accessibilityLabel(EditorText.imageOpacity.text)
                                }
                                WSSParameterTextField(
                                    value: property.value(image), range: property.range,
                                    title: property.title
                                ) { try document.setImage(property, value: $0, layer: id) }
                            }
                        }
                    }
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
                        Text(section.title).font(.headline)
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
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .disabled(document.interactionLocked)
        }
    }
}

// A native button consumes its own mouse sequence independently of List row gestures.
struct WSSLayerVisibilityButton: NSViewRepresentable {
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
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.isEnabled = enabled
    }
    final class Coordinator: NSObject {
        var action: () -> Void = {}
        @objc func click() { action() }
    }
}
