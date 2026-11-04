import MetalKit
import XCTest
import simd

@testable import Wupsy

final class WSSRippleDetailTests: XCTestCase {
    func decode(_ json: [String: Any]) throws -> WSSRippleEffect {
        try WSSRippleOrientationTests().decode(json)
    }
    func testOptionalDefaultStrictRangeAndUnchangedGenerator() throws {
        let json = WSSRippleTests().effectJSON()
        let absent = try decode(json)
        XCTAssertEqual(absent.lateralDetail, 1)
        var explicit = json
        explicit["lateralDetail"] = 1
        XCTAssertEqual(try decode(explicit), absent)
        for value: Float in [0.125, 0.5, 3, 8] {
            explicit["lateralDetail"] = value
            XCTAssertEqual(try decode(explicit).lateralDetail, value)
        }
        for value: Any in [0, -1, 0.124, 8.001, NSNull(), true, "3"] {
            explicit["lateralDetail"] = value
            XCTAssertThrowsError(try decode(explicit), "\(value)")
        }
        for key in ["lateralStructureScale", "coherence", "dxFrequencyMultiplier"] {
            explicit = json
            explicit[key] = 3
            XCTAssertThrowsError(try decode(explicit))
        }
        for value: Float in [.nan, .infinity, -.infinity] {
            var effect = absent
            effect.lateralDetail = value
            XCTAssertThrowsError(try effect.validate())
        }
        var detail = absent
        detail.lateralDetail = 3
        for (old, new) in zip(absent.waves, detail.waves) {
            XCTAssertEqual(old.k, new.k)
            XCTAssertEqual(old.displacement, new.displacement)
            XCTAssertEqual(old.offset, new.offset)
            XCTAssertEqual(old.evolution, new.evolution)
        }
    }
    func testDefaultUsesOriginalGPUPathIncludingChain() throws {
        let helper = WSSRippleTests()
        let absent = try decode(helper.effectJSON())
        var json = helper.effectJSON()
        json["lateralDetail"] = 1
        let explicit = try decode(json)
        let a = try helper.resources(absent)
        let b = try helper.resources(explicit)
        XCTAssertNil(a.ripple?.detail)
        XCTAssertNil(b.ripple?.detail)
        let chain = WSSRippleChainTests()
        let oldChain = try chain.resources([chain.a, chain.b])
        var first = chain.a
        first.lateralDetail = 1
        let explicitChain = try chain.resources([first, chain.b])
        XCTAssertNil(explicitChain.ripple?.detail)
        for time in [0.0, 0.25, 2, 8, 1e6] {
            XCTAssertEqual(try helper.render(a, time: time), try helper.render(b, time: time))
            XCTAssertEqual(
                try chain.render(oldChain, time: time).0,
                try chain.render(explicitChain, time: time).0)
        }
    }
    func waterfall() throws -> WSSRippleEffect {
        guard case .ripple(let effect) = NativeTestData.rippleProfile[0] else {
            throw WSSSceneError.invalid("W2 waterfall profile")
        }
        return effect
    }
    func testAcceptedW2FieldExactVerticalAndComparableLateralStrength() throws {
        let detail = try waterfall()
        XCTAssertEqual(detail.lateralDetail, 3)
        var original = detail
        original.lateralDetail = 1
        var energy = SIMD2<Double>.zero
        var smooth = SIMD2<Double>.zero
        var count = 0.0
        for time in [0.0, 0.25, 1, 2, 4, 8] {
            for y in stride(from: 525.0, through: 1300, by: 31) {
                for x in stride(from: 1375.0, through: 2840, by: 37) {
                    let point = SIMD2(x, y)
                    let old = try original.displacement(at: point, time: time)
                    let new = try detail.displacement(at: point, time: time)
                    XCTAssertEqual(old.y.bitPattern, new.y.bitPattern)
                    // Accepted C's independent horizontal sum, with unchanged
                    // offset vectors/evolution and temporal frequency from k*3.
                    var accepted: Float = 0
                    for wave in original.waves {
                        let k = wave.k * 3
                        let hz =
                            -simd_dot(k, original.velocity)
                            + wave.evolution * Double(original.evolutionRate)
                        let cycles =
                            hz == 0 ? 0 : time.truncatingRemainder(dividingBy: 1 / abs(hz)) * hz
                        let phase = Float(
                            (wave.offset + cycles).truncatingRemainder(dividingBy: 1) * 2 * .pi)
                        accepted +=
                            wave.displacement.x
                            * Float(sin(simd_dot(k, point) * 2 * .pi + Double(phase)))
                            * original.amplitude
                    }
                    XCTAssertEqual(new.x.bitPattern, accepted.bitPattern)
                    energy += SIMD2(Double(old.x * old.x), Double(new.x * new.x))
                    func mean(_ effect: WSSRippleEffect) throws -> Double {
                        var sum = 0.0
                        for wave in effect.lateralWaves {
                            func sinc(_ x: Double) -> Double {
                                x == 0 ? 1 : sin(.pi * x) / (.pi * x)
                            }
                            let filter = sinc(wave.k.x * 64) * sinc(wave.k.y * 64)
                            let phase = Double(try effect.phase(wave, at: time))
                            sum +=
                                Double(wave.displacement.x)
                                * sin(simd_dot(wave.k, point) * 2 * .pi + phase)
                                * Double(effect.amplitude) * filter
                        }
                        return sum
                    }
                    let a = try mean(original)
                    let b = try mean(detail)
                    smooth += SIMD2(a * a, b * b)
                    count += 1
                }
            }
        }
        let rms = SIMD2(sqrt(energy.x / count), sqrt(energy.y / count))
        XCTAssertGreaterThan(rms.y / rms.x, 0.9)
        XCTAssertLessThan(rms.y / rms.x, 1.1)
        XCTAssertLessThan(sqrt(smooth.y / smooth.x), 0.45)
        print(
            "W2 lateralDetail 1/3 local RMS \(rms), box64 RMS \(sqrt(smooth.x/count))/\(sqrt(smooth.y/count))"
        )
    }
    func testRelativeDirectionProjectionAdvectionAndDeterminism() throws {
        for direction: Float in [0, 17, 45, 90, 130, 180, 219, 270, 359.5] {
            let original = WSSRippleEffect(
                amplitude: 12, wavelength: 80, stretch: 1.7,
                direction: direction, travelSpeed: 35, evolutionRate: 0, seed: 7319,
                structureRotation: 37)
            var detail = original
            detail.lateralDetail = 3
            let lateral = detail.lateralAxis
            let longitudinal = SIMD2(-lateral.y, lateral.x)
            XCTAssertEqual(simd_length(lateral), 1, accuracy: 0.000001)
            XCTAssertEqual(simd_dot(SIMD2<Float>(original.velocity), lateral), 0, accuracy: 0.00001)
            for point in [SIMD2<Double>(37, 91), SIMD2(1811, 1003)] {
                let old = try original.displacement(at: point, time: 0)
                let new = try detail.displacement(at: point, time: 0)
                XCTAssertEqual(
                    simd_dot(old, longitudinal), simd_dot(new, longitudinal), accuracy: 0.000003)
                XCTAssertEqual(new, try detail.displacement(at: point, time: 0))
                let moved = try detail.displacement(at: point + detail.velocity * 0.5, time: 0.5)
                XCTAssertEqual(new.x, moved.x, accuracy: 0.00002)
                XCTAssertEqual(new.y, moved.y, accuracy: 0.00002)
            }
        }
    }
    func testGPUUntouchedProjectionAndW2VerticalBits() throws {
        let device = try WSSStaticTests().device()
        let source =
            WSSStaticResources.shader + WSSRippleDetailResources.shader + """
                kernel void probe(constant RippleDetailUniforms &r [[buffer(0)]],
                    device float4 *output [[buffer(1)]], uint i [[thread_position_in_grid]]) {
                    float2 p = float2(1373+(i%64)*23,523+(i/64)*47);
                    float2 old = float2(0);
                    for (uint j=0;j<6;++j)
                        old += r.vectors[j].xy * sin(dot(p,r.waves[j].xy)+r.waves[j].z);
                    output[i]=float4(old,rippleDetailDelta(p,r));
                }
                """
        let library = try device.makeLibrary(source: source, options: nil)
        let pipeline = try device.makeComputePipelineState(
            function: XCTUnwrap(library.makeFunction(name: "probe")))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let buffer = try XCTUnwrap(
            device.makeBuffer(
                length: 1024 * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared))
        for direction: Float in [0, 45, 90, 130, 180, 270] {
            var effect = try waterfall()
            effect.direction = direction
            let axis = effect.lateralAxis
            let along = SIMD2(-axis.y, axis.x)
            for time in [0.0, 0.25, 2, 8] {
                var uniforms = try WSSRippleDetailResources.uniforms(
                    effect, size: SIMD2(3840, 2160), uv: SIMD2(1, 1), time: time)
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
                encoder.setComputePipelineState(pipeline)
                encoder.setBytes(&uniforms, length: MemoryLayout.size(ofValue: uniforms), index: 0)
                encoder.setBuffer(buffer, offset: 0, index: 1)
                encoder.dispatchThreads(
                    MTLSize(width: 1024, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                encoder.endEncoding()
                command.commit()
                command.waitUntilCompleted()
                XCTAssertEqual(command.status, .completed)
                let data = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 1024)
                for i in 0..<1024 {
                    let a = SIMD2(data[i].x, data[i].y)
                    let b = SIMD2(data[i].z, data[i].w)
                    XCTAssertEqual(simd_dot(a, along), simd_dot(b, along), accuracy: 0.000001)
                    if direction == 180 { XCTAssertEqual(a.y.bitPattern, b.y.bitPattern) }
                    let point = SIMD2<Double>(
                        Double(1373 + (i % 64) * 23), Double(523 + (i / 64) * 47))
                    let cpu = try effect.displacement(at: point, time: time)
                    XCTAssertEqual(b.x * effect.amplitude, cpu.x, accuracy: 0.003)
                    XCTAssertEqual(b.y * effect.amplitude, cpu.y, accuracy: 0.003)
                }
            }
        }
    }

}
