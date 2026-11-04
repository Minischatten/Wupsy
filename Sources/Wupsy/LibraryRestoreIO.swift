import CArchive
import Darwin
import Foundation

struct LibraryRestoreLimits: Sendable {
    var total = LibraryBackupLimits.total
    var file = LibraryBackupLimits.file
    var files = LibraryBackupLimits.files
    var manifest = LibraryBackupLimits.manifest
    func validate() throws {
        guard total >= 0, total <= LibraryBackupLimits.total, file >= 0,
            file <= LibraryBackupLimits.file, files >= 6, files <= LibraryBackupLimits.files,
            manifest > 0, manifest <= LibraryBackupLimits.manifest
        else {
            throw LibraryBackupError("Invalid restore budgets.")
        }
    }
    var archive: Int64 { total + Int64(files) * 4096 + Int64(manifest) }
    func metadata(_ path: String) -> Int64 {
        switch path {
        case "playlists.json": return min(Int64(manifest), Int64(WallpaperPlaylistStore.byteLimit))
        case "organization.json": return min(Int64(manifest), 4 * 1024 * 1024)
        case "settings.json": return min(Int64(manifest), 4096)
        default: return Int64(manifest)
        }
    }
    func check(_ value: LibraryBackupManifest) throws {
        try value.validate()
        guard value.fileCount <= files, value.totalLogicalSize <= total,
            value.files.allSatisfy({
                $0.size <= file && ($0.path.contains("/") || $0.size <= metadata($0.path))
            })
        else {
            throw LibraryBackupError("Backup exceeds restore budgets.")
        }
    }
}

// This is only a bounded JSON structure/ambiguity check. JSONDecoder remains the
// syntax/type decoder. Keys are decoded to catch escaped duplicate spellings too.
enum LibraryRestoreJSON {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try validate(data)
        return try JSONDecoder().decode(type, from: data)
    }
    static func validate(_ data: Data) throws {
        var scan = Scan(data: data)
        try scan.value(depth: 0)
        scan.space()
        guard scan.index == data.count else { throw LibraryBackupError("Ambiguous backup JSON.") }
    }
    private struct Scan {
        let data: Data
        var index = 0
        var nodes = 0
        mutating func space() {
            while index < data.count, [9, 10, 13, 32].contains(data[index]) { index += 1 }
        }
        mutating func take(_ byte: UInt8) throws {
            space()
            guard index < data.count, data[index] == byte else {
                throw LibraryBackupError("Invalid backup JSON structure.")
            }
            index += 1
        }
        mutating func string(key: Bool) throws -> String? {
            space()
            let start = index
            try take(34)
            while index < data.count {
                let byte = data[index]
                index += 1
                if byte == 34 {
                    return key
                        ? try JSONDecoder().decode(
                            String.self, from: data.subdata(in: start..<index)) : nil
                }
                if byte == 92 {
                    guard index < data.count else { break }
                    let escaped = data[index]
                    index += 1
                    if escaped == 117 {
                        guard data.count - index >= 4 else { break }
                        index += 4
                    }
                }
            }
            throw LibraryBackupError("Unterminated backup JSON string.")
        }
        mutating func value(depth: Int) throws {
            space()
            nodes += 1
            guard depth <= 64, nodes <= LibraryBackupLimits.files * 32 + 1024, index < data.count
            else {
                throw LibraryBackupError("Backup JSON structure exceeds its budget.")
            }
            switch data[index] {
            case 123:
                index += 1
                space()
                if index < data.count, data[index] == 125 {
                    index += 1
                    return
                }
                var keys = Set<String>()
                while true {
                    guard let key = try string(key: true), keys.insert(key).inserted else {
                        throw LibraryBackupError("Duplicate JSON key in backup metadata.")
                    }
                    try take(58)
                    try value(depth: depth + 1)
                    space()
                    if index < data.count, data[index] == 125 {
                        index += 1
                        return
                    }
                    try take(44)
                }
            case 91:
                index += 1
                space()
                if index < data.count, data[index] == 93 {
                    index += 1
                    return
                }
                while true {
                    try value(depth: depth + 1)
                    space()
                    if index < data.count, data[index] == 93 {
                        index += 1
                        return
                    }
                    try take(44)
                }
            case 34: _ = try string(key: false)
            default:
                let start = index
                while index < data.count, ![9, 10, 13, 32, 44, 93, 125].contains(data[index]) {
                    index += 1
                }
                guard index > start else { throw LibraryBackupError("Invalid backup JSON value.") }
            }
        }
    }
}

