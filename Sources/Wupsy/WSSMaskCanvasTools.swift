import SwiftUI

struct WSSMaskCanvasTools: View {
    @ObservedObject var session: WSSMaskCanvasSession
    @ObservedObject var document: WSSEditorDocument
    init(document: WSSEditorDocument) {
        self.document = document
        session = document.maskCanvas
    }
    private var directPaint: Bool {
        document.maskManagementTarget?.slot.supportsDirectPaint == true
    }
    var body: some View {
        if document.maskManagementTarget != nil {
            HStack {
                Menu(EditorText.mask.text) {
                    ForEach(WSSMaskAction.allCases, id: \.self) { action in
                        Button(action.title) {
                            Task { await document.performMaskAction(action) }
                        }
                        .disabled(!document.canManageMask(action))
                    }
                }.fixedSize()
                if document.maskManagementTarget?.slot == .rain {
                    Button(EditorText.rainFullArea.text) {
                        Task { await document.performMaskAction(.remove) }
                    }
                    .disabled(!document.canManageMask(.remove))
                    .accessibilityIdentifier("wss.mask.full-area")
                }
                if !directPaint && document.selectedMaskTarget == nil {
                    Text(EditorText.maskBlackHint.text)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 10)
                .disabled(
                    document.interactionLocked || document.importingImage || document.saving
                        || document.saveAsBusy)
            if !directPaint && session.loaded == nil {
                brush.padding(.horizontal, 10).padding(.bottom, 8)
                    .disabled(
                        !document.canManageMask(.create) && document.selectedMaskTarget == nil
                            || document.interactionLocked || document.importingImage
                            || document.saving || document.saveAsBusy || !session.overlayAvailable)
            }
        }
        if directPaint || session.loaded != nil {
            settings.padding(.horizontal, 10).padding(.bottom, 8)
                .disabled(
                    session.blocksDocumentActions || !session.overlayAvailable
                        || document.interactionLocked || document.importingImage || document.saving
                        || document.saveAsBusy)
        }
        if let error = session.error {
            Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
        }
    }
    private var settings: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                brush
                size
                opacity
                erase
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    brush
                    size
                }
                HStack {
                    opacity
                    erase
                }
            }
        }
    }
    @ViewBuilder private var brush: some View {
        if directPaint {
            // Match the existing direct Direction Paint title, without a toggle action.
            Text(EditorText.brush.text).font(.headline)
                .accessibilityIdentifier("wss.mask.brush-title")
        } else {
            Toggle(
                EditorText.brush.text,
                isOn: Binding(get: { session.brushEnabled }, set: { session.setBrush($0) })
            )
            .toggleStyle(.button).help(EditorText.maskBrushHelp.text)
        }
    }
    private var displayedDiameter: Double {
        directPaint ? min(session.maximumDiameter, max(1, session.diameter)) : session.diameter
    }
    private var size: some View {
        HStack(spacing: 4) {
            Text(EditorText.brushSize.text).font(.caption)
            Slider(
                value: Binding(
                    get: { log2(displayedDiameter) }, set: { session.setDiameter(pow(2, $0)) }),
                in: 0...max(0.001, log2(session.maximumDiameter))
            ) {
                Text(EditorText.maskDiameter.text)
            }
            .labelsHidden()
            .frame(minWidth: 50, idealWidth: 75, maxWidth: 110)
            TextField(
                EditorText.brushSize.text,
                value: Binding(get: { displayedDiameter }, set: { session.setDiameter($0) }),
                format: .number.precision(.fractionLength(0...1))
            )
            .frame(width: 54).textFieldStyle(.roundedBorder).accessibilityLabel(
                EditorText.brushSizeAX.text)
            Text("px").font(.caption)
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var opacity: some View {
        HStack(spacing: 4) {
            Text(EditorText.maskOpacity.text).font(.caption)
            Slider(
                value: Binding(get: { session.opacity }, set: { session.setOpacity($0) }), in: 0...1
            ) {
                Text(EditorText.maskOpacityAX.text)
            }
            .labelsHidden()
            .frame(minWidth: 45, idealWidth: 65, maxWidth: 90)
            TextField(
                EditorText.maskOpacity.text,
                value: Binding(
                    get: { session.opacity * 100 }, set: { session.setOpacity($0 / 100) }),
                format: .number.precision(.fractionLength(0...1))
            )
            .frame(width: 48).textFieldStyle(.roundedBorder).accessibilityLabel(
                EditorText.maskOpacityPercent.text)
            Text("%").font(.caption)
        }.fixedSize(horizontal: true, vertical: false)
            .help(EditorText.maskOpacityHelp.text)
    }
    private var erase: some View {
        Text(EditorText.optionErase.text).font(.caption).help(EditorText.maskEraseHelp.text)
    }
}
