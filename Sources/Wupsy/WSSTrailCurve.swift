import simd

// Position-only cubic, derived from endpoint/tangent requirements documented in
// docs/CURSOR-TRAIL-CURVES.md. No timing, color, opacity or history state belongs here.
struct WSSTrailCurve {
    static let subdivisions = 5
    let start: SIMD2<Float>
    let firstControl: SIMD2<Float>
    let secondControl: SIMD2<Float>
    let end: SIMD2<Float>

    // Caller supplies finite observations and a validated amount in 0...0.5.
    // At boundaries the caller repeats the nearest endpoint for its missing neighbor.
    init(
        previous: SIMD2<Float>, start: SIMD2<Float>, end: SIMD2<Float>,
        following: SIMD2<Float>, amount: Float
    ) {
        self.start = start
        self.end = end
        firstControl = start + (end - previous) * amount
        secondControl = end + (start - following) * amount
    }
    func point(at t: Float) -> SIMD2<Float> {
        let u = 1 - t
        // Bernstein form; explicit Float operation order preserves the accepted
        // 0.15 default. The parameter is interpolation progress, not sample age.
        return u * u * u * start + 3 * u * u * t * firstControl
            + 3 * u * t * t * secondControl + t * t * t * end
    }
}
