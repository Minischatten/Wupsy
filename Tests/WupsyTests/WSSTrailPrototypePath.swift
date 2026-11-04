import Foundation
import simd

// Test-only deterministic input. Never compiled into the product target.
// Original analytic input, no captured video coordinates or reference assets.
enum WSSTrailPrototypePath: String, CaseIterable {
    case straight, slowArc, quickTurn
    func pointer(time: Double) -> SIMD2<Float> {
        let t = Float(max(0, min(1, time)))  // all paths stop at one second
        switch self {
        case .straight: return SIMD2(100 + 600 * t, 240)
        case .slowArc:
            let a = Float.pi * t
            return SIMD2(400 + 60 * cos(a), 240 + 60 * sin(a))
        case .quickTurn:
            if t < 0.5 { return SIMD2(100 + 1200 * t, 180) }
            return SIMD2(700 - 1000 * (t - 0.5), 180 + 400 * (t - 0.5))
        }
    }
}
