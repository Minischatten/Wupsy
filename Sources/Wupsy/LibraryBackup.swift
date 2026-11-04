import Darwin
import Foundation

struct LibraryBackupSource {
    let url: URL
    let path: String
    let size: Int64
}
struct LibraryBackupPlan {
    let storage: URL
    var wallpapers: [LibraryBackupWallpaper] = []
    var recovery: [LibraryBackupRecovery] = []
    var sources: [LibraryBackupSource] = []
    var roots: [URL] = []
    var notes = ["Historical cache NativeProjects are excluded: provenance cannot be established."]
    var complete = true
    var playlists = PlaylistCollectionState()
    private var paths = Set<String>()
    private var total: Int64 = 0
    private var bases: [(WSSProjectDiskBasis, WSSProjectHandle)] = []

    mutating func add(_ url: URL, path inputPath: String) throws {
        let path = inputPath.precomposedStringWithCanonicalMapping
        guard paths.insert(try LibraryBackupLimits.path(path)).inserted,
            sources.count + 6 < LibraryBackupLimits.files
        else {
            throw LibraryBackupError("Duplicate backup path or file count limit exceeded.")
        }
        let fd = try LibraryBackupIO.input(url)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size <= LibraryBackupLimits.total - total else {
            throw LibraryBackupError("Backup size limit exceeded.")
        }
        total += info.st_size
        sources.append(LibraryBackupSource(url: url, path: path, size: info.st_size))
    }
    mutating func tree(_ root: URL, prefix: String) throws {
        roots.append(root)
        let fd = try WSSAssetIO.directory(root)
        close(fd)
        var pending: [(URL, String, Int)] = [(root, prefix, 0)]
        var directories = 0
        while let (directory, path, depth) = pending.popLast() {
            try Task.checkCancellation()
            directories += 1
            guard depth <= 32, directories <= LibraryBackupLimits.files else {
                throw LibraryBackupError("Project directory count or depth limit exceeded.")
            }
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                ])
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let next =
                    path + "/" + child.lastPathComponent.precomposedStringWithCanonicalMapping
                _ = try LibraryBackupLimits.path(next)
                let values = try child.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey,
                ])
                guard values.isSymbolicLink != true, values.isAliasFile != true else {
                    throw LibraryBackupError(
                        "Links and Finder aliases are not supported in backup sources.")
                }
                if values.isDirectory == true {
                    pending.append((child, next, depth + 1))
                } else if values.isRegularFile == true {
                    try add(child, path: next)
                } else {
                    throw LibraryBackupError("Unsupported special file in backup source.")
                }
            }
        }
    }
    mutating func native(_ root: URL, id: UUID, prefix: String) throws {
        let item = Wallpaper(
            id: id, title: "Backup validation",
            path: root.appendingPathComponent("scene.wss.json").path,
            root: root.path, kind: .scene,
            managed: .init(directory: "WSS/" + id.uuidString, entry: "scene.wss.json"),
            sceneSource: .nativeWSS)
        let handle = WSSProjectHandle(
            wallpaper: item, root: root,
            entry: root.appendingPathComponent("scene.wss.json"), origin: .native)
        let loaded = try WSSEditorProjectLoader.read(handle: handle)
        bases.append((loaded.diskBasis, handle))
        roots.append(root)
        try add(handle.entry, path: prefix + "/scene.wss.json")
        for path in loaded.document.referencedPaths.sorted() {
            try add(root.appendingPathComponent(path), path: prefix + "/" + path)
        }
    }
    static func analyze(storage: URL) throws -> Self {
        var plan = Self(storage: storage)
        plan.playlists = try WallpaperPlaylistStore(
            url: storage.deletingLastPathComponent().appendingPathComponent("playlists.json")
        ).load()
        let store = ManagedWallpaperStore(storage: storage)
        try ManagedWallpaperStore.checkPath(storage.deletingLastPathComponent())
        try ManagedWallpaperStore.checkPath(storage)
        let items: [Wallpaper]
        var rootInfo = stat()
        if lstat(storage.deletingLastPathComponent().path, &rootInfo) == 0 {
            let parent = try WSSAssetIO.directory(storage.deletingLastPathComponent())
            defer { close(parent) }
            let input = openat(
                parent, storage.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            if input >= 0 {
                defer { close(input) }
                let bytes = try WSSAssetIO.read(input, limit: LibraryBackupLimits.manifest)
                items = try JSONDecoder().decode([Wallpaper].self, from: bytes).map {
                    try store.resolve($0)
                }
            } else {
                guard errno == ENOENT else {
                    throw LibraryBackupError("Cannot safely read saved library metadata.")
                }
                items = []
            }
        } else {
            guard errno == ENOENT else {
                throw LibraryBackupError("Cannot access the library storage directory.")
            }
            items = []
        }
        guard Set(items.map(\.id)).count == items.count,
            Set(items.compactMap { $0.managed?.directory }).count
                == items.compactMap({ $0.managed }).count
        else {
            throw LibraryBackupError("Ambiguous library ownership or duplicate wallpaper UUID.")
        }
        for item in items {
            try Task.checkCancellation()
            let prefix = "payloads/" + item.id.uuidString
            let root = URL(fileURLWithPath: item.root)
            let native: String? = nil
            let sourceExists = FileManager.default.fileExists(atPath: item.path)
            var entry: String?
            if sourceExists {
                if item.sceneSource == .nativeWSS {
                    try plan.native(root, id: item.id, prefix: prefix + "/source")
                    entry = "scene.wss.json"
                } else if item.managed != nil
                    && item.kind == .web && item.url.pathExtension.lowercased() != "gif"
                {
                    try plan.tree(root, prefix: prefix + "/source")
                    entry = item.managed!.entry.precomposedStringWithCanonicalMapping
                } else {
                    // External project roots have no reliable ownership boundary in v1.
                    guard
                        item.managed != nil || item.kind == .image || item.kind == .video
                            || item.url.pathExtension.lowercased() == "gif"
                    else {
                        throw LibraryBackupError(
                            "An external project must first be imported into the managed library.")
                    }
                    entry = item.url.lastPathComponent.precomposedStringWithCanonicalMapping
                    plan.roots.append(item.url)
                    try plan.add(item.url, path: prefix + "/source/" + entry!)
                }
            } else {
                throw LibraryBackupError("A wallpaper source is missing.")
            }
            plan.wallpapers.append(
                LibraryBackupWallpaper(
                    id: item.id, title: item.title, kind: item.kind,
                    ownership: item.ownership, managed: item.managed, sceneSource: item.sceneSource,
                    scenePlaybackMode: item.scenePlaybackMode,
                    source: sourceExists ? prefix + "/source" : nil, entry: entry,
                    native: native, missingSource: !sourceExists))
        }
        let projects = store.wallpaperRoot.appendingPathComponent("NativeProjects")
        try ManagedWallpaperStore.checkPath(projects)
        if FileManager.default.fileExists(atPath: projects.path) {
            let ids = Set(items.map(\.id))
            for root in try FileManager.default.contentsOfDirectory(
                at: projects, includingPropertiesForKeys: nil
            ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try Task.checkCancellation()
                guard let id = UUID(uuidString: root.lastPathComponent), !ids.contains(id) else {
                    continue
                }
                // Validate before adding anything. Invalid managed recovery is not silently lost.
                let recoveryID = id.uuidString
                try plan.native(root, id: id, prefix: "recovery/" + recoveryID)
                plan.recovery.append(
                    .init(
                        id: recoveryID, originalProjectID: id,
                        origin: "managed-native-project", payload: "recovery/" + recoveryID))
            }
        }
        return plan
    }
    func validateDestination(_ destination: URL, staging: URL? = nil) throws {
        let parent = destination.deletingLastPathComponent()
        let fd = try WSSAssetIO.directory(parent)
        defer { close(fd) }
        let values = try? destination.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
        guard values?.isAliasFile != true, values?.isSymbolicLink != true else {
            throw LibraryBackupError("The backup destination cannot be a link or alias.")
        }
        let target = destination.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let forbidden = [storage.deletingLastPathComponent()] + roots + (staging.map { [$0] } ?? [])
        for root in forbidden {
            let components = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard !target.starts(with: components) else {
                throw LibraryBackupError(
                    "Choose a backup destination outside Wupsy and its wallpaper sources.")
            }
        }
        // A hardlinked existing destination is also refused.
        if FileManager.default.fileExists(atPath: destination.path) {
            let file = try LibraryBackupIO.input(destination)
            close(file)
        }
    }
    func snapshot(
        to root: URL, preferences: LibraryBackupPreferences,
        progress: @Sendable (String) -> Void,
        itemProgress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) throws -> LibraryBackupManifest {
        try LibraryBackupIO.available(root, needed: sources.reduce(0) { $0 + $1.size })
        var files: [LibraryBackupFile] = []
        for source in sources {
            try Task.checkCancellation()
            progress("Creating snapshot… \(files.count + 1)/\(sources.count)")
            itemProgress(files.count + 1, sources.count)
            let output = root.appendingPathComponent(source.path)
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let input = try LibraryBackupIO.input(source.url)
            defer { close(input) }
            let fd = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw LibraryBackupError("Cannot create snapshot file.") }
            defer { close(fd) }
            let (size, hash) = try LibraryBackupIO.stream(input) {
                try LibraryBackupIO.write($0, fd: fd)
            }
            guard size == source.size else {
                throw LibraryBackupError("Source size changed during backup.")
            }
            files.append(.init(path: source.path, size: size, sha256: hash))
        }
        let sourcePaths = Dictionary(grouping: sources, by: { $0.url.standardizedFileURL.path })
        let copiedFiles = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        for (basis, handle) in bases {
            try basis.verify(handle)
            let expectedFiles = basis.assets.merging(
                ["scene.wss.json": basis.manifest], uniquingKeysWith: { a, _ in a })
            for (path, expected) in expectedFiles {
                let sourceURL = handle.root.appendingPathComponent(path).standardizedFileURL.path
                for source in sourcePaths[sourceURL] ?? [] {
                    guard let copied = copiedFiles[source.path], copied.size == expected.byteCount,
                        copied.sha256
                            == expected.sha256.map({ String(format: "%02x", $0) }).joined()
                    else {
                        throw LibraryBackupError("Saved WSS resources changed during the snapshot.")
                    }
                }
            }
        }
        let ids = Set(wallpapers.map(\.id))
        guard playlists.definitions.allSatisfy({ Set($0.wallpaperIDs).isSubset(of: ids) }) else {
            throw LibraryBackupError("A saved playlist references unavailable wallpapers.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func metadata<T: Encodable>(_ value: T, _ path: String) throws {
            let bytes = try encoder.encode(value)
            guard bytes.count <= LibraryBackupLimits.manifest else {
                throw LibraryBackupError("Backup metadata is too large.")
            }
            try bytes.write(to: root.appendingPathComponent(path), options: .withoutOverwriting)
            files.append(
                .init(path: path, size: Int64(bytes.count), sha256: LibraryBackupIO.digest(bytes)))
        }
        try metadata(wallpapers, "library.json")
        try metadata(playlists, "playlists.json")
        try metadata(
            LibraryBackupOrganization(
                favorites: preferences.organization.favorites.filter { ids.contains($0) }),
            "organization.json")
        try metadata(preferences.settings, "settings.json")
        try metadata(preferences.widgets, "widgets.json")
        let manifest = LibraryBackupManifest(
            createdAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            completeness: complete ? "complete" : "incomplete", notes: notes,
            wallpapers: wallpapers,
            playlistIDs: playlists.definitions.map(\.id), recovery: recovery, files: files,
            fileCount: files.count + 1,
            totalLogicalSize: files.reduce(0) { $0 + $1.size })
        try manifest.validate()
        let bytes = try encoder.encode(manifest)
        guard bytes.count <= LibraryBackupLimits.manifest else {
            throw LibraryBackupError("Backup manifest exceeds 16 MiB.")
        }
        try bytes.write(
            to: root.appendingPathComponent("backup.json"), options: .withoutOverwriting)
        return manifest
    }
}

