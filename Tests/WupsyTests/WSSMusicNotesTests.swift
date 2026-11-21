import MetalKit
import XCTest

@testable import Wupsy

final class WSSMusicNotesTests: XCTestCase {
    private let region = WSSSceneDocumentV1.Region(x: 8, y: 8, width: 48, height: 48)

    private func model(_ layer: WSSMusicNotesLayer) throws -> WSSSceneDocumentV1 {
        let config = try JSONSerialization.jsonObject(with: JSONEncoder().encode(layer.notes))
        let region = try JSONSerialization.jsonObject(with: JSONEncoder().encode(layer.region))
        return try WSSSceneDocumentV1.decode(
            data: JSONSerialization.data(withJSONObject: [
                "format": "wss-scene", "version": 1, "title": "Synthetic notes",
                "canvas": ["width": 64, "height": 64],
                "layers": [
                    [
                        "type": "musicNotes", "visible": layer.visible, "region": region,
                        "musicNotes": config,
                    ]
                ],
            ]))
    }

    private func resources(
        _ model: WSSSceneDocumentV1, foreground: Bool = false, reversed: Bool = false
    ) throws -> WSSStaticResources {
        var scene = try model.scene()
        let id = WSSAssetID(value: "foreground")
        let image = WSSSceneLayer.image(
            .init(asset: id, transform: .init(center: .init(32, 32), size: .init(64, 64))))
        if foreground { scene.layers.insert(image, at: reversed ? 0 : scene.layers.count) }
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 0, 0, 0]
        return try WSSStaticResources(
            scene: scene,
            assets: WSSStaticTests.Assets(values: [
                id: WSSImageAsset(width: 2, height: 1, payload: .rgba8(Data(pixels)))
            ]), device: WSSStaticTests().device())
    }

    private func render(_ resources: WSSStaticResources, time: Double = 0) throws -> Data {
        try WSSStormLightingRenderTests().render(resources, time: time).0
    }

    func testDefaultsBoundsAndStrictRoundTrip() throws {
        var layer = WSSMusicNotesLayer(region: region)
        XCTAssertEqual(layer.notes.count, 12)
        XCTAssertEqual(layer.notes.symbols, [.quarter, .eighth, .double])
        XCTAssertTrue(layer.isAnimated)
        layer.visible = false
        layer.notes.count = 128
        layer.notes.seed = .max
        layer.notes.direction = 217.123
        layer.notes.speed = 0.0007
        layer.notes.color = .init(red: 0.12, green: 0.7, blue: 0.25)
        layer.notes.symbols = [.double, .quarter]
        layer.notes.hover = true
        layer.notes.rotation = true
        let doc = try model(layer)
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: doc.encoded()), doc)
        XCTAssertTrue(doc.referencedPaths.isEmpty)
        XCTAssertFalse(try doc.scene().isAnimated)

        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: doc.encoded()) as? [String: Any])
        let layers = try XCTUnwrap(obj["layers"] as? [[String: Any]])
        let config = try XCTUnwrap(layers[0]["musicNotes"] as? [String: Any])
        for (key, value): (String, Any) in [
            ("count", -1), ("count", 129), ("count", 1.5), ("size", 3), ("size", 193),
            ("opacity", 1.01), ("direction", 361), ("speed", -1), ("speed", 257),
            ("seed", -1), ("hover", NSNull()), ("future", 0), ("symbols", [] as [String]),
            ("symbols", ["quarter", "quarter"]), ("symbols", ["unknown"]),
            ("color", ["red": 0.1, "green": 1.2, "blue": 0.1]),
            ("color", ["red": 0.1, "green": 0.2, "blue": 0.1, "alpha": 0.2]),
        ] {
            var json = obj
            var node = layers[0]
            var invalid = config
            invalid[key] = value
            node["musicNotes"] = invalid
            json["layers"] = [node]
            XCTAssertThrowsError(
                try WSSSceneDocumentV1.decode(data: JSONSerialization.data(withJSONObject: json)),
                key)
        }

        layer.region = .init(x: 0, y: 0, width: 8192, height: 8192)
        XCTAssertThrowsError(try layer.validate())
        layer.region = region
        layer.notes.size = .nan
        XCTAssertThrowsError(try layer.validate())
    }

    func testDeterministicPopulationAndBudgetsIncludingHiddenLayers() throws {
        let a = WSSMusicNotesLayer.instances(seed: 29)
        XCTAssertEqual(a, WSSMusicNotesLayer.instances(seed: 29))
        XCTAssertNotEqual(a, WSSMusicNotesLayer.instances(seed: 30))
        XCTAssertEqual(a.count, 128)
        XCTAssertTrue(a.allSatisfy { (0..<1).contains($0.x) && (0..<1).contains($0.y) })
        var layer = WSSMusicNotesLayer(visible: false, region: region)
        layer.notes.count = 128
        func scene(_ count: Int) -> WSSScene {
            .init(width: 64, height: 64, layers: Array(repeating: .musicNotes(layer), count: count))
        }
        try scene(4).validate()
        XCTAssertThrowsError(try scene(5).validate())
        layer.notes.count = 1
        try scene(8).validate()
        XCTAssertThrowsError(try scene(9).validate())
    }

    func testGPUSeamPeriodClippingAndStaticSettings() throws {
        var layer = WSSMusicNotesLayer(region: region)
        layer.notes.count = 1
        layer.notes.direction = 0
        layer.notes.speed = 0.02
        layer.notes.size = 22
        layer.notes.symbols = [.double]
        let resources = try resources(model(layer))
        let period = Double(region.width) / Double(layer.notes.speed)
        let first = WSSMusicNotesLayer.instances(seed: layer.notes.seed)[0]
        let crossing = period * (1 - Double(first.x))
        let before = try render(resources, time: crossing - 0.1)
        let seam = try render(resources, time: crossing)
        let after = try render(resources, time: crossing + 0.1)
        XCTAssertEqual(try render(resources), try render(resources, time: period))
        XCTAssertNotEqual(try render(resources), try render(resources, time: period * 0.25))
        XCTAssertTrue(layer.phases(at: 1e100).x.isFinite)
        // The samples are 0.004 output pixels apart. Raster subpixel rounding
        // and the atlas's steepest texel edges can change a few 8-bit levels.
        let maxDifference = zip(before, after).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(maxDifference, 8)
        func energy(_ range: Range<Int>) -> Int {
            (0..<64).reduce(0) { total, y in
                total + range.reduce(0) { $0 + Int(seam[(y * 64 + $1) * 4]) }
            }
        }
        XCTAssertGreaterThan(energy(8..<20), 0)
        XCTAssertGreaterThan(energy(44..<56), 0)
        for y in 0..<64 {
            for x in 0..<64 where x < 8 || x >= 56 || y < 8 || y >= 56 {
                XCTAssertEqual(seam[(y * 64 + x) * 4], 0)
            }
        }

        layer.notes.speed = 0
        let candidate = try model(layer)
        let original = try model(
            {
                var moving = layer
                moving.notes.speed = 0.02
                return moving
            }())
        let still = try XCTUnwrap(resources.updatingTransforms(from: original, to: candidate))
        XCTAssertFalse(still.scene.isAnimated)
        XCTAssertEqual(try render(still), try render(still, time: 1e10))
        let doubleResolution = try WSSStormLightingRenderTests().render(
            still, time: 0, width: 128, height: 128
        ).0
        XCTAssertTrue(
            stride(from: 0, to: doubleResolution.count, by: 4).contains {
                doubleResolution[$0] > 0
            })
        for y in 0..<128 {
            for x in 0..<128 where x < 16 || x >= 112 || y < 16 || y >= 112 {
                XCTAssertEqual(doubleResolution[(y * 128 + x) * 4], 0)
            }
        }

        for motion: WritableKeyPath<WSSMusicNotesLayer.Configuration, Bool> in [
            \.hover, \.rotation,
        ] {
            layer.notes[keyPath: motion] = true
            XCTAssertTrue(layer.isAnimated)
            let moving = try XCTUnwrap(still.updatingTransforms(from: candidate, to: model(layer)))
            XCTAssertNotEqual(try render(moving), try render(moving, time: 1.5))
            layer.notes[keyPath: motion] = false
        }
        layer.notes.hover = true
        layer.notes.opacity = 0
        XCTAssertFalse(layer.isAnimated)
    }

    func testGPUHoverFollowsPerpendicularAxisAndKeepsAmplitude() throws {
        var layer = WSSMusicNotesLayer(region: region)
        layer.notes.count = 1
        layer.notes.size = 18
        layer.notes.symbols = [.quarter]
        // Keep the entire note away from the boundary while measuring its centroid.
        layer.notes.seed = try XCTUnwrap(
            (0..<100).map(UInt32.init).first {
                let position = WSSMusicNotesLayer.instances(seed: $0)[0]
                return (0.4...0.6).contains(position.x) && (0.4...0.6).contains(position.y)
            })
        let phase = Double(WSSMusicNotesLayer.instances(seed: layer.notes.seed)[0].w)
        let time = (1.25 - phase) / 0.23
        func centroid(_ resources: WSSStaticResources) throws -> SIMD2<Double> {
            // Oversample the atlas silhouettes so subpixel texture sampling
            // does not bias the measured displacement at diagonal angles.
            let resolution = 256
            let pixels = try WSSStormLightingRenderTests().render(
                resources, time: time, width: resolution, height: resolution
            ).0
            var weighted = SIMD2<Double>.zero
            var weight = 0.0
            for y in 0..<resolution {
                for x in 0..<resolution {
                    let light = Double(pixels[(y * resolution + x) * 4])
                    weighted += SIMD2(Double(x), Double(resolution - 1 - y)) * light
                    weight += light
                }
            }
            XCTAssertGreaterThan(weight, 0)
            return weighted / weight * (64.0 / Double(resolution))
        }
        let diagonal = sqrt(0.5)
        for (direction, speed, axis): (Float, Float, SIMD2<Double>) in [
            (0, 0.1, SIMD2(0, 1)), (90, 0.1, SIMD2(-1, 0)),
            (45, 0.1, SIMD2(-diagonal, diagonal)), (90, 0, SIMD2(0, 1)),
            (360, 0.1, SIMD2(0, 1)),
        ] {
            layer.notes.direction = direction
            layer.notes.speed = speed
            layer.notes.hover = false
            let base = try model(layer)
            let prepared = try resources(base)
            layer.notes.hover = true
            let hovering = try XCTUnwrap(prepared.updatingTransforms(from: base, to: model(layer)))
            let delta = try centroid(hovering) - centroid(prepared)
            let expected = axis * Double(layer.notes.size) * 0.12
            XCTAssertEqual(delta.x, expected.x, accuracy: 0.18)
            XCTAssertEqual(delta.y, expected.y, accuracy: 0.18)
        }
    }

    func testGPUSymbolsOrderingOpacityAndResourceReuse() throws {
        var layer = WSSMusicNotesLayer(region: region)
        layer.notes.speed = 0
        layer.notes.size = 20
        layer.notes.color = .init(red: 0, green: 1, blue: 0)
        layer.notes.opacity = 0.5
        layer.notes.symbols = [.quarter]
        let base = try model(layer)
        let prepared = try resources(base)
        let before = try render(prepared)
        XCTAssertEqual(prepared.bufferBytes, 128 * MemoryLayout<SIMD4<Float>>.stride)
        let atlasBytes = try XCTUnwrap(prepared.musicNotes?.textureBytes)
        XCTAssertGreaterThanOrEqual(atlasBytes, 192 * 64)
        XCTAssertEqual(prepared.textureBytes, atlasBytes)

        var appearances = [before]
        for symbols: [WSSMusicNoteSymbol] in [[.eighth], [.double], [.quarter, .eighth, .double]] {
            layer.notes.symbols = symbols
            let candidate = try model(layer)
            let reuse = try XCTUnwrap(prepared.updatingTransforms(from: base, to: candidate))
            XCTAssertTrue(reuse.musicNotes === prepared.musicNotes)
            let output = try render(reuse)
            XCTAssertFalse(appearances.contains(output))
            appearances.append(output)
        }
        let behind = try render(resources(base, foreground: true))
        let inFront = try render(resources(base, foreground: true, reversed: true))
        XCTAssertNotEqual(behind, inFront)
        var blended = false
        for y in 0..<64 {
            for x in 0..<64 {
                let i = (y * 64 + x) * 4
                XCTAssertEqual(inFront[i + 3], 255)
                if x < 12 {
                    XCTAssertEqual(behind[i + 1], 0)
                    if inFront[i + 1] > 0, inFront[i + 2] < behind[i + 2],
                        inFront[i + 2] > 0
                    {
                        blended = true
                    }
                }
                if x >= 55 {
                    XCTAssertEqual(behind[i + 1], before[i + 1])
                }
            }
        }
        XCTAssertTrue(blended)
    }
}
