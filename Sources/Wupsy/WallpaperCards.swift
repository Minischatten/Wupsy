import AppKit
import SwiftUI

extension Wallpaper {
    var isGIF: Bool { url.pathExtension.lowercased() == "gif" }
    var displayKind: String {
        kind == .scene
            ? ProductText.mediaScene.text
            : isGIF
                ? "GIF"
                : kind == .web
                    ? ProductText.mediaWeb.text
                    : kind == .image ? ProductText.mediaImage.text : ProductText.mediaVideo.text
    }
    var symbol: String {
        kind == .scene
            ? "cube.transparent"
            : isGIF
                ? "square.stack.3d.up"
                : kind == .video ? "play.rectangle" : kind == .web ? "globe" : "photo"
    }
}
struct WallpaperHero: View {
    @EnvironmentObject private var library: Library
    let item: Wallpaper
    let isFavorite: Bool
    let isActive: Bool
    let preparing: Bool
    let favorite: () -> Void
    let apply: () -> Void
    @State private var details = MediaDetails()
    @State private var detailsRevision = UUID()
    @State private var fitPreview = true
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if item.kind == .scene && item.managed != nil {
                WSSLibraryLivePreview(
                    item: item, fit: fitPreview,
                    policy: .library(
                        profile: library.profile,
                        resolution: library.sceneRenderResolution, fps: library.sceneFPS),
                    owner: library.livePreview)
            } else {
                WallpaperPreview(item: item, maxPixel: 1280, fit: fitPreview)
            }
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.15), location: 0),
                    .init(color: .clear, location: 0.35),
                    .init(color: .black.opacity(0.88), location: 1),
                ], startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    DetailBadge(
                        text: isActive
                            ? ProductText.currentWallpaperHeader.text
                            : ProductText.previewHeader.text,
                        icon: isActive ? "checkmark.circle.fill" : "viewfinder")
                    Spacer()
                    Button {
                        fitPreview.toggle()
                    } label: {
                        Image(
                            systemName: fitPreview
                                ? "arrow.up.left.and.arrow.down.right"
                                : "arrow.down.right.and.arrow.up.left"
                        ).wupsyFont(size: 12).foregroundStyle(.white).wupsyControlFrame(
                            width: 34, height: 34
                        ).background(.black.opacity(0.32), in: Circle()).overlay(
                            Circle().stroke(.white.opacity(0.15)))
                    }.buttonStyle(.plain).help(
                        fitPreview ? ProductText.fillPreview.text : ProductText.showEntire.text
                    ).accessibilityLabel(ProductText.previewFitLabel.text)
                    Button(action: favorite) {
                        Image(systemName: isFavorite ? "heart.fill" : "heart").wupsyFont(size: 14)
                            .foregroundStyle(isFavorite ? WupsyTheme.lavender : .white)
                            .wupsyControlFrame(
                                width: 34, height: 34
                            ).background(.black.opacity(0.32), in: Circle()).overlay(
                                Circle().stroke(.white.opacity(0.15)))
                    }.buttonStyle(.plain).help(
                        isFavorite ? ProductText.removeFavorite.text : ProductText.addFavorite.text
                    ).accessibilityLabel(ProductText.favoriteSelected.text)
                }
                Spacer()
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.title).wupsyFont(size: 27, weight: .semibold, design: .rounded)
                            .lineLimit(1).foregroundStyle(.white)
                        HStack(spacing: 6) {
                            DetailBadge(text: item.displayKind, icon: item.symbol)
                            if !details.dimensions.isEmpty {
                                DetailBadge(
                                    text: details.dimensions,
                                    icon: "arrow.up.left.and.arrow.down.right")
                            }
                            if !details.size.isEmpty {
                                DetailBadge(text: details.size, icon: "doc")
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Button(action: apply) {
                        Label(
                            preparing ? ProductText.preparing.text : ProductText.setWallpaper.text,
                            systemImage: "play.fill")
                    }.buttonStyle(VioletButtonStyle()).disabled(preparing)
                }
            }.wupsyPadding(.all, 20)
        }
        .frame(height: 245).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(
            RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12))
        )
        .task(id: "\(item.id)|\(item.path)|\(detailsRevision)") {
            details = MediaDetails()
            let loaded = await MediaDetails.read(item)
            guard !Task.isCancelled else { return }
            details = loaded
        }
        .onReceive(NotificationCenter.default.publisher(for: .wssPreviewCommitted)) {
            notification in
            if notification.object as? UUID == item.id { detailsRevision = UUID() }
        }
    }
}
struct WallpaperCard: View {
    @Environment(\.wupsyMetrics) private var metrics
    let item: Wallpaper
    let isSelected: Bool
    let isActive: Bool
    let isFavorite: Bool
    let select: () -> Void
    let apply: () -> Void
    let favorite: () -> Void
    var navigate: ((LibraryGridDirection) -> Void)? = nil
    var reorderItem: LibraryReorderItem? = nil
    @State private var hovered = false
    private var border: Color {
        isSelected
            ? WupsyTheme.accent.opacity(0.85)
            : hovered ? WupsyTheme.accent.opacity(0.35) : WupsyTheme.border
    }
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 0) {
                WallpaperPreview(item: item).frame(height: 107).overlay(alignment: .bottomLeading) {
                    Label(item.displayKind, systemImage: item.symbol).wupsyFont(
                        size: 8, weight: .semibold
                    ).wupsyPadding(.horizontal, 7).wupsyPadding(.vertical, 4).background(
                        .black.opacity(0.6), in: Capsule()
                    ).wupsyPadding(.all, 8)
                }.clipped().modifier(LibraryThumbnailDrag(item: reorderItem))
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).wupsyFont(size: 11, weight: .medium)
                            .lineLimit(metrics.scale == .standard ? 1 : 2)
                        Text(
                            isActive
                                ? ProductText.currentWallpaper.text
                                : item.url.pathExtension.uppercased()
                        )
                        .wupsyFont(size: 9).foregroundStyle(
                            isActive ? WupsyTheme.lavender : Color.secondary)
                    }
                    Spacer(minLength: 2)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(
                            WupsyTheme.accent
                        ).wupsyFont(size: 13)
                    }
                }.wupsyPadding(.all, 11)
            }
            .background(WupsyTheme.surface).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .onKeyPress(keys: Set(LibraryGridDirection.allCases.map(\.key)), phases: [.down, .repeat]) {
            guard $0.modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
                let navigate, let direction = LibraryGridDirection(key: $0.key)
            else { return .ignored }
            navigate(direction)
            return .handled
        }
        .buttonStyle(.plain).simultaneousGesture(TapGesture(count: 2).onEnded { apply() }).onHover {
            hovered = $0
        }.help(ProductText.cardClickHelp.text)
        .overlay(alignment: .topTrailing) {
            Button(action: favorite) {
                Image(systemName: isFavorite ? "heart.fill" : "heart").wupsyFont(size: 11)
                    .foregroundStyle(isFavorite ? WupsyTheme.lavender : .white.opacity(0.85))
                    .wupsyControlFrame(width: 27, height: 27).background(
                        .black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain).wupsyPadding(.all, 7).help(
                isFavorite ? ProductText.removeFavorite.text : ProductText.addFavorite.text
            ).accessibilityLabel(ProductText.favoriteTitle.format(item.title))
        }
    }
}
