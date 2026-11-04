import Darwin
import Foundation

// A separate creation operation, never a normal save/receipt for source A.
struct WSSSaveAsSnapshot {
    let operationID = UUID()
    let destinationID: UUID
    let sessionID: UUID
    let revision: UInt64
    let source: WSSProjectHandle
    let diskBasis: WSSProjectDiskBasis
    let model: WSSSceneDocumentV1
    let catalog: [String: WSSContentFingerprint]
    let generations: [String: WSSImageGeneration]
    init(
        document: WSSSceneDocumentV1, state: WSSEditorDocumentState, source: WSSProjectHandle,
        name: String, destinationID: UUID = UUID()
    ) throws {
        self.destinationID = destinationID
        let title = try Self.title(name)
        sessionID = state.sessionID
        revision = state.workingRevision
        self.source = source
        diskBasis = state.diskBasis
        var model = document
        model.title = title
        _ = try model.encoded()
        self.model = model
        catalog = state.resourceCatalog.filter { model.referencedPaths.contains($0.key) }
        generations = state.sessionAssets.filter { model.referencedPaths.contains($0.key) }
        guard Set(catalog.keys) == model.referencedPaths else { throw WSSSaveAsError.conflict }
    }
    static func title(_ name: String) throws -> String {
        let title = try WallpaperTitle.normalized(name)
        guard title.utf8.count <= 1024 else { throw WSSSaveAsError.name }
        return title
    }
    func checkBudget(limit: Int = WSSSaveAsPreparation.projectLimit) throws {
        var available = limit - (try model.encoded()).count
        guard available >= 0 else { throw WSSSaveAsError.budget }
        for fingerprint in catalog.values {
            guard fingerprint.byteCount >= 0, fingerprint.byteCount <= 128 * 1024 * 1024,
                fingerprint.byteCount <= available
            else { throw WSSSaveAsError.budget }
            available -= fingerprint.byteCount
        }
    }
}

struct WSSSaveAsReceipt {
    let operationID: UUID
    let project: WSSLoadedEditorProject
    let warnings: [String]
    // Construction means library.json has committed. Follow-up failures cannot undo it.
}

enum WSSSaveAsError: LocalizedError {
    case name, budget, conflict, collision, storage, invalid, cleanup, library, busy
    var errorDescription: String? {
        switch self {
        case .busy: return "Wait for Save As to finish before opening this copy."
        case .name: return "Use a wallpaper name with at most 1024 UTF-8 bytes."
        case .budget: return "The new wallpaper exceeds the 512 MiB project budget."
        case .conflict:
            return
                "The source wallpaper or its resources changed. Your editor changes are still here."
        case .collision:
            return
                "The new wallpaper destination is already in use. Nothing was replaced. Please try again."
        case .storage:
            return
                "The new wallpaper could not be written safely. Your original wallpaper is unchanged."
        case .invalid:
            return
                "The copied wallpaper could not be validated. Your original wallpaper is unchanged."
        case .cleanup:
            return
                "The copy failed and its temporary project could not be safely removed. The original wallpaper is unchanged."
        case .library:
            return
                "The copy could not be added to the library. A complete unreferenced project may remain; your original wallpaper is unchanged."
        }
    }
}

enum WSSSaveAsStage {
    case resourceRead, staging, write, flush, close, fingerprint, preparation
    case projectPublish, finalValidation, libraryPersistence, libraryCommit, afterCommit
}
typealias WSSSaveAsCheckpoint = (WSSSaveAsStage) throws -> Void

