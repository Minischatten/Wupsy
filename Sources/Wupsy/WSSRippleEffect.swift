import Foundation
import simd

// Independently authored WSS wave field. No imported normal map, shader, or
// compatibility calculation. Coordinates are logical local image units, y down.
struct WSSRippleEffect: Sendable, Equatable {
    var amplitude: Float = 6
    var wavelength: Float = 120
    var stretch: Float = 1
    var direction: Float = 180
    var travelSpeed: Float = 20
    var evolutionRate: Float = 0.2
    var mask: WSSImageMask?
    var seed: UInt32 = 1

    // Clockwise degrees relative to the original stretched structure, local y down.
    // Zero uses the original v1 arithmetic without a rotation round-trip.
    var structureRotation: Float = 0

    // Dimensionless spatial detail of displacement transverse to direction.
    // One bypasses projection and retains the original v1 arithmetic/render path.
    var lateralDetail: Float = 1

    func validate() throws {
        guard amplitude.isFinite, (0...256).contains(amplitude),
            wavelength.isFinite, (4...8192).contains(wavelength),
            stretch.isFinite, (0.125...8).contains(stretch),
            direction.isFinite, (0..<360).contains(direction),
            travelSpeed.isFinite, (0...4096).contains(travelSpeed),
            evolutionRate.isFinite, (0...8).contains(evolutionRate),
            mask.map({ !$0.asset.value.isEmpty }) ?? true,
            structureRotation.isFinite, (0..<360).contains(structureRotation),
            lateralDetail.isFinite, (0.125...8).contains(lateralDetail)
        else { throw WSSSceneError.invalid("ripple parameters or mask") }
    }
    var velocity: SIMD2<Double> {
        let angle = Double(direction) * .pi / 180
        return SIMD2(sin(angle), -cos(angle)) * Double(travelSpeed)
    }
    struct Wave {
        let k: SIMD2<Double>  // cycles per logical unit
        let offset: Double  // cycles
        let evolution: Double  // signed cycles per second at rate 1
        let displacement: SIMD2<Float>  // weighted unit vector
    }
    var waves: [Wave] {
        var state = UInt64(seed) + 0x9e37_79b9_7f4a_7c15
        // Own deterministic integer mixer; fixed arithmetic, no platform RNG.
        func random() -> Double {
            state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            return Double(state >> 32) / 4_294_967_296
        }
        let original = (0..<6).map { i in
            let angle = (Double(i) + random() * 0.7) * 2 * .pi / 6
            let frequency = (0.65 + random() * 1.25) / Double(wavelength)
            let displacementAngle = random() * 2 * .pi
            let offset = random()
            let evolution = (random() * 2 - 1) * (0.15 + Double(i) * 0.11)
            return Wave(
                k: SIMD2(cos(angle), sin(angle) / Double(stretch)) * frequency,
                offset: offset, evolution: evolution,
                displacement: SIMD2(Float(cos(displacementAngle)), Float(sin(displacementAngle)))
                    / 6)
        }
        guard structureRotation != 0 else { return original }
        let angle = Double(structureRotation) * .pi / 180
        let c = cos(angle)
        let s = sin(angle)
        // Rotate the already stretched spatial wavevectors clockwise in y-down
        // coordinates. Keep sample-offset vectors, phases, weights and seeds intact.
        return original.map { wave in
            Wave(
                k: SIMD2(c * wave.k.x - s * wave.k.y, s * wave.k.x + c * wave.k.y),
                offset: wave.offset, evolution: wave.evolution,
                displacement: wave.displacement)
        }
    }
    // Unit transverse axis in logical image coordinates (y down), independent of
    // speed and structure rotation. Exact cardinal axes avoid trigonometric leakage
    // into the untouched component, including W2's downward flow.
    var lateralAxis: SIMD2<Float> {
        switch direction {
        case 0: return SIMD2(-1, 0)
        case 90: return SIMD2(0, -1)
        case 180: return SIMD2(1, 0)
        case 270: return SIMD2(0, 1)
        default:
            let angle = Double(direction) * .pi / 180
            return SIMD2(Float(-cos(angle)), Float(-sin(angle)))
        }
    }
    var lateralWaves: [Wave] {
        waves.map {
            Wave(
                k: $0.k * Double(lateralDetail), offset: $0.offset,
                evolution: $0.evolution, displacement: $0.displacement)
        }
    }
    // Preserve the longitudinal projection; cardinal cases also preserve the
    // untouched coordinate bit-for-bit. Shared by the CPU diagnostic and Metal.
    func replacingLateral(_ original: SIMD2<Float>, with value: Float) -> SIMD2<Float> {
        let axis = lateralAxis
        if axis.y == 0 { return SIMD2(axis.x * value, original.y) }
        if axis.x == 0 { return SIMD2(original.x, axis.y * value) }
        return original + axis * (value - simd_dot(axis, original))
    }
    // Reduce each component's complete temporal frequency in Double. Wrapping a
    // shared base phase would jump when component frequencies are nonintegral.
    func phase(_ wave: Wave, at time: Double) throws -> Float {
        try validate()
        guard time.isFinite, time >= 0 else { throw WSSSceneError.invalid("ripple time") }
        let frequency = -simd_dot(wave.k, velocity) + wave.evolution * Double(evolutionRate)
        let cycles =
            frequency == 0
            ? 0 : time.truncatingRemainder(dividingBy: 1 / abs(frequency)) * frequency
        return Float((wave.offset + cycles).truncatingRemainder(dividingBy: 1) * 2 * .pi)
    }
    // CPU diagnostic reference to the independently specified field, not a renderer.
    func displacement(at point: SIMD2<Double>, time: Double) throws -> SIMD2<Float> {
        let original = try waves.reduce(SIMD2<Float>.zero) { result, wave in
            let angle = simd_dot(wave.k, point) * 2 * .pi + Double(try phase(wave, at: time))
            return result + wave.displacement * Float(sin(angle)) * amplitude
        }
        guard lateralDetail != 1 else { return original }
        let axis = lateralAxis
        let lateral = try lateralWaves.reduce(Float.zero) { result, wave in
            let angle = simd_dot(wave.k, point) * 2 * .pi + Double(try phase(wave, at: time))
            return result + simd_dot(axis, wave.displacement) * Float(sin(angle)) * amplitude
        }
        return replacingLateral(original, with: lateral)
    }
}
