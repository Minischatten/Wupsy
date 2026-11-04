import SwiftUI

/// Shared presentation and creation workflow for the overview and collection.
struct WallpaperActions: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var editors: WSSEditorCoordinator
    let importWallpaper: () -> Void

    var onFirstSave: ((UUID) -> Void)? = nil

    var body: some View {
        HStack {
            Button(ProductText.createWallpaper.text) {
                Task { await editors.newWallpaper(onFirstSave: onFirstSave) }
            }
            .buttonStyle(VioletButtonStyle())
            .disabled(!editors.canCreateWallpaper || library.importing)
            Button(action: importWallpaper) {
                Label(
                    library.importing ? ProductText.importing.text : ProductText.addWallpaper.text,
                    systemImage: "plus")
            }
            .buttonStyle(VioletButtonStyle()).disabled(library.importing)
        }
    }
}
