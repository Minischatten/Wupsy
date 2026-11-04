import Darwin
import Foundation

// Internal root lock. 8B.3 must additionally exclude backup/mutations and drain
// all runtime users before constructing the transaction capability.
final class RestoreTransactionIO {
    let root: URL
    let support: Int32
    let restore: Int32
    let staging: Int32
    private let lock: Int32
    static let journalLimit = 128 << 20
    init(root: URL) throws {
        self.root = root.standardizedFileURL
        support = try WSSAssetIO.directory(self.root)
        do {
            restore = try Self.folder(support, ".restore", create: true)
        } catch {
            close(support)
            throw error
        }
        do {
            staging = try Self.folder(restore, "staging", create: true)
        } catch {
            close(restore)
            close(support)
            throw error
        }
        let descriptor = openat(
            restore, "transaction.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        var info = stat()
        guard descriptor >= 0, fstat(descriptor, &info) == 0,
            info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1,
            info.st_uid == getuid(), flock(descriptor, LOCK_EX | LOCK_NB) == 0
        else {
            if descriptor >= 0 { close(descriptor) }
            close(staging)
            close(restore)
            close(support)
            throw LibraryBackupError("Another restore transaction is active or its lock is unsafe.")
        }
        lock = descriptor
    }
    deinit {
        flock(lock, LOCK_UN)
        close(lock)
        close(staging)
        close(restore)
        close(support)
    }
    static func folder(_ parent: Int32, _ name: String, create: Bool = false) throws -> Int32 {
        if create, mkdirat(parent, name, 0o700) != 0, errno != EEXIST {
            throw LibraryBackupError("Cannot create transaction folder.")
        }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw LibraryBackupError("Unsafe or missing transaction folder.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            close(fd)
            throw LibraryBackupError("Unsafe transaction folder ownership.")
        }
        return fd
    }
    static func parent(_ root: Int32, _ path: String, create: Bool = false) throws -> (
        Int32, String
    ) {
        let parts = try ManagedWallpaperStore.components(path)
        var fd = dup(root)
        guard fd >= 0 else { throw LibraryBackupError("Cannot pin transaction parent.") }
        do {
            for part in parts.dropLast() {
                let next = try folder(fd, part, create: create)
                close(fd)
                fd = next
            }
            return (fd, parts.last!)
        } catch {
            close(fd)
            throw error
        }
    }
    static func identity(_ fd: Int32, _ path: String) throws -> RestoreObjectIdentity? {
        let (parent, name) = try parent(fd, path)
        defer { close(parent) }
        return try RestoreObjectIdentity.read(parent, name)
    }
    static func optionalIdentity(_ root: Int32, _ path: String) throws -> RestoreObjectIdentity? {
        let parts = try ManagedWallpaperStore.components(path)
        var fd = dup(root)
        guard fd >= 0 else { throw LibraryBackupError("Cannot inspect cleanup slot parent.") }
        defer { close(fd) }
        for part in parts.dropLast() {
            guard let identity = try RestoreObjectIdentity.read(fd, part) else { return nil }
            guard identity.kind == UInt16(S_IFDIR) else {
                throw LibraryBackupError("Unsafe cleanup slot parent.")
            }
            let next = try folder(fd, part)
            close(fd)
            fd = next
        }
        return try RestoreObjectIdentity.read(fd, parts.last!)
    }
    static func read(_ root: Int32, _ path: String, limit: Int) throws -> Data {
        let (parent, name) = try parent(root, path)
        defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw LibraryBackupError("Cannot open transaction data.") }
        defer { close(fd) }
        guard try RestoreObjectIdentity.descriptor(fd).kind == UInt16(S_IFREG) else {
            throw LibraryBackupError("Unsafe transaction data.")
        }
        return try WSSAssetIO.read(fd, limit: limit)
    }
    static func sync(_ fd: Int32) throws {
        guard fsync(fd) == 0 else {
            throw LibraryBackupError("Cannot synchronize restore filesystem state.")
        }
        if fcntl(fd, F_FULLFSYNC) != 0, errno != ENOTSUP, errno != EINVAL {
            throw LibraryBackupError("Cannot fully synchronize restore filesystem state.")
        }
    }
    static func children(_ fd: Int32) throws -> [String] {
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard copy >= 0 else { throw LibraryBackupError("Cannot enumerate transaction folder.") }
        guard let stream = fdopendir(copy) else {
            close(copy)
            throw LibraryBackupError("Cannot enumerate transaction folder.")
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
        guard errno == 0 else {
            throw LibraryBackupError("Cannot completely enumerate transaction folder.")
        }
        return result.sorted()
    }
    static func inventory(_ fd: Int32, prefix: String = "", count: inout Int) throws -> [String] {
        var result: [String] = []
        for name in try children(fd) {
            guard let identity = try RestoreObjectIdentity.read(fd, name) else {
                throw LibraryBackupError("Target inventory changed.")
            }
            if identity.kind == UInt16(S_IFDIR) {
                let next = try folder(fd, name)
                defer { close(next) }
                result += try inventory(next, prefix: prefix + name + "/", count: &count)
            } else {
                count += 1
                guard count <= LibraryBackupLimits.files else {
                    throw LibraryBackupError("Target inventory exceeds its budget.")
                }
                result.append(prefix + name)
            }
        }
        return result
    }
    static func flushTree(_ fd: Int32) throws {
        for name in try children(fd) {
            let identity = try RestoreObjectIdentity.read(fd, name)!
            let child = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard child >= 0 else { throw LibraryBackupError("Cannot flush transaction object.") }
            defer { close(child) }
            guard try RestoreObjectIdentity.descriptor(child) == identity else {
                throw LibraryBackupError("Transaction object changed.")
            }
            if identity.kind == UInt16(S_IFDIR) { try flushTree(child) } else { try sync(child) }
        }
        try sync(fd)
    }
    static func write(_ data: Data, root: Int32, name: String) throws {
        let file = openat(root, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else {
            throw LibraryBackupError("Cannot exclusively write transaction data.")
        }
        defer { close(file) }
        try WSSAssetIO.write(data, to: file)
        try sync(root)
    }
    func load() throws -> LibraryRestoreJournal? {
        guard try RestoreObjectIdentity.read(restore, "journal.json") != nil else { return nil }
        let value = try LibraryRestoreJSON.decode(
            LibraryRestoreJournal.self,
            from: Self.read(restore, "journal.json", limit: Self.journalLimit))
        try value.validate()
        return value
    }
    func persist(
        _ journal: LibraryRestoreJournal, transaction: Int32,
        checkpoint: LibraryRestoreTransaction.Checkpoint
    ) throws {
        try journal.validate()
        let bytes = try JSONEncoder().encode(journal)
        guard bytes.count <= Self.journalLimit else {
            throw LibraryBackupError("Restore journal exceeds its budget.")
        }
        let priorIdentity = try RestoreObjectIdentity.read(restore, "journal.json")
        if let prior = try load() {
            guard prior.id == journal.id, prior.owner == journal.owner else {
                throw LibraryBackupError("Another transaction owns the journal.")
            }
        }
        let name = ".journal-" + UUID().uuidString
        try Self.write(bytes, root: transaction, name: name)
        try checkpoint(.journalTempWritten, journal.phase.rawValue)
        guard try RestoreObjectIdentity.read(restore, "journal.json") == priorIdentity else {
            throw LibraryBackupError("Journal changed before atomic publication.")
        }
        guard
            renameatx_np(
                transaction, name, restore, "journal.json",
                priorIdentity == nil ? UInt32(RENAME_EXCL) : 0) == 0
        else { throw LibraryBackupError("Cannot publish restore journal.") }
        try checkpoint(.journalRenamed, journal.phase.rawValue)
        try Self.sync(transaction)
        try Self.sync(restore)
    }
    func verify(_ journal: LibraryRestoreJournal, preferenceDomain: String) throws -> Int32? {
        try journal.validate()
        guard journal.preferenceDomain == preferenceDomain,
            try RestoreObjectIdentity.descriptor(support) == journal.support,
            try RestoreObjectIdentity.descriptor(staging) == journal.stagingParent
        else { throw LibraryBackupError("Restore journal root/domain identity mismatch.") }
        let currentSupport = try WSSAssetIO.directory(root)
        defer { close(currentSupport) }
        let currentRestore = try Self.folder(currentSupport, ".restore")
        defer { close(currentRestore) }
        let currentStaging = try Self.folder(currentRestore, "staging")
        defer { close(currentStaging) }
        guard try RestoreObjectIdentity.descriptor(currentSupport) == journal.support,
            try RestoreObjectIdentity.descriptor(currentRestore)
                == RestoreObjectIdentity.descriptor(restore),
            try RestoreObjectIdentity.descriptor(currentStaging) == journal.stagingParent,
            try RestoreObjectIdentity.read(currentRestore, "transaction.lock")
                == RestoreObjectIdentity.descriptor(lock)
        else {
            throw LibraryBackupError("Restore root namespace changed.")
        }
        let actual = try RestoreObjectIdentity.read(staging, journal.id.uuidString)
        if actual == nil,
            journal.phase == .cleanupComplete || journal.phase == .rollbackCleanupComplete
        {
            return nil
        }
        guard actual == journal.transaction else {
            throw LibraryBackupError("Restore transaction identity mismatch.")
        }
        let fd = try Self.folder(staging, journal.id.uuidString)
        do {
            if try RestoreObjectIdentity.read(fd, "owner.json") == nil,
                journal.phase == .cleanupComplete || journal.phase == .rollbackCleanupComplete
            {
                guard try Self.children(fd).isEmpty else {
                    throw LibraryBackupError("Unexpected terminal cleanup data.")
                }
                return fd
            }
            guard try Self.read(fd, "owner.json", limit: 1024) == journal.owner else {
                throw LibraryBackupError("Restore ownership token mismatch.")
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }
    static func remove(
        _ root: Int32, _ name: String, checkpoint: LibraryRestoreTransaction.Checkpoint,
        depth: Int = 0
    ) throws {
        guard depth <= 64 else {
            throw LibraryBackupError("Owned cleanup nesting exceeds its safety budget.")
        }
        var info = stat()
        guard fstatat(root, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw LibraryBackupError("Cannot inspect cleanup object.")
        }
        try checkpoint(.cleanupEntry, name)
        if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
            let fd = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0 else { throw LibraryBackupError("Unsafe cleanup folder.") }
            defer { close(fd) }
            guard try RestoreObjectIdentity.descriptor(fd) == RestoreObjectIdentity(info) else {
                throw LibraryBackupError("Cleanup identity changed.")
            }
            for child in try children(fd) {
                try remove(fd, child, checkpoint: checkpoint, depth: depth + 1)
            }
            try sync(fd)
            guard unlinkat(root, name, AT_REMOVEDIR) == 0 else {
                throw LibraryBackupError("Cannot remove owned cleanup directory.")
            }
        } else {
            guard unlinkat(root, name, 0) == 0 else {
                throw LibraryBackupError("Cannot unlink owned cleanup entry.")
            }
        }
        try sync(root)
    }
}
