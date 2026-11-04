import Darwin
import Foundation

// All filesystem mutation is relative to pinned, locally created directories.
// No archive permissions, links, ownership, xattrs or ACLs are installed.
final class LibraryRestoreStaging {
    let id: UUID
    let root: URL
    private let parentURL: URL
    private let parent: Int32
    private let directory: Int32
    private let identity: stat
    private let marker: Data
    private let lock = NSLock()
    private var discarded = false
    private var transactionClaimed = false
    private var output: Int32 = -1

    init(supportRoot: URL) throws {
        id = UUID()
        parentURL = supportRoot.standardizedFileURL.appendingPathComponent(".restore/staging")
        root = parentURL.appendingPathComponent(id.uuidString)
        let restore = try WSSAssetIO.directory(parentURL.deletingLastPathComponent(), create: true)
        var restoreInfo = stat()
        guard fstat(restore, &restoreInfo) == 0, restoreInfo.st_uid == getuid(),
            restoreInfo.st_mode & 0o022 == 0
        else {
            close(restore)
            throw LibraryBackupError("Unsafe restore namespace.")
        }
        close(restore)
        parent = try WSSAssetIO.directory(parentURL, create: true)
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            close(parent)
            throw LibraryBackupError("Unsafe restore staging parent.")
        }
        guard mkdirat(parent, id.uuidString, 0o700) == 0 else {
            close(parent)
            throw LibraryBackupError("Cannot claim restore staging.")
        }
        let fd = openat(parent, id.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0, fstat(fd, &info) == 0 else {
            if fd >= 0 { close(fd) }
            unlinkat(parent, id.uuidString, AT_REMOVEDIR)
            close(parent)
            throw LibraryBackupError("Cannot pin restore staging.")
        }
        directory = fd
        identity = info
        marker = try JSONEncoder().encode([
            "version": "1", "id": id.uuidString, "token": UUID().uuidString,
        ])
        do {
            let owner = openat(fd, "owner.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard owner >= 0 else {
                throw LibraryBackupError("Cannot create restore ownership marker.")
            }
            defer { close(owner) }
            try WSSAssetIO.write(marker, to: owner)
        } catch {
            unlinkat(fd, "owner.json", 0)
            close(fd)
            unlinkat(parent, id.uuidString, AT_REMOVEDIR)
            close(parent)
            throw error
        }
    }
    deinit {
        if output >= 0 { close(output) }
        close(directory)
        close(parent)
    }
    private func owned() throws {
        guard !discarded, UUID(uuidString: root.lastPathComponent) == id,
            root.path == parentURL.appendingPathComponent(id.uuidString).path
        else { throw LibraryBackupError("Restore staging is no longer owned.") }
        let currentParent = try WSSAssetIO.directory(parentURL)
        defer { close(currentParent) }
        var p = stat()
        var q = stat()
        var item = stat()
        guard fstat(parent, &p) == 0, fstat(currentParent, &q) == 0,
            p.st_dev == q.st_dev, p.st_ino == q.st_ino,
            fstatat(parent, id.uuidString, &item, AT_SYMLINK_NOFOLLOW) == 0,
            item.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            item.st_dev == identity.st_dev, item.st_ino == identity.st_ino
        else {
            throw LibraryBackupError("Restore staging identity changed; cleanup refused.")
        }
        let owner = openat(directory, "owner.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard owner >= 0 else { throw LibraryBackupError("Restore ownership marker is missing.") }
        defer { close(owner) }
        guard try WSSAssetIO.read(owner, limit: 1024) == marker else {
            throw LibraryBackupError("Restore ownership marker changed; cleanup refused.")
        }
    }
    // Paths already passed the archive/plan checks. These operations additionally
    // prohibit following links at every component, including local parent folders.
    private func folder(_ path: String, create: Bool) throws -> Int32 {
        var fd = dup(directory)
        guard fd >= 0 else { throw LibraryBackupError("Cannot duplicate staging descriptor.") }
        do {
            for part in try ManagedWallpaperStore.components(path) {
                if create, mkdirat(fd, part, 0o700) != 0, errno != EEXIST {
                    throw LibraryBackupError("Cannot create staging directory.")
                }
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else { throw LibraryBackupError("Unsafe staging directory.") }
                close(fd)
                fd = next
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }
    private func create(_ path: String) throws -> Int32 {
        let parts = try ManagedWallpaperStore.components(path)
        let parent = try folder(parts.dropLast().joined(separator: "/"), create: true)
        defer { close(parent) }
        let file = openat(parent, parts.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw LibraryBackupError("Cannot create exclusive staging file.") }
        return file
    }
    private func write<T: Encodable>(_ value: T, path: String) throws {
        let file = try create(path)
        defer { close(file) }
        try WSSAssetIO.write(JSONEncoder().encode(value), to: file)
    }
    func sink(checkpoint: @escaping LibraryRestorePreparer.Checkpoint) -> LibraryBackupReadSink {
        LibraryBackupReadSink(
            begin: { path, _ in
                try self.owned()
                if path.contains("/") { self.output = try self.create("payload/" + path) }
            },
            write: { path, bytes in
                if self.output >= 0 {
                    try LibraryBackupIO.write(bytes, fd: self.output)
                    try checkpoint(.extracting, path, bytes.count)
                }
            },
            end: { _ in
                if self.output >= 0 {
                    guard fsync(self.output) == 0 else {
                        throw LibraryBackupError("Could not flush restore payload.")
                    }
                    close(self.output)
                    self.output = -1
                }
            })
    }
    func reconstruct(_ plan: LibraryRestorePlan) throws {
        try owned()
        try LibraryBackupIO.available(root, needed: 1 << 20)
        for category in ["Packages", "Loose", "Media", "Web", "WSS", "NativeProjects"] {
            close(try folder("new/Wallpapers/" + category, create: true))
        }
        for mapping in plan.files {
            try Task.checkCancellation()
            let source = "payload/" + mapping.source.path
            let destination = "new/" + mapping.target
            let from = try folder(
                String(source.prefix(upTo: source.lastIndex(of: "/")!)), create: false)
            defer { close(from) }
            let to = try folder(
                String(destination.prefix(upTo: destination.lastIndex(of: "/")!)), create: true)
            defer { close(to) }
            guard
                renameatx_np(
                    from, URL(fileURLWithPath: source).lastPathComponent, to,
                    URL(fileURLWithPath: destination).lastPathComponent, UInt32(RENAME_EXCL)) == 0
            else {
                throw LibraryBackupError("Cannot reconstruct restore payload.")
            }
        }
        try write(plan.library, path: "new/library.json")
        let playlistBytes = try JSONEncoder().encode(plan.playlists)
        guard playlistBytes.count <= WallpaperPlaylistStore.byteLimit else {
            throw LibraryBackupError("Reconstructed playlists exceed the store budget.")
        }
        try write(plan.playlists, path: "new/playlists.json")
        let payload = try folder("payload", create: true)
        defer { close(payload) }
        try Self.removeContents(payload)
        guard unlinkat(directory, "payload", AT_REMOVEDIR) == 0 else {
            throw LibraryBackupError("Cannot remove temporary payload directories.")
        }
    }
    func validate(_ plan: LibraryRestorePlan) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !transactionClaimed else {
            throw LibraryBackupError("Restore staging belongs to a transaction.")
        }
        try owned()
        let new = root.appendingPathComponent("new")
        let loaded = try ManagedWallpaperStore(storage: new.appendingPathComponent("library.json"))
            .load()
        guard loaded.count == plan.library.count else {
            throw LibraryBackupError("Reconstructed library count mismatch.")
        }
        for (actual, expected) in zip(loaded, plan.library) {
            guard actual.id == expected.id, actual.title == expected.title,
                actual.kind == expected.kind,
                actual.managed == expected.managed, actual.sceneSource == expected.sceneSource,
                actual.scenePlaybackMode == expected.scenePlaybackMode,
                actual.path.hasPrefix(new.path + "/Wallpapers/"),
                actual.root.hasPrefix(new.path + "/Wallpapers/")
            else {
                throw LibraryBackupError("Invalid reconstructed managed record.")
            }
            let fd = try LibraryBackupIO.input(actual.url)
            close(fd)
        }
        let playlists = try WallpaperPlaylistStore(
            url: new.appendingPathComponent("playlists.json")
        ).load()
        guard playlists == plan.playlists, playlists.playback == nil else {
            throw LibraryBackupError("Reconstructed playlists changed.")
        }
        let newFD = try folder("new", create: false)
        defer { close(newFD) }
        let names = try Self.inventory(newFD)
        guard Set(names) == Set(plan.files.map(\.target)).union(["library.json", "playlists.json"])
        else {
            throw LibraryBackupError("Unexpected reconstructed files.")
        }
        for file in plan.files {
            let fd = try LibraryBackupIO.input(new.appendingPathComponent(file.target))
            defer { close(fd) }
            let (size, hash) = try LibraryBackupIO.stream(fd) { _ in }
            guard size == file.source.size, hash == file.source.sha256 else {
                throw LibraryBackupError("Staged payload integrity mismatch.")
            }
        }
        let projectFiles = Dictionary(grouping: plan.files) {
            $0.target.split(separator: "/").prefix(3).joined(separator: "/")
        }
        for project in plan.projects {
            let projectRoot = new.appendingPathComponent(project.directory)
            let data = try WSSAssetIO.read(
                root: projectRoot, path: "scene.wss.json", limit: WSSSceneDocumentV1.byteLimit)
            try LibraryRestoreJSON.validate(data)
            let wallpaper = Wallpaper(
                id: project.id, title: "Restore validation",
                path: projectRoot.appendingPathComponent("scene.wss.json").path,
                root: projectRoot.path, kind: .scene,
                managed: .init(directory: "WSS/" + project.id.uuidString, entry: "scene.wss.json"),
                sceneSource: .nativeWSS)
            let loaded = try WSSEditorProjectLoader.read(
                handle: WSSProjectHandle(
                    wallpaper: wallpaper, root: projectRoot,
                    entry: wallpaper.url, origin: .native))
            let actual = Set(
                (projectFiles[project.directory] ?? []).map {
                    String($0.target.dropFirst(project.directory.count + 1))
                })
            let expected = Set(
                loaded.document.referencedPaths.map { $0.precomposedStringWithCanonicalMapping }
            ).union(["scene.wss.json"])
            guard actual == expected else {
                throw LibraryBackupError(
                    "WSS payload does not exactly match its referenced resources.")
            }
        }
        try owned()
    }
    func discard() throws {
        lock.lock()
        defer { lock.unlock() }
        if discarded { return }
        guard !transactionClaimed else {
            throw LibraryBackupError("Restore staging belongs to a transaction.")
        }
        if output >= 0 {
            close(output)
            output = -1
        }
        try owned()
        // Deliberately no Task cancellation checks in owned cleanup.
        for name in try Self.children(directory) where name != "owner.json" {
            try Self.remove(directory, name)
        }
        try owned()
        guard unlinkat(directory, "owner.json", 0) == 0,
            unlinkat(parent, id.uuidString, AT_REMOVEDIR) == 0
        else {
            throw LibraryBackupError("Could not remove owned restore staging.")
        }
        discarded = true
    }
    func claimTransaction() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        try owned()
        guard !transactionClaimed else {
            throw LibraryBackupError("Restore staging is already claimed.")
        }
        transactionClaimed = true
        return root
    }
    func releaseTransactionClaim() {
        lock.lock()
        defer { lock.unlock() }
        transactionClaimed = false
    }
    private static func children(_ fd: Int32) throws -> [String] {
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard copy >= 0 else { throw LibraryBackupError("Cannot enumerate staging.") }
        guard let stream = fdopendir(copy) else {
            close(copy)
            throw LibraryBackupError("Cannot enumerate staging.")
        }
        defer { closedir(stream) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { result.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw LibraryBackupError("Staging directory enumeration failed.") }
        return result
    }
    private static func inventory(_ fd: Int32, prefix: String = "") throws -> [String] {
        var result: [String] = []
        for name in try children(fd) {
            try Task.checkCancellation()
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw LibraryBackupError("Cannot inspect staging file.")
            }
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else { throw LibraryBackupError("Unsafe staging folder.") }
                defer { close(next) }
                result += try inventory(next, prefix: prefix + name + "/")
            } else {
                guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else {
                    throw LibraryBackupError("Unexpected staging link or special file.")
                }
                result.append(prefix + name)
            }
        }
        return result
    }
    private static func removeContents(_ fd: Int32) throws {
        for name in try children(fd) { try remove(fd, name) }
    }
    private static func remove(_ fd: Int32, _ name: String) throws {
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw LibraryBackupError("Cannot inspect owned cleanup entry.")
        }
        if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard child >= 0 else { throw LibraryBackupError("Unsafe owned cleanup folder.") }
            defer { close(child) }
            var pinned = stat()
            guard fstat(child, &pinned) == 0, pinned.st_ino == info.st_ino,
                pinned.st_dev == info.st_dev
            else { throw LibraryBackupError("Owned cleanup identity changed.") }
            try removeContents(child)
            guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else {
                throw LibraryBackupError("Cannot remove owned staging directory.")
            }
        } else {
            // Unlinking a link never follows it. Only entries inside our proven
            // transaction are removed, even after injected failure or cancellation.
            guard unlinkat(fd, name, 0) == 0 else {
                throw LibraryBackupError("Cannot remove owned staging file.")
            }
        }
    }
}
