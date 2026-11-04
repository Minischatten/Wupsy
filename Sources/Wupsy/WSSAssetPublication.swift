import Darwin
import Foundation

// Called synchronously under ManagedWallpaperStore's existing Save/Remove actor.
// Only session-owned generations may be installed. Existing files are never replaced.
enum WSSAssetPublication {
    static func install(
        _ generation: WSSImageGeneration, directory root: Int32,
        identity: WSSProjectDiskBasis.Identity,
        checkpoint: WSSManifestWriter.Checkpoint?, verifyTarget: () throws -> Void
    ) throws {
        let parts = generation.path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "assets", parts[1].hasPrefix("editor-"),
            parts[1].hasSuffix("." + generation.kind.fileExtension)
        else { throw WSSImageImportError.storage }
        if mkdirat(root, "assets", mode_t(0o755)) != 0, errno != EEXIST {
            throw WSSImageImportError.storage
        }
        let folder = openat(root, "assets", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard folder >= 0 else { throw WSSImageImportError.storage }
        defer { Darwin.close(folder) }
        var folderInfo = stat()
        guard fstat(folder, &folderInfo) == 0, folderInfo.st_uid == geteuid() else {
            throw WSSImageImportError.storage
        }
        let name = parts[1]
        // Retry may reuse ONLY an inode this exact generation published itself in
        // this project. Fingerprint equality alone never establishes ownership.
        let existing = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if existing >= 0 {
            defer { Darwin.close(existing) }
            var info = stat()
            guard fstat(existing, &info) == 0, info.st_uid == geteuid(),
                generation.published(identity) == UInt64(info.st_ino),
                WSSContentFingerprint(
                    try WSSAssetIO.read(existing, limit: generation.fingerprint.byteCount))
                    == generation.fingerprint
            else { throw WSSImageImportError.storage }
            return
        }
        guard errno == ENOENT else { throw WSSImageImportError.storage }
        let temp = ".wss-asset-" + UUID().uuidString
        var fd = openat(folder, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw WSSImageImportError.storage }
        var ownsTemp = true
        defer { if fd >= 0 { Darwin.close(fd) } }
        do {
            try checkpoint?(.assetWrite)
            try WSSAssetIO.write(generation.read(), to: fd, checkpoint: checkpoint)
            guard fchmod(fd, mode_t(0o444)) == 0, fsync(fd) == 0 else {
                throw WSSImageImportError.storage
            }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw WSSImageImportError.storage }
            try checkpoint?(.assetClose)
            let closed = Darwin.close(fd)
            fd = -1
            guard closed == 0 else { throw WSSImageImportError.storage }
            try checkpoint?(.assetPublish)
            try verifyTarget()
            // Ensure the pinned assets directory is still the authoritative one.
            let current = openat(root, "assets", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard current >= 0 else { throw WSSImageImportError.storage }
            var currentInfo = stat()
            let checked = fstat(current, &currentInfo)
            Darwin.close(current)
            guard checked == 0, currentInfo.st_ino == folderInfo.st_ino,
                currentInfo.st_dev == folderInfo.st_dev, currentInfo.st_uid == geteuid()
            else { throw WSSImageImportError.storage }
            // Exclusive link is the atomic publication; it cannot replace even a symlink.
            guard linkat(folder, temp, folder, name, 0) == 0 else {
                throw WSSImageImportError.storage
            }
            generation.recordPublication(identity, inode: UInt64(info.st_ino))
            guard unlinkat(folder, temp, 0) == 0 else { throw WSSImageImportError.cleanup }
            ownsTemp = false
            guard fsync(folder) == 0, fsync(root) == 0 else { throw WSSImageImportError.storage }
            try checkpoint?(.afterAssetPublish)
        } catch {
            if ownsTemp, unlinkat(folder, temp, 0) != 0, errno != ENOENT {
                throw WSSImageImportError.cleanup
            }
            throw error
        }
    }
}
