import Foundation
import simd

// Native cursor-trail DTO used by scene-v1 cursorTrail layers and isolated QA.
// All distances are logical canvas pixels, all durations seconds, RGB is linear.
struct WSSTrailColor: Codable, Equatable, Sendable {
    var r: Float
    var g: Float
    var b: Float
    var rgb: SIMD3<Float> { SIMD3(r, g, b) }
}
struct WSSTrailConfiguration: Codable, Equatable, Sendable {
    enum ColorMode: String, Codable, Sendable { case sampleRandom, ageGradient }
    static let defaultCurveSmoothing: Float = 0.15
    var colors: [WSSTrailColor]
    var colorMode: ColorMode = .sampleRandom
    var maxLength: Float? = nil
    var width: Float = 12
    var curveSmoothing: Float = WSSTrailConfiguration.defaultCurveSmoothing
    var lifetime: Double = 1
    var emissionRate: Double = 32
    var fadeIn: Double = 0.1
    var fadeOut: Double = 0.9
    var opacity: Float = 1
    var edgeSoftness: Float = 0.65
    var seed: UInt32 = 1

    func validate() throws {
        guard maxLength.map({ $0.isFinite && $0 > 0 && $0 <= 16384 }) ?? true,
            (1...16).contains(colors.count),
            colors.allSatisfy({ color in
                color.rgb.indices.allSatisfy { i in
                    color.rgb[i].isFinite && (0...1).contains(color.rgb[i])
                }
            }),
            width.isFinite, width > 0, width <= 256,
            curveSmoothing.isFinite, (0...0.5).contains(curveSmoothing),
            lifetime.isFinite, lifetime > 0, lifetime <= 10,
            emissionRate.isFinite, emissionRate >= 1, emissionRate <= 512,
            lifetime * emissionRate <= 4096,
            fadeIn.isFinite, fadeOut.isFinite, fadeIn >= 0, fadeOut >= 0,
            fadeIn + fadeOut <= lifetime + 1e-9,
            opacity.isFinite, (0...1).contains(opacity),
            edgeSoftness.isFinite, (0...1).contains(edgeSoftness)
        else { throw WSSSceneError.invalid("native trail parameters") }
    }
    func color(_ coordinate: Float) -> SIMD3<Float> {
        let x = max(0, min(1, coordinate)) * Float(colors.count - 1)
        let i = min(colors.count - 1, Int(x))
        return simd_mix(
            colors[i].rgb, colors[min(i + 1, colors.count - 1)].rgb,
            SIMD3(repeating: x - Float(i)))
    }
    func alpha(age: Double) -> Float {
        guard age >= 0, age < lifetime else { return 0 }
        let enter = fadeIn > 0 ? min(1, age / fadeIn) : 1
        let leave = fadeOut > 0 ? min(1, (lifetime - age) / fadeOut) : 1
        return opacity * Float(min(enter, leave))
    }
}
struct WSSTrailSample: Equatable {
    var position: SIMD2<Float>
    var birth: Double
    var colorCoordinate: Float
}
struct WSSTrailVertex {
    var position: SIMD2<Float>
    var side: Float
    var padding: Float = 0
    var color: SIMD4<Float>
}

