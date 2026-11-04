import SwiftUI

struct WallpaperRenameView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    let wallpaperID: UUID
    @State private var title: String
    @State private var error: String?
    @State private var saving = false
    @FocusState private var focused: Bool

    init(wallpaperID: UUID, currentTitle: String) {
        self.wallpaperID = wallpaperID
        _title = State(initialValue: currentTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ProductText.renameWallpaperTitle.text).font(.headline)
            TextField(ProductText.wallpaperName.text, text: $title)
                .accessibilityLabel(ProductText.wallpaperName.text)
                .focused($focused).disabled(saving)
                .onSubmit { save() }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
                    .accessibilityLabel(ProductText.wallpaperNameError.format(error))
            }
            HStack {
                Spacer()
                Button(ProductText.cancel.text) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? ProductText.saving.text : ProductText.save.text) { save() }
                    .keyboardShortcut(.defaultAction).disabled(saving)
            }
        }
        .padding(24).frame(width: 380)
        .interactiveDismissDisabled(saving)
        .onAppear { focused = true }
    }

    private func save() {
        guard !saving else { return }
        if let message = ProductCoreError.nameValidation(title) {
            self.error = message
            return
        }
        saving = true
        error = nil
        Task {
            do {
                try await library.rename(wallpaperID: wallpaperID, newTitle: title)
                dismiss()
            } catch {
                self.error = ProductText.renameError.text
                saving = false
            }
        }
    }
}
