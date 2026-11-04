import SwiftUI

struct StudioOverview: View {
    @ObservedObject var library: Library
    @ObservedObject var widgets: DesktopWidgets
    let showWallpapers: () -> Void
    let showWidgets: () -> Void
    let importWallpaper: () -> Void
    let revealWallpaper: (UUID) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        welcome
                        Spacer()
                        WallpaperActions(
                            importWallpaper: importWallpaper, onFirstSave: revealWallpaper)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        welcome
                        WallpaperActions(
                            importWallpaper: importWallpaper, onFirstSave: revealWallpaper)
                    }
                }
                HStack(spacing: 14) {
                    summary(
                        ProductText.wallpapers.text, value: "\(library.items.count)",
                        icon: "photo.stack",
                        action: showWallpapers
                    ).accessibilityLabel(
                        ProductText.wallpaperCount.format(Int64(library.items.count)))
                    summary(
                        ProductText.widgetsEnabled.text, value: "\(widgets.enabledCount)",
                        icon: "rectangle.3.group", action: showWidgets
                    ).accessibilityLabel(
                        ProductText.widgetCount.format(Int64(widgets.enabledCount)))
                    summary(
                        ProductText.pictureQuality.text, value: library.profile.title,
                        icon: "sparkles",
                        action: showWallpapers)
                }
                if let active = library.active {
                    WallpaperHero(
                        item: active, isFavorite: library.favorites.contains(active.id),
                        isActive: true, preparing: library.preparing,
                        favorite: { library.toggleFavorite(active) },
                        apply: { library.apply(active) })
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label(ProductText.playbackHealth.text, systemImage: "heart.text.square")
                            .font(.headline)
                        Spacer()
                        Text(library.status).foregroundStyle(WupsyTheme.lavender)
                    }
                    Text(
                        ProductText.playbackHealthHint.text
                    ).font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        Button(
                            library.manuallyPaused
                                ? ProductText.resume.text : ProductText.pause.text
                        ) {
                            library.manuallyPaused.toggle()
                        }.disabled(library.active == nil)
                        Button(ProductText.restartWallpaper.text) {
                            if let active = library.active { library.apply(active) }
                        }.disabled(library.active == nil)
                        Spacer()
                        Button(ProductText.openWidgets.text, action: showWidgets).buttonStyle(
                            VioletButtonStyle())
                    }
                    Divider()
                    Text(ProductText.recentActivity.text).font(.caption.weight(.semibold))
                        .foregroundStyle(
                            .secondary)
                    ForEach(
                        Array(library.playbackEvents.suffix(6).reversed().enumerated()),
                        id: \.offset
                    ) { _, event in
                        Text(event.localized()).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(
                                .secondary
                            ).textSelection(.enabled)
                    }
                }.padding(22).background(
                    WupsyTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            }.padding(26)
        }.background(WupsyTheme.background)
            .background(OverviewInitialFocus().allowsHitTesting(false))
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            Eyebrow(text: ProductText.overviewHeader.text)
            Text(ProductText.overviewWelcome.text).font(
                .system(size: 30, weight: .semibold, design: .rounded))
        }
    }
    private func summary(_ label: String, value: String, icon: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Label(label, systemImage: icon).font(.caption).foregroundStyle(
                    WupsyTheme.lavender)
                Text(value).font(.system(size: 25, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(
                WupsyTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
    }
}
