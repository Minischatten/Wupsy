import Foundation

// Native WSS values. No engine shader identity, runtime resource or document format.
enum WSSImageEffect: Sendable, Equatable {
    case clouds(WSSCloudsEffect)
    case ripple(WSSRippleEffect)
    case flow(WSSFlowEffect)
}
struct WSSImageMask: Sendable, Equatable {
    // Linear red intensity, top-left origin, normalized local image UV; clamp at edges.
    var asset: WSSAssetID
}
struct WSSCloudsField: Sendable, Equatable {
    var velocity: SIMD2<Float>
    var scale: Float
    func validate() throws {
        guard velocity.x.isFinite, velocity.y.isFinite,
            abs(velocity.x) <= 4096, abs(velocity.y) <= 4096,
            scale.isFinite, (1...8192).contains(scale)
        else { throw WSSSceneError.invalid("clouds field") }
    }
}
struct WSSCloudsEffect: Sendable, Equatable {
    var velocity = SIMD2<Float>(12, 0)  // Logical scene units per second along local image axes.
    var scale: Float = 256
    var intensity: Float = 0.3
    var density: Float = 0.5
    var seed: UInt32 = 1
    var mask: WSSImageMask?
    var secondaryField: WSSCloudsField?
    var secondaryInfluence: Float = 0.35
    var softness: Float = 0  // 0 preserves existing structure; 1 broad diffuse masses.
    var brightness: Float = 1
    var shadingAmount: Float = 0
    var shadingDirection: Float = 0  // Degrees: 0 up, 90 right, local top-left image UV.
    var primaryField: WSSCloudsField {
        get { WSSCloudsField(velocity: velocity, scale: scale) }
        set {
            velocity = newValue.velocity
            scale = newValue.scale
        }
    }
    var isExtended: Bool {
        (secondaryField != nil && secondaryInfluence > 0) || brightness != 1 || shadingAmount > 0
            || softness > 0
    }
    var shadingVector: SIMD2<Float> {
        let angle = shadingDirection * .pi / 180
        return SIMD2(sin(angle), -cos(angle))
    }
    func secondaryPhase(at time: Double) throws -> SIMD2<Float> {
        guard let field = secondaryField else { return .zero }
        return try WSSCloudsEffect(velocity: field.velocity, scale: field.scale).phase(
            at: time, orientation: WSSCloudsNoise.secondaryOrientation)
    }

    func validate() throws {
        guard velocity.x.isFinite, velocity.y.isFinite,
            abs(velocity.x) <= 4096, abs(velocity.y) <= 4096,
            scale.isFinite, (1...8192).contains(scale),
            intensity.isFinite, (0...1).contains(intensity),
            density.isFinite, (0...1).contains(density),
            mask.map({ !$0.asset.value.isEmpty }) ?? true
        else { throw WSSSceneError.invalid("clouds parameters or mask") }
        try secondaryField?.validate()
        guard softness.isFinite, (0...1).contains(softness),
            secondaryInfluence.isFinite, (0...1).contains(secondaryInfluence),
            brightness.isFinite, (0...2).contains(brightness),
            shadingAmount.isFinite, (0...1).contains(shadingAmount),
            shadingDirection.isFinite, shadingDirection >= 0, shadingDirection < 360
        else { throw WSSSceneError.invalid("extended clouds parameters") }
    }
    func phase(at time: Double, frequency: Float = 1, orientation: SIMD2<Float> = SIMD2(1, 0))
        throws -> SIMD2<Float>
    {
        try validate()
        guard time.isFinite, time >= 0, frequency.isFinite, frequency > 0 else {
            throw WSSSceneError.invalid("playback time")
        }
        // Reduce each sampled domain independently in Double. Noninteger detail
        // frequencies cannot reuse a wrapped base phase: that would jump at wraps.
        // All domains still describe the same translation, with no relative drift.
        func component(_ speed: Float) -> Float {
            guard speed != 0 else { return 0 }
            let period = Double(scale) / (abs(Double(speed)) * Double(frequency))
            let value =
                time.truncatingRemainder(dividingBy: period) * Double(speed) * Double(frequency)
                / Double(scale)
            return Float(value)
        }
        guard orientation.x.isFinite, orientation.y.isFinite,
            abs(orientation.x * orientation.x + orientation.y * orientation.y - 1) < 0.0001
        else { throw WSSSceneError.invalid("clouds orientation") }
        let rotated = SIMD2(
            orientation.x * velocity.x - orientation.y * velocity.y,
            orientation.y * velocity.x + orientation.x * velocity.y)
        return SIMD2(component(rotated.x), component(rotated.y))
    }
}

// Independently authored WSS scalar value field: a seeded 8x8 periodic lattice
// with quintic interpolation, stored as 128x128 R8. No CPU octave averaging:
// the shader explicitly assigns shape, interior and detail their own roles.
// No imported noise, shader source or third-party implementation is used.
enum WSSCloudsNoise {
    static let size = 128
    // Noninteger relative frequencies and distinct offsets reduce repeated/correlated
    // detail. These are implementation choices, not new document/editor parameters.
    // Unit rotation makes the lattice axes independent of image edges. Rotate
    // the translation by the same basis so visible velocity remains unchanged.
    static let orientation = SIMD2<Float>(0.8, 0.6)
    static let secondaryOrientation = SIMD2<Float>(0.6, -0.8)
    static let middleFrequency: Float = 2.37
    static let detailFrequency: Float = 5.83
    static func pixels(seed: UInt32) -> Data {
        var state = seed
        let cells = 8
        let grid = (0..<(cells * cells)).map { _ -> Double in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Double(state >> 8) / Double(0xFFFFFF)
        }
        func blend(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }
        var field = Data(count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let px = Double(x) * Double(cells) / Double(size)
                let py = Double(y) * Double(cells) / Double(size)
                let ix = Int(px)
                let iy = Int(py)
                let sx = blend(px - Double(ix))
                let sy = blend(py - Double(iy))
                func g(_ dx: Int, _ dy: Int) -> Double {
                    grid[((iy + dy) % cells) * cells + (ix + dx) % cells]
                }
                let a = g(0, 0) * (1 - sx) + g(1, 0) * sx
                let b = g(0, 1) * (1 - sx) + g(1, 1) * sx
                field[y * size + x] = UInt8(((a * (1 - sy) + b * sy) * 255).rounded())
            }
        }
        return field
    }
}

// Clock is explicit and testable; stopped time remains frozen. Renderer recreates
// sessions on resume, supplying this elapsed value as its existing offset.
struct WSSPlaybackClock {
    private var offset: Double
    private var start: Double?
    init(offset: Double = 0) { self.offset = offset }
    mutating func play(now: Double) { if start == nil { start = now } }
    mutating func stop(now: Double) {
        if let start { offset += max(0, now - start) }
        start = nil
    }
    func time(now: Double) -> Double { offset + (start.map { max(0, now - $0) } ?? 0) }
}

extension WSSImageEffect {
    var samplingRipple: WSSRippleEffect? {
        if case .ripple(let effect) = self { return effect }
        return nil
    }
}
