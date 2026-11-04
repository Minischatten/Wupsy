import Darwin
import Foundation

/// A caller supplies decisions; capture only seals explicitly named evidence. No discovery,
/// title matching, registration inference or historical defaults are performed here.
struct LibraryRecoveryPlan: Codable {
    let version: Int
    let id: UUID
    let expectedMetadata: [RecoveryFileFingerprint]
    let library: Data
    let playlists: Data
    let expectedIDs: [UUID]
    let excludedIDs: [UUID]
    let projects: [RecoveryProjectEvidence]
    let preserved: [RecoveryTreeEvidence]
    let absentProjectDirectories: [String]
    let historicalMetadataSource: String?

    func validate(root: URL, verifyOriginalMetadata: Bool) throws {
        guard version == 1, expectedMetadata.map(\.path) == LibraryMetadataRecovery.names,
            expectedIDs.count <= LibraryBackupLimits.files,
            Set(expectedIDs).count == expectedIDs.count,
            Set(excludedIDs).count == excludedIDs.count,
            Set(expectedIDs).isDisjoint(with: excludedIDs),
            projects.map(\.id) == expectedIDs,
            library.count <= LibraryBackupLimits.manifest,
            playlists.count <= WallpaperPlaylistStore.byteLimit,
            historicalMetadataSource.map({
                $0.count <= 1024 && !$0.hasPrefix("/") && !$0.hasPrefix("~")
            }) ?? true
        else { throw LibraryBackupError("Invalid recovery plan contract.") }
        for file in expectedMetadata { try file.validate() }
        if verifyOriginalMetadata {
            guard try Self.metadata(root: root) == expectedMetadata else {
                throw LibraryBackupError(
                    "Recovery baseline changed; create and confirm a new plan.")
            }
        }
        let items = try LibraryRestoreJSON.decode([Wallpaper].self, from: library)
        let collection = try LibraryRestoreJSON.decode(
            PlaylistCollectionState.self, from: playlists)
        try collection.validate()
        guard items.map(\.id) == expectedIDs, collection.playback == nil,
            collection.definitions.allSatisfy({
                Set($0.wallpaperIDs).isSubset(of: Set(expectedIDs))
            })
        else {
            throw LibraryBackupError("Recovery IDs, playlist references or playback are invalid.")
        }
        let store = ManagedWallpaperStore(storage: root.appendingPathComponent("library.json"))
        var directories = Set<String>()
        for (item, project) in zip(items, projects) {
            guard let location = item.managed,
                project.source.directory == "Wallpapers/" + location.directory,
                directories.insert(project.source.directory).inserted
            else { throw LibraryBackupError("Recovery requires unique managed project ownership.") }
            let parts = try ManagedWallpaperStore.components(location.directory)
            let category: String
            switch item.kind {
            case .image, .video: category = "Media"
            case .web: category = "Web"
            case .scene:
                category =
                    "WSS"
            }
            guard parts.count == 2, parts[0] == category,
                try WallpaperTitle.normalized(item.title) == item.title
            else { throw LibraryBackupError("Recovery project type or title mismatch.") }
            try project.source.verify(root: root)
            let resolved = try store.resolve(item)
            let ext = resolved.url.pathExtension.lowercased()
            let supportedEntry: Bool
            switch item.kind {
            case .image: supportedEntry = ["png", "jpg", "jpeg", "heic", "tiff"].contains(ext)
            case .video: supportedEntry = ["mp4", "mov", "m4v"].contains(ext)
            case .web: supportedEntry = ["html", "htm", "gif"].contains(ext)
            case .scene:
                supportedEntry =
                    item.sceneSource == .nativeWSS && location.entry == "scene.wss.json"
            }
            guard supportedEntry else {
                throw LibraryBackupError("Recovery entry type disagrees with its library kind.")
            }
            let entry = project.source.directory + "/" + location.entry
            guard project.source.files.contains(where: { $0.path == entry }) else {
                throw LibraryBackupError("Recovery entry is absent from sealed project evidence.")
            }
            if item.kind == .scene, item.sceneSource == .nativeWSS {
                guard location.entry == "scene.wss.json", project.native == nil else {
                    throw LibraryBackupError("Invalid native WSS recovery mapping.")
                }
                try Self.validateWSS(directory: project.source, root: root)
            } else if project.native != nil {
                throw LibraryBackupError("Native mapping on a non-scene recovery entry.")
            }
        }
        let support = try WSSAssetIO.directory(root)
        defer { close(support) }
        guard Set(absentProjectDirectories).count == absentProjectDirectories.count else {
            throw LibraryBackupError("Duplicate absent recovery evidence.")
        }
        for path in absentProjectDirectories {
            try RecoveryTreeEvidence.validateDirectory(path)
            guard directories.insert(path).inserted,
                try RestoreTransactionIO.optionalIdentity(support, path) == nil
            else {
                throw LibraryBackupError("An expected absent project now exists.")
            }
        }
        for tree in preserved {
            guard directories.insert(tree.directory).inserted else {
                throw LibraryBackupError("Overlapping preserved recovery evidence.")
            }
            try tree.verify(root: root)
        }
    }

