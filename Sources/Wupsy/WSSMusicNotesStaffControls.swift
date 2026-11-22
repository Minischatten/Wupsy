import SwiftUI

enum WSSMusicNotesStaffInputError: LocalizedError {
    case widthMustBeLessThanSpacing

    var errorDescription: String? { WSSMusicNotesText.text("staffWidthLessThanSpacing") }
}

extension WSSEditorDocument {
    func beginMusicNotesStaffOpacity(_ id: WSSLayerID) -> Bool {
        guard permitsStructureEditing, finishEditing(),
            let staff = musicNotesLayer(id)?.staff, staff.enabled
        else { return false }
        musicNotesStaffOpacityDrag = (id, staff.opacity)
        return true
    }

    func setMusicNotesStaffOpacity(_ id: WSSLayerID, value: Float) throws {
        guard musicNotesStaffOpacityDrag?.layer == id else {
            try changeMusicNotesStaff(id, name: WSSMusicNotesText.text("staffOpacity")) {
                $0.opacity = value
            }
            return
        }
        try applyMusicNotesStaff(id, name: WSSMusicNotesText.text("staffOpacity"), undo: false) {
            $0.opacity = value
        }
    }

    func endMusicNotesStaffOpacity() {
        guard let drag = musicNotesStaffOpacityDrag else { return }
        musicNotesStaffOpacityDrag = nil
        guard let index = identity.layers.firstIndex(where: { $0.id == drag.layer }),
            var layer = musicNotesLayer(drag.layer),
            let staff = layer.staff, staff.opacity != drag.opacity
        else { return }
        layer.staff?.opacity = drag.opacity
        var before = state.workingModel
        before.layers[index].content = .musicNotes(layer)
        registerModelUndo(before, name: WSSMusicNotesText.text("staffOpacity"))
        objectWillChange.send()
    }

    func changeMusicNotesStaff(
        _ id: WSSLayerID, name: String, change: (inout WSSMusicNotesStaff) -> Void
    ) throws {
        guard permitsStructureEditing, finishParameterInteractions() else { return }
        try applyMusicNotesStaff(id, name: name, undo: true, change: change)
    }

    private func applyMusicNotesStaff(
        _ id: WSSLayerID, name: String, undo: Bool,
        change: (inout WSSMusicNotesStaff) -> Void
    ) throws {
        guard permitsStructureEditing,
            let index = identity.layers.firstIndex(where: { $0.id == id }),
            var layer = musicNotesLayer(id)
        else { return }
        let previous = layer.staff ?? .init()
        var staff = previous
        change(&staff)
        guard staff != previous else { return }

        if staff.width >= staff.spacing {
            throw WSSMusicNotesStaffInputError.widthMustBeLessThanSpacing
        }
        try staff.validate()
        layer.staff = staff

        var model = state.workingModel
        model.layers[index].content = .musicNotes(layer)
        try mutate(model, name: name, undo: undo)
    }
}

struct WSSMusicNotesStaffControls: View {
    @ObservedObject var document: WSSEditorDocument
    let layer: WSSLayerID
    let value: WSSMusicNotesLayer
    @State private var opacityGestureRejected = false
    @State private var error: String?

    private var staff: WSSMusicNotesStaff { value.staff ?? .init() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(WSSMusicNotesText.text("staffTitle")).wupsyFont(.headline)
            Toggle(
                WSSMusicNotesText.text("staffEnabled"),
                isOn: Binding(
                    get: { staff.enabled },
                    set: { update("staffEnabled", \.enabled, $0) })
            )
            .accessibilityIdentifier("wss.musicNotes.staff.enabled")
            if staff.enabled {
                field("staffSpacing", \.spacing, range: WSSMusicNotesStaff.spacingRange)
                field("staffWidth", \.width, range: WSSMusicNotesStaff.widthRange)
                let color = WSSMusicNotesText.text("staffColor")
                HStack {
                    Text(color).wupsyFont(.caption)
                    Spacer()
                    WSSNativeSDRColorWell(color: staff.color, title: color) {
                        update("staffColor", \.color, $0)
                    }
                    .wupsyControlFrame(width: 50, height: 24)
                }
                Slider(
                    value: Binding(
                        get: { Double(staff.opacity) },
                        set: { opacity in
                            guard !opacityGestureRejected else { return }
                            if document.musicNotesStaffOpacityDrag == nil, !document.finishEditing()
                            {
                                return
                            }
                            perform {
                                try document.setMusicNotesStaffOpacity(layer, value: Float(opacity))
                            }
                        }),
                    in: 0...1
                ) {
                    Text(WSSMusicNotesText.text("staffOpacity")).wupsyFont(.caption)
                } onEditingChanged: { editing in
                    if editing {
                        opacityGestureRejected = !document.beginMusicNotesStaffOpacity(layer)
                    } else {
                        document.endMusicNotesStaffOpacity()
                        opacityGestureRejected = false
                    }
                }
                .accessibilityIdentifier("wss.musicNotes.staff.opacitySlider")
                field("staffOpacity", \.opacity, range: 0...1)
                if (try? value.preparedStaff())?.hasTightTurns == true {
                    Text(WSSMusicNotesText.text("staffTightTurns"))
                        .wupsyFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error {
                Text(error).wupsyFont(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func field(
        _ key: String, _ property: WritableKeyPath<WSSMusicNotesStaff, Float>,
        range: ClosedRange<Float>
    ) -> some View {
        let title = WSSMusicNotesText.text(key)
        let bounds = "\(range.lowerBound.formatted())–\(range.upperBound.formatted())"
        return HStack {
            VStack(alignment: .leading) {
                Text(title).wupsyFont(.caption)
                Text(bounds).wupsyFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            WSSParameterTextField(
                value: staff[keyPath: property], range: range, title: "\(title) (\(bounds))",
                maximumFractionDigits: 3
            ) { value in
                try document.changeMusicNotesStaff(layer, name: title) {
                    $0[keyPath: property] = value
                }
            }
            .wupsyControlFrame(width: 100)
            .accessibilityIdentifier("wss.musicNotes.\(key)")
        }
    }

    private func update<T>(
        _ key: String, _ property: WritableKeyPath<WSSMusicNotesStaff, T>, _ value: T
    ) {
        guard document.finishEditing() else { return }
        perform {
            try document.changeMusicNotesStaff(layer, name: WSSMusicNotesText.text(key)) {
                $0[keyPath: property] = value
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = EditorErrorPresentation.message(error)
        }
    }
}
