import Foundation

// Native playback identity. Historical backend values are not accepted.
enum ScenePlaybackMode: String, Codable, Hashable {
    case wss
}

enum ScenePlaybackError: LocalizedError, Equatable {
    case notSceneWallpaper
    var errorDescription: String? { "Scene playback applies only to scene wallpapers." }
}
