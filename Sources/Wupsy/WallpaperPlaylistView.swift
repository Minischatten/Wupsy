import SwiftUI
import UniformTypeIdentifiers

struct WallpaperPlaylistView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var playlist: WallpaperPlaylist
    let playlistID: UUID
    private var definition: PlaylistDefinition {
        playlist.definition(playlistID)
            ?? PlaylistDefinition(id: playlistID, name: ProductText.playlistDefault.text)
    }
    @State private var dropTargetID: UUID?
    @State private var dropAtEnd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(definition.name).font(.largeTitle.weight(.semibold))
                    Text(
                        definition.playbackMode == .shuffle
                            ? ProductText.playlistShuffleHint.text
                            : ProductText.playlistOrderHint.text
                    )
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                    ProductText.playlistEnable.text,
                    isOn: Binding(
                        get: { playlist.activePlaylistID == playlistID },
                        set: { enabled in
                            if enabled {
                                playlist.activatePlaylist(id: playlistID)
                            } else {
                                playlist.deactivatePlaylist(id: playlistID)
                            }
                        }
                    )
                )
                .toggleStyle(.switch)
                .disabled(
                    !playlist.canEdit || playlist.pendingActivationID != nil
                        || (playlist.activePlaylistID != playlistID
                            && !playlist.canActivate(playlistID))
                )
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { playlistControls }
                VStack(alignment: .leading, spacing: 12) { playlistControls }
            }
            if playlist.activePlaylistID != nil || playlist.pendingActivationID != nil
                || playlist.error != nil
            {
                Text(playlist.status).font(.callout)
                    .foregroundStyle(playlist.error == nil ? Color.secondary : Color.orange)
                    .accessibilityIdentifier("playlistStatus")
            }
            Text(
                ProductText.playlistRotationHint.text
            )
            .font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 18) {
                GroupBox(ProductText.playlistOrder.text) {
                    Group {
                        if definition.wallpaperIDs.isEmpty {
                            ContentUnavailableView(
                                ProductText.playlistEmpty.text, systemImage: "list.number",
                                description: Text(ProductText.playlistAddHint.text))
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 6) {
                                    ForEach(
                                        Array(definition.wallpaperIDs.enumerated()),
                                        id: \.element
                                    ) { index, id in
                                        if let item = library.items.first(where: { $0.id == id }) {
                                            playlistRow(item, index: index)
                                                .dropDestination(for: PlaylistReorderItem.self) {
                                                    items, _ in
                                                    acceptDrop(items, before: id)
                                                } isTargeted: { targeted in
                                                    if targeted {
                                                        dropTargetID = id
                                                    } else if dropTargetID == id {
                                                        dropTargetID = nil
                                                    }
                                                }
                                                .overlay(alignment: .top) {
                                                    Rectangle().fill(WupsyTheme.accent).frame(
                                                        height: 2
                                                    )
                                                    .opacity(dropTargetID == id ? 1 : 0)
                                                    .allowsHitTesting(false)
                                                }
                                        }
                                    }
                                    Text(ProductText.playlistDropEnd.text)
                                        .font(.caption).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                        .contentShape(Rectangle())
                                        .overlay(alignment: .bottom) {
                                            Rectangle().fill(WupsyTheme.accent).frame(height: 2)
                                                .opacity(dropAtEnd ? 1 : 0).allowsHitTesting(false)
                                        }
                                        .dropDestination(for: PlaylistReorderItem.self) {
                                            items, _ in
                                            acceptDrop(items, before: nil)
                                        } isTargeted: {
                                            dropAtEnd = $0
                                        }
                                }
                            }.padding(8)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                GroupBox(ProductText.playlistFromLibrary.text) {
                    Group {
                        if library.items.isEmpty {
                            ContentUnavailableView(
                                ProductText.libraryEmpty.text, systemImage: "photo.on.rectangle",
                                description: Text(ProductText.playlistImportHint.text))
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 6) {
                                    ForEach(library.items) { item in
                                        HStack(spacing: 10) {
                                            WallpaperPreview(item: item).frame(
                                                width: 44, height: 32
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 5))
                                            Text(item.title).lineLimit(2)
                                            Spacer()
                                            Button {
                                                playlist.perform {
                                                    if definition.wallpaperIDs.contains(item.id) {
                                                        try playlist.remove(
                                                            item.id, from: playlistID)
                                                    } else {
                                                        try playlist.add(item.id, to: playlistID)
                                                    }
                                                }
                                            } label: {
                                                Image(
                                                    systemName: definition.wallpaperIDs
                                                        .contains(
                                                            item.id)
                                                        ? "checkmark" : "plus")
                                            }
                                            .accessibilityLabel(
                                                definition.wallpaperIDs.contains(item.id)
                                                    ? ProductText.playlistRemoveTitle.format(
                                                        item.title)
                                                    : ProductText.playlistAddTitle.format(
                                                        item.title)
                                            )
                                            .disabled(
                                                !playlist.canEditDefinition(playlistID)
                                            )
                                        }.buttonStyle(.borderless).padding(.vertical, 5)
                                            .accessibilityElement(children: .contain)
                                    }
                                }
                            }.padding(8)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(
                ProductText.playlistIntervalsHint.text
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(26).background(WupsyTheme.background)
        .onChange(of: playlistID) { _, _ in
            dropTargetID = nil
            dropAtEnd = false
        }
    }

    @ViewBuilder private var playlistControls: some View {
        Picker(
            ProductText.playlistChangeEvery.text,
            selection: Binding(
                get: { definition.intervalSeconds },
                set: { seconds in
                    playlist.perform { try playlist.setInterval(seconds, for: playlistID) }
                }
            )
        ) {
            ForEach(PlaylistDefinition.intervals, id: \.seconds) { interval in
                Text(interval.title).tag(interval.seconds)
            }
        }.frame(width: 280).disabled(!playlist.canEditDefinition(playlistID))
        Text(verbatim: definition.name).font(.callout).foregroundStyle(.secondary)
        Picker(
            ProductText.playlistPlaybackMode.text,
            selection: Binding(
                get: { definition.playbackMode },
                set: { mode in
                    playlist.perform {
                        try playlist.setPlaybackMode(playlistID: playlistID, mode: mode)
                    }
                }
            )
        ) {
            ForEach(PlaylistPlaybackMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .labelsHidden().frame(width: 130)
        .disabled(!playlist.canSetPlaybackMode(playlistID))
    }

    private func acceptDrop(_ items: [PlaylistReorderItem], before target: UUID?) -> Bool {
        guard items.count == 1 else { return false }
        let accepted = playlist.acceptDrop(items[0], before: target, in: playlistID)
        dropTargetID = nil
        dropAtEnd = false
        return accepted
    }

    private func playlistRow(_ item: Wallpaper, index: Int) -> some View {
        HStack(spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 32)
                    .contentShape(Rectangle())
                    .help(ProductText.playlistDrag.text)
                    .accessibilityLabel(ProductText.playlistDragTitle.format(item.title))
                Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                WallpaperPreview(item: item).frame(width: 44, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).lineLimit(2)
                    if playlist.pendingWallpaperID == item.id,
                        playlist.pendingActivationID == playlistID
                            || playlist.activePlaylistID == playlistID
                    {
                        Text(ProductText.preparing.text).font(.caption).foregroundStyle(.secondary)
                    } else if playlist.activePlaylistID == playlistID,
                        playlist.state.playback?.currentWallpaperID == item.id,
                        library.active?.id == item.id
                    {
                        Label(ProductText.playlistCurrent.text, systemImage: "play.fill").font(
                            .caption
                        )
                        .foregroundStyle(WupsyTheme.lavender)
                    }
                }
                Spacer(minLength: 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .draggable(PlaylistReorderItem(sourcePlaylistID: playlistID, wallpaperID: item.id)) {
                Label(item.title, systemImage: "line.3.horizontal").padding(8)
            }
            .disabled(!playlist.canEditDefinition(playlistID))
            Button {
                playlist.perform { try playlist.remove(item.id, from: playlistID) }
            } label: {
                Image(systemName: "xmark.circle")
            }
            .help(ProductText.playlistRemove.text)
            .accessibilityLabel(ProductText.playlistRemoveTitle.format(item.title))
            .disabled(!playlist.canEditDefinition(playlistID))
        }.buttonStyle(.borderless)
            .accessibilityElement(children: .contain)
            .contextMenu {
                Button(ProductText.moveUp.text) {
                    playlist.perform { try playlist.move(item.id, by: -1, in: playlistID) }
                }
                .disabled(!playlist.canEditDefinition(playlistID) || index == 0)
                Button(ProductText.moveDown.text) {
                    playlist.perform { try playlist.move(item.id, by: 1, in: playlistID) }
                }
                .disabled(
                    !playlist.canEditDefinition(playlistID)
                        || index == definition.wallpaperIDs.count - 1)
            }
            .accessibilityActions {
                if playlist.canEditDefinition(playlistID), index > 0 {
                    Button(ProductText.moveUp.text) {
                        playlist.perform { try playlist.move(item.id, by: -1, in: playlistID) }
                    }
                }
                if playlist.canEditDefinition(playlistID), index < definition.wallpaperIDs.count - 1
                {
                    Button(ProductText.moveDown.text) {
                        playlist.perform { try playlist.move(item.id, by: 1, in: playlistID) }
                    }
                }
            }
    }
}

extension UTType {
    fileprivate static let wupsyPlaylistEntry = UTType(
        exportedAs: "com.wirdschonsoftware.wupsy.playlist-entry")
}

/// Carries existing Library identity only, never a title, position or media copy.
struct PlaylistReorderItem: Codable, Transferable {
    let sourcePlaylistID: UUID
    let wallpaperID: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .wupsyPlaylistEntry)
    }
}