struct WSSTrailSimulation {
    let configuration: WSSTrailConfiguration
    private(set) var samples: [WSSTrailSample] = []
    private var previous: (time: Double, pointer: SIMD2<Float>)?
    private var epoch: Double = 0
    private var nextIndex: Int = 0
    init(configuration: WSSTrailConfiguration) throws {
        try configuration.validate()
        self.configuration = configuration
    }
    mutating func reset() {
        samples.removeAll()
        previous = nil
        nextIndex = 0
    }
    private func random(_ index: Int) -> Float {
        var x = UInt32(truncatingIfNeeded: index) &+ configuration.seed &* 747_796_405
        x = (x ^ (x >> 16)) &* 2_246_822_519
        x = (x ^ (x >> 13)) &* 3_266_489_917
        return Float((x ^ (x >> 16)) >> 8) / Float(0xffffff)
    }
    mutating func update(time: Double, pointer: SIMD2<Float>?) {
        guard time.isFinite, abs(time) < 1e12, let p = pointer, p.x.isFinite, p.y.isFinite else {
            reset()
            return
        }
        if let old = previous, time < old.time || time - old.time > configuration.lifetime {
            reset()
        }
        guard let old = previous else {
            epoch = time
            nextIndex = 1
            samples = [.init(position: p, birth: time, colorCoordinate: random(0))]
            previous = (time, p)
            return
        }
        samples.removeAll { time - $0.birth >= configuration.lifetime }
        // Skip expired emissions after a gap; work stays bounded by the live population.
        let oldest = max(
            0,
            Int(
                floor(
                    (time - configuration.lifetime - epoch)
                        * configuration.emissionRate)) + 1)
        nextIndex = max(nextIndex, oldest)
        while epoch + Double(nextIndex) / configuration.emissionRate <= time + 1e-9 {
            let birth = epoch + Double(nextIndex) / configuration.emissionRate
            let f = time > old.time ? Float((birth - old.time) / (time - old.time)) : 1
            samples.append(
                .init(
                    position: old.pointer + (p - old.pointer) * f,
                    birth: birth, colorCoordinate: random(nextIndex)))
            nextIndex += 1
        }
        previous = (time, p)
        if let limit = configuration.maxLength { clipHistory(to: limit) }
    }
    // Walk the bounded live population once. The boundary replaces an existing
    // endpoint; clipping never adds a sample or changes the emission epoch.
    private mutating func clipHistory(to limit: Float) {
        guard samples.count > 1 else { return }
        var distance: Float = 0
        for i in stride(from: samples.count - 2, through: 0, by: -1) {
            let older = samples[i]
            let newer = samples[i + 1]
            let segment = simd_distance(older.position, newer.position)
            if distance + segment > limit {
                let fraction = (limit - distance) / segment
                samples[i] = .init(
                    position: newer.position + (older.position - newer.position) * fraction,
                    birth: newer.birth + (older.birth - newer.birth) * Double(fraction),
                    colorCoordinate: newer.colorCoordinate
                        + (older.colorCoordinate - newer.colorCoordinate) * fraction)
                samples.removeFirst(i)
                return
            }
            distance += segment
            if distance == limit {
                samples.removeFirst(i)
                return
            }
        }
    }
    func vertices(time: Double) -> [WSSTrailVertex] {
        guard time.isFinite, samples.count >= 2 else { return [] }
        let c = configuration
        func rgba(_ s: WSSTrailSample) -> SIMD4<Float> {
            let age = time - s.birth
            return SIMD4(
                c.color(
                    c.colorMode == .ageGradient
                        ? Float(age / c.lifetime) : s.colorCoordinate), c.alpha(age: age))
        }
        var result: [WSSTrailVertex] = []
        for i in 0..<(samples.count - 1) {
            let p = samples[i].position
            let q = samples[i + 1].position
            let before = samples[max(0, i - 1)].position
            let after = samples[min(samples.count - 1, i + 2)].position
            func normal(_ v: SIMD2<Float>) -> SIMD2<Float> {
                let len = simd_length(v)
                return len > 1e-5 ? SIMD2(-v.y, v.x) / len * c.width * 0.5 : .zero
            }
            let n0 = normal(q - before)
            let n1 = normal(after - p)
            if simd_length(n0) + simd_length(n1) == 0 { continue }
            let curve = WSSTrailCurve(
                previous: before, start: p, end: q, following: after,
                amount: c.curveSmoothing)
            func vertex(_ t: Float, _ side: Float) -> WSSTrailVertex {
                let center = curve.point(at: t)
                return .init(
                    position: center + (n0 + (n1 - n0) * t) * side, side: side,
                    color: rgba(samples[i]) + (rgba(samples[i + 1]) - rgba(samples[i])) * t)
            }
            for j in 0..<WSSTrailCurve.subdivisions {
                let t0 = Float(j) / Float(WSSTrailCurve.subdivisions)
                let t1 = Float(j + 1) / Float(WSSTrailCurve.subdivisions)
                result += [
                    vertex(t0, -1), vertex(t1, -1), vertex(t1, 1),
                    vertex(t0, -1), vertex(t1, 1), vertex(t0, 1),
                ]
            }
        }
        return result
    }
}

struct WSSTrailLayer {
    var configuration: WSSTrailConfiguration
    var visible = true
}

extension WSSTrailColor {
    enum CodingKeys: String, CodingKey { case r, g, b }
    init(from decoder: Decoder) throws {
        try decoder.fields(["r", "g", "b"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        r = try c.decode(Float.self, forKey: .r)
        g = try c.decode(Float.self, forKey: .g)
        b = try c.decode(Float.self, forKey: .b)
    }
}
extension WSSTrailConfiguration {
    enum CodingKeys: String, CodingKey {
        case colors, colorMode, maxLength, width, lifetime, emissionRate, fadeIn, fadeOut, opacity,
            edgeSoftness, seed, curveSmoothing
    }
    init(from decoder: Decoder) throws {
        try decoder.fields([
            "colors", "colorMode", "maxLength", "width", "lifetime", "emissionRate", "fadeIn",
            "fadeOut",
            "opacity", "edgeSoftness", "seed", "curveSmoothing",
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxLength = c.contains(.maxLength) ? try c.decode(Float.self, forKey: .maxLength) : nil
        colors = try c.decode([WSSTrailColor].self, forKey: .colors)
        colorMode = try c.decode(ColorMode.self, forKey: .colorMode)
        curveSmoothing =
            c.contains(.curveSmoothing)
            ? try c.decode(Float.self, forKey: .curveSmoothing) : Self.defaultCurveSmoothing
        width = try c.decode(Float.self, forKey: .width)
        lifetime = try c.decode(Double.self, forKey: .lifetime)
        emissionRate = try c.decode(Double.self, forKey: .emissionRate)
        fadeIn = try c.decode(Double.self, forKey: .fadeIn)
        fadeOut = try c.decode(Double.self, forKey: .fadeOut)
        opacity = try c.decode(Float.self, forKey: .opacity)
        edgeSoftness = try c.decode(Float.self, forKey: .edgeSoftness)
        seed = try c.decode(UInt32.self, forKey: .seed)
        try validate()
    }
}
