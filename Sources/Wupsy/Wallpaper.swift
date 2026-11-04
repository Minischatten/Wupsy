import Foundation

enum WallpaperKind: String, Codable { case video, image, web, scene }
struct ManagedWallpaperLocation: Codable, Hashable {
    var directory: String  // Relative to Wallpapers/, e.g. WSS/Example.
    var entry: String  // Relative to that wallpaper's own directory.
}
enum SceneSource: String, Codable, Hashable { case nativeWSS }
struct Wallpaper: Identifiable, Codable, Hashable {
    enum Ownership: String, Codable { case external, managed }
    var id = UUID()
    var title: String
    // Resolved runtime paths. Managed records persist only the relative location.
    var path: String
    var root: String
    var kind: WallpaperKind
    var managed: ManagedWallpaperLocation? = nil
    private(set) var sceneSource: SceneSource?
    private(set) var scenePlaybackMode: ScenePlaybackMode?

    init(
        id: UUID = UUID(), title: String, path: String, root: String, kind: WallpaperKind,
        managed: ManagedWallpaperLocation? = nil, scenePlaybackMode: ScenePlaybackMode? = nil,
        sceneSource: SceneSource? = nil
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.root = root
        self.kind = kind
        self.managed = managed
        self.sceneSource = kind == .scene ? (sceneSource ?? .nativeWSS) : nil
        self.scenePlaybackMode = nil
    }

    // Native WSS is the only scene backend. Persisted backend selectors are rejected.
    var playbackMode: ScenePlaybackMode { .wss }
    var ownership: Ownership { managed == nil ? .external : .managed }
    var url: URL { URL(fileURLWithPath: path) }

}

extension Wallpaper {
    private enum CodingKeys: String, CodingKey {
        case id, title, path, root, kind, ownership, managed, scenePlaybackMode, sceneSource
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        kind = try c.decode(WallpaperKind.self, forKey: .kind)
        if kind == .scene {
            guard try c.decodeIfPresent(SceneSource.self, forKey: .sceneSource) == .nativeWSS,
                !c.contains(.scenePlaybackMode)
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sceneSource, in: c,
                    debugDescription:
                        "Only native Wupsy scenes are supported. Legacy scene records require an older application."
                )
            }
            sceneSource = .nativeWSS
            scenePlaybackMode = nil
        } else {
            guard !c.contains(.sceneSource) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sceneSource, in: c,
                    debugDescription: "Scene source on non-scene wallpaper")
            }
            sceneSource = nil
            guard !c.contains(.scenePlaybackMode) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .scenePlaybackMode, in: c,
                    debugDescription: "Scene playback mode on a non-scene wallpaper")
            }
            scenePlaybackMode = nil
        }
        let owner = try c.decodeIfPresent(Ownership.self, forKey: .ownership) ?? .external
        if owner == .managed {
            managed = try c.decode(ManagedWallpaperLocation.self, forKey: .managed)
            path = ""
            root = ""
        } else {
            guard !c.contains(.managed) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .managed, in: c,
                    debugDescription: "External wallpaper has managed ownership data")
            }
            path = try c.decode(String.self, forKey: .path)
            root = try c.decode(String.self, forKey: .root)
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(kind, forKey: .kind)
        if kind == .scene { try c.encode(SceneSource.nativeWSS, forKey: .sceneSource) }
        try c.encode(ownership, forKey: .ownership)
        if let managed {
            try c.encode(managed, forKey: .managed)
        } else {
            try c.encode(path, forKey: .path)
            try c.encode(root, forKey: .root)
        }
    }
}
enum ImportFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}
enum WallpaperImporter {
    static func resolve(_ input: URL) throws -> Wallpaper {
        let requested = input.standardizedFileURL
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: requested.path, isDirectory: &isDirectory)
        let nativeEntry =
            isDirectory.boolValue ? requested.appendingPathComponent("scene.wss.json") : requested
        if nativeEntry.lastPathComponent == "scene.wss.json",
            FileManager.default.fileExists(atPath: nativeEntry.path)
        {
            let root = nativeEntry.deletingLastPathComponent()
            let document = try WSSSceneDocumentV1.load(entry: nativeEntry, root: root)
            return Wallpaper(
                title: document.title, path: nativeEntry.path, root: root.path,
                kind: .scene, sceneSource: .nativeWSS)
        }
        let input = input.standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: input.path, isDirectory: &directory) else {
            throw ImportFailure.message("This file is no longer available.")
        }
        var file = input
        var root = input.deletingLastPathComponent()
        var title = input.deletingPathExtension().lastPathComponent
        if directory.boolValue {
            root = input
            file = root.appendingPathComponent("index.html")
            title = root.lastPathComponent
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ImportFailure.message("The wallpaper's media file was not found.")
        }
        let kind: WallpaperKind
        switch file.pathExtension.lowercased() {
        case "mp4", "mov", "m4v": kind = .video
        case "png", "jpg", "jpeg", "heic", "tiff": kind = .image
        case "html", "htm", "gif": kind = .web
        default:
            throw ImportFailure.message(
                "Unsupported format. Import MP4, MOV, M4V, GIF, PNG, JPEG, HEIC, TIFF, HTML, a native Wupsy project, or a web folder. Convert other video containers to H.264 or HEVC MP4 first."
            )
        }
        return Wallpaper(title: title, path: file.path, root: root.path, kind: kind)
    }
}

/// Display names are metadata, not filesystem components.
enum WallpaperTitle {
    enum Issue {
        case singleLine, required, length
        var diagnostic: String {
            switch self {
            case .singleLine: return "Use a single line without control characters."
            case .required: return "Enter a wallpaper name."
            case .length: return "Use a name with at most 256 characters."
            }
        }
    }
    static func validationIssue(_ input: String) -> Issue? {
        if input.unicodeScalars.contains(where: {
            CharacterSet.newlines.contains($0) || $0.properties.generalCategory == .control
        }) {
            return .singleLine
        }
        let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return .required }
        if title.count > 256 { return .length }
        return nil
    }
    static func normalized(_ input: String) throws -> String {
        if let issue = validationIssue(input) { throw ImportFailure.message(issue.diagnostic) }
        return input.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
