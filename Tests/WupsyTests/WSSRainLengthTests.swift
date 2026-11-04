import Foundation
import MetalKit
import XCTest

@testable import Wupsy

final class WSSRainLengthTests: XCTestCase {
    func population(seed: UInt32 = 7, length: Float = 64) throws -> WSSRainPopulation {
        try WSSRainPopulation(
            .init(
                region: .init(x: 0, y: 0, width: 3840, height: 1920),
                rain: .init(
                    speed: 1800, density: Float(200.0 / 7.3728), length: length,
                    width: 2.4, opacity: .init(min: 0.05, max: 0.3), seed: seed)))
    }
    func testIndependentDeterministicClassesAndLayout() throws {
        let a = try population()
        let b = try population()
        let c = try population(seed: 8)
        XCTAssertEqual(a.instances, b.instances)
        XCTAssertNotEqual(a.instances.map(\.lengthScale), c.instances.map(\.lengthScale))
        XCTAssertEqual(Set(a.instances.map(\.lengthScale)), Set([Float(0.5), 1, 1.5]))
        XCTAssertEqual(MemoryLayout<WSSRainInstance>.stride, 32)
        XCTAssertEqual(MemoryLayout<WSSRainInstance>.alignment, 16)
        XCTAssertEqual(MemoryLayout<WSSRainInstance>.offset(of: \.variation), 16)
        for p in a.instances {
            XCTAssertEqual(p.variation.y, 0)
            XCTAssertEqual(p.variation.z, 0)
            XCTAssertEqual(p.variation.w, 0)
        }
        XCTAssertEqual(a.nominalCount, 200)
        XCTAssertEqual(a.instances.count, 219)
        XCTAssertEqual(a.crossSpan, 3928.4, accuracy: 0.001)
        XCTAssertGreaterThan(a.travelSpan - a.layer.region.height, 64 * 1.5 * 1.35)
    }
    func testReferenceLengthDepthAndUnchangedWidthSpeed() throws {
        let a = try population()
        let doubled = try population(length: 128)
        for i in 0..<min(a.instances.count, doubled.instances.count) {
            let p = a.instances[i]
            XCTAssertEqual(p, doubled.instances[i])
            let depth = WSSRainPopulation.depthScale(Int(p.state.z))
            let length = a.geometricLength(i)
            XCTAssertTrue(length.isFinite && (22.19...125.5).contains(length))
            XCTAssertEqual(doubled.geometricLength(i), length * 2)
            XCTAssertEqual(a.layer.rain.width * depth, doubled.layer.rain.width * depth)
            XCTAssertEqual(a.layer.rain.speed * depth, doubled.layer.rain.speed * depth)
            // At fixed depth, the new independent class changes only length.
            for other in a.instances where other.state.z == p.state.z {
                XCTAssertEqual(
                    a.layer.rain.width * depth,
                    a.layer.rain.width * WSSRainPopulation.depthScale(Int(other.state.z)))
            }
        }
        XCTAssertGreaterThan(Set(a.instances.indices.map { a.geometricLength($0) }).count, 8)
        for group in 0..<8 {
            let factors = Set(a.instances.filter { Int($0.state.z) == group }.map(\.lengthScale))
            XCTAssertEqual(factors, Set([Float(0.5), 1, 1.5]))
        }
    }
    func testShapeChangesKeepLayoutPrefixAndLengthStreamStable() throws {
        let original = try population()
        let longer = try population(length: 128)
        var authored = original.layer
        authored.rain.profiles = WSSRainEffect.authoredProfiles
        let profiled = try WSSRainPopulation(authored)
        for (a, b) in zip(original.instances, longer.instances) {
            XCTAssertEqual(a.state, b.state)
            XCTAssertEqual(a.variation, b.variation)
        }
        for (a, b) in zip(original.instances, profiled.instances) {
            XCTAssertEqual(a.state, b.state)
        }
        // Compare at common count: domain padding may change population size,
        // but choosing profiles or longer shapes must not consume layout draws.
        XCTAssertFalse(original.instances.isEmpty)
        XCTAssertFalse(profiled.instances.isEmpty)
    }
    func testCalibrationStatisticsAndFixtureImpact() throws {
        func summary(_ p: WSSRainPopulation, name: String, previousCount: Int) -> [String: Any] {
            func statistics(_ values: [Float]) -> [String: Float] {
                let sorted = values.sorted()
                let n = values.count
                return [
                    "min": sorted.first!, "max": sorted.last!,
                    "median": (sorted[(n - 1) / 2] + sorted[n / 2]) / 2,
                    "mean": values.reduce(0, +) / Float(n),
                ]
            }
            let classes = WSSRainPopulation.lengthScales.map { factor in
                [
                    "factor": factor,
                    "count": Float(p.instances.filter { $0.lengthScale == factor }.count),
                ]
            }
            let current = statistics(p.instances.indices.map { p.geometricLength($0) })
            // Compare current seeded depths with and without length classes. This is
            // not a reconstruction of historical PCG pixels or WE behavior.
            let previous = statistics(
                p.instances.prefix(previousCount).map {
                    p.layer.rain.length * WSSRainPopulation.depthScale(Int($0.state.z))
                })
            print(
                "\(name) LENGTH: before \(previous), after \(current), classes \(classes), nominal \(p.nominalCount), instances \(p.instances.count), buffer \(p.instances.count * MemoryLayout<WSSRainInstance>.stride)"
            )
            return [
                "name": name, "before": previous, "after": current, "classes": classes,
                "nominalCount": p.nominalCount, "instanceCount": p.instances.count,
                "bufferBytes": p.instances.count * MemoryLayout<WSSRainInstance>.stride,
            ]
        }
        let fixture = try WSSRainPopulation(
            .init(region: .init(x: 0, y: 0, width: 1920, height: 1080)))
        let summaries = [
            summary(try population(), name: "W7", previousCount: 215),
            summary(fixture, name: "Native fixture", previousCount: 221),
        ]
        if let directory = ProcessInfo.processInfo.environment["AMBIENT_RAIN_LENGTH_QA"] {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(
                withJSONObject: summaries, options: [.prettyPrinted, .sortedKeys]
            ).write(to: folder.appendingPathComponent("length-statistics.json"))
        }
    }
    func testGPUClassChangesLengthButNotWidth() throws {
        let layer = WSSRainLayer(
            region: .init(x: 0, y: 0, width: 512, height: 512),
            rain: .init(
                speed: 0, density: 4, length: 64, width: 8,
                opacity: .init(min: 1, max: 1)))
        let scene = WSSScene(width: 512, height: 512, layers: [.rain(layer)])
        let r = try WSSStaticResources(
            scene: scene, assets: WSSStaticTests.Assets(values: [:]),
            device: WSSStaticTests().device())
        let prepared = try XCTUnwrap(r.rain?.layers[0])
        let buffer = try XCTUnwrap(prepared.buffer)
        var extents: [(Int, Int)] = []
        for factor in WSSRainPopulation.lengthScales {
            // Test-only controlled GPU input: isolate one stationary drop at fixed
            // depth/width/opacity. Production buffers remain immutable after setup.
            let instances = prepared.population.instances.indices.map { index in
                WSSRainInstance(
                    state: SIMD4(0.5, 0.5, 3, index == 0 ? 1 : 0),
                    variation: SIMD4(factor, 0, 0, 0))
            }
            _ = instances.withUnsafeBytes { memcpy(buffer.contents(), $0.baseAddress!, $0.count) }
            let pixels = try WSSCloudsTests().render(r, width: 512, height: 512, clearAlpha: 0).0
            var xs = Set<Int>()
            var ys = Set<Int>()
            for y in 0..<512 {
                for x in 0..<512 {
                    if pixels[(y * 512 + x) * 4 + 3] > 1 {
                        xs.insert(x)
                        ys.insert(y)
                    }
                }
            }
            XCTAssertFalse(xs.isEmpty || ys.isEmpty)
            extents.append((xs.count, ys.count))
        }
        XCTAssertEqual(Set(extents.map { $0.0 }).count, 1)
        XCTAssertLessThan(extents[0].1, extents[1].1)
        XCTAssertLessThan(extents[1].1, extents[2].1)
        XCTAssertEqual(Float(extents[2].1) / Float(extents[0].1), 3, accuracy: 0.2)
        print("Native length GPU extents (width,height): \(extents)")
    }

}
