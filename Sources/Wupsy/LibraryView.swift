import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.wupsyMetrics) private var metrics
    private var sidebarMinimum: CGFloat {
        min(280, metrics.points(LibrarySidebarLayout.minimumWidth))
    }
    private enum ImportDropTarget: Equatable {
        case card(UUID)
        case gridEnd
    }

    @ObservedObject private var maintenance = MaintenanceCoordinator.shared
    @EnvironmentObject var library: Library
    @EnvironmentObject var editors: WSSEditorCoordinator
    @EnvironmentObject var widgets: DesktopWidgets
    @EnvironmentObject var playlist: WallpaperPlaylist
    @AppStorage("playlistsExpanded") private var playlistsExpanded = true
    @State private var playlistDialog: PlaylistDialogTarget?
    @State private var deletingPlaylist: PlaylistDefinition?
    @State private var renameTarget: Wallpaper?
    @State private var page: LibraryPage = .overview
    @State private var search = ""
    @State private var filter: WallpaperFilter = .all
    @State private var favoritesOnly = false
    @StateObject private var reorder = LibraryReorderController()
    @State private var showCompatibility = false
    @State private var showQualityHelp = false
    @State private var isBackgroundDropTarget = false
    @State private var importDropTarget: ImportDropTarget?
    @State private var gridWidth: CGFloat = 0
    private var gridMinimum: CGFloat { 178 + metrics.spacing(32) - 32 }
    private var gridColumns: Int {
        LibraryGridLayout.columnCount(width: gridWidth, minimum: gridMinimum)
    }
    @StateObject private var collectionFocus = LibraryCollectionFocus()
    private var filtered: [Wallpaper] {
        let list = library.items.filter { item in
            filter.accepts(item) && (!favoritesOnly || library.favorites.contains(item.id))
                && (search.isEmpty || item.title.localizedCaseInsensitiveContains(search))
        }
        return LibraryOrder.visible(list)
    }
    private var selected: Wallpaper? {
        filtered.first { $0.id == library.selected } ?? filtered.first
    }
    var body: some View {
        NavigationSplitView {
            sidebar
                .frame(
                    minWidth: sidebarMinimum,
                    maxWidth: metrics.points(LibrarySidebarLayout.maximumWidth)
                )
                .navigationSplitViewColumnWidth(
                    min: sidebarMinimum, ideal: metrics.points(LibrarySidebarLayout.idealWidth),
                    max: metrics.points(LibrarySidebarLayout.maximumWidth))
        } detail: {
            // Keep changing content's intrinsic width out of split-column sizing.
            GeometryReader { geometry in
                detail.frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .disabled(!maintenance.allowsNewOperations)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .tint(WupsyTheme.accent)
        .onChange(of: library.favorites) { _, _ in synchronizeSelection() }
        .onChange(of: library.items.map(\.id)) { _, _ in synchronizeSelection() }
        .onChange(of: filter) { _, _ in
            reorder.invalidate()
            synchronizeSelection()
        }
        .onChange(of: favoritesOnly) { _, _ in
            reorder.invalidate()
            synchronizeSelection()
        }
        .onChange(of: search) { _, _ in
            reorder.invalidate()
            synchronizeSelection()
        }
        .onChange(of: filtered.map(\.id)) { _, _ in reorder.invalidate() }
        .onChange(of: page) { _, _ in reorder.invalidate() }
        .onChange(of: maintenance.state) { _, _ in reorder.invalidate() }
        .onDisappear { reorder.invalidate() }
        .onAppear { synchronizeSelection() }
        .alert(
            "Wupsy",
            isPresented: Binding(
                get: { library.message != nil }, set: { if !$0 { library.message = nil } })
        ) {
            Button(ProductText.ok.text) { library.message = nil }
        } message: {
            Text(library.messagePresentation ?? library.message ?? "")
        }
        .sheet(item: $library.importFailureReport) { report in
            ImportFailureView(report: report).id(report.id)
        }
        .sheet(item: $renameTarget) { item in
            WallpaperRenameView(wallpaperID: item.id, currentTitle: item.title)
                .environmentObject(library)
        }
        .sheet(item: $playlistDialog) { target in
            PlaylistNameView(playlistID: target.playlistID, currentName: target.name) {
                page = .playlist
                playlistsExpanded = true
            }
            .environmentObject(playlist)
        }
        .alert(
            ProductText.deletePlaylist.text,
            isPresented: Binding(
                get: { deletingPlaylist != nil }, set: { if !$0 { deletingPlaylist = nil } }
            )
        ) {
            Button(ProductText.cancel.text, role: .cancel) { deletingPlaylist = nil }
            Button(ProductText.delete.text, role: .destructive) {
                if let id = deletingPlaylist?.id {
                    playlist.perform { try playlist.deletePlaylist(id: id) }
                }
                deletingPlaylist = nil
            }
        } message: {
            Text(
                ProductText.deletePlaylistMessage.format(deletingPlaylist?.name ?? "")
            )
        }
        .sheet(isPresented: $showCompatibility) { compatibility }
    }
    private var detail: some View {
        Group {
            if page == .playlist {
                if let id = playlist.selectedPlaylistID {
                    WallpaperPlaylistView(playlistID: id).id(id)
                } else {
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            ProductText.noPlaylists.text, systemImage: "list.number",
                            description: Text(
                                playlist.presentedError
                                    ?? ProductText.createPlaylistHint.text))
                        Button(ProductText.newPlaylistAction.text) {
                            playlistDialog = PlaylistDialogTarget()
                        }
                        .disabled(!playlist.canEdit)
                    }.wupsyPadding(.all, 26)
                }
            } else if page == .widgets {
                WidgetStudio(widgets: widgets)
            } else if page == .overview {
                StudioOverview(
                    library: library, widgets: widgets, showWallpapers: { page = .wallpapers },
                    showWidgets: { page = .widgets },
                    importWallpaper: { library.importFiles(onSuccess: revealWallpaper) },
                    revealWallpaper: revealWallpaper)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let selected {
                        WallpaperHero(
                            item: selected, isFavorite: library.favorites.contains(selected.id),
                            isActive: library.active?.id == selected.id,
                            preparing: library.preparing,
                            favorite: { library.toggleFavorite(selected) },
                            apply: { library.apply(selected) })
                    } else {
                        emptyState
                    }
                    collectionToolbar
                    ScrollViewReader { scroll in
                        ScrollView {
                            VStack(spacing: 0) {
                                LazyVGrid(
                                    columns: Array(
                                        repeating: GridItem(
                                            .flexible(
                                                minimum: min(gridMinimum, gridWidth), maximum: 270),
                                            spacing: LibraryGridLayout.columnSpacing),
                                        count: gridColumns),
                                    spacing: metrics.spacing(16)
                                ) {
                                    ForEach(filtered) { item in
                                        wallpaperCard(
                                            item,
                                            navigate: { direction in
                                                moveSelection(
                                                    direction, scroll: scroll, from: item.id)
                                            }
                                        )
                                        .id(item.id)
                                    }
                                }
                                .background(LibraryDragScroll(controller: reorder))
                                .wupsyPadding(.bottom, 4)
                                if let last = filtered.last {
                                    Color.clear.frame(height: 28).contentShape(Rectangle())
                                        .overlay(alignment: .top) {
                                            if reorder.insertion
                                                == LibraryInsertion(
                                                    targetID: last.id, placement: .after)
                                            {
                                                Rectangle().fill(WupsyTheme.accent).frame(height: 3)
                                            }
                                        }
                                        .onDrop(
                                            of: LibraryCardDrop.types,
                                            delegate: gridEndDrop(last.id)
                                        )
                                        .onDisappear {
                                            setImportDropTarget(.gridEnd, active: false)
                                        }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .onGeometryChange(for: CGFloat.self) {
                                $0.size.width
                            } action: {
                                gridWidth = $0
                            }
                        }
                        .background(
                            LibraryCollectionResponder(
                                focus: collectionFocus, remove: removeSelectedWallpaper,
                                rename: renameSelectedWallpaper,
                                navigate: { moveSelection($0, scroll: scroll) }
                            )
                            .allowsHitTesting(false))
                    }
                    footer
                }.wupsyPadding(.all, 26).background(WupsyTheme.background)
                    .onDrop(
                        of: [UTType.fileURL.identifier], isTargeted: $isBackgroundDropTarget,
                        perform: receiveDrop
                    )
                    .overlay {
                        if isBackgroundDropTarget || importDropTarget != nil { dropOverlay }
                    }
            }
        }
    }

    private func gridEndDrop(_ id: UUID) -> LibraryCardDrop {
        LibraryCardDrop(
            controller: reorder, targetID: id, width: 1, end: true,
            library: library, visibleIDs: { filtered.map(\.id) }, importFiles: receiveDrop,
            importTargetChanged: { setImportDropTarget(.gridEnd, active: $0) })
    }

    private func setImportDropTarget(_ target: ImportDropTarget, active: Bool) {
        if active {
            if importDropTarget != target { importDropTarget = target }
        } else if importDropTarget == target {
            importDropTarget = nil
        }
    }

    private func moveSelection(
        _ direction: LibraryGridDirection, scroll: ScrollViewProxy, from focusedID: UUID? = nil
    ) {
        guard maintenance.allowsNewOperations else { return }
        let items = filtered
        let currentID = focusedID ?? library.selected
        let index = items.firstIndex { $0.id == currentID }
        guard
            let destination = direction.destination(
                from: index, count: items.count, columns: gridColumns)
        else { return }
        let id = items[destination].id
        library.selected = id
        if focusedID != nil { collectionFocus.focus() }
        scroll.scrollTo(id)
    }

    private func wallpaperCard(
        _ item: Wallpaper, navigate: @escaping (LibraryGridDirection) -> Void
    ) -> some View {
        WallpaperCard(
            item: item, isSelected: selected?.id == item.id,
            isActive: library.active?.id == item.id,
            isFavorite: library.favorites.contains(item.id),
            select: {
                library.selected = item.id
                collectionFocus.focus()
            },
            apply: { library.apply(item) },
            favorite: { library.toggleFavorite(item) },
            navigate: navigate,
            reorderItem: reorder.isMoving
                ? nil
                : LibraryReorderItem(
                    contextID: reorder.contextID, wallpaperID: item.id)
        )
        .modifier(
            LibraryCardDropModifier(
                controller: reorder, targetID: item.id, library: library,
                visibleIDs: { filtered.map(\.id) }, importFiles: receiveDrop,
                importTargetChanged: { setImportDropTarget(.card(item.id), active: $0) })
        )
        .contextMenu {
            if item.canOpenInEditor {
                Button(ProductText.editWallpaper.text) {
                    Task {
                        do {
                            try await editors.open(wallpaperID: item.id)
                        } catch is CancellationError {} catch {
                            library.presentWallpaperFailure(
                                error, item: item, operation: .editorOpenError)
                        }
                    }
                }
            }
            Button(ProductText.renameAction.text) { renameTarget = item }
            Button(ProductText.applyWallpaper.text) { library.apply(item) }
            Button(
                library.favorites.contains(item.id)
                    ? ProductText.removeFavorite.text : ProductText.addFavorite.text
            ) { library.toggleFavorite(item) }
            Menu(ProductText.addPlaylist.text) {
                if playlist.state.definitions.isEmpty {
                    Text(ProductText.createPlaylistFirst.text)
                }
                ForEach(playlist.state.definitions) { definition in
                    Button {
                        playlist.perform {
                            try playlist.add(item.id, to: definition.id)
                        }
                    } label: {
                        if definition.wallpaperIDs.contains(item.id) {
                            Label(definition.name, systemImage: "checkmark")
                        } else {
                            Text(definition.name)
                        }
                    }
                    .disabled(
                        !playlist.canEditDefinition(definition.id)
                            || definition.wallpaperIDs.contains(item.id))
                }
            }
            Divider()
            Button(ProductText.showFinder.text) {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Button(
                item.ownership == .managed
                    ? ProductText.removeManaged.text
                    : ProductText.removeExternal.text, role: .destructive
            ) { library.remove(item) }
            .help(
                item.ownership == .managed
                    ? ProductText.managedRemoveHint.text : ProductText.externalRemoveHint.text)
        }
    }

    private func renameSelectedWallpaper() {
        guard library.maintenance.allowsNewOperations, renameTarget == nil,
            let item = filtered.first(where: { $0.id == library.selected })
        else { return }
        renameTarget = item
    }

    private func removeSelectedWallpaper() {
        guard let item = filtered.first(where: { $0.id == library.selected }),
            library.canRemove(item)
        else { return }
        library.remove(item)
    }
    private func revealWallpaper(_ id: UUID) {
        search = ""
        filter = .all
        favoritesOnly = false
        library.selected = id
        page = .wallpapers
    }
    private func synchronizeSelection() { library.selected = selected?.id }
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                headerTitle
                Spacer()
                headerActions
            }
            VStack(alignment: .leading, spacing: 12) {
                headerTitle
                headerActions
            }
        }
    }
    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Eyebrow(text: ProductText.personalSpace.text)
            Text(ProductText.atmosphere.text).wupsyFont(
                size: 29, weight: .semibold, design: .rounded)
            Text(ProductText.atmosphereHint.text).wupsyFont(.subheadline).foregroundStyle(
                .secondary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var headerActions: some View {
        WallpaperActions(importWallpaper: library.importFiles)
    }

    private var collectionToolbar: some View {
        VStack(spacing: 13) {
            HStack(spacing: 7) {
                Text(favoritesOnly ? ProductText.favorites.text : ProductText.collection.text)
                    .wupsyFont(size: 14, weight: .semibold)
                Text(ProductText.wallpaperCount.format(Int64(filtered.count))).wupsyFont(
                    size: 10, weight: .medium
                ).foregroundStyle(
                    WupsyTheme.lavender
                ).wupsyPadding(.horizontal, 7).wupsyPadding(.vertical, 3).background(
                    WupsyTheme.accent.opacity(0.12), in: Capsule())
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(ProductText.searchWallpapers.text, text: $search).textFieldStyle(
                        .plain)
                }.wupsyFont(size: 11).wupsyPadding(.all, 8).wupsyControlFrame(width: 185)
                    .background(
                        WupsyTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            if metrics.scale == .standard {
                categoryButtons
            } else {
                ScrollView(.horizontal) { categoryButtons }
            }
        }
    }

    private var categoryButtons: some View {
        HStack(spacing: metrics.spacing(6)) {
            ForEach(WallpaperFilter.allCases) { category in
                Button {
                    filter = category
                } label: {
                    Text(category.title).wupsyFont(size: 10, weight: .medium).wupsyPadding(
                        .horizontal, 13
                    ).wupsyPadding(.vertical, 7)
                        .foregroundStyle(
                            filter == category ? WupsyTheme.lavender : Color.secondary
                        )
                        .background(
                            filter == category
                                ? WupsyTheme.accent.opacity(0.16) : Color.clear, in: Capsule()
                        )
                        .overlay(
                            Capsule().stroke(
                                filter == category
                                    ? WupsyTheme.accent.opacity(0.3)
                                    : Color.white.opacity(0.06)))
                }.buttonStyle(.plain).accessibilityLabel(
                    ProductText.filterLabel.format(category.title))
            }
            if metrics.scale == .standard { Spacer() }
        }
    }
    private var sidebar: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 11) {
                        Image(systemName: "sparkles.rectangle.stack.fill").wupsyFont(size: 23)
                            .foregroundStyle(WupsyTheme.lavender).frame(width: 38, height: 38)
                            .background(
                                WupsyTheme.accent.opacity(0.13),
                                in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Wupsy").wupsyFont(size: 22, weight: .semibold, design: .rounded)
                            Text(ProductText.studioTagline.text).wupsyFont(size: 7, weight: .medium)
                                .tracking(1.2).foregroundStyle(.secondary)
                        }
                    }.wupsyPadding(.vertical, 8)
                    VStack(alignment: .leading, spacing: 7) {
                        Eyebrow(text: ProductText.studio.text).wupsyPadding(.bottom, 3)
                        navigationRow(
                            ProductText.navOverview.text, icon: "rectangle.grid.1x2", count: -1,
                            active: page == .overview
                        ) { page = .overview }
                        navigationRow(
                            ProductText.navWidgets.text, icon: "rectangle.3.group",
                            count: widgets.enabledCount,
                            active: page == .widgets, countResource: .widgetCount
                        ) { page = .widgets }
                        navigationRow(
                            ProductText.navAll.text, icon: "square.grid.2x2",
                            count: library.items.count,
                            active: page == .wallpapers && !favoritesOnly
                        ) {
                            page = .wallpapers
                            favoritesOnly = false
                        }
                        navigationRow(
                            ProductText.favorites.text, icon: "heart",
                            count: library.favorites.count,
                            active: page == .wallpapers && favoritesOnly
                        ) {
                            page = .wallpapers
                            favoritesOnly = true
                        }
                    }
                    DisclosureGroup(isExpanded: $playlistsExpanded) {
                        VStack(spacing: 3) {
                            ForEach(playlist.state.definitions) { definition in
                                playlistNavigationRow(definition)
                            }
                            if playlist.state.definitions.isEmpty {
                                Text(ProductText.noPlaylistsYet.text).wupsyFont(.caption)
                                    .foregroundStyle(.secondary)
                                    .wupsyPadding(.vertical, 8)
                            }
                        }.wupsyPadding(.top, 6)
                    } label: {
                        Label(ProductText.playlists.text, systemImage: "list.number").wupsyFont(
                            size: 11, weight: .medium)
                    }
                    .disclosureGroupStyle(
                        PlaylistHeaderDisclosureStyle(count: playlist.state.definitions.count)
                    )
                    .contextMenu {
                        Button(ProductText.newPlaylistAction.text) {
                            playlistDialog = PlaylistDialogTarget()
                        }
                        .disabled(!playlist.canEdit)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Eyebrow(text: ProductText.pictureQualityHeader.text)
                            Spacer()
                            Button {
                                showQualityHelp.toggle()
                            } label: {
                                Image(systemName: "info.circle").wupsyFont(.caption)
                                    .foregroundStyle(
                                        .secondary)
                            }.buttonStyle(.plain).help(ProductText.qualityHelp.text).popover(
                                isPresented: $showQualityHelp
                            ) { qualityHelp }
                        }
                        Text(ProductText.qualityProfile.text).wupsyFont(.caption).foregroundStyle(
                            .secondary)
                        qualityPicker.pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .labelsHidden().wupsyControlSize(.small)
                        Label(
                            library.profile.detail,
                            systemImage: library.profile == .original ? "checkmark.shield" : "leaf"
                        )
                        .wupsyFont(size: 10).foregroundStyle(WupsyTheme.lavender)
                        .fixedSize(horizontal: false, vertical: true)
                        if library.profile != .original {
                            Text(ProductText.reducedQualityHint.text)
                                .wupsyFont(.caption2).foregroundStyle(.secondary)
                        }
                        if library.active?.kind == .scene || selected?.kind == .scene {
                            Divider()
                            Text(ProductText.sceneRenderScope.text)
                                .wupsyFont(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Text(ProductText.sceneResolution.text).wupsyFont(.caption)
                                Spacer()
                                Picker(
                                    ProductText.sceneResolution.text,
                                    selection: $library.sceneRenderResolution
                                ) {
                                    ForEach(SceneRenderResolution.allCases) { resolution in
                                        Text(resolution.title).tag(resolution)
                                    }
                                }.pickerStyle(.menu).labelsHidden().wupsyControlSize(.small)
                                    .frame(width: 100)
                                    .help(ProductText.resolutionHelp.text)
                            }
                            HStack {
                                Text(ProductText.sceneMotion.text).wupsyFont(.caption)
                                Spacer()
                                Picker(ProductText.sceneMotion.text, selection: $library.sceneFPS) {
                                    Text(ProductText.fps24.text).tag(24)
                                    Text(ProductText.fps30.text).tag(30)
                                    Text(ProductText.fps60.text).tag(60)
                                }.pickerStyle(.menu).labelsHidden().wupsyControlSize(.small)
                                    .frame(width: 100)
                                    .help(ProductText.motionHelp.text)
                            }
                            Text(ProductText.sceneProfileLimit.text)
                                .wupsyFont(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.wupsyPadding(.all, 13).background(
                        WupsyTheme.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 12)
                    ).overlay(
                        RoundedRectangle(cornerRadius: 12).stroke(WupsyTheme.accent.opacity(0.14))
                    )
                    Spacer(minLength: 12)
                    nowPlaying
                    HStack {
                        Button {
                            showCompatibility = true
                        } label: {
                            Label(ProductText.formatGuide.text, systemImage: "questionmark.circle")
                        }.buttonStyle(.plain)
                        Spacer()
                        Menu {
                            Button(ProductText.performanceTitle.text) {
                                library.openPerformancePanel()
                            }
                            .accessibilityIdentifier("desktop-performance-menu")
                            Divider()
                            Button(ProductText.clearOptimized.text) { library.clearCache() }
                                .help(ProductText.clearCacheHelp.text)
                                .accessibilityHint(ProductText.clearCacheHelp.text)
                            Text(ProductText.originalsPreserved.text)
                            Divider()
                            SettingsLink { Text(ProductText.openSettings.text) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }.menuStyle(.borderlessButton).fixedSize().help(
                            ProductText.clearCacheHelp.text
                        )
                        .accessibilityLabel(ProductText.maintenanceHelp.text)
                    }.wupsyFont(size: 10).foregroundStyle(.secondary)
                }
                // Constrain the whole scroll content, not just one disclosure row.
                // A control's intrinsic width must not widen or crop every sibling.
                .frame(
                    width: LibrarySidebarLayout.contentWidth(for: geometry.size.width),
                    alignment: .leading
                )
                .padding(LibrarySidebarLayout.inset)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }.background(WupsyTheme.surface.ignoresSafeArea(edges: .top))
        }
    }
    private var qualityPicker: some View {
        Picker(ProductText.qualityProfile.text, selection: $library.profile) {
            ForEach(QualityProfile.allCases) { Text($0.title).tag($0) }
        }
    }
    private func playlistNavigationRow(_ definition: PlaylistDefinition) -> some View {
        Button {
            playlist.select(definition.id)
            page = .playlist
        } label: {
            HStack(spacing: 9) {
                Text(definition.name).lineLimit(1)
                Spacer(minLength: 2)
                if playlist.pendingActivationID == definition.id {
                    ProgressView().wupsyControlSize(.mini).accessibilityLabel(
                        ProductText.playlistActivating.format(definition.name))
                } else if playlist.activePlaylistID == definition.id {
                    Image(systemName: "play.fill").accessibilityLabel(
                        ProductText.activePlaylist.text)
                }
            }
            .wupsyFont(size: 11, weight: .medium)
            .wupsyPadding(.horizontal, 11).wupsyPadding(.vertical, 10)
            .background(
                page == .playlist && playlist.selectedPlaylistID == definition.id
                    ? WupsyTheme.accent.opacity(0.13) : .clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                playlist.select(definition.id)
                page = .playlist
                playlist.activatePlaylist(id: definition.id)
            }
        )
        .help(ProductText.playlistClickHelp.text)
        .accessibilityAction(named: ProductText.activatePlaylist.text) {
            playlist.activatePlaylist(id: definition.id)
        }
        .contextMenu {
            Button(ProductText.renameAction.text) {
                playlistDialog = PlaylistDialogTarget(
                    playlistID: definition.id, name: definition.name)
            }
            .disabled(!playlist.canEdit)
            Button(ProductText.deleteAction.text, role: .destructive) {
                deletingPlaylist = definition
            }
            .disabled(!playlist.canDelete(definition.id))
        }
    }

    private func navigationRow(
        _ title: String, icon: String, count: Int, active: Bool,
        countResource: ProductText = .wallpaperCount, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 16)
                Text(title)
                Spacer(minLength: 4)
                if count >= 0 {
                    Text("\(count)").accessibilityLabel(
                        countResource.format(Int64(count))
                    ).fixedSize().wupsyFont(size: 10).monospacedDigit().foregroundStyle(
                        active ? WupsyTheme.lavender : .secondary)
                }
            }
            .wupsyFont(size: 11, weight: .medium).foregroundStyle(
                active ? WupsyTheme.lavender : Color.secondary
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .wupsyPadding(.horizontal, 11).wupsyPadding(.vertical, 11).background(
                active ? WupsyTheme.accent.opacity(0.13) : .clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 11) {
            Eyebrow(
                text: library.active == nil
                    ? ProductText.readyHeader.text : ProductText.onDesktopHeader.text)
            if playlist.activePlaylistID != nil || playlist.pendingActivationID != nil {
                Text(playlist.status).wupsyFont(.caption2).foregroundStyle(
                    WupsyTheme.lavender)
            }
            if let active = library.active {
                HStack(spacing: 9) {
                    WallpaperPreview(item: active).frame(width: 38, height: 38).clipShape(
                        RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(active.title).wupsyFont(size: 11, weight: .medium).lineLimit(1)
                        Text(ProductText.qualityLabel.format(library.profile.title)).wupsyFont(
                            size: 9
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 6) {
                Circle().fill(
                    library.playbackStatus.isPlaying ? WupsyTheme.accent : .secondary
                ).frame(width: 5, height: 5)
                Text(library.status).wupsyFont(size: 9).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            HStack(spacing: 8) {
                Button {
                    library.manuallyPaused.toggle()
                } label: {
                    Label(
                        library.manuallyPaused ? ProductText.resume.text : ProductText.pause.text,
                        systemImage: library.manuallyPaused ? "play.fill" : "pause.fill"
                    ).wupsyFont(size: 10, weight: .medium).frame(maxWidth: .infinity).padding(
                        .vertical, 8
                    ).background(
                        WupsyTheme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).disabled(library.active == nil)
                Button {
                    library.stop()
                } label: {
                    Image(systemName: "stop.fill").wupsyFont(size: 9).wupsyPadding(.all, 10)
                        .background(
                            .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).help(ProductText.stopWallpaperHelp.text).disabled(
                    library.active == nil)
            }.foregroundStyle(WupsyTheme.lavender)
        }.wupsyPadding(.all, 13).background(
            .black.opacity(0.16), in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(WupsyTheme.border))
    }
    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.down.doc").foregroundStyle(WupsyTheme.lavender)
            Text(ProductText.dropImport.text).foregroundStyle(.secondary)
            Spacer()
            Text(ProductText.shortcutHint.text).foregroundStyle(.tertiary)
        }.wupsyFont(size: 9)
    }
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: favoritesOnly ? "heart" : "sparkles.rectangle.stack").wupsyFont(
                size: 43, weight: .ultraLight
            ).foregroundStyle(WupsyTheme.lavender)
            Text(
                library.items.isEmpty
                    ? ProductText.emptyWelcome.text : ProductText.emptyResults.text
            ).wupsyFont(size: 21, weight: .medium, design: .rounded)
            Text(
                library.items.isEmpty
                    ? ProductText.emptyImportHint.text
                    : favoritesOnly
                        ? ProductText.emptyFavoritesHint.text
                        : ProductText.emptySearchHint.text
            ).wupsyFont(.subheadline).foregroundStyle(.secondary)
            if library.items.isEmpty {
                Button(ProductText.browseWallpapers.text, action: library.importFiles).buttonStyle(
                    VioletButtonStyle())
            } else {
                Button(ProductText.showAll.text) {
                    filter = .all
                    favoritesOnly = false
                    search = ""
                }.buttonStyle(.link)
            }
        }.frame(maxWidth: .infinity).frame(height: 245).background(
            LinearGradient(
                colors: [WupsyTheme.accent.opacity(0.1), WupsyTheme.surface],
                startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16)
        ).overlay(RoundedRectangle(cornerRadius: 16).stroke(WupsyTheme.border))
    }
    private var dropOverlay: some View {
        ZStack {
            WupsyTheme.background.opacity(0.94)
            VStack(spacing: 15) {
                Image(systemName: "square.and.arrow.down").wupsyFont(size: 42)
                Text(ProductText.dropCollection.text).wupsyFont(size: 17, weight: .semibold)
                Text(ProductText.dropFormats.text).foregroundStyle(.secondary)
            }.foregroundStyle(WupsyTheme.lavender)
        }.wupsyPadding(.all, 8).overlay(
            RoundedRectangle(cornerRadius: 15).stroke(
                WupsyTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
        ).wupsyPadding(.all, 12).allowsHitTesting(false)
    }
    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard library.maintenance.allowsNewOperations else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
                        item, _ in
                        if let data = item as? Data {
                            continuation.resume(
                                returning: URL(dataRepresentation: data, relativeTo: nil))
                        } else if let url = item as? URL {
                            continuation.resume(returning: url)
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                }
                if let url { urls.append(url) }
            }
            if !urls.isEmpty { library.importURLs(urls) }
        }
        return true
    }
    private var qualityHelp: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(ProductText.qualityChoice.text).wupsyFont(.headline)
            Text(
                ProductText.qualityOriginalHelp.text
            )
            Text(
                ProductText.qualityBalancedHelp.text
            ).foregroundStyle(.secondary)
            Text(
                ProductText.qualityPreparationHelp.text
            ).foregroundStyle(.secondary)
        }.wupsyFont(size: 11).wupsyPadding(.all, 20).wupsyControlFrame(width: 315)
    }
    private var compatibility: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(ProductText.formatsTitle.text, systemImage: "sparkles").wupsyFont(
                size: 17, weight: .bold
            )
            .foregroundStyle(WupsyTheme.lavender)
            Text(
                ProductText.formatsList.text
            )
            Text(
                ProductText.formatsWebWarning.text
            ).foregroundStyle(.secondary)
            Button(ProductText.gotIt.text) { showCompatibility = false }.buttonStyle(
                VioletButtonStyle()
            ).frame(
                maxWidth: .infinity, alignment: .trailing)
        }.wupsyPadding(.all, 30).wupsyControlFrame(width: 520).background(WupsyTheme.surface)
    }
}

private struct PlaylistDialogTarget: Identifiable {
    let id = UUID()
    var playlistID: UUID?
    var name = ""
}

/// Keep the header a single full-width button without the default label's extra inset.
private struct PlaylistHeaderDisclosureStyle: DisclosureGroupStyle {
    let count: Int
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .wupsyFont(size: 9, weight: .semibold).frame(width: 8)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ProductText.playlistCount.format(Int64(count)))
            .accessibilityValue(
                configuration.isExpanded ? ProductText.expanded.text : ProductText.collapsed.text
            )
            .accessibilityHint(ProductText.playlistsDisclosureHint.text)
            if configuration.isExpanded { configuration.content }
        }
    }
}
