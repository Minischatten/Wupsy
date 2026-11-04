import Darwin
import Foundation

// Logical saved bytes, never allocated disk space, decoded textures or editor state.
enum WallpaperLogicalSize {
    enum Failure: Error { case unsafe, incomplete, limit, changed }
    static func read(_ item: Wallpaper) async -> Int64? {
        let worker = Task.detached { try measure(item) }
        return try? await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func adding(_ total: Int64, _ bytes: Int64) throws -> Int64 {
        let (sum, overflow) = total.addingReportingOverflow(bytes)
        guard total >= 0, bytes >= 0, !overflow else { throw Failure.limit }
        return sum
    }

    static func measure(_ item: Wallpaper) throws -> Int64 {
        try Task.checkCancellation()
        if item.managed != nil { try validateManagedBoundary(item) }
        if item.kind == .scene, item.sceneSource == .nativeWSS {
            let root = URL(fileURLWithPath: item.root)
            guard item.url.lastPathComponent == "scene.wss.json",
                item.url.deletingLastPathComponent().path == root.path
            else { throw Failure.unsafe }
            let fd = try WSSAssetIO.directory(root)
            defer { close(fd) }
            let entry = try openFile(fd, "scene.wss.json")
            defer { close(entry) }
            let bytes = try WSSAssetIO.read(entry, limit: WSSSceneDocumentV1.byteLimit)
            let document = try WSSSceneDocumentV1.decode(data: bytes)
            _ = try document.assetSource(root: root)
            let paths = document.referencedPaths
            guard paths.count < LibraryBackupLimits.files else { throw Failure.limit }
            var total = Int64(bytes.count)
            for path in paths.sorted() {
                try Task.checkCancellation()
                try WSSNativeAssets.validatePath(path)
                // The manifest is already counted, even if referenced as a resource.
                if path == "scene.wss.json" { continue }
                total = try adding(total, size(fd, path))
            }
            return total
        }
        if let location = item.managed,
            item.kind == .web && item.url.pathExtension.lowercased() != "gif"
        {
            let category = "Web"
            guard try ManagedWallpaperStore.components(location.directory).first == category else {
                throw Failure.unsafe
            }
            let fd = try WSSAssetIO.directory(URL(fileURLWithPath: item.root))
            defer { close(fd) }
            // A missing or nonregular entry must not turn into a plausible tree total.
            _ = try size(fd, location.entry)
            var count = 0
            return try tree(fd, depth: 0, count: &count)
        }
        // External media/web have no proven exclusive root. Count only their entry.
        let fd = try WSSAssetIO.directory(item.url.deletingLastPathComponent())
        defer { close(fd) }
        return try size(fd, item.url.lastPathComponent)
    }

    private static func validateManagedBoundary(_ item: Wallpaper) throws {
        guard let location = item.managed else { throw Failure.unsafe }
        let components = try ManagedWallpaperStore.components(location.directory)
        _ = try ManagedWallpaperStore.components(location.entry)
        let root = URL(fileURLWithPath: item.root)
        guard components.count == 2,
            ["Media", "Web", "WSS"].contains(components[0]),
            root.lastPathComponent == components[1],
            root.deletingLastPathComponent().lastPathComponent == components[0],
            root.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                == "Wallpapers",
            root.appendingPathComponent(location.entry).path == item.url.path
        else { throw Failure.unsafe }
    }

    private static func openFile(_ directory: Int32, _ name: String) throws -> Int32 {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.incomplete }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            close(fd)
            throw Failure.unsafe
        }
        return fd
    }
    private static func size(_ root: Int32, _ path: String) throws -> Int64 {
        let parts = try ManagedWallpaperStore.components(path)
        guard parts.count <= 64 else { throw Failure.limit }
        var directory = dup(root)
        guard directory >= 0 else { throw Failure.incomplete }
        defer { close(directory) }
        for component in parts.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure.unsafe }
            close(directory)
            directory = next
        }
        let file = try openFile(directory, parts.last!)
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_size >= 0 else { throw Failure.incomplete }
        return Int64(info.st_size)
    }
    private static func tree(_ directory: Int32, depth: Int, count: inout Int) throws -> Int64 {
        guard depth < 64 else { throw Failure.limit }
        var before = stat()
        guard fstat(directory, &before) == 0 else { throw Failure.incomplete }
        let copy = dup(directory)
        guard copy >= 0 else { throw Failure.incomplete }
        guard let stream = fdopendir(copy) else {
            close(copy)
            throw Failure.incomplete
        }
        defer { closedir(stream) }
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw Failure.incomplete }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            count += 1
            guard count <= LibraryBackupLimits.files else { throw Failure.limit }
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw Failure.incomplete
            }
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                total = try adding(total, size(directory, name))
            case S_IFDIR:
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw Failure.unsafe }
                defer { close(child) }
                total = try adding(total, tree(child, depth: depth + 1, count: &count))
            default: throw Failure.unsafe
            }
        }
        var after = stat()
        guard fstat(directory, &after) == 0,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw Failure.changed }
        return total
    }
}