struct LibraryRestoreZIPEntry {
    let size: Int64
    let offset: Int64
}

// Before the seekable libarchive reader builds its internal index, inspect ONLY
// end records and fixed central headers/name/extra fields. No payload parsing or
// decompression. Bounds come from v1's file/path and writer-overhead budgets.
final class LibraryRestoreArchive {
    let fd: Int32
    let entries: [String: LibraryRestoreZIPEntry]
    let limits: LibraryRestoreLimits
    private let original: stat

    init(url: URL, limits: LibraryRestoreLimits) throws {
        try limits.validate()
        self.limits = limits
        let parent = try WSSAssetIO.directory(url.deletingLastPathComponent())
        defer { close(parent) }
        guard try url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile != true else {
            throw LibraryBackupError("A backup cannot be a Finder alias.")
        }
        let input = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw LibraryBackupError("Cannot open the selected backup.") }
        do {
            var info = stat()
            guard fstat(input, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                info.st_size >= 22, info.st_size <= limits.archive
            else {
                throw LibraryBackupError("Invalid backup file or archive size limit exceeded.")
            }
            original = info
            entries = try Self.preflight(fd: input, size: info.st_size, limits: limits)
            fd = input
        } catch {
            close(input)
            throw error
        }
    }
    deinit { close(fd) }

