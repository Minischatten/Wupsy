import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

// Descriptor-relative I/O is shared by session staging and exclusive publication.
enum WSSAssetIO {
    static func directory(_ url: URL, create: Bool = false) throws -> Int32 {
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw WSSImageImportError.storage }
        do {
            // macOS supplies these trusted system aliases for temporary URLs.
            let path = url.standardizedFileURL.path
            let canonical =
                (path == "/var" || path == "/tmp" || path.hasPrefix("/var/")
                    || path.hasPrefix("/tmp/")) ? "/private" + path : path
            for part in URL(fileURLWithPath: canonical).pathComponents where part != "/" {
                var next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(fd, part, 0o700) == 0 || errno == EEXIST else {
                        throw WSSImageImportError.storage
                    }
                    next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                }
                guard next >= 0 else { throw WSSImageImportError.storage }
                Darwin.close(fd)
                fd = next
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }
    static func read(_ fd: Int32, limit: Int) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            info.st_size >= 0, info.st_size <= limit
        else { throw WSSImageImportError.fileSize }
        var bytes = Data(count: Int(info.st_size))
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = pread(
                    fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset,
                    off_t(offset))
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw WSSImageImportError.corrupt }
                offset += n
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == info.st_size,
            after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
            after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
            after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
            after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec
        else { throw WSSImageImportError.corrupt }
        return bytes
    }
    static func read(root: URL, path: String, limit: Int) throws -> Data {
        try WSSNativeAssets.validatePath(path)
        var fd = try directory(root)
        defer { Darwin.close(fd) }
        let parts = path.split(separator: "/").map(String.init)
        for part in parts.dropLast() {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw WSSImageImportError.storage }
            Darwin.close(fd)
            fd = next
        }
        let file = openat(fd, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw WSSImageImportError.storage }
        defer { Darwin.close(file) }
        return try read(file, limit: limit)
    }
    static func write(_ bytes: Data, to fd: Int32, checkpoint: WSSManifestWriter.Checkpoint? = nil)
        throws
    {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = offset == 0 ? max(1, buffer.count / 2) : buffer.count - offset
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), count)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw WSSImageImportError.storage }
                if offset == 0 { try checkpoint?(.assetPartialWrite) }
                offset += n
            }
        }
        try checkpoint?(.assetFlush)
        guard fsync(fd) == 0 else { throw WSSImageImportError.storage }
        if fcntl(fd, F_FULLFSYNC) != 0, errno != ENOTSUP, errno != EINVAL {
            throw WSSImageImportError.storage
        }
    }
}

enum WSSImageImportError: LocalizedError {
    case unsupported, corrupt, dimensions, pixels, decodedBudget, fileSize, layerLimit,
        stagingBudget, incompatible, stale, storage, cleanup
    var errorDescription: String? {
        switch self {
        case .unsupported: return "Choose one PNG or JPEG image with a matching file extension."
        case .corrupt: return "The image could not be decoded. Choose a valid PNG or JPEG."
        case .dimensions: return "Images must be no larger than 8192 pixels on either axis."
        case .pixels: return "The image exceeds the 32-million-pixel limit."
        case .decodedBudget: return "The images exceed the 128 MiB decoded-image budget."
        case .fileSize:
            return "The image file exceeds the 128 MiB input limit or is not a regular file."
        case .layerLimit: return "The wallpaper already has 128 layers."
        case .stagingBudget:
            return
                "This editor session has reached its 512 MiB image staging budget. Close and reopen after saving to start a new session."
        case .incompatible:
            return
                "This image is incompatible with the layer or its existing effects and masks. The wallpaper has not changed."
        case .stale:
            return "The target layer changed while the image was being prepared. Please try again."
        case .cleanup:
            return
                "The image operation failed and its temporary file could not be removed. Your saved wallpaper is unchanged."
        case .storage:
            return
                "The image generation could not be staged or published safely. Your changes are still available to retry."
        }
    }
}

