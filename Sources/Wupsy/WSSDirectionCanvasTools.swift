import SwiftUI

struct WSSDirectionBrushTools: View {
    @ObservedObject var document: WSSEditorDocument
    @ObservedObject var session: WSSDirectionCanvasSession
    init(document: WSSEditorDocument) {
        self.document = document
        session = document.directionCanvas
    }
    var body: some View {
        if session.brushEnabled {
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        title
                        size
                        magnitude
                        erase
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            title
                            size
                        }
                        HStack {
                            magnitude
                            erase
                        }
                    }
                }
                Text(session.dragHelp).wupsyFont(.caption).foregroundStyle(
                    .secondary)
                if let error = session.error {
                    Text(error).wupsyFont(.caption).foregroundStyle(.secondary)
                }
            }.wupsyPadding(.horizontal, 10).wupsyPadding(.bottom, 8)
                .disabled(
                    session.blocksDocumentActions || document.interactionLocked || document.saving
                        || document.saveAsBusy || document.importingImage
                )
                .accessibilityIdentifier("wss.direction.brush-tools")
        }
    }
    private var title: some View { Text(EditorText.brush.text).wupsyFont(.headline) }
    private var erase: some View {
        Text(EditorText.optionErase.text).wupsyFont(.caption).help(session.optionHelp)
    }
    private var size: some View {
        HStack(spacing: 4) {
            Text(EditorText.brushSize.text).wupsyFont(.caption)
            Slider(
                value: Binding(
                    get: { log2(session.diameter) }, set: { session.setDiameter(pow(2, $0)) }),
                in: log2(
                    session.minimumDiameter)...max(
                        log2(session.minimumDiameter) + 0.001, log2(session.maximumDiameter))
            )
            .frame(minWidth: 45, idealWidth: 65, maxWidth: 90).accessibilityLabel(
                EditorText.directionDiameter.text)
            TextField(
                EditorText.brushSize.text,
                value: Binding(get: { session.diameter }, set: { session.setDiameter($0) }),
                format: .number.precision(.fractionLength(0...1))
            )
            .frame(width: 54).textFieldStyle(.roundedBorder)
            .accessibilityLabel(EditorText.directionDiameter.text)
            Text("px").wupsyFont(.caption)
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var magnitude: some View {
        HStack(spacing: 4) {
            Text(EditorText.movementStrength.text).wupsyFont(.caption)
            Slider(
                value: Binding(
                    get: { Double(session.magnitude) }, set: { session.setMagnitude(Float($0)) }),
                in: 0...1
            )
            .frame(minWidth: 45, idealWidth: 65, maxWidth: 90).accessibilityLabel(
                EditorText.vectorMagnitude.text)
            Text("\(Int(session.magnitude * 100)) %").wupsyFont(.caption).monospacedDigit().frame(
                width: 38)
        }.fixedSize(horizontal: true, vertical: false)
    }
}