// Owns exclusively created staging, with inode-checked descriptor-relative cleanup.
final class WSSSaveAsStaging: @unchecked Sendable {
    let parent: URL
    let name: String
    let parentFD: Int32
    let directory: Int32
    private let inode: ino_t
    private let device: dev_t
    private var files: [(String, ino_t, dev_t)] = []
    private var folders: [(String, ino_t, dev_t)] = []
    private(set) var published = false
    private var publishedName: String?
    var url: URL { parent.appendingPathComponent(name) }
    init(parent: URL, draft: Bool = false) throws {
        self.parent = parent
        name = (draft ? ProductIdentity.draftPrefix : ".wss-saveas-") + UUID().uuidString
        let fd = try WSSAssetIO.directory(parent)
        guard mkdirat(fd, name, mode_t(0o700)) == 0 else {
            Darwin.close(fd)
            throw WSSSaveAsError.storage
        }
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        var info = stat()
        guard child >= 0, fstat(child, &info) == 0, info.st_uid == geteuid() else {
            if child >= 0 { Darwin.close(child) }
            unlinkat(fd, name, AT_REMOVEDIR)
            Darwin.close(fd)
            throw WSSSaveAsError.storage
        }
        parentFD = fd
        directory = child
        inode = info.st_ino
        device = info.st_dev
    }
    deinit {
        Darwin.close(directory)
        Darwin.close(parentFD)
    }
    private func parentDescriptor(_ path: String, create: Bool) throws -> (Int32, String) {
        try WSSNativeAssets.validatePath(path)
        let parts = path.split(separator: "/").map(String.init)
        var fd = dup(directory)
        guard fd >= 0 else { throw WSSSaveAsError.storage }
        do {
            var prefix: [String] = []
            for part in parts.dropLast() {
                prefix.append(part)
                if create {
                    if mkdirat(fd, part, mode_t(0o700)) == 0 {
                        var info = stat()
                        guard fstatat(fd, part, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                            throw WSSSaveAsError.storage
                        }
                        folders.append((prefix.joined(separator: "/"), info.st_ino, info.st_dev))
                    } else if errno != EEXIST {
                        throw WSSSaveAsError.storage
                    }
                }
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else { throw WSSSaveAsError.storage }
                Darwin.close(fd)
                fd = next
            }
            return (fd, parts.last!)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }
    func write(_ bytes: Data, path: String, checkpoint: WSSSaveAsCheckpoint?) throws {
        let (parent, leaf) = try parentDescriptor(path, create: true)
        defer { Darwin.close(parent) }
        var file = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard file >= 0 else { throw WSSSaveAsError.collision }
        defer { if file >= 0 { Darwin.close(file) } }
        var info = stat()
        guard fstat(file, &info) == 0 else { throw WSSSaveAsError.storage }
        files.append((path, info.st_ino, info.st_dev))
        try checkpoint?(.write)
        try WSSAssetIO.write(
            bytes, to: file,
            checkpoint: { stage in
                if stage == .assetFlush { try checkpoint?(.flush) }
            })
        try checkpoint?(.close)
        let result = Darwin.close(file)
        file = -1
        guard result == 0, fsync(parent) == 0 else { throw WSSSaveAsError.storage }
    }
    func syncDirectories(checkpoint: WSSSaveAsCheckpoint?) throws {
        for (path, _, _) in folders.reversed() {
            let (parent, leaf) = try parentDescriptor(path, create: false)
            defer { Darwin.close(parent) }
            let folder = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard folder >= 0 else { throw WSSSaveAsError.storage }
            defer { Darwin.close(folder) }
            try checkpoint?(.flush)
            guard fsync(folder) == 0 else { throw WSSSaveAsError.storage }
        }
        guard fsync(directory) == 0 else { throw WSSSaveAsError.storage }
    }
    func verifyOwnership() throws {
        var info = stat()
        guard fstatat(parentFD, publishedName ?? name, &info, AT_SYMLINK_NOFOLLOW) == 0,
            info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_ino == inode,
            info.st_dev == device, info.st_uid == geteuid()
        else { throw WSSSaveAsError.cleanup }
        let currentParent = try WSSAssetIO.directory(parent)
        defer { Darwin.close(currentParent) }
        var pinned = stat()
        var current = stat()
        guard fstat(parentFD, &pinned) == 0, fstat(currentParent, &current) == 0,
            pinned.st_dev == current.st_dev, pinned.st_ino == current.st_ino
        else { throw WSSSaveAsError.cleanup }
    }
    func publish(to leaf: String) throws {
        try verifyOwnership()
        guard UUID(uuidString: leaf) != nil,
            renameatx_np(parentFD, name, parentFD, leaf, UInt32(RENAME_EXCL)) == 0
        else { throw WSSSaveAsError.collision }
        published = true
        publishedName = leaf
        guard fsync(parentFD) == 0 else { throw WSSSaveAsError.library }
    }
    func discard() throws {
        guard !published else { return }
        try removeOwnedFiles()
    }
    // Only the owning transaction may roll back before its Library commit.
    func rollbackUnregisteredPublication() throws {
        try removeOwnedFiles()
    }
    private func removeOwnedFiles() throws {
        try verifyOwnership()
        for (path, inode, device) in files.reversed() {
            let (parent, leaf) = try parentDescriptor(path, create: false)
            defer { Darwin.close(parent) }
            var info = stat()
            guard fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0,
                info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_ino == inode,
                info.st_dev == device, unlinkat(parent, leaf, 0) == 0
            else { throw WSSSaveAsError.cleanup }
        }
        for (path, inode, device) in folders.reversed() {
            let (parent, leaf) = try parentDescriptor(path, create: false)
            defer { Darwin.close(parent) }
            var info = stat()
            guard fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0,
                info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_ino == inode,
                info.st_dev == device, unlinkat(parent, leaf, AT_REMOVEDIR) == 0
            else { throw WSSSaveAsError.cleanup }
        }
        guard unlinkat(parentFD, publishedName ?? name, AT_REMOVEDIR) == 0 else {
            throw WSSSaveAsError.cleanup
        }
    }
}

actor WSSSaveAsPreparation {
    static let projectLimit = 512 * 1024 * 1024
    func prepare(_ snapshot: WSSSaveAsSnapshot, item: Wallpaper, checkpoint: WSSSaveAsCheckpoint?)
        throws -> WSSSaveAsStaging
    {
        try snapshot.checkBudget()
        try snapshot.diskBasis.verify(snapshot.source)
        try checkpoint?(.staging)
        let staging = try WSSSaveAsStaging(
            parent: URL(fileURLWithPath: item.root).deletingLastPathComponent())
        do {
            for path in snapshot.model.referencedPaths.sorted() {
                try Task.checkCancellation()
                try checkpoint?(.resourceRead)
                guard let expected = snapshot.catalog[path] else { throw WSSSaveAsError.conflict }
                let bytes: Data
                if let generation = snapshot.generations[path] {
                    bytes = try generation.read()
                } else {
                    bytes = try WSSAssetIO.read(
                        root: snapshot.source.root, path: path, limit: expected.byteCount)
                }
                guard WSSContentFingerprint(bytes) == expected else {
                    throw WSSSaveAsError.conflict
                }
                try staging.write(bytes, path: path, checkpoint: checkpoint)
            }
            try staging.write(
                snapshot.model.encoded(), path: "scene.wss.json", checkpoint: checkpoint)
            try checkpoint?(.fingerprint)
            for (path, expected) in snapshot.catalog {
                guard
                    WSSContentFingerprint(
                        try WSSAssetIO.read(
                            root: staging.url, path: path, limit: expected.byteCount)) == expected
                else { throw WSSSaveAsError.conflict }
            }
            try checkpoint?(.preparation)
            var stagedItem = item
            stagedItem.root = staging.url.path
            stagedItem.path = staging.url.appendingPathComponent("scene.wss.json").path
            let loaded = try WSSEditorProjectLoader.read(stagedItem)
            guard loaded.document == snapshot.model, loaded.diskBasis.assets == snapshot.catalog
            else { throw WSSSaveAsError.invalid }
            try snapshot.diskBasis.verify(snapshot.source)
            try Task.checkCancellation()
            try staging.syncDirectories(checkpoint: checkpoint)
            return staging
        } catch {
            do { try staging.discard() } catch { throw WSSSaveAsError.cleanup }
            if let known = error as? WSSSaveAsError { throw known }
            if error is CancellationError { throw CancellationError() }
            throw WSSSaveAsError.invalid
        }
    }
}

// Library replacement is the logical commit point, not the preceding project rename.
enum WSSSaveAsLibraryWriter {
    static func commit(before: Data?, after: Data, storage: URL, checkpoint: WSSSaveAsCheckpoint?)
        throws -> [String]
    {
        guard (before?.count ?? 0) <= WSSSaveAsPreparation.projectLimit,
            after.count <= WSSSaveAsPreparation.projectLimit
        else { throw WSSSaveAsError.library }
        let parent = try WSSAssetIO.directory(storage.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        let original = openat(parent, storage.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        defer { if original >= 0 { Darwin.close(original) } }
        var info = stat()
        if let before {
            guard original >= 0, fstat(original, &info) == 0, info.st_uid == geteuid(),
                try WSSAssetIO.read(original, limit: before.count) == before
            else { throw WSSSaveAsError.library }
        } else {
            guard original < 0, errno == ENOENT else {
                throw WSSSaveAsError.library
            }
        }
        let temp = ".wss-library-" + UUID().uuidString
        var file = openat(parent, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard file >= 0 else { throw WSSSaveAsError.library }
        var ownsTemp = true
        do {
            guard
                original < 0
                    || fcopyfile(original, file, nil, copyfile_flags_t(COPYFILE_SECURITY)) == 0
            else {
                throw WSSSaveAsError.library
            }
            try WSSAssetIO.write(
                after, to: file,
                checkpoint: { stage in
                    if stage == .assetFlush { try checkpoint?(.flush) }
                })
            try checkpoint?(.close)
            let result = Darwin.close(file)
            file = -1
            guard result == 0 else { throw WSSSaveAsError.library }
            try checkpoint?(.libraryCommit)
            let currentParent = try WSSAssetIO.directory(storage.deletingLastPathComponent())
            defer { Darwin.close(currentParent) }
            var pinned = stat()
            var current = stat()
            var target = stat()
            guard fstat(parent, &pinned) == 0, fstat(currentParent, &current) == 0,
                pinned.st_dev == current.st_dev, pinned.st_ino == current.st_ino
            else { throw WSSSaveAsError.library }
            if let before {
                guard fstatat(parent, storage.lastPathComponent, &target, AT_SYMLINK_NOFOLLOW) == 0,
                    target.st_ino == info.st_ino, target.st_dev == info.st_dev,
                    target.st_uid == info.st_uid, target.st_gid == info.st_gid,
                    target.st_mode == info.st_mode,
                    target.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
                    target.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec,
                    try WSSAssetIO.read(
                        root: storage.deletingLastPathComponent(),
                        path: storage.lastPathComponent, limit: before.count) == before
                else { throw WSSSaveAsError.library }
            }
            try Task.checkCancellation()
            let publishResult =
                before == nil
                ? renameatx_np(parent, temp, parent, storage.lastPathComponent, UInt32(RENAME_EXCL))
                : renameat(parent, temp, parent, storage.lastPathComponent)
            guard publishResult == 0 else { throw WSSSaveAsError.library }
            // COMMIT. No cancellation or failure may turn this into an unsaved result.
            ownsTemp = false
        } catch {
            if file >= 0 { Darwin.close(file) }
            if ownsTemp, unlinkat(parent, temp, 0) != 0, errno != ENOENT {
                throw WSSSaveAsError.cleanup
            }
            throw WSSSaveAsError.library
        }
        var warnings: [String] = []
        if fsync(parent) != 0 {
            warnings.append(EditorText.warningCopyDirectory.text)
        }
        do { try checkpoint?(.afterCommit) } catch {
            warnings.append(EditorText.warningCopyCommitted.text)
        }
        return warnings
    }
}
