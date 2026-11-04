import MetalKit
import XCTest

@testable import Wupsy

final class WSSCloudsDirectionTests: XCTestCase {
    // Compare an asymmetric own seeded field in an interior window. Searching
    // rendered pixels tests the complete Swift/Metal/UV path, not phase signs alone.
    func displacement(_ a: Data, _ b: Data, width: Int, height: Int, limit: Int) -> SIMD2<Int> {
        var best = Double.infinity
        var result = SIMD2<Int>.zero
        for dy in -limit...limit {
            for dx in -limit...limit {
                var error = 0.0
                for y in stride(from: limit + 4, to: height - limit - 4, by: 6) {
                    for x in stride(from: limit + 4, to: width - limit - 4, by: 6) {
                        let v =
                            Double(a[(y * width + x) * 4])
                            - Double(b[((y + dy) * width + x + dx) * 4])
                        error += v * v
                    }
                }
                if error < best {
                    best = error
                    result = SIMD2(dx, dy)
                }
            }
        }
        return result
    }
    func testRenderedCardinalDirectionsForBothFields() throws {
        let helper = WSSCloudsExtensionTests()
        for secondary in [false, true] {
            for velocity in [SIMD2<Float>(16, 0), SIMD2(-16, 0), SIMD2(0, 16), SIMD2(0, -16)] {
                var e = WSSCloudsEffect(
                    velocity: velocity, scale: 180, intensity: 1, density: 0.55, seed: 7)
                if secondary {
                    e.velocity = .zero
                    e.scale = 8192
                    e.secondaryField = .init(velocity: velocity, scale: 180)
                    e.secondaryInfluence = 1
                }
                let r = try helper.resources(e)
                let a = try WSSCloudsTests().render(r, time: 0, width: 256, height: 256).0
                let b = try WSSCloudsTests().render(r, time: 1, width: 256, height: 256).0
                let shift = displacement(a, b, width: 256, height: 256, limit: 20)
                print(
                    "Native Clouds rendered \(secondary ? "secondary" : "primary") velocity \(velocity): pixel shift \(shift)"
                )
                XCTAssertEqual(shift.x, Int(velocity.x), accuracy: 2)
                XCTAssertEqual(shift.y, Int(velocity.y), accuracy: 2)
            }
        }
    }

}