    static func bytes(_ fd: Int32, offset: Int64, count: Int, size: Int64) throws -> Data {
        guard offset >= 0, count >= 0, offset <= size, Int64(count) <= size - offset else {
            throw LibraryBackupError("ZIP record is outside the backup file.")
        }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < count {
                try Task.checkCancellation()
                let n = pread(
                    fd, buffer.baseAddress!.advanced(by: done), count - done, offset + Int64(done))
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw LibraryBackupError("Truncated or unreadable ZIP record.") }
                done += n
            }
        }
        return data
    }
    private static func preflight(fd: Int32, size: Int64, limits: LibraryRestoreLimits) throws
        -> [String: LibraryRestoreZIPEntry]
    {
        let tailCount = Int(min(size, 65_557))
        let tail = try bytes(fd, offset: size - Int64(tailCount), count: tailCount, size: size)
        var end: Int?
        for i in stride(from: tail.count - 22, through: 0, by: -1) {
            if tail.u32(i) == 0x0605_4b50, i + 22 + Int(tail.u16(i + 20)) == tail.count {
                end = i
                break
            }
        }
        guard let end, tail.u16(end + 4) == 0, tail.u16(end + 6) == 0 else {
            throw LibraryBackupError("Not a single-volume ZIP backup.")
        }
        let endOffset = size - Int64(tailCount) + Int64(end)
        var count = Int64(tail.u16(end + 10))
        var directorySize = Int64(tail.u32(end + 12))
        var directoryOffset = Int64(tail.u32(end + 16))
        var directoryEnd = endOffset
        if endOffset >= 20 {
            let locator = try bytes(fd, offset: endOffset - 20, count: 20, size: size)
            if locator.u32(0) == 0x0706_4b50 {
                guard locator.u32(4) == 0, locator.u32(16) == 1 else {
                    throw LibraryBackupError("Multipart ZIP64 is unsupported.")
                }
                let offset = try locator.i64(8)
                let zip64 = try bytes(fd, offset: offset, count: 56, size: size)
                let recordSize = try zip64.i64(4)
                guard zip64.u32(0) == 0x0606_4b50, recordSize >= 44,
                    offset <= endOffset - 32, recordSize == endOffset - 32 - offset,
                    zip64.u32(16) == 0, zip64.u32(20) == 0,
                    try zip64.i64(24) == zip64.i64(32)
                else { throw LibraryBackupError("Invalid ZIP64 end record.") }
                count = try zip64.i64(32)
                directorySize = try zip64.i64(40)
                directoryOffset = try zip64.i64(48)
                directoryEnd = offset
            } else if count == 65_535 || directorySize == Int64(UInt32.max)
                || directoryOffset == Int64(UInt32.max)
            {
                throw LibraryBackupError("ZIP64 locator is missing.")
            }
        }
        guard tail.u16(end + 8) == tail.u16(end + 10), count >= 1, count <= limits.files,
            directorySize >= count * 46, directorySize <= Int64(limits.files) * 4096,
            directoryOffset >= 0, directoryOffset <= directoryEnd,
            directorySize == directoryEnd - directoryOffset
        else { throw LibraryBackupError("ZIP index exceeds its budget or has invalid bounds.") }
        var cursor = directoryOffset
        var result: [String: LibraryRestoreZIPEntry] = [:]
        var spans: [(Int64, Int64)] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            let h = try bytes(fd, offset: cursor, count: 46, size: directoryEnd)
            let nameLength = Int(h.u16(28))
            let extraLength = Int(h.u16(30))
            let commentLength = Int(h.u16(32))
            guard h.u32(0) == 0x0201_4b50, h.u16(10) == 0, h.u16(8) & ~UInt16(0x0808) == 0,
                nameLength > 0, nameLength <= 1024
            else {
                throw LibraryBackupError(
                    "Unsupported ZIP entry or compression; v1 requires unencrypted STORE files.")
            }
            let nameBytes = try bytes(
                fd, offset: cursor + 46, count: nameLength, size: directoryEnd)
            guard let name = String(data: nameBytes, encoding: .utf8), result[name] == nil else {
                throw LibraryBackupError("Invalid or duplicate ZIP entry name.")
            }
            _ = try LibraryBackupLimits.path(name)
            let mode = h.u32(38) >> 16
            guard mode == 0 || mode & UInt32(S_IFMT) == UInt32(S_IFREG) else {
                throw LibraryBackupError("ZIP links and special files are unsupported.")
            }
            let extra = try bytes(
                fd, offset: cursor + 46 + Int64(nameLength), count: extraLength, size: directoryEnd)
            var unpacked = Int64(h.u32(24))
            var packed = Int64(h.u32(20))
            var local = Int64(h.u32(42))
            var disk = UInt32(h.u16(34))
            var pos = 0
            var has64 = false
            while pos < extra.count {
                guard extra.count - pos >= 4 else {
                    throw LibraryBackupError("Invalid ZIP extra field.")
                }
                let tag = extra.u16(pos)
                let length = Int(extra.u16(pos + 2))
                pos += 4
                guard length <= extra.count - pos else {
                    throw LibraryBackupError("Truncated ZIP extra field.")
                }
                if tag == 1 {
                    guard !has64 else { throw LibraryBackupError("Duplicate ZIP64 extra field.") }
                    has64 = true
                    var field = pos
                    func number() throws -> Int64 {
                        guard field + 8 <= pos + length else {
                            throw LibraryBackupError("Truncated ZIP64 sizes.")
                        }
                        defer { field += 8 }
                        return try extra.i64(field)
                    }
                    if unpacked == Int64(UInt32.max) { unpacked = try number() }
                    if packed == Int64(UInt32.max) { packed = try number() }
                    if local == Int64(UInt32.max) { local = try number() }
                    if disk == UInt32(UInt16.max) {
                        guard field + 4 <= pos + length else {
                            throw LibraryBackupError("Truncated ZIP64 disk number.")
                        }
                        disk = extra.u32(field)
                    }
                } else if tag == 0x7075 {
                    guard length >= 5, extra[pos] == 1,
                        extra.subdata(in: pos + 5..<pos + length) == nameBytes
                    else {
                        throw LibraryBackupError("Ambiguous Unicode ZIP filename.")
                    }
                }
                pos += length
            }
            let entryLimit = name.contains("/") ? limits.file : limits.metadata(name)
            guard disk == 0, unpacked >= 0, unpacked <= entryLimit, packed == unpacked,
                local >= 0, local <= directoryOffset - 30
            else { throw LibraryBackupError("Invalid ZIP entry size or disk.") }
            // Check only the local envelope; libarchive remains the payload/CRC reader.
            let l = try bytes(fd, offset: local, count: 30, size: directoryOffset)
            let ln = Int(l.u16(26))
            let le = Int(l.u16(28))
            guard l.u32(0) == 0x0403_4b50, l.u16(6) == h.u16(8), l.u16(8) == 0, ln == nameLength,
                try bytes(fd, offset: local + 30, count: ln, size: directoryOffset) == nameBytes
            else {
                throw LibraryBackupError("ZIP local and central headers disagree.")
            }
            let dataStart = local + 30 + Int64(ln + le)
            guard dataStart <= directoryOffset, packed <= directoryOffset - dataStart else {
                throw LibraryBackupError("ZIP payload extends outside its area.")
            }
            spans.append((local, dataStart + packed))
            result[name] = LibraryRestoreZIPEntry(size: unpacked, offset: local)
            cursor += 46 + Int64(nameLength + extraLength + commentLength)
            guard cursor <= directoryEnd else {
                throw LibraryBackupError("ZIP index length mismatch.")
            }
        }
        guard cursor == directoryEnd else { throw LibraryBackupError("Unexpected ZIP index data.") }
        let sorted = spans.sorted { $0.0 < $1.0 }
        for i in sorted.indices.dropFirst() where sorted[i].0 < sorted[i - 1].1 {
            throw LibraryBackupError("Overlapping ZIP entries.")
        }
        try LibraryBackupLimits.paths(Array(result.keys))
        return result
    }
    func unchanged() throws {
        var current = stat()
        guard fstat(fd, &current) == 0, current.st_dev == original.st_dev,
            current.st_ino == original.st_ino,
            current.st_size == original.st_size,
            current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
            current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
            current.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
            current.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec
        else {
            throw LibraryBackupError("The selected backup changed during preparation.")
        }
    }
    func manifest() throws -> LibraryBackupManifest {
        guard let declared = entries["backup.json"],
            declared.size <= limits.metadata("backup.json"),
            lseek(fd, 0, SEEK_SET) == 0, let a = archive_read_new()
        else { throw LibraryBackupError("Backup manifest is missing.") }
        defer { archive_read_free(a) }
        try LibraryBackupArchive.check(archive_read_support_format_zip_seekable(a), a)
        try LibraryBackupArchive.check(archive_read_set_options(a, "zip:hdrcharset=UTF-8"), a)
        try LibraryBackupArchive.check(archive_read_open_fd(a, fd, LibraryBackupLimits.chunk), a)
        var seen = 0
        while true {
            var entry: OpaquePointer?
            let code = archive_read_next_header(a, &entry)
            guard code != 1 else { throw LibraryBackupError("Backup manifest is missing.") }
            try LibraryBackupArchive.check(code, a)
            seen += 1
            guard seen <= entries.count, let entry, let raw = archive_entry_pathname(entry),
                let name = String(validatingUTF8: raw),
                entries[name]?.size == archive_entry_size(entry)
            else { throw LibraryBackupError("ZIP reader disagrees with its bounded index.") }
            if name == "backup.json" {
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: LibraryBackupLimits.chunk)
                while true {
                    try Task.checkCancellation()
                    let n = buffer.withUnsafeMutableBytes {
                        archive_read_data(a, $0.baseAddress, $0.count)
                    }
                    guard n >= 0, data.count + max(n, 0) <= limits.manifest else {
                        throw LibraryBackupError(
                            "Backup manifest exceeds its budget or is damaged.")
                    }
                    if n == 0 { break }
                    data.append(contentsOf: buffer.prefix(n))
                }
                guard data.count == declared.size else {
                    throw LibraryBackupError("Backup manifest size mismatch.")
                }
                let manifest = try LibraryRestoreJSON.decode(LibraryBackupManifest.self, from: data)
                try limits.check(manifest)
                guard Set(entries.keys) == Set(manifest.files.map(\.path)).union(["backup.json"]),
                    manifest.files.allSatisfy({ entries[$0.path]?.size == $0.size })
                else {
                    throw LibraryBackupError("ZIP inventory does not match the manifest.")
                }
                try unchanged()
                return manifest
            }
            try Task.checkCancellation()
            try LibraryBackupArchive.check(archive_read_data_skip(a), a)
        }
    }
}

extension Data {
    fileprivate func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    fileprivate func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
    fileprivate func i64(_ i: Int) throws -> Int64 {
        let n = UInt64(u32(i)) | UInt64(u32(i + 4)) << 32
        guard n <= UInt64(Int64.max) else { throw LibraryBackupError("ZIP64 integer overflow.") }
        return Int64(n)
    }
}