// Own the destination directory descriptor and temporary leaf until publication.
// The old destination is never opened for writing. Only the verified file is renamed.
final class LibraryBackupDestination {
    let directory: Int32
    let temporary: String
    let destination: String
    let fd: Int32
    private var published = false
    private var verified: stat?
    private let parentURL: URL
    private let original: stat?
    private static func inspect(_ directory: Int32, _ name: String) throws -> stat? {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else {
                throw LibraryBackupError("Unsafe backup destination.")
            }
            return info
        }
        guard errno == ENOENT else {
            throw LibraryBackupError("Cannot inspect backup destination.")
        }
        return nil
    }
    private static func same(_ a: stat?, _ b: stat?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
            && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
            && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    init(_ url: URL) throws {
        parentURL = url.deletingLastPathComponent()
        directory = try WSSAssetIO.directory(parentURL)
        do { original = try Self.inspect(directory, url.lastPathComponent) } catch {
            close(directory)
            throw error
        }
        temporary = ProductIdentity.backupPartialPrefix + UUID().uuidString + ".partial"
        destination = url.lastPathComponent
        fd = openat(directory, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            close(directory)
            throw LibraryBackupError("Cannot create temporary backup at the chosen destination.")
        }
    }
    private func ownedTemporary() throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0, let leaf = try Self.inspect(directory, temporary),
            info.st_dev == leaf.st_dev, info.st_ino == leaf.st_ino
        else {
            throw LibraryBackupError("Temporary backup ownership changed.")
        }
        return info
    }
    func verify(
        expected: LibraryBackupManifest, progress: @Sendable (String) -> Void = { _ in },
        entryProgress: @Sendable (String) -> Void = { _ in }
    )
        throws
    {
        let before = try ownedTemporary()
        let input = openat(directory, temporary, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw LibraryBackupError("Cannot reopen the completed backup.") }
        defer { close(input) }
        var opened = stat()
        guard fstat(input, &opened) == 0, Self.same(before, opened) else {
            throw LibraryBackupError("Temporary backup changed before verification.")
        }
        try LibraryBackupArchive.verify(
            fd: input, expected: expected, progress: progress, entryProgress: entryProgress)
        let after = try ownedTemporary()
        guard Self.same(before, after) else {
            throw LibraryBackupError("Backup changed during verification.")
        }
        verified = after
    }
    func publish() throws {
        try Task.checkCancellation()
        guard let verified, Self.same(verified, try ownedTemporary()) else {
            throw LibraryBackupError("Only an unchanged, fully verified backup can be published.")
        }
        guard fsync(fd) == 0 else { throw LibraryBackupError("Cannot flush the completed backup.") }
        let currentDirectory = try WSSAssetIO.directory(parentURL)
        defer { close(currentDirectory) }
        var pinned = stat()
        var current = stat()
        guard fstat(directory, &pinned) == 0, fstat(currentDirectory, &current) == 0,
            pinned.st_dev == current.st_dev, pinned.st_ino == current.st_ino,
            Self.same(original, try Self.inspect(directory, destination))
        else {
            throw LibraryBackupError(
                "Backup destination changed during creation; publication cancelled.")
        }
        guard renameat(directory, temporary, directory, destination) == 0 else {
            throw LibraryBackupError("Cannot publish backup; the previous backup is unchanged.")
        }
        published = true
        // Publication has committed. A directory flush failure is a durability warning,
        // not a claim that the old destination still exists.
        _ = fsync(directory)
    }
    func discard() throws {
        if published { return }
        guard try Self.inspect(directory, temporary) != nil else { return }
        _ = try ownedTemporary()
        guard unlinkat(directory, temporary, 0) == 0 else {
            throw LibraryBackupError("Could not remove temporary backup file.")
        }
    }
    deinit {
        close(fd)
        close(directory)
    }
}