// Immutable bytes/description. A retained descriptor owns the private staging file;
// snapshots and undo retain the generation independently of the live document.
enum WSSEditorAssetKind: String, Sendable {
    case png, vectorField, flowRegion
    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .vectorField: return "wssvf"
        case .flowRegion: return "wssregion"
        }
    }
}

final class WSSEditorAssetGeneration: @unchecked Sendable {
    let kind: WSSEditorAssetKind
    let path: String
    private let stagingName: String
    let fingerprint: WSSContentFingerprint
    let width: Int
    let height: Int
    private let root: URL
    private let directory: Int32
    private let descriptor: Int32
    private let lock = NSLock()
    private var publications: [String: UInt64] = [:]
    convenience init(bytes: Data, width: Int, height: Int) throws {
        try self.init(bytes: bytes, width: width, height: height, kind: .png)
    }
    static func vectorField(
        _ field: WSSVectorFieldAsset, remainingBudget: Int,
        checkpoint: WSSManifestWriter.Checkpoint? = nil
    ) throws
        -> WSSEditorAssetGeneration
    {
        let count =
            WSSVectorFieldAsset.fileHeaderBytes + field.vectors.count
            + (field.coverage?.count ?? 0)
        guard count <= remainingBudget else { throw WSSVectorFieldEditError.budget }
        let bytes = try field.encodedNative()
        return try Self(
            bytes: bytes, width: field.width, height: field.height, kind: .vectorField,
            checkpoint: checkpoint)
    }
    static func flowRegion(
        _ region: WSSFlowRegion, remainingBudget: Int,
        checkpoint: WSSManifestWriter.Checkpoint? = nil
    ) throws
        -> WSSEditorAssetGeneration
    {
        guard region.pixels.count + 20 <= remainingBudget else {
            throw WSSVectorFieldEditError.budget
        }
        return try Self(
            bytes: region.encoded(), width: region.width, height: region.height, kind: .flowRegion,
            checkpoint: checkpoint)
    }
    private init(
        bytes: Data, width: Int, height: Int, kind: WSSEditorAssetKind,
        checkpoint: WSSManifestWriter.Checkpoint? = nil
    ) throws {
        self.kind = kind
        path = "assets/editor-" + UUID().uuidString.lowercased() + "." + kind.fileExtension
        stagingName = "asset." + kind.fileExtension
        self.width = width
        self.height = height
        fingerprint = WSSContentFingerprint(bytes)
        var template = Array(
            ProductPaths.current.temporaryRoot.appendingPathComponent(
                ProductIdentity.editorTemporaryTemplate
            ).path.utf8CString)
        guard let name = mkdtemp(&template) else { throw WSSImageImportError.storage }
        root = URL(fileURLWithPath: String(cString: name))
        directory = try WSSAssetIO.directory(root)
        let fd = openat(
            directory, stagingName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else {
            Darwin.close(directory)
            rmdir(root.path)
            throw WSSImageImportError.storage
        }
        do {
            try WSSAssetIO.write(bytes, to: fd, checkpoint: checkpoint)
            guard fchmod(fd, mode_t(0o400)) == 0 else { throw WSSImageImportError.storage }
            descriptor = fd
        } catch {
            Darwin.close(fd)
            unlinkat(directory, stagingName, 0)
            Darwin.close(directory)
            rmdir(root.path)
            throw error
        }
    }
    deinit {
        Darwin.close(descriptor)
        unlinkat(directory, stagingName, 0)
        Darwin.close(directory)
        rmdir(root.path)
    }
    func read() throws -> Data {
        let bytes = try WSSAssetIO.read(descriptor, limit: fingerprint.byteCount)
        guard WSSContentFingerprint(bytes) == fingerprint else {
            throw WSSSaveError.externalConflict
        }
        return bytes
    }
    func published(_ identity: WSSProjectDiskBasis.Identity) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return publications["\(identity.root)|\(identity.device)|\(identity.inode)"]
    }
    func recordPublication(_ identity: WSSProjectDiskBasis.Identity, inode: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        publications["\(identity.root)|\(identity.device)|\(identity.inode)"] = inode
    }
    var definition: WSSNativeImageDefinition {
        precondition(kind == .png)
        return .init(
            asset: path, encoding: "image", width: width, height: height,
            uvScale: [1, 1], filter: "linear", edge: "clamp", mipmapped: true)
    }
}

