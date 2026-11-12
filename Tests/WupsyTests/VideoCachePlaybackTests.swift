import AVFoundation
import AppKit
import Combine
import XCTest

@testable import Wupsy

@MainActor final class VideoCachePlaybackTests: XCTestCase {
    private var root: URL!
    private var cache: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var libraries: [Library] = []

    override func setUpWithError() throws {
        suite = "WupsyVideoCacheTests-" + UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        cache = root.appendingPathComponent("Video cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "conserve")
        defaults.set(false, forKey: "pauseOnBattery")
    }
    override func tearDown() async throws {
        for library in libraries { await library.stopAndDrainForMaintenance() }
        libraries.removeAll()
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }
    private func library(
        profile: QualityProfile = .original,
        removeFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws -> Library {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        defaults.set(profile.rawValue, forKey: "profile")
        let directory = cache!
        let value = Library(
            maintenance: MaintenanceCoordinator(),
            storage: root.appendingPathComponent("library.json"),
            defaults: defaults, restoreOnLaunch: false, targetScreens: { [screen] },
            makeVideoOptimizer: { VideoOptimizer(directory: directory, removeFile: removeFile) })
        libraries.append(value)
        return value
    }
    private func write(_ name: String, bytes: Data = Data([1, 2, 3])) throws -> URL {
        let url = cache.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
    private func video() async throws -> Wallpaper {
        let url = root.appendingPathComponent(UUID().uuidString + ".mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32,
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32ARGB, nil, &buffer),
            kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(
            try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)), 255,
            CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for index in 0..<4 {
            for _ in 0..<200 where !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            XCTAssertTrue(
                adaptor.append(
                    pixels, withPresentationTime: CMTime(value: Int64(index), timescale: 120)))
        }
        writer.endSession(atSourceTime: CMTime(value: 4, timescale: 120))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
        return Wallpaper(title: "Video", path: url.path, root: root.path, kind: .video)
    }
    private func apply(_ item: Wallpaper, to library: Library) async throws -> Renderer {
        library.items = [item]
        library.selected = item.id
        guard case .accepted = await library.apply(item).outcome else {
            throw NSError(domain: "VideoCachePlaybackTests.apply", code: 1)
        }
        return try XCTUnwrap(library.renderers.first)
    }
    func testOriginalVideoCacheClearKeepsPlayerSelectionAndActivePreference() async throws {
        let item = try await video()
        let library = try library()
        let renderer = try await apply(item, to: library)
        let player = try XCTUnwrap(renderer.player)
        let currentItem = player.currentItem
        let unused = try write("unused.mp4")
        library.clearCache()
        XCTAssertTrue(library.renderers.first === renderer)
        XCTAssertTrue(renderer.player === player)
        XCTAssertTrue(player.currentItem === currentItem)
        XCTAssertEqual(library.active?.id, item.id)
        XCTAssertEqual(library.selected, item.id)
        XCTAssertEqual(defaults.string(forKey: "activeWallpaper"), item.id.uuidString)
        XCTAssertFalse(library.manuallyPaused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unused.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
    }
    func testOptimizedVideoAndPausedRendererKeepUsedCacheFile() async throws {
        let item = try await video()
        let library = try library(profile: .eco)
        let renderer = try await apply(item, to: library)
        XCTAssertTrue(library.usingOptimizedVideo)
        XCTAssertNotEqual(renderer.mediaURL, item.url)
        let player = try XCTUnwrap(renderer.player)
        let unused = try write("unused.mp4")
        library.clearCache()
        XCTAssertTrue(renderer.player === player)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renderer.mediaURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unused.path))
        library.manuallyPaused = true
        XCTAssertTrue(renderer.paused)
        let pausedSelection = library.selected
        library.clearCache()
        XCTAssertTrue(library.manuallyPaused)
        XCTAssertTrue(renderer.paused)
        XCTAssertTrue(library.renderers.first === renderer)
        XCTAssertEqual(library.selected, pausedSelection)
        XCTAssertEqual(library.active?.id, item.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renderer.mediaURL.path))
        library.manuallyPaused = false
        XCTAssertFalse(renderer.paused)
        XCTAssertNotNil(renderer.player)
    }
    func testPendingVideoPreparationIsNotCancelledOrTrimmed() async throws {
        let item = try await video()
        let library = try library(profile: .eco)
        library.items = [item]
        library.selected = item.id
        let unused = try write("unused.mp4")
        let request = library.apply(item)
        XCTAssertTrue(library.preparing)
        library.clearCache()
        XCTAssertTrue(library.preparing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unused.path))
        XCTAssertEqual(library.message, ProductText.operationWait.text)
        guard case .accepted = await request.outcome else {
            return XCTFail("Preparation was interrupted")
        }
        XCTAssertEqual(library.active?.id, item.id)
        XCTAssertEqual(library.selected, item.id)
        XCTAssertTrue(library.usingOptimizedVideo)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: try XCTUnwrap(library.renderers.first).mediaURL.path))
    }
    func testDeleteFailureKeepsOriginalPlayerAndSelection() async throws {
        let item = try await video()
        let library = try library(removeFile: { _ in throw CocoaError(.fileWriteNoPermission) })
        let renderer = try await apply(item, to: library)
        let player = try XCTUnwrap(renderer.player)
        let unused = try write("unused.mp4")
        library.clearCache()
        XCTAssertNotNil(library.message)
        XCTAssertTrue(library.renderers.first === renderer)
        XCTAssertTrue(renderer.player === player)
        XCTAssertEqual(library.active?.id, item.id)
        XCTAssertEqual(library.selected, item.id)
        XCTAssertEqual(defaults.string(forKey: "activeWallpaper"), item.id.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unused.path))
    }
    func testCanonicalProtectionAndBudgetNeverRemoveUsedFile() throws {
        let used = try write("used video.mp4", bytes: Data(repeating: 1, count: 20))
        let unused = try write("unused.mp4", bytes: Data(repeating: 2, count: 10))
        let partial = try write("pending.partial.mp4")
        let outside = root.appendingPathComponent("original.mp4")
        try Data([4]).write(to: outside)
        let equivalent = URL(
            fileURLWithPath: used.deletingLastPathComponent().path + "/./" + used.lastPathComponent)
        try VideoOptimizer(directory: cache).trim(to: 5, excluding: [equivalent, outside])
        XCTAssertEqual(try Data(contentsOf: used), Data(repeating: 1, count: 20))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unused.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data([4]))
        try VideoOptimizer(directory: cache).trim(to: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: used.path))
    }
    func testOutsideURLWithSameNameCannotProtectCacheEntry() throws {
        let cached = try write("same.mp4")
        let outside = root.appendingPathComponent("same.mp4")
        try Data([9]).write(to: outside)
        try VideoOptimizer(directory: cache).trim(to: 0, excluding: [outside])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data([9]))
    }
    func testAutomaticExportBudgetUsesCurrentProtectionAtEvictionTime() async throws {
        let item = try await video()
        let used = try write("used.mp4")
        let handle = try FileHandle(forWritingTo: used)
        try handle.truncate(atOffset: UInt64(VideoOptimizer.budget + 1))
        try handle.close()
        let unused = try write("unused.mp4")
        var protectionRequested = false
        let output = try await VideoOptimizer(directory: cache).preparedURL(
            for: item, profile: .eco
        ) {
            protectionRequested = true
            return [used]
        }
        XCTAssertTrue(protectionRequested)
        XCTAssertNotEqual(output, item.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: used.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unused.path))
    }
    func testNonVideoRenderersAreNotStoppedByCacheClear() async throws {
        let fixture = NativeProjectTestFixture()
        try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        let image = root.appendingPathComponent("image.png")
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: image)
        let gif = root.appendingPathComponent("image.gif")
        try XCTUnwrap(
            Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")
        ).write(to: gif)
        let html = root.appendingPathComponent("index.html")
        try Data("<html><body>Cache fixture</body></html>".utf8).write(to: html)
        let library = try library()
        for item in [
            Wallpaper(title: "Image", path: image.path, root: root.path, kind: .image),
            Wallpaper(title: "GIF", path: gif.path, root: root.path, kind: .web),
            Wallpaper(title: "Web", path: html.path, root: root.path, kind: .web),
            try fixture.item(),
        ] {
            let renderer = try await apply(item, to: library)
            let unused = try write("unused.mp4")
            library.clearCache()
            XCTAssertTrue(library.renderers.first === renderer)
            XCTAssertTrue(renderer.hasLiveResources)
            XCTAssertEqual(library.active?.id, item.id)
            XCTAssertEqual(library.selected, item.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: unused.path))
        }
    }
    func testCacheClearPreservesPlaylistRotation() async throws {
        let item = try await video()
        let second = try await video()
        let library = try library()
        library.items = [item, second]
        let clock = VideoCachePlaylistScheduler()
        let playlist = WallpaperPlaylist(
            library: library, storage: root.appendingPathComponent("playlists.json"),
            defaults: defaults,
            scheduler: clock, restoreOnLaunch: false)
        defer { playlist.shutdown() }
        let id = try playlist.createPlaylist(name: "Cache test")
        try playlist.add(item.id, to: id)
        try playlist.add(second.id, to: id)
        try playlist.setInterval(5, for: id)
        playlist.activatePlaylist(id: id)
        for _ in 0..<200 where library.preparing || library.renderers.isEmpty || clock.count == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let active = library.active?.id
        XCTAssertNotNil(active)
        XCTAssertEqual(playlist.activePlaylistID, id)
        XCTAssertEqual(clock.count, 1)
        library.clearCache()
        XCTAssertEqual(playlist.activePlaylistID, id)
        XCTAssertEqual(library.active?.id, active)
        XCTAssertEqual(clock.count, 1)
        clock.advance(5)
        for _ in 0..<200 where library.preparing || library.active?.id == active {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotEqual(library.active?.id, active)
        XCTAssertEqual(playlist.activePlaylistID, id)
    }
}

@MainActor private final class VideoCachePlaylistScheduler: PlaylistScheduling {
    var now: TimeInterval = 0
    private var alarms: [UUID: (TimeInterval, @MainActor () -> Void)] = [:]
    var count: Int { alarms.count }
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void)
        -> AnyCancellable
    {
        let id = UUID()
        alarms[id] = (now + seconds, action)
        return AnyCancellable { [weak self] in self?.alarms.removeValue(forKey: id) }
    }
    func advance(_ seconds: TimeInterval) {
        now += seconds
        let due = alarms.filter { $0.value.0 <= now }.sorted { $0.value.0 < $1.value.0 }
        for (id, _) in due {
            guard let alarm = alarms.removeValue(forKey: id) else { continue }
            alarm.1()
        }
    }
}
