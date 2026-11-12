import AVFoundation
import AppKit
import CryptoKit
import ImageIO

// Serial actor bounds still-image decoding and thumbnail work. Never retain full-size originals.
actor ImageLoader {
    static let shared = ImageLoader()
    private let thumbnails = NSCache<NSString, NSImage>()
    private var sceneKeys: [UUID: Set<String>] = [:]
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }
    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
    init() {
        thumbnails.totalCostLimit = 16 * 1024 * 1024
        thumbnails.countLimit = 48
    }
    func clear() {
        thumbnails.removeAllObjects()
        sceneKeys.removeAll()
    }
    private func sceneKey(_ item: Wallpaper, manifest: WSSContentFingerprint, maxPixel: Int)
        -> String
    {
        "wss|\(item.id)|\(item.path)|\(maxPixel)|"
            + manifest.sha256.map { String(format: "%02x", $0) }.joined()
    }
    private func cacheScene(_ image: NSImage, key: String, id: UUID) {
        sceneKeys[id, default: []].insert(key)
        thumbnails.setObject(
            image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * 4))
    }
    @discardableResult
    func committedWSS(_ item: Wallpaper, basis: WSSProjectDiskBasis, resources: WSSStaticResources)
        async -> Bool
    {
        await acquire()
        defer { release() }
        for key in sceneKeys.removeValue(forKey: item.id) ?? [] {
            thumbnails.removeObject(forKey: key as NSString)
        }
        var success = true
        // Only the exact successfully committed candidate is used, never editor Working N+1.
        for size in [480, 1280] {
            if let image = try? WSSLibraryThumbnail.render(resources, maxPixel: size) {
                cacheScene(
                    image, key: sceneKey(item, manifest: basis.manifest, maxPixel: size),
                    id: item.id)
            } else {
                success = false
            }
        }
        return success
    }
    private func nativeThumbnail(_ item: Wallpaper, maxPixel: Int) async throws -> NSImage? {
        let handle = try WSSExistingProjectResolver.resolve(item)
        let bytes = try WSSNativeAssets(root: handle.root).read(
            "scene.wss.json", limit: WSSSceneDocumentV1.byteLimit)
        let key = sceneKey(item, manifest: WSSContentFingerprint(bytes), maxPixel: maxPixel)
        if let cached = thumbnails.object(forKey: key as NSString) { return cached }
        let project = try await WSSEditorProjectLoader().load(item)
        let image = try WSSLibraryThumbnail.render(project.resources, maxPixel: maxPixel)
        cacheScene(
            image, key: sceneKey(item, manifest: project.diskBasis.manifest, maxPixel: maxPixel),
            id: item.id)
        return image
    }
    func image(_ url: URL, maxPixel: Int) -> NSImage? {
        guard
            let source = CGImageSourceCreateWithURL(
                url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let cg = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
    func thumbnail(_ item: Wallpaper, maxPixel: Int = 480) async -> NSImage? {
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }
        if item.kind == .scene, item.managed != nil {
            do {
                return try await nativeThumbnail(item, maxPixel: maxPixel)
            } catch WSSEditorOpenError.missingProject {
                // Original preview until an explicit WSS project exists.
            } catch {
                // Existing invalid WSS stays authoritative; do not show its old source picture.
                return nil
            }
        }
        let key =
            (item.path + "-\(maxPixel)-"
            + String(
                (try? item.url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate?.timeIntervalSince1970) ?? 0)) as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        let result: NSImage?
        if item.kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            if let frame = try? await generator.image(at: .zero) {
                result = NSImage(cgImage: frame.image, size: .zero)
            } else {
                result = nil
            }
        } else if item.kind == .scene
            || item.kind == .web && item.url.pathExtension.lowercased() != "gif"
        {
            let preview = URL(fileURLWithPath: item.root).appendingPathComponent("preview.jpg")
            result = image(preview, maxPixel: maxPixel)
        } else {
            result = image(item.url, maxPixel: maxPixel)
        }
        if let result {
            thumbnails.setObject(
                result, forKey: key, cost: Int(result.size.width * result.size.height * 4))
        }
        return result
    }
}

