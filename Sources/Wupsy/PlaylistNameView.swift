import SwiftUI

struct PlaylistNameView: View {
    @EnvironmentObject private var playlist: WallpaperPlaylist
    @Environment(\.dismiss) private var dismiss
    let playlistID: UUID?
    let completed: () -> Void
    @State private var name: String
    @State private var error: String?
    @State private var saving = false
    @FocusState private var focused: Bool

    init(playlistID: UUID?, currentName: String, completed: @escaping () -> Void) {
        self.playlistID = playlistID
        self.completed = completed
        _name = State(initialValue: currentName)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(
                playlistID == nil
                    ? ProductText.playlistNewTitle.text : ProductText.playlistRenameTitle.text
            ).font(.headline)
            TextField(ProductText.playlistName.text, text: $name).focused($focused)
                .accessibilityLabel(ProductText.playlistName.text).onSubmit { save() }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).accessibilityLabel(
                    ProductText.playlistNameError.format(error))
            }
            HStack {
                Spacer()
                Button(ProductText.cancel.text) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(playlistID == nil ? ProductText.create.text : ProductText.save.text) {
                    save()
                }.keyboardShortcut(
                    .defaultAction)
            }
        }.padding(24).frame(width: 380).onAppear { focused = true }
    }
    private func save() {
        guard !saving else { return }
        if let message = ProductCoreError.nameValidation(name) {
            self.error = message
            return
        }
        saving = true
        do {
            if let playlistID {
                try playlist.renamePlaylist(id: playlistID, newName: name)
            } else {
                try playlist.createPlaylist(name: name)
            }
            completed()
            dismiss()
        } catch {
            self.error = ProductText.playlistActionError.text
            saving = false
        }
    }
}
