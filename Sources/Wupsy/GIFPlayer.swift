import AppKit
import ImageIO

struct GIFTimeline {
    let ends: [TimeInterval]
    let duration: TimeInterval
    init(delays: [TimeInterval]) {
        var total: TimeInterval = 0
        ends = delays.map {
            total += max(0.02, $0)
            return total
        }
        duration = total
    }
    func index(at time: TimeInterval) -> Int {
        guard duration > 0 else { return 0 }
        let position = max(0, time).truncatingRemainder(dividingBy: duration)
        var low = 0
        var high = ends.count
        while low < high {
            let mid = (low + high) / 2
            if ends[mid] <= position { low = mid + 1 } else { high = mid }
        }
        return min(low, max(0, ends.count - 1))
    }
}

// Decodes only the frame needed now. No array of decompressed animation frames.
@MainActor final class GIFPlayer {
    let view: NSImageView
    private let source: CGImageSource
    private let timeline: GIFTimeline
    private let maxPixel: Int
    private let minimumInterval: Double
    private var timer: Timer?
    private var start: TimeInterval?
    private(set) var position: TimeInterval = 0
    private(set) var frameEnd: TimeInterval = 0
    private(set) var lastFrame = -1
    init(url: URL, size: CGSize, maxPixel: Int, fps: Int32) throws {
        guard
            let source = CGImageSourceCreateWithURL(
                url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw RuntimeDiagnostic.gifRead }
        self.source = source
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= 20000 else {
            throw RuntimeDiagnostic.gifFrames
        }
        let delays = (0..<count).map { index -> Double in
            let properties =
                CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        }
        timeline = GIFTimeline(delays: delays)
        self.maxPixel = maxPixel
        minimumInterval = 1 / Double(fps)
        view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.imageScaling = .scaleProportionallyUpOrDown
    }
    func play() {
        guard start == nil else { return }
        start = ProcessInfo.processInfo.systemUptime - position
        if lastFrame < 0 {
            tick()
        } else if timeline.ends.count > 1 {
            schedule(after: frameEnd - position)
        }
    }
    func pause() {
        if let start {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            // A timer may be overdue. Keep the displayed frame until it can advance.
            position = min(elapsed, frameEnd)
        }
        start = nil
        timer?.invalidate()
        timer = nil
        if lastFrame < 0 {
            frameEnd = timeline.ends[0]
            showFrame(0)
        }
    }
    private func tick() {
        guard let start else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let index = timeline.index(at: elapsed)
        let untilNext =
            timeline.ends[index] - elapsed.truncatingRemainder(dividingBy: timeline.duration)
        frameEnd = elapsed + untilNext
        showFrame(index)
        guard timeline.ends.count > 1 else { return }
        schedule(after: untilNext)
    }
    private func schedule(after delay: TimeInterval) {
        timer = Timer.scheduledTimer(
            withTimeInterval: max(minimumInterval, delay), repeats: false
        ) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        timer?.tolerance = 0.003
    }
    private func showFrame(_ index: Int) {
        if index != lastFrame {
            autoreleasepool {
                if let cg = CGImageSourceCreateThumbnailAtIndex(
                    source, index,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceShouldCache: false,
                    ] as CFDictionary)
                {
                    view.image = NSImage(cgImage: cg, size: .zero)
                }
            }
            lastFrame = index
        }
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        start = nil
        position = 0
        lastFrame = -1
        view.image = nil
    }
    deinit { timer?.invalidate() }
}