@MainActor final class VideoOptimizer {
    static let budget: Int64 = 1024 * 1024 * 1024
    let directory: URL
    private var session: AVAssetExportSession?
    private let removeFile: (URL) throws -> Void
    init(
        directory: URL? = nil,
        removeFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.directory =
            directory
            ?? ProductPaths.current.videoCache
        self.removeFile = removeFile
    }
    func cancel() { session?.cancelExport() }
    func preparedURL(
        for item: Wallpaper, profile: QualityProfile,
        protectedURLs: () -> [URL] = { [] }
    ) async throws -> URL {
        guard item.kind == .video, profile != .original else { return item.url }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: item.url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ImportFailure.message("No video track was found.")
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let source = CGSize(width: abs(rect.width), height: abs(rect.height))
        let rate = try await track.load(.nominalFrameRate)
        guard
            max(source.width, source.height) > CGFloat(profile.maxDimension)
                || rate > Float(profile.fps) + 0.1
        else { return item.url }
        let attributes = try item.url.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey,
        ])
        let identity =
            "v2|\(item.path)|\(attributes.fileSize ?? 0)|\(attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(profile.rawValue)"
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }
            .joined()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Recover abandoned temporary exports after a previous process crash.
        for file
            in (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where file.lastPathComponent.hasSuffix(".partial.mp4") {
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, Date().timeIntervalSince(modified) > 86400
            {
                try? FileManager.default.removeItem(at: file)
            }
        }
        let output = directory.appendingPathComponent(hash + ".mp4")
        if FileManager.default.fileExists(atPath: output.path) {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: output.path)
            return output
        }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".partial.mp4")
        defer {
            try? FileManager.default.removeItem(at: temporary)
            session = nil
        }
        guard
            let export = AVAssetExportSession(
                asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality)
        else {
            throw ImportFailure.message(
                "Could not prepare an efficient copy. Try Original quality.")
        }
        let target = profile.targetSize(source)
        let composition = AVMutableVideoComposition()
        composition.renderSize = target
        composition.frameDuration = CMTime(
            value: 1, timescale: min(profile.fps, max(1, Int32(rate.rounded(.up)))))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let adjusted = transform.concatenating(
            CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
        ).concatenating(
            CGAffineTransform(scaleX: target.width / source.width, y: target.height / source.height)
        )
        layer.setTransform(adjusted, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        export.videoComposition = composition
        export.outputURL = temporary
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = false
        session = export
        await withTaskCancellationHandler(
            operation: { await export.export() },
            onCancel: { [weak self] in Task { @MainActor in self?.cancel() } })
        try Task.checkCancellation()
        guard export.status == .completed else {
            throw export.error
                ?? ImportFailure.message("Could not optimize this video. Try Original quality.")
        }
        let size = Int64((try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        guard size <= Self.budget else {
            throw ImportFailure.message(
                "The efficient copy exceeds the 1 GB cache budget. Choose a shorter video or Original quality."
            )
        }
        try trim(to: Self.budget - size, excluding: protectedURLs())
        try FileManager.default.moveItem(at: temporary, to: output)
        return output
    }
    func trim(to budget: Int64, excluding usedURLs: [URL] = []) throws {
        let cache = directory.standardizedFileURL.resolvingSymlinksInPath()
        // Only direct members of this cache can be protected. Canonical URLs also
        // match percent-encoded paths and macOS /var -> /private/var aliases.
        let protected = Set(
            usedURLs.filter { $0.isFileURL }.map {
                $0.standardizedFileURL.resolvingSymlinksInPath()
            }.filter { $0.deletingLastPathComponent() == cache })
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let entries = files.filter {
            $0.pathExtension == "mp4" && !$0.lastPathComponent.contains(".partial.")
        }.map { url in
            (url, try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]))
        }.sorted {
            ($0.1?.contentModificationDate ?? .distantPast)
                < ($1.1?.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + Int64($1.1?.fileSize ?? 0) }
        for (url, value) in entries where total > budget {
            guard !protected.contains(url.standardizedFileURL.resolvingSymlinksInPath()) else {
                continue
            }
            try removeFile(url)
            total -= Int64(value?.fileSize ?? 0)
        }
    }
}
