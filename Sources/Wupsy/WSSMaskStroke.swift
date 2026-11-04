import Foundation

struct WSSMaskBrushSettings {
    enum Mode { case paint, erase }
    let diameter: Double
    let opacity: Double
    let mode: Mode
    init(diameter: Double, opacity: Double, mode: Mode) throws {
        guard diameter.isFinite, diameter >= 1, opacity.isFinite, (0...1).contains(opacity) else {
            throw WSSMaskError.invalid
        }
        self.diameter = diameter
        self.opacity = opacity
        self.mode = mode
    }
    static func maximumDiameter(width: Int, height: Int) -> Double {
        Double(2 * max(width, height))
    }
    static func coverage(distance: Double, radius: Double) -> Double {
        guard distance.isFinite, radius.isFinite, radius > 0, distance >= 0 else { return 0 }
        let t = min(1, max(0, (distance - radius * 0.5) / (radius * 0.5)))
        return 1 - t * t * (3 - 2 * t)
    }
    static func quantized(_ value: Double) -> UInt8 {
        UInt8((min(1, max(0, value)) * 255).rounded(.toNearestOrAwayFromZero))
    }
}
struct WSSMaskStrokeCandidate {
    let resolved: WSSResolvedMaskTarget
    let revision: UInt64
    let before: WSSMaskBitmap
    let result: WSSMaskBitmap
    fileprivate init(
        resolved: WSSResolvedMaskTarget, revision: UInt64, before: WSSMaskBitmap,
        result: WSSMaskBitmap
    ) {
        self.resolved = resolved
        self.revision = revision
        self.before = before
        self.result = result
    }
}

// Pure CPU transaction. Positions are texel-center coordinates, independent of views/devices.
struct WSSMaskStrokeTransaction {
    let resolved: WSSResolvedMaskTarget
    let revision: UInt64
    let before: WSSMaskBitmap
    let settings: WSSMaskBrushSettings
    private(set) var pixels: Data
    private(set) var dirtyRegion: CGRect?
    private var maxima: [Float]
    private var last: SIMD2<Double>?
    private var remaining: Double
    private var active = true
    private var spacing: Double { settings.diameter / 8 }
    init(
        resolved: WSSResolvedMaskTarget, revision: UInt64, bitmap: WSSMaskBitmap,
        settings: WSSMaskBrushSettings, start: SIMD2<Double>
    ) throws {
        guard
            settings.diameter
                <= WSSMaskBrushSettings.maximumDiameter(
                    width: bitmap.width, height: bitmap.height)
        else { throw WSSMaskError.invalid }
        self.resolved = resolved
        self.revision = revision
        before = bitmap
        self.settings = settings
        pixels = bitmap.pixels
        maxima = [Float](repeating: 0, count: pixels.count)
        remaining = settings.diameter / 8
        try append(start)
    }
    mutating func append(_ point: SIMD2<Double>) throws {
        guard active else { throw WSSMaskError.transaction }
        guard point.x.isFinite, point.y.isFinite, abs(point.x) <= 32768, abs(point.y) <= 32768
        else { throw WSSMaskError.invalid }
        dirtyRegion = nil
        guard let previous = last else {
            last = point
            remaining = spacing
            stamp(point)
            return
        }
        let delta = point - previous
        let distance = hypot(delta.x, delta.y)
        if distance > 0 {
            let direction = delta / distance
            var travelled = 0.0
            while remaining <= distance - travelled {
                travelled += remaining
                stamp(previous + direction * travelled)
                remaining = spacing
            }
            remaining -= distance - travelled
        }
        last = point
    }
    // Explicit outside/discontinuity boundary. No line to the next input segment.
    mutating func breakSegment() throws {
        guard active else { throw WSSMaskError.transaction }
        dirtyRegion = nil
        if let last { stamp(last) }
        last = nil
        remaining = spacing
    }
    mutating func finish(at point: SIMD2<Double>? = nil) throws -> WSSMaskStrokeCandidate? {
        guard active else { throw WSSMaskError.transaction }
        if let point { try append(point) }
        if let last { stamp(last) }
        active = false
        maxima.removeAll()
        guard pixels != before.pixels else { return nil }
        return WSSMaskStrokeCandidate(
            resolved: resolved, revision: revision, before: before,
            result: try WSSMaskBitmap(
                width: before.width, height: before.height, uvScale: before.uvScale, pixels: pixels)
        )
    }
    mutating func cancel() {
        active = false
        pixels = before.pixels
        maxima.removeAll()
        last = nil
    }
    private mutating func stamp(_ point: SIMD2<Double>) {
        guard settings.mode == .paint || settings.opacity > 0 else { return }
        let radius = settings.diameter / 2
        // A one-pixel brush must also cover subpixel paths between texel centers.
        // Integrate its fixed falloff over a deterministic 4x4 pixel footprint.
        let extent = radius + (radius < 1 ? 0.5 : 0)
        let x0 = max(0, Int(ceil(point.x - extent)))
        let x1 = min(before.width - 1, Int(floor(point.x + extent)))
        let y0 = max(0, Int(ceil(point.y - extent)))
        let y1 = min(before.height - 1, Int(floor(point.y + extent)))
        guard x0 <= x1, y0 <= y1 else { return }
        for y in y0...y1 {
            for x in x0...x1 {
                var amount = 0.0
                if radius < 1 {
                    for sy in 0..<4 {
                        for sx in 0..<4 {
                            amount +=
                                WSSMaskBrushSettings.coverage(
                                    distance: hypot(
                                        Double(x) + (Double(sx) + 0.5) / 4 - 0.5 - point.x,
                                        Double(y) + (Double(sy) + 0.5) / 4 - 0.5 - point.y),
                                    radius: radius) / 16
                        }
                    }
                } else {
                    amount = WSSMaskBrushSettings.coverage(
                        distance: hypot(Double(x) - point.x, Double(y) - point.y), radius: radius)
                }
                let coverage = Float(amount)
                let index = y * before.width + x
                guard coverage > maxima[index] else { continue }
                maxima[index] = coverage
                let a = settings.opacity * Double(coverage)
                let old = Double(before.pixels[index]) / 255
                let value =
                    settings.mode == .paint
                    ? old + (settings.opacity - old) * Double(coverage) : old * (1 - a)
                let byte = WSSMaskBrushSettings.quantized(value)
                if pixels[index] != byte {
                    pixels[index] = byte
                    let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                    dirtyRegion = dirtyRegion.map { $0.union(pixel) } ?? pixel
                }
            }
        }
    }
}
