import Foundation
import simd

// Original Wupsy implementation. No external assets, shaders or generator code.
struct WSSStormConfiguration: Codable, Equatable {
    var x: Double = 960
    var y: Double = 1000
    var direction: Double = 0
    var length: Double = 800
    var spread: Double = 120
    var width: Double = 2
    var glow: Double = 24
    var brightness: Double = 1
    var red: Double = 0.55
    var green: Double = 0.7
    var blue: Double = 1
    var branchDepth: Int = 2
    var interval: Double = 4
    var duration: Double = 0.12
    var flashes: Int = 2
    var flashGap: Double = 0.1
    var seed: UInt32 = 1
    init() {}
    enum CodingKeys: String, CodingKey, CaseIterable {
        case x, y, direction, length, spread, width, glow, brightness, red, green, blue
        case branchDepth, interval, duration, flashes, flashGap, seed
    }
    init(from decoder: Decoder) throws {
        try decoder.fields(CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        direction = try c.decode(Double.self, forKey: .direction)
        length = try c.decode(Double.self, forKey: .length)
        spread = try c.decode(Double.self, forKey: .spread)
        width = try c.decode(Double.self, forKey: .width)
        glow = try c.decode(Double.self, forKey: .glow)
        brightness = try c.decode(Double.self, forKey: .brightness)
        red = try c.decode(Double.self, forKey: .red)
        green = try c.decode(Double.self, forKey: .green)
        blue = try c.decode(Double.self, forKey: .blue)
        branchDepth = try c.decode(Int.self, forKey: .branchDepth)
        interval = try c.decode(Double.self, forKey: .interval)
        duration = try c.decode(Double.self, forKey: .duration)
        flashes = try c.decode(Int.self, forKey: .flashes)
        flashGap = try c.decode(Double.self, forKey: .flashGap)
        seed = try c.decode(UInt32.self, forKey: .seed)
        try validate()
    }
    // A minimum presentation width keeps short authored pulses visible at 24 fps.
    var presentationDuration: Double { max(0.05, duration) }
    var eventDuration: Double {
        Double(flashes) * presentationDuration + Double(flashes - 1) * flashGap
    }
    var segmentCount: Int { 64 * (branchDepth + 1) }
    func validate() throws {
        guard
            WSSStormParameter.allCases.allSatisfy({
                let value = $0.value(self)
                return value.isFinite && $0.range.contains(value)
            }), (0...3).contains(branchDepth), (1...3).contains(flashes),
            eventDuration <= interval * 0.75
        else { throw WSSSceneError.invalid("storm parameters or event overlap") }
    }
}
struct WSSStormLayer: Equatable {
    var name: String? = nil
    var visible = true
    var storm = WSSStormConfiguration()
    func validate() throws {
        if let name { _ = try WallpaperTitle.normalized(name) }
        try storm.validate()
    }
}

// Domain-separated, stateless random samples; scheduling never consumes geometry draws.
enum WSSStormRandom {
    static func hash(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
    static func unit(_ value: UInt64) -> Double {
        Double(hash(value) >> 11) / 9_007_199_254_740_992
    }
}
struct WSSStormEvent: Equatable {
    let identity: UInt64
    let age: Double
    let intensity: Float
}
enum WSSStormEvents {
    // Constant work for every finite time, including seeks beyond exact integer precision.
    // Fixed cadence with a seeded initial phase. At most one event per emitter.
    static func event(_ c: WSSStormConfiguration, at time: Double) -> WSSStormEvent? {
        guard time.isFinite, time >= 0, c.interval.isFinite, c.interval >= 0.5 else { return nil }
        let onset =
            c.interval * (0.1 + 0.1 * WSSStormRandom.unit(UInt64(c.seed) ^ 0x5343_4845_4455_4c45))
        let phase = time.truncatingRemainder(dividingBy: c.interval)
        let age = phase - onset
        guard age >= 0, age < c.eventDuration else { return nil }
        let cycle = floor(time / c.interval)
        let identity = cycle.isFinite ? cycle.bitPattern : time.bitPattern
        let pulse = floor(age / (c.presentationDuration + c.flashGap))
        let pulseAge = age - pulse * (c.presentationDuration + c.flashGap)
        let intensity: Double
        if pulseAge < c.presentationDuration {
            // Fast attack, held visibility, then a short decay. No frame-history dependency.
            let tail = max(0, (pulseAge - 0.04) / max(0.01, c.presentationDuration - 0.04))
            intensity = (1 - tail) * pow(0.72, pulse)
        } else {
            intensity = 0
        }
        return WSSStormEvent(identity: identity, age: age, intensity: Float(intensity))
    }
}
struct WSSStormSegment: Equatable {
    let a: SIMD2<Float>
    let b: SIMD2<Float>
    let strength: Float
    var previous: SIMD2<Float>? = nil
    var next: SIMD2<Float>? = nil
}
enum WSSStormGeometry {
    static let maximumSegmentsPerLayer = 256
    static let maximumSegmentsPerScene = 4096
    static let maximumLayers = 8
    static func segments(_ c: WSSStormConfiguration, event: UInt64) throws -> [WSSStormSegment] {
        try c.validate()
        var result: [WSSStormSegment] = []
        var counter = WSSStormRandom.hash(UInt64(c.seed) ^ event ^ 0x4745_4f4d_4554_5259)
        func random() -> Float {
            counter &+= 1
            return Float(WSSStormRandom.unit(counter))
        }
        func path(
            _ start: SIMD2<Float>, _ end: SIMD2<Float>, count: Int, depth: Int, strength: Float
        ) {
            let delta = end - start
            let normal = SIMD2(-delta.y, delta.x) / max(0.001, simd_length(delta))
            // Correlated large bends plus smaller kinks, rather than independent
            // full-width jumps at every vertex. Counts are bounded powers of two.
            var offsets = [Float](repeating: 0, count: count + 1)
            var step = count
            while step > 1 {
                for left in stride(from: 0, to: count, by: step) {
                    let mid = left + step / 2
                    offsets[mid] =
                        (offsets[left] + offsets[left + step]) * 0.5
                        + (random() * 2 - 1) * Float(c.spread) * strength
                        * Float(step) / Float(count)
                }
                step /= 2
            }
            let points = (0...count).map { i -> SIMD2<Float> in
                if i == 0 { return start }
                if i == count { return end }
                let t = Float(i) / Float(count)
                return start + delta * t + normal * offsets[i] * sin(t * .pi)
            }
            for i in 0..<count {
                result.append(
                    .init(
                        a: points[i], b: points[i + 1], strength: strength,
                        previous: i > 0 ? points[i - 1] : nil,
                        next: i + 2 < points.count ? points[i + 2] : nil))
            }
            if depth > 0 {
                for sign: Float in [-1, 1] {
                    let index = count / 4 + Int(random() * Float(count / 2))
                    let origin = points[index]
                    let tip =
                        origin + delta * 0.38 + normal * sign * simd_length(delta)
                        * (0.12 + random() * 0.18)
                    path(origin, tip, count: count / 2, depth: depth - 1, strength: strength * 0.6)
                }
            }
        }
        // Local geometry: translation/rotation are uniforms and do not invalidate the cache.
        path(.zero, SIMD2(0, -Float(c.length)), count: 64, depth: c.branchDepth, strength: 1)
        guard result.count <= maximumSegmentsPerLayer else {
            throw WSSSceneError.invalid("storm segment budget")
        }
        return result
    }
}