    private static func validateWSS(directory: RecoveryTreeEvidence, root: URL) throws {
        let folder = root.appendingPathComponent(directory.directory)
        let model = try WSSSceneDocumentV1.load(
            entry: folder.appendingPathComponent("scene.wss.json"), root: folder)
        _ = try model.assetSource(root: folder)
        let paths = Set(directory.files.map(\.path))
        guard model.referencedPaths.allSatisfy({ paths.contains(directory.directory + "/" + $0) })
        else {
            throw LibraryBackupError("A WSS resource is missing from recovery evidence.")
        }
    }
    static func metadata(root: URL) throws -> [RecoveryFileFingerprint] {
        try LibraryMetadataRecovery.names.map { try .capture(root: root, path: $0) }
    }
}

struct RecoveryProjectEvidence: Codable {
    let id: UUID
    let source: RecoveryTreeEvidence
    let native: RecoveryTreeEvidence?
}

struct RecoveryFileFingerprint: Codable, Equatable {
    let path: String
    let size: Int64
    let sha256: String
    func validate() throws {
        _ = try ManagedWallpaperStore.components(path)
        guard size >= 0, size <= LibraryBackupLimits.file, sha256.count == 64,
            sha256.allSatisfy({ "0123456789abcdef".contains($0) })
        else { throw LibraryBackupError("Invalid recovery fingerprint.") }
    }
    static func capture(root: URL, path: String) throws -> Self {
        _ = try ManagedWallpaperStore.components(path)
        let file = try LibraryBackupIO.input(root.appendingPathComponent(path))
        defer { close(file) }
        let (size, hash) = try LibraryBackupIO.stream(file) { _ in }
        return .init(path: path, size: size, sha256: hash)
    }
}

struct RecoveryTreeEvidence: Codable, Equatable {
    let directory: String
    let files: [RecoveryFileFingerprint]
    static func validateDirectory(_ directory: String) throws {
        let parts = try ManagedWallpaperStore.components(directory)
        guard parts.count == 3, parts[0] == "Wallpapers",
            ["Loose", "Packages", "Media", "Web", "WSS", "NativeProjects"].contains(parts[1])
        else { throw LibraryBackupError("Unsafe recovery project directory.") }
    }
    static func capture(root: URL, directory: String) throws -> Self {
        try validateDirectory(directory)
        let fd = try WSSAssetIO.directory(root.appendingPathComponent(directory))
        defer { close(fd) }
        var count = 0
        let paths = try RestoreTransactionIO.inventory(fd, count: &count)
        return .init(
            directory: directory,
            files: try paths.sorted().map {
                try RecoveryFileFingerprint.capture(root: root, path: directory + "/" + $0)
            })
    }
    func verify(root: URL) throws {
        for file in files { try file.validate() }
        guard !files.isEmpty, try Self.capture(root: root, directory: directory) == self else {
            throw LibraryBackupError("Recovery project evidence changed or is incomplete.")
        }
    }
}
