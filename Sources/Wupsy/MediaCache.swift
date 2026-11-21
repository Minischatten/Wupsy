import AVFoundation
import AppKit
import CryptoKit
import ImageIO

// Cache access stays available while a single generation job decodes or renders.
actor ImageLoader {
    static let shared = ImageLoader()
    struct CacheUsage: Sendable {
        let gridBytes: Int
        let detailBytes: Int
    }

    private struct Key: Hashable {
        let source: String
        let maxPixel: Int
        var sceneID: UUID?
    }

    private struct Cache {
        struct Entry {
            let image: NSImage
            let bytes: Int
            var access: UInt64
        }

        let budget: Int
        let limit: Int
        var entries: [Key: Entry] = [:]
        var bytes = 0
        private var clock: UInt64 = 0

        init(budget: Int, limit: Int) {
            self.budget = budget
            self.limit = limit
        }

        mutating func get(_ key: Key) -> NSImage? {
            guard let image = entries[key]?.image else { return nil }
            clock += 1
            entries[key]?.access = clock
            return image
        }

        mutating func insert(_ image: NSImage, for key: Key) {
            let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
            let cost = max(pixels, Int(image.size.width * image.size.height)) * 4
            guard cost > 0, cost <= budget else { return }
            remove(key)
            while bytes + cost > budget || entries.count >= limit {
                guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else {
                    break
                }
                remove(oldest.key)
            }
            clock += 1
            entries[key] = Entry(image: image, bytes: cost, access: clock)
            bytes += cost
        }

        mutating func remove(_ key: Key) {
            if let entry = entries.removeValue(forKey: key) { bytes -= entry.bytes }
        }

        mutating func invalidate(_ id: UUID) {
            for key in entries.keys.filter({ $0.sceneID == id }) { remove(key) }
        }

        mutating func clear() {
            entries.removeAll()
            bytes = 0
        }
    }

    private var grid: Cache
    private var detail: Cache
    private var cacheGeneration = UUID()
    private var busy = false
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    private let beforeThumbnailWork: @Sendable (Wallpaper) async -> Void

    init(
        gridBudget: Int = 24 * 1024 * 1024, detailBudget: Int = 8 * 1024 * 1024,
        beforeThumbnailWork: @escaping @Sendable (Wallpaper) async -> Void = { _ in }
    ) {
        grid = Cache(budget: gridBudget, limit: 64)
        detail = Cache(budget: detailBudget, limit: 8)
        self.beforeThumbnailWork = beforeThumbnailWork
    }

    func cacheUsage() -> CacheUsage { CacheUsage(gridBytes: grid.bytes, detailBytes: detail.bytes) }

    private func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if !busy {
            busy = true
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiting.append((id, $0)) }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: false)
    }

    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().continuation.resume(returning: true)
        }
    }

    func clear() {
        cacheGeneration = UUID()
        grid.clear()
        detail.clear()
    }

    private func cached(_ key: Key) -> NSImage? {
        if key.maxPixel <= 480 { return grid.get(key) }
        return detail.get(key)
    }

    private func store(_ image: NSImage, key: Key, generation: UUID) {
        guard generation == cacheGeneration else { return }
        if key.maxPixel <= 480 {
            grid.insert(image, for: key)
        } else {
            detail.insert(image, for: key)
        }
    }

    private func sceneKey(_ item: Wallpaper, manifest: WSSContentFingerprint, maxPixel: Int) -> Key
    {
        Key(
            source: item.path + "|" + manifest.sha256.map { String(format: "%02x", $0) }.joined(),
            maxPixel: maxPixel, sceneID: item.id)
    }

    private func source(_ item: Wallpaper, maxPixel: Int) throws -> (Key, URL) {
        if item.kind == .scene, item.managed != nil {
            do {
                let handle = try WSSExistingProjectResolver.resolve(item)
                let bytes = try WSSNativeAssets(root: handle.root).read(
                    "scene.wss.json", limit: WSSSceneDocumentV1.byteLimit)
                return (
                    sceneKey(item, manifest: WSSContentFingerprint(bytes), maxPixel: maxPixel),
                    item.url
                )
            } catch WSSEditorOpenError.missingProject {
                // A missing native project can still use its original preview.
            }
        }
        let url =
            item.kind == .scene || (item.kind == .web && !item.isGIF)
            ? URL(fileURLWithPath: item.root).appendingPathComponent("preview.jpg") : item.url
        let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey, .attributeModificationDateKey, .fileSizeKey])
        let date = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let attributes = values?.attributeModificationDate?.timeIntervalSince1970 ?? 0
        let key = Key(
            source: "\(item.kind)|\(url.path)|\(date)|\(attributes)|\(values?.fileSize ?? -1)",
            maxPixel: maxPixel
        )
        return (key, url)
    }

    @discardableResult
    func committedWSS(_ item: Wallpaper, basis: WSSProjectDiskBasis, resources: WSSStaticResources)
        async -> Bool
    {
        guard await acquire() else { return false }
        defer { release() }
        grid.invalidate(item.id)
        detail.invalidate(item.id)
        let generation = cacheGeneration
        var success = true
        // Only the exact successfully committed candidate is used, never editor Working N+1.
        for size in [480, 1280] {
            guard !Task.isCancelled else { return false }
            let key = sceneKey(item, manifest: basis.manifest, maxPixel: size)
            if let image = try? await Self.render(resources, maxPixel: size) {
                if (try? source(item, maxPixel: size).0) == key {
                    store(image, key: key, generation: generation)
                }
            } else {
                success = false
            }
        }
        return success
    }

    private nonisolated static func render(_ resources: WSSStaticResources, maxPixel: Int)
        async throws -> NSImage
    {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try WSSLibraryThumbnail.render(resources, maxPixel: maxPixel)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func image(_ url: URL, maxPixel: Int) -> NSImage? {
        Self.decodeImage(url, maxPixel: maxPixel)
    }

    private nonisolated static func decodeImage(_ url: URL, maxPixel: Int) -> NSImage? {
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
        guard !Task.isCancelled, let (initial, _) = try? source(item, maxPixel: maxPixel) else {
            return nil
        }
        if let image = cached(initial) {
            return image
        }
        guard await acquire() else { return nil }
        defer { release() }
        // The source or cache can have changed while this request was waiting.
        guard !Task.isCancelled, let (key, url) = try? source(item, maxPixel: maxPixel) else {
            return nil
        }
        if let image = cached(key) {
            return image
        }

        let generation = cacheGeneration
        await beforeThumbnailWork(item)
        guard !Task.isCancelled else { return nil }
        let result: NSImage?
        var finishedKey = key
        if key.sceneID != nil {
            // Existing invalid native WSS remains authoritative.
            guard let project = try? await WSSEditorProjectLoader().load(item), !Task.isCancelled
            else {
                return nil
            }
            finishedKey = sceneKey(item, manifest: project.diskBasis.manifest, maxPixel: maxPixel)
            result = try? await Self.render(project.resources, maxPixel: maxPixel)
        } else if item.kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            if let frame = try? await generator.image(at: .zero) {
                result = NSImage(cgImage: frame.image, size: .zero)
            } else {
                result = nil
            }
        } else {
            let task = Task.detached(priority: .utility) {
                Task.isCancelled ? nil : Self.decodeImage(url, maxPixel: maxPixel)
            }
            result = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
        guard let result, (try? source(item, maxPixel: maxPixel).0) == finishedKey else {
            return nil
        }
        store(result, key: finishedKey, generation: generation)
        return Task.isCancelled ? nil : result
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
