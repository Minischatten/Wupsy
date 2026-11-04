import CArchive
import CryptoKit
import Darwin
import Foundation

enum LibraryBackupIO {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func input(_ url: URL) throws -> Int32 {
        guard try url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile != true else {
            throw LibraryBackupError("Finder aliases are not supported in backup sources.")
        }
        let parent = try WSSAssetIO.directory(url.deletingLastPathComponent())
        defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw LibraryBackupError("Cannot read a backup source file.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            info.st_nlink == 1, info.st_size >= 0, info.st_size <= LibraryBackupLimits.file
        else {
            close(fd)
            throw LibraryBackupError("Unsupported source file type, hardlink, or size.")
        }
        return fd
    }
    @discardableResult static func stream(
        _ fd: Int32, consume: (UnsafeRawBufferPointer) throws -> Void
    ) throws -> (Int64, String) {
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw LibraryBackupError("Cannot inspect source.") }
        var buffer = [UInt8](repeating: 0, count: LibraryBackupLimits.chunk)
        var hash = SHA256()
        var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { throw LibraryBackupError("Could not read backup data.") }
            if n == 0 { break }
            count += Int64(n)
            guard count <= LibraryBackupLimits.file else {
                throw LibraryBackupError("Backup file limit exceeded.")
            }
            try buffer.withUnsafeBytes {
                let chunk = UnsafeRawBufferPointer(rebasing: $0[..<n])
                hash.update(bufferPointer: chunk)
                try consume(chunk)
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
            before.st_size == count, after.st_size == count,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else {
            throw LibraryBackupError("Source changed while creating the backup snapshot.")
        }
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func write(_ bytes: UnsafeRawBufferPointer, fd: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else {
                throw LibraryBackupError("Could not write backup data; check available disk space.")
            }
            offset += n
        }
    }
    static func available(_ url: URL, needed: Int64) throws {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < needed {
            throw LibraryBackupError("Not enough available space for this backup.")
        }
    }
}

final class LibraryBackupStaging {
    let url: URL
    private let device: dev_t
    private let inode: ino_t
    init(parent: URL = FileManager.default.temporaryDirectory) throws {
        var template = Array(
            parent.appendingPathComponent(ProductIdentity.backupTemporaryTemplate).path.utf8CString)
        guard let path = mkdtemp(&template) else {
            throw LibraryBackupError("Cannot create backup snapshot staging.")
        }
        url = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw LibraryBackupError("Cannot inspect snapshot staging.")
        }
        device = info.st_dev
        inode = info.st_ino
    }
    func discard() throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_dev == device, info.st_ino == inode,
            info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw LibraryBackupError("Snapshot ownership changed; cleanup refused.")
        }
        try ManagedWallpaperStore.inspectTree(url)
        try FileManager.default.removeItem(at: url)
    }
}