// Source compatibility for existing image/mask callers; the carrier has a closed asset kind.
typealias WSSImageGeneration = WSSEditorAssetGeneration

actor WSSImageImporter {
    static let inputLimit = 128 * 1024 * 1024
    static let stagingLimit = 512 * 1024 * 1024
    static func validateDimensions(_ width: Int, _ height: Int) throws {
        guard (1...8192).contains(width), (1...8192).contains(height) else {
            throw WSSImageImportError.dimensions
        }
        guard width <= (32 * 1024 * 1024) / height else { throw WSSImageImportError.pixels }
        guard width <= (128 * 1024 * 1024) / 4 / height else {
            throw WSSImageImportError.decodedBudget
        }
    }
    func load(_ url: URL, remainingBudget: Int = stagingLimit) throws -> WSSImageGeneration {
        try Task.checkCancellation()
        let bytes = try WSSAssetIO.read(
            root: url.deletingLastPathComponent(), path: url.lastPathComponent,
            limit: Self.inputLimit)
        return try normalize(
            bytes, extension: url.pathExtension.lowercased(), remainingBudget: remainingBudget)
    }
    func normalize(_ bytes: Data, extension ext: String, remainingBudget: Int = stagingLimit) throws
        -> WSSImageGeneration
    {
        guard bytes.count <= Self.inputLimit else { throw WSSImageImportError.fileSize }
        guard ["png", "jpg", "jpeg"].contains(ext) else { throw WSSImageImportError.unsupported }
        guard
            let source = CGImageSourceCreateWithData(
                bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let type = CGImageSourceGetType(source) as String?
        else { throw WSSImageImportError.corrupt }
        guard
            (type == UTType.png.identifier && ext == "png")
                || (type == UTType.jpeg.identifier && ["jpg", "jpeg"].contains(ext))
        else { throw WSSImageImportError.unsupported }
        guard CGImageSourceGetCount(source) == 1,
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Int,
            let height = props[kCGImagePropertyPixelHeight] as? Int
        else { throw WSSImageImportError.corrupt }
        try Self.validateDimensions(width, height)
        guard
            let decoded = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary), CGImageSourceGetStatus(source) == .statusComplete,
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: decoded.width, height: decoded.height,
                bitsPerComponent: 8, bytesPerRow: decoded.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw WSSImageImportError.corrupt }
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        let output = NSMutableData()
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(
                output, UTType.png.identifier as CFString, 1, nil)
        else { throw WSSImageImportError.corrupt }
        CGImageDestinationAddImage(destination, image, [:] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= Self.inputLimit else {
            throw WSSImageImportError.corrupt
        }
        guard output.length <= remainingBudget else { throw WSSImageImportError.stagingBudget }
        try Task.checkCancellation()
        return try WSSImageGeneration(
            bytes: output as Data, width: decoded.width, height: decoded.height)
    }
}

extension WSSNativeImageDefinition {
    init(
        asset: String, encoding: String, width: Int, height: Int, uvScale: [Float], filter: String,
        edge: String, mipmapped: Bool
    ) {
        self.asset = asset
        self.encoding = encoding
        self.width = width
        self.height = height
        self.uvScale = uvScale
        self.filter = filter
        self.edge = edge
        self.mipmapped = mipmapped
    }
}

// Display metadata only; never used for asset paths or layer identity.
enum WSSImageLayerName {
    static func fromSource(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let safe = String(
            stem.unicodeScalars.map {
                CharacterSet.controlCharacters.contains($0) ? " " : String($0)
            }.joined())
        return (try? WallpaperTitle.normalized(safe)) ?? "Image"
    }
}
