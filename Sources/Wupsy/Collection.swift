import AVFoundation
import Foundation
import ImageIO

enum WallpaperFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case video = "Video"
    case image = "Images"
    case gif = "GIF"
    case web = "Web"
    case scene = "Scenes"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return ProductText.filterAll.text
        case .video: return ProductText.mediaVideo.text
        case .image: return ProductText.filterImages.text
        case .gif: return "GIF"
        case .web: return ProductText.mediaWeb.text
        case .scene: return ProductText.filterScenes.text
        }
    }
    func accepts(_ item: Wallpaper) -> Bool {
        switch self {
        case .scene: return item.kind == .scene
        case .all: return true
        case .video: return item.kind == .video
        case .image: return item.kind == .image
        case .gif: return item.url.pathExtension.lowercased() == "gif"
        case .web: return item.kind == .web && item.url.pathExtension.lowercased() != "gif"
        }
    }
}
struct MediaDetails {
    var dimensions = ""
    var size = ""
    var format = ""
    static func read(_ item: Wallpaper) async -> MediaDetails {
        var value = MediaDetails()
        value.format = item.url.pathExtension.uppercased()
        if let bytes = await WallpaperLogicalSize.read(item) {
            value.size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
        if item.kind == .scene {
            if item.sceneSource == .nativeWSS {
                value.format = "WSS"
                if let document = try? WSSSceneDocumentV1.load(
                    entry: item.url, root: URL(fileURLWithPath: item.root))
                {
                    value.dimensions = "\(document.canvas.width) × \(document.canvas.height) · WSS"
                }
                return value
            }
        } else if item.kind == .video {
            if let tracks = try? await AVURLAsset(url: item.url).loadTracks(withMediaType: .video),
                let track = tracks.first,
                let size = try? await track.load(.naturalSize),
                let transform = try? await track.load(.preferredTransform),
                let fps = try? await track.load(.nominalFrameRate)
            {
                let bounds = CGRect(origin: .zero, size: size).applying(transform)
                value.dimensions =
                    ProductText.videoDimensions.format(
                        Int64(abs(bounds.width)), Int64(abs(bounds.height)), Int64(fps.rounded()))
            }
        } else if item.kind == .image || item.url.pathExtension.lowercased() == "gif",
            let source = CGImageSourceCreateWithURL(
                item.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int,
            let h = props[kCGImagePropertyPixelHeight] as? Int
        {
            value.dimensions = "\(w) × \(h)"
        }
        return value
    }
}