enum LibraryBackupArchive {
    static func check(_ code: Int32, _ archive: OpaquePointer) throws {
        guard code == 0 else {
            throw LibraryBackupError(
                archive_error_string(archive).map { String(cString: $0) } ?? "ZIP operation failed."
            )
        }
    }
    static func write(
        snapshot: URL, manifest: LibraryBackupManifest, fd: Int32,
        progress: @Sendable (String) -> Void,
        entryProgress: @Sendable (String) -> Void = { _ in }
    ) throws {
        guard let a = archive_write_new() else {
            throw LibraryBackupError("Cannot create ZIP writer.")
        }
        defer { archive_write_free(a) }
        try check(archive_write_set_format_zip(a), a)
        // STORE avoids wasting CPU recompressing already-compressed photos/videos.
        // Force ZIP64 even for tiny archives so every backup exercises the same path.
        try check(archive_write_set_options(a, "zip:zip64,zip:compression=store"), a)
        try check(archive_write_open_fd(a, fd), a)
        for path in ["backup.json"] + manifest.files.map(\.path) {
            try Task.checkCancellation()
            progress("Writing backup… \(path)")
            entryProgress(path)
            let source = try LibraryBackupIO.input(snapshot.appendingPathComponent(path))
            defer { close(source) }
            var info = stat()
            guard fstat(source, &info) == 0, let entry = archive_entry_new() else {
                throw LibraryBackupError("Cannot create ZIP entry.")
            }
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname(entry, path)
            archive_entry_set_size(entry, info.st_size)
            archive_entry_set_filetype(entry, UInt32(S_IFREG))
            archive_entry_set_perm(entry, 0o600)
            try check(archive_write_header(a, entry), a)
            try LibraryBackupIO.stream(source) { bytes in
                var offset = 0
                while offset < bytes.count {
                    let n = archive_write_data(
                        a, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard n > 0 else { throw LibraryBackupError("Could not write ZIP data.") }
                    offset += n
                }
            }
        }
        try check(archive_write_close(a), a)
        guard fsync(fd) == 0 else { throw LibraryBackupError("Could not flush backup archive.") }
    }
    static func regularEntry(_ entry: OpaquePointer) throws {
        guard archive_entry_filetype(entry) == UInt32(S_IFREG),
            archive_entry_symlink(entry) == nil, archive_entry_hardlink(entry) == nil,
            archive_entry_is_encrypted(entry) == 0
        else {
            throw LibraryBackupError("ZIP links, encryption and special files are unsupported.")
        }
    }
    // Read-only verifier, never an extractor. A seekable reader checks the ZIP
    // central directory as well as entry contents. No paths are written to disk.
    static func verify(
        fd: Int32, expected: LibraryBackupManifest,
        progress: @Sendable (String) -> Void = { _ in },
        entryProgress: @Sendable (String) -> Void = { _ in }
    ) throws {
        _ = try read(fd: fd, expected: expected, progress: progress, entryProgress: entryProgress)
    }
    // One entry/hash engine: backup verifies; restore supplies a private staging sink.
    static func read(
        fd: Int32, expected: LibraryBackupManifest,
        metadataLimit: (String) -> Int64 = { _ in Int64(LibraryBackupLimits.manifest) },
        validateJSON: (Data) throws -> Void = { _ in },
        sink: LibraryBackupReadSink? = nil,
        progress: @Sendable (String) -> Void = { _ in },
        entryProgress: @Sendable (String) -> Void = { _ in }
    ) throws -> LibraryBackupContents {
        try expected.validate()
        guard lseek(fd, 0, SEEK_SET) == 0, let a = archive_read_new() else {
            throw LibraryBackupError("Cannot reopen backup archive.")
        }
        defer { archive_read_free(a) }
        try check(archive_read_support_format_zip_seekable(a), a)
        try check(archive_read_set_options(a, "zip:hdrcharset=UTF-8"), a)
        try check(archive_read_open_fd(a, fd, LibraryBackupLimits.chunk), a)
        var seen = Set<String>()
        var normalized = Set<String>()
        var metadata: [String: Data] = [:]
        let inventory = Dictionary(uniqueKeysWithValues: expected.files.map { ($0.path, $0) })
        var buffer = [UInt8](repeating: 0, count: LibraryBackupLimits.chunk)
        while true {
            try Task.checkCancellation()
            var entry: OpaquePointer?
            let code = archive_read_next_header(a, &entry)
            if code == 1 { break }
            try check(code, a)
            guard let entry, let raw = archive_entry_pathname(entry),
                let path = String(validatingUTF8: raw),
                normalized.insert(try LibraryBackupLimits.path(path)).inserted,
                seen.insert(path).inserted, seen.count <= LibraryBackupLimits.files,
                path == "backup.json" || inventory[path] != nil
            else {
                throw LibraryBackupError("Unexpected or unsafe ZIP entry.")
            }
            try regularEntry(entry)
            let declared =
                path == "backup.json" ? Int64(LibraryBackupLimits.manifest) : inventory[path]!.size
            let capture = !path.contains("/")
            let limit = capture ? min(declared, metadataLimit(path)) : declared
            guard archive_entry_size(entry) >= 0, archive_entry_size(entry) <= limit else {
                throw LibraryBackupError("ZIP entry size mismatch.")
            }
            progress("Verifying backup… \(path)")
            entryProgress(path)
            var size: Int64 = 0
            var hash = SHA256()
            var contents = Data()
            try sink?.begin(path, archive_entry_size(entry))
            while true {
                try Task.checkCancellation()
                let n = buffer.withUnsafeMutableBytes {
                    archive_read_data(a, $0.baseAddress, $0.count)
                }
                guard n >= 0 else { throw LibraryBackupError("ZIP payload is damaged.") }
                if n == 0 { break }
                size += Int64(n)
                guard size <= limit, !capture || size <= LibraryBackupLimits.manifest else {
                    throw LibraryBackupError("ZIP entry exceeds its declared size.")
                }
                try buffer.withUnsafeBytes {
                    let chunk = UnsafeRawBufferPointer(rebasing: $0[..<n])
                    hash.update(bufferPointer: chunk)
                    if capture { contents.append(contentsOf: chunk) }
                    try sink?.write(path, chunk)
                }
            }
            guard size == archive_entry_size(entry) else {
                throw LibraryBackupError("Truncated ZIP entry.")
            }
            if capture { try validateJSON(contents) }
            if path == "backup.json" {
                let decoded = try JSONDecoder().decode(LibraryBackupManifest.self, from: contents)
                try decoded.validate()
                guard decoded == expected else {
                    throw LibraryBackupError("Backup manifest changed.")
                }
            } else {
                let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
                guard size == inventory[path]!.size, actual == inventory[path]!.sha256 else {
                    throw LibraryBackupError("Backup integrity check failed.")
                }
            }
            try sink?.end(path)
            if capture { metadata[path] = contents }
        }
        guard seen == Set(inventory.keys).union(["backup.json"]) else {
            throw LibraryBackupError("Backup is missing declared files.")
        }
        let library = try JSONDecoder().decode(
            [LibraryBackupWallpaper].self, from: metadata["library.json"] ?? Data())
        let playlists = try JSONDecoder().decode(
            PlaylistCollectionState.self, from: metadata["playlists.json"] ?? Data())
        try playlists.validate()
        let ids = Set(library.map(\.id))
        guard library == expected.wallpapers,
            playlists.definitions.map(\.id) == expected.playlistIDs,
            playlists.definitions.allSatisfy({ Set($0.wallpaperIDs).isSubset(of: ids) })
        else {
            throw LibraryBackupError("Backup library and playlist relationships disagree.")
        }
        let org = try JSONDecoder().decode(
            LibraryBackupOrganization.self, from: metadata["organization.json"] ?? Data())
        guard Set(org.favorites).isSubset(of: ids) else {
            throw LibraryBackupError("Invalid favorite reference.")
        }
        let settings = try JSONDecoder().decode(
            LibraryBackupSettings.self, from: metadata["settings.json"] ?? Data())
        let widgets = try JSONDecoder().decode(
            LibraryBackupWidgets.self, from: metadata["widgets.json"] ?? Data())
        return LibraryBackupContents(
            manifest: expected, library: library, playlists: playlists,
            organization: org, settings: settings, widgets: widgets)
    }
}

struct LibraryBackupReadSink {
    let begin: (String, Int64) throws -> Void
    let write: (String, UnsafeRawBufferPointer) throws -> Void
    let end: (String) throws -> Void
}
struct LibraryBackupContents {
    let manifest: LibraryBackupManifest
    let library: [LibraryBackupWallpaper]
    let playlists: PlaylistCollectionState
    let organization: LibraryBackupOrganization
    let settings: LibraryBackupSettings
    let widgets: LibraryBackupWidgets
}
