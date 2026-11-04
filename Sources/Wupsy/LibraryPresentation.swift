import Foundation

// Shared by all navigation destinations. Only the split view/user chooses the
// outer width; scroll content stays inside the width actually assigned to it.
enum LibrarySidebarLayout {
    static let minimumWidth: CGFloat = 240
    static let idealWidth: CGFloat = 255
    static let maximumWidth: CGFloat = 300
    static let inset: CGFloat = 20

    static func contentWidth(for columnWidth: CGFloat) -> CGFloat {
        max(0, columnWidth - 2 * inset)
    }
}

// Transient UI state only. These identities never replace persisted keys/values.
enum LibraryPage: CaseIterable {
    case overview, wallpapers, widgets, playlist
}

enum LibrarySort: CaseIterable {
    case newest, name, favorites

    var title: String {
        switch self {
        case .newest: return ProductText.sortNewest.text
        case .name: return ProductText.sortName.text
        case .favorites: return ProductText.sortFavorites.text
        }
    }

    func ordered(_ items: [Wallpaper], favorites: Set<UUID>) -> [Wallpaper] {
        switch self {
        case .newest: return items.reversed()
        case .name:
            return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .favorites:
            return items.sorted { a, b in
                let af = favorites.contains(a.id)
                let bf = favorites.contains(b.id)
                return af == bf
                    ? a.title.localizedStandardCompare(b.title) == .orderedAscending : af
            }
        }
    }
}

enum LibraryPlaybackStatus: Equatable {
    case ready, stopped
    case preparing(QualityProfile)
    case paused(PauseReason)
    case playing(displayCount: Int)

    var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    var title: String { localizedTitle() }
    func localizedTitle(language: String? = nil) -> String {
        switch self {
        case .ready: return ProductText.playbackReady.localized(language: language)
        case .stopped: return ProductText.playbackStopped.localized(language: language)
        case .preparing(let quality):
            return ProductText.preparingQuality.format(
                quality.displayName(language: language), language: language)
        case .paused(let reason): return reason.displayName(language: language)
        case .playing(let count):
            return ProductText.playingDisplays.format(Int64(count), language: language)
        }
    }
    // Stable English diagnostics; not a user-facing localization source.
    var technicalTitle: String {
        switch self {
        case .ready: return "Ready"
        case .stopped: return "Stopped"
        case .preparing(let quality): return "Preparing \(quality.rawValue) playback…"
        case .paused(let reason): return reason.rawValue
        case .playing(let count):
            return "Playing · \(count) display\(count == 1 ? "" : "s")"
        }
    }
}
