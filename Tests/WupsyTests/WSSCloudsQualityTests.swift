import ImageIO
import MetalKit
import UniformTypeIdentifiers
import XCTest

@testable import Wupsy

final class WSSCloudsQualityTests: XCTestCase {
    func testFixtureQualityDiagnosticsAndPerformance() async throws {
        let fixture = WSSCloudsFixtureTests().fixture
        let r = try await WSSCloudsFixtureTests().resources(fixture)
        var plain = r.scene
        plain.testImages[0].effects = []
        let base = try WSSStaticResources(
            scene: plain, assets: WSSNativeAssets(root: fixture), device: r.device)
        let helper = WSSCloudsTests()
        for width in [1920, 3840] {
            let height = width * 9 / 16
            let factor = width / 1920
            let background = try helper.render(base, width: width, height: height).0
            var reference: Data?
            for time in [0.0, 4, 60, 3600] {
                let pixels = try helper.render(r, time: time, width: width, height: height).0
                if time == 0 {
                    reference = pixels
                } else if time == 4 {
                    XCTAssertNotEqual(reference, pixels)
                }
                for y in stride(from: 840 * factor, to: height, by: 8 * factor) {
                    for x in stride(from: 0, to: width, by: 8 * factor) {
                        let p = (y * width + x) * 4
                        XCTAssertEqual(pixels[p..<p + 4], background[p..<p + 4])
                    }
                }
                var sum = 0.0
                var square = 0.0
                var gradient = 0.0
                var clear = 0.0
                var count = 0.0
                func coverage(_ x: Int, _ y: Int) -> Double {
                    let p = (y * width + x) * 4
                    return Double(Int(pixels[p]) - Int(background[p]))
                        / Double(255 - Int(background[p]))
                }
                // Fully masked crop. Indicators describe the field, not cloud likeness.
                for y in stride(from: 60 * factor, to: 360 * factor, by: factor) {
                    for x in stride(from: 120 * factor, to: 1320 * factor, by: factor) {
                        let p = (y * width + x) * 4
                        XCTAssertEqual(pixels[p + 3], 255)
                        let value = coverage(x, y)
                        XCTAssertTrue(value.isFinite)
                        XCTAssertGreaterThanOrEqual(value, -0.01)
                        XCTAssertLessThanOrEqual(value, 0.46)
                        sum += value
                        square += value * value
                        gradient += abs(value - coverage(x + factor, y))
                        if value < 0.02 { clear += 1 }
                        count += 1
                    }
                }
                let deviation = sqrt(max(0, square / count - pow(sum / count, 2)))
                print(
                    "Cloud field \(width)x\(height) t=\(time): mean \(sum/count), deviation \(deviation), logical gradient \(gradient/count), clear fraction \(clear/count)"
                )
                if time <= 4,
                    let directory = ProcessInfo.processInfo.environment["AMBIENT_WSS_QUALITY_QA"]
                {
                    let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
                    let image = try XCTUnwrap(
                        CGImage(
                            width: width, height: height, bitsPerComponent: 8,
                            bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(
                                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                            ).union(.byteOrder32Little),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent))
                    func save(_ image: CGImage, _ suffix: String) throws {
                        let url = URL(fileURLWithPath: directory).appendingPathComponent(
                            "clouds-\(width)-t\(Int(time))\(suffix).png")
                        let output = try XCTUnwrap(
                            CGImageDestinationCreateWithURL(
                                url as CFURL, UTType.png.identifier as CFString, 1, nil))
                        CGImageDestinationAddImage(output, image, nil)
                        XCTAssertTrue(CGImageDestinationFinalize(output))
                    }
                    try save(image, "")
                    let crop = try XCTUnwrap(
                        image.cropping(
                            to: CGRect(
                                x: 120 * factor, y: 60 * factor, width: 1200 * factor,
                                height: 300 * factor)))
                    try save(crop, "-crop")
                }
            }
            var times: [Double] = []
            for i in 0..<25 {
                let ms = try helper.render(r, time: 4, width: width, height: height).1
                if i >= 5 { times.append(ms) }
            }
            print(
                "Fixture GPU \(r.device.name) \(width)x\(height): mean \(times.reduce(0,+)/Double(times.count)) ms, samples=\(times.count), texture bytes=\(r.textureBytes), one draw, zero intermediates"
            )
        }
    }
    func testIndependentDomainWrapsAndDensityEndpoints() throws {
        let helper = WSSCloudsTests()
        let effect = WSSCloudsEffect(
            velocity: SIMD2(24, -3), scale: 600, intensity: 0.8, density: 0.5, seed: 7)
        let r = try helper.resources(effect)
        let orientation = WSSCloudsNoise.orientation
        let rotated = SIMD2(
            orientation.x * effect.velocity.x - orientation.y * effect.velocity.y,
            orientation.y * effect.velocity.x + orientation.x * effect.velocity.y)
        for frequency in [Float(1), WSSCloudsNoise.middleFrequency, WSSCloudsNoise.detailFrequency]
        {
            for speed in [rotated.x, rotated.y] {
                let wrap = Double(effect.scale) / (abs(Double(speed)) * Double(frequency))
                let before = try helper.render(r, time: wrap - 0.0001).0
                let after = try helper.render(r, time: wrap + 0.0001).0
                let mean =
                    zip(before, after).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) }
                    / Double(before.count)
                XCTAssertLessThan(mean, 0.1, "domain wrap must not jump")
            }
            for time in [0.0, 4, 60, 3600, 1e12, Double.greatestFiniteMagnitude] {
                let phase = try effect.phase(
                    at: time, frequency: frequency, orientation: orientation)
                XCTAssertTrue(phase.x.isFinite && phase.y.isFinite)
                XCTAssertLessThanOrEqual(abs(phase.x), 1)
                XCTAssertLessThanOrEqual(abs(phase.y), 1)
            }
        }
        for time in [3600.0, 1e12] {
            let a = try helper.render(r, time: time - 0.0001).0
            let b = try helper.render(r, time: time + 0.0001).0
            let mean =
                zip(a, b).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(a.count)
            XCTAssertLessThan(mean, 0.1)
        }
        XCTAssertEqual(try helper.render(r, time: 1e12).0, try helper.render(r, time: 1e12).0)
        var previous: Data?
        for density: Float in [0, 0.25, 0.5, 0.75, 1] {
            var value = effect
            value.density = density
            let pixels = try helper.render(helper.resources(value)).0
            if let previous {
                for i in 0..<pixels.count { XCTAssertGreaterThanOrEqual(pixels[i], previous[i]) }
            }
            if density == 0 { XCTAssertEqual(pixels, try helper.render(helper.resources(nil)).0) }
            if density == 1 {
                for channel in 0..<3 {
                    XCTAssertLessThanOrEqual(
                        abs(Int(pixels[channel]) - [228, 220, 212][channel]), 1)
                }
            }
            previous = pixels
        }
    }

}
