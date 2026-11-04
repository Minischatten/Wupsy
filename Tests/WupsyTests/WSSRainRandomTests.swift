import MetalKit
import XCTest

@testable import Wupsy

final class WSSRainRandomTests: XCTestCase {
    func testPublishedRecurrenceVectorsIncludingWrapping() {
        // Computed independently with arbitrary-precision integer arithmetic,
        // explicitly reducing after addition/multiplication; see RAIN-RANDOM.md.
        let vectors: [(UInt64, [UInt64])] = [
            (
                0,
                [
                    0xE220_A839_7B1D_CDAF, 0x6E78_9E6A_A1B9_65F4,
                    0x06C4_5D18_8009_454F, 0xF88B_B8A8_724C_81EC,
                ]
            ),
            (
                1,
                [
                    0x910A_2DEC_8902_5CC1, 0xBEEB_8DA1_658E_EC67,
                    0xF893_A2EE_FB32_555E, 0x71C1_8690_EE42_C90B,
                ]
            ),
            (
                .max,
                [
                    0xE4D9_7177_1B65_2C20, 0xE99F_F867_DBF6_82C9,
                    0x382F_F84C_B272_81E9, 0x6D1D_B36C_CBA9_82D2,
                ]
            ),
        ]
        for (seed, words) in vectors {
            var random = WSSRainRandom(seed: seed)
            XCTAssertEqual(words.map { _ in random.next() }, words)
        }
    }

    func testUnitConversionIncludesZeroAndExcludesOneExactly() {
        // Inverting the documented bijection gives first words 0 and UInt64.max.
        var zero = WSSRainRandom(seed: 0x61C8_8646_80B5_83EB)
        var maximum = WSSRainRandom(seed: 0x3162_8AF6_7B21_31AB)
        var maximumWord = maximum
        XCTAssertEqual(maximumWord.next(), UInt64.max)
        XCTAssertEqual(zero.unit(), 0)
        XCTAssertEqual(maximum.unit(), 1 - 1 / Float(16_777_216))
        for seed: UInt64 in [0, 1, .max] {
            var words = WSSRainRandom(seed: seed)
            var fractions = words
            for _ in 0..<4096 {
                let expected = Float(words.next() >> 40) / 16_777_216
                let value = fractions.unit()
                XCTAssertEqual(value, expected)
                XCTAssertTrue(value.isFinite && value >= 0 && value < 1)
                XCTAssertEqual(value * 16_777_216, (value * 16_777_216).rounded())
            }
        }
    }

    func testPurposePackingAndIndependentDrawPositionsAtSeedBoundaries() {
        for seed: UInt32 in [0, 1, 0x4C45_4E47, .max] {
            var starts = Set<UInt64>()
            for stream in WSSRainRandom.Stream.allCases {
                var packed = WSSRainRandom(seed: (UInt64(seed) << 32) | UInt64(stream.rawValue))
                var selected = WSSRainRandom(seed: seed, stream: stream)
                let first = selected.next()
                XCTAssertEqual(first, packed.next())
                starts.insert(first)
            }
            XCTAssertEqual(starts.count, 3)
            var layout = WSSRainRandom(seed: seed, stream: .layout)
            var expected = layout
            var length = WSSRainRandom(seed: seed, stream: .length)
            var profile = WSSRainRandom(seed: seed, stream: .profile)
            for i in 0..<256 {
                for _ in 0..<(i % 5) { _ = length.next() }
                for _ in 0..<(i % 7) { _ = profile.next() }
                XCTAssertEqual(layout.next(), expected.next())
            }
        }
    }

    func testPopulationRangesVariationAndPrefixForAllSeedBoundaries() throws {
        for seed: UInt32 in [0, 1, .max] {
            let effect = WSSRainEffect(
                profiles: WSSRainEffect.authoredProfiles,
                density: 1000, seed: seed)
            let a = try WSSRainTests().population(effect)
            let b = try WSSRainTests().population(effect)
            XCTAssertEqual(a.instances, b.instances)
            XCTAssertEqual(Set(a.instances.map { Int($0.state.z) }), Set(0..<8))
            XCTAssertEqual(Set(a.instances.map { Int($0.variation.z) }), Set(0..<3))
            var lengths = Set<Float>()
            var widths = Set<Float>()
            var speeds = Set<Float>()
            for instance in a.instances {
                XCTAssertTrue((0..<1).contains(instance.state.x))
                XCTAssertTrue((0..<1).contains(instance.state.y))
                XCTAssertTrue((effect.opacity.min...effect.opacity.max).contains(instance.state.w))
                let group = Int(instance.state.z)
                XCTAssertTrue((0..<8).contains(group))
                let depth = WSSRainPopulation.depthScale(group)
                let profile = effect.profiles![Int(instance.variation.z)]
                XCTAssertEqual(instance.variation.x, profile.length)
                XCTAssertEqual(instance.variation.y, profile.width)
                lengths.insert(profile.length * depth)
                widths.insert(profile.width * depth)
                speeds.insert(effect.speed * depth)
            }
            XCTAssertGreaterThan(lengths.count, 8)
            XCTAssertGreaterThan(widths.count, 8)
            XCTAssertEqual(speeds.count, 8)
            var fewer = effect
            fewer.density = 100
            let prefix = try WSSRainTests().population(fewer)
            XCTAssertEqual(Array(a.instances.prefix(prefix.instances.count)), prefix.instances)
        }
    }

    func testProfileDimensionEditsKeepLayoutAndProfileChoiceStable() throws {
        let effect = WSSRainEffect(profiles: WSSRainEffect.authoredProfiles, seed: 7)
        let original = try WSSRainTests().population(effect)
        var changed = effect
        changed.profiles = [
            .init(length: 30, width: 2), .init(length: 50, width: 3),
            .init(length: 70, width: 4),
        ]
        let edited = try WSSRainTests().population(changed)
        for (a, b) in zip(original.instances, edited.instances) {
            XCTAssertEqual(a.state, b.state)
            XCTAssertEqual(a.variation.z, b.variation.z)
            XCTAssertEqual(b.variation.x, changed.profiles![Int(b.variation.z)].length)
            XCTAssertEqual(b.variation.y, changed.profiles![Int(b.variation.z)].width)
        }
    }

    func testCodecRoundtripRebuildsSamePopulationAndRenderedFrames() throws {
        let root = WSSRainTests().fixture
        let original = try WSSSceneDocumentV1.load(
            entry: root.appendingPathComponent("scene.wss.json"), root: root)
        let rebuilt = try WSSSceneDocumentV1.decode(data: original.encoded())
        XCTAssertEqual(original, rebuilt)
        let device = try WSSStaticTests().device()
        let a = try WSSStaticResources(
            scene: original.scene(), assets: original.assetSource(root: root), device: device)
        let b = try WSSStaticResources(
            scene: rebuilt.scene(), assets: rebuilt.assetSource(root: root), device: device)
        for time in [0.0, 0.7, 60.0] {
            XCTAssertEqual(
                try WSSCloudsTests().render(a, time: time, width: 192, height: 108).0,
                try WSSCloudsTests().render(b, time: time, width: 192, height: 108).0)
        }
    }
}
