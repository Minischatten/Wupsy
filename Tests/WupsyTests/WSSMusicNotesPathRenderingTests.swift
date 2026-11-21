import MetalKit
import XCTest
import simd

@testable import Wupsy

final class WSSMusicNotesPathRenderingTests: XCTestCase {
    private typealias Path = WSSMusicNotesPath
    private typealias Timing = WSSMusicNotesRenderer.PreparedPath

    private func anchor(_ x: Double, _ y: Double) -> Path.Anchor {
        let p = SIMD2(x, y)
        return .init(position: p, incoming: p, outgoing: p)
    }

    private func layer() -> WSSMusicNotesLayer {
        var notes = WSSMusicNotesLayer.Configuration()
        notes.count = 1
        notes.size = 18
        notes.speed = 32
        notes.opacity = 1
        notes.symbols = [.quarter]
        return .init(
            region: .init(x: 32, y: 48, width: 64, height: 32), notes: notes,
            path: .init(
                enabled: true, closed: false, direction: .forward,
                anchors: [anchor(0, 0.5), anchor(1, 0.5)]))
    }

    private func model(_ layer: WSSMusicNotesLayer) throws -> WSSSceneDocumentV1 {
        let data = Data(
            """
            {"format":"wss-scene","version":1,"title":"Paths",
             "canvas":{"width":128,"height":128},"layers":[]}
            """.utf8)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let node = WSSSceneDocumentV1.Layer(content: .musicNotes(layer))
        json["layers"] = [try JSONSerialization.jsonObject(with: JSONEncoder().encode(node))]
        return try WSSSceneDocumentV1.decode(data: JSONSerialization.data(withJSONObject: json))
    }

    private func resources(_ model: WSSSceneDocumentV1) throws -> WSSStaticResources {
        try WSSStaticResources(
            scene: model.scene(), assets: WSSStaticTests.Assets(values: [:]),
            device: WSSStaticTests().device())
    }

    private func render(_ resources: WSSStaticResources, _ time: Double, size: Int = 256) throws
        -> Data
    {
        try WSSStormLightingRenderTests().render(resources, time: time, width: size, height: size).0
    }

    private func measure(_ frame: Data, size: Int = 256) -> (energy: Double, center: SIMD2<Double>)
    {
        var center = SIMD2<Double>.zero
        var energy = 0.0
        frame.withUnsafeBytes { bytes in
            let pixels = bytes.bindMemory(to: UInt8.self)
            for y in 0..<size {
                for x in 0..<size {
                    let light = Double(pixels[(y * size + x) * 4])
                    energy += light
                    center += SIMD2(Double(x) + 0.5, Double(size - y) - 0.5) * light
                }
            }
        }
        return (energy, energy > 0 ? center * (128.0 / Double(size) / energy) : .zero)
    }

    func testBoundedTimingAndUnclampedShortFastPath() {
        let normal = Timing.timing(length: 64, speed: 32, time: 0.125, closed: false)
        XCTAssertEqual(normal, SIMD2(0.0625, 0.125))
        XCTAssertEqual(
            normal, Timing.timing(length: 64, speed: 32, time: 1e12 + 0.125, closed: false))
        XCTAssertEqual(Timing.timing(length: 64, speed: 0, time: 1e100, closed: false), .zero)
        XCTAssertEqual(Timing.timing(length: 64, speed: 32, time: .infinity, closed: true), .zero)
        let short = Timing.timing(length: 0.01, speed: 256, time: 0.01 / 1024, closed: false)
        XCTAssertEqual(short.x, 0.25, accuracy: 1e-6)
        XCTAssertEqual(short.y, 0.2, accuracy: 1e-6)
    }

    func testGPUOpenFadeUniformMotionReverseAndStatic() throws {
        var layer = layer()
        let forwardModel = try model(layer)
        let forward = try resources(forwardModel)
        let middle = measure(try render(forward, 0))
        XCTAssertGreaterThan(middle.energy, 0)
        XCTAssertEqual(try render(forward, 0), try render(forward, 2))
        XCTAssertEqual(try render(forward, 0), try render(forward, 1e12))
        XCTAssertEqual(measure(try render(forward, 1)).energy, 0)
        for t in [0.875, 1.125] {
            let ratio = measure(try render(forward, t)).energy / middle.energy
            XCTAssertEqual(ratio, 0.5, accuracy: 0.03)
        }

        let early = measure(try render(forward, 0.25)).center
        let later = measure(try render(forward, 0.5)).center
        XCTAssertEqual(early.x - middle.center.x, 8, accuracy: 0.1)
        XCTAssertEqual(later.x - early.x, 8, accuracy: 0.1)
        XCTAssertEqual(later.y, early.y, accuracy: 0.1)
        let smaller = measure(try render(forward, 0.5, size: 128), size: 128).center
        XCTAssertLessThan(simd_distance(smaller, later), 0.75)

        layer.path?.direction = .reverse
        let reverseModel = try model(layer)
        let reverse = try XCTUnwrap(
            forward.updatingTransforms(from: forwardModel, to: reverseModel))
        XCTAssertEqual(
            measure(try render(reverse, 0.25)).center.x - middle.center.x, -8, accuracy: 0.1)
        XCTAssertEqual(measure(try render(reverse, 1)).energy, 0)

        layer.notes.speed = 0
        let still = try XCTUnwrap(reverse.updatingTransforms(from: reverseModel, to: model(layer)))
        XCTAssertFalse(still.scene.isAnimated)
        XCTAssertEqual(try render(still, 0), try render(still, 1e100))
        XCTAssertEqual(try render(still, 0), try render(forward, 0))
    }

    func testGPUStationaryNotesAreEvenlySpaced() throws {
        var layer = layer()
        layer.notes.count = 4
        layer.notes.size = 10
        layer.notes.speed = 0
        let prepared = try resources(model(layer))
        let frame = try render(prepared, 100)
        var centers: [Double] = []
        for slot in 0..<4 {
            var weighted = 0.0
            var weight = 0.0
            for y in 0..<256 {
                for x in (64 + slot * 32)..<(96 + slot * 32) {
                    let light = Double(frame[(y * 256 + x) * 4])
                    weighted += light * (Double(x) + 0.5) / 2
                    weight += light
                }
            }
            XCTAssertGreaterThan(weight, 0)
            centers.append(weighted / weight)
        }
        for (a, b) in zip(centers, centers.dropFirst()) {
            XCTAssertEqual(b - a, 16, accuracy: 0.1)
        }
    }

    func testCPUPreparedStorageIgnoresPlacementDirectionAndActivation() throws {
        let layer = layer()
        var path = try XCTUnwrap(layer.path)
        let baseline = try path.prepare(in: layer.region)
        path.direction = .reverse
        path.enabled = false
        let translated = WSSSceneDocumentV1.Region(x: 50, y: 40, width: 64, height: 32)
        let reused = try path.prepare(in: translated)
        baseline.samples.withUnsafeBufferPointer { a in
            reused.samples.withUnsafeBufferPointer { b in
                XCTAssertEqual(a.baseAddress, b.baseAddress)
            }
        }
        path.anchors[1] = anchor(0.75, 0.5)
        let edited = try path.prepare(in: translated)
        XCTAssertEqual(edited.length, 48, accuracy: 1e-8)
        XCTAssertEqual(baseline.length, 64, accuracy: 1e-8)
    }

    func testGPUClosedSeamAndReversal() throws {
        var layer = layer()
        let k = 0.2761423749
        layer.path?.closed = true
        layer.path?.anchors = [
            .init(
                position: SIMD2(1, 0.5), incoming: SIMD2(1, 0.5 - k), outgoing: SIMD2(1, 0.5 + k)),
            .init(
                position: SIMD2(0.5, 1), incoming: SIMD2(0.5 + k, 1), outgoing: SIMD2(0.5 - k, 1)),
            .init(
                position: SIMD2(0, 0.5), incoming: SIMD2(0, 0.5 + k), outgoing: SIMD2(0, 0.5 - k)),
            .init(
                position: SIMD2(0.5, 0), incoming: SIMD2(0.5 - k, 0), outgoing: SIMD2(0.5 + k, 0)),
        ]
        layer.notes.hover = true
        for direction: Path.Direction in [.forward, .reverse] {
            layer.path?.direction = direction
            let prepared = try resources(model(layer))
            let half =
                try XCTUnwrap(prepared.musicNotesPaths[0]).length / Double(layer.notes.speed) / 2
            let seam = measure(try render(prepared, half))
            let before = measure(try render(prepared, half - 0.002))
            let after = measure(try render(prepared, half + 0.002))
            XCTAssertGreaterThan(seam.energy, 0)
            XCTAssertLessThan(simd_distance(before.center, after.center), 0.4)
            XCTAssertGreaterThan(
                (after.center.y - before.center.y) * (direction == .forward ? 1 : -1), 0)
        }
    }

    func testGPUHoverUsesScaledNormalAndSurvivesOppositeTangents() throws {
        var layer = layer()
        layer.notes.speed = 0
        layer.path?.anchors = [anchor(0, 0), anchor(1, 1)]
        let base = try model(layer)
        let still = try resources(base)
        let instancePhase = Double(WSSMusicNotesLayer.instances(seed: layer.notes.seed)[0].w)
        let time = (1.25 - instancePhase) / 0.23
        let reference = measure(try render(still, time, size: 512), size: 512).center
        layer.notes.hover = true
        let drawnSize = min(layer.notes.size, min(layer.region.width, layer.region.height) * 0.48)
        let expected = simd_normalize(SIMD2<Double>(-32, 64)) * Double(drawnSize) * 0.12
        for direction: Path.Direction in [.forward, .reverse] {
            layer.path?.direction = direction
            let hovering = try XCTUnwrap(still.updatingTransforms(from: base, to: model(layer)))
            let delta = measure(try render(hovering, time, size: 512), size: 512).center - reference
            XCTAssertLessThan(simd_distance(delta, expected), 0.23)
            XCTAssertEqual(try render(hovering, time), try render(hovering, time))
        }

        layer.notes.speed = 32
        layer.path?.anchors = [anchor(0, 0.5), anchor(1, 0.5), anchor(0, 0.5)]
        let reversal = try resources(model(layer))
        let period = try XCTUnwrap(reversal.musicNotesPaths[0]).length / 32
        let step = period / 512
        for offset in [-step, -step / 2, 0, step / 2, step] {
            let result = measure(try render(reversal, period + offset))
            XCTAssertGreaterThan(result.energy, 0)
            XCTAssertTrue(result.center.x.isFinite && result.center.y.isFinite)
        }
    }

    func testPathBuffersReuseAndDisabledManifestsRenderBitExactly() throws {
        var layer = layer()
        let original = try model(layer)
        let prepared = try resources(original)
        let pathBuffer = try XCTUnwrap(prepared.musicNotesPaths[0]?.buffer)
        let payload = 257 * MemoryLayout<Path.Table.Sample>.stride
        XCTAssertEqual(pathBuffer.length, payload)
        XCTAssertEqual(prepared.bufferBytes, 2048 + payload)
        let frame = try render(prepared, 0.25)

        layer.path?.direction = .reverse
        layer.notes.speed = 12
        layer.region = .init(x: 28, y: 44, width: 64, height: 32)
        let edited = try model(layer)
        let reuse = try XCTUnwrap(prepared.updatingTransforms(from: original, to: edited))
        XCTAssertTrue(reuse.musicNotes === prepared.musicNotes)
        XCTAssertTrue(reuse.musicNotesPaths[0]?.buffer === pathBuffer)
        XCTAssertTrue(reuse.sharesPreparedResources(with: prepared))

        layer.region = .init(x: 28, y: 44, width: 56, height: 40)
        let resizedModel = try model(layer)
        let resized = try XCTUnwrap(reuse.updatingTransforms(from: edited, to: resizedModel))
        XCTAssertTrue(resized.musicNotes === prepared.musicNotes)
        XCTAssertFalse(resized.musicNotesPaths[0]?.buffer === pathBuffer)
        XCTAssertEqual(try render(prepared, 0.25), frame)

        layer.path?.enabled = false
        let disabled = try XCTUnwrap(
            resized.updatingTransforms(from: resizedModel, to: model(layer)))
        XCTAssertTrue(disabled.musicNotesPaths[0]?.buffer === resized.musicNotesPaths[0]?.buffer)
        let coldDisabled = try resources(model(layer))
        XCTAssertTrue(coldDisabled.musicNotesPaths.isEmpty)
        layer.path = nil
        let legacy = try resources(model(layer))
        for t in [0.0, 0.25, 1e12] {
            XCTAssertEqual(try render(legacy, t), try render(disabled, t))
            XCTAssertEqual(try render(legacy, t), try render(coldDisabled, t))
        }
    }

    func testAssetFreeAcceptanceFixtureRendersBothLayers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Test-Wallpaper/WSS-Music-Notes-Paths")
        let model = try WSSSceneDocumentV1.load(
            entry: root.appendingPathComponent("scene.wss.json"), root: root)
        XCTAssertTrue(model.referencedPaths.isEmpty)
        let prepared = try resources(model)
        XCTAssertEqual(prepared.musicNotesPaths.count, 2)
        let helper = WSSStormLightingRenderTests()
        let first = try helper.render(prepared, time: 0, width: 640, height: 360).0
        let later = try helper.render(prepared, time: 0.55, width: 640, height: 360).0
        XCTAssertNotEqual(first, later)
        for frame in [first, later] {
            XCTAssertTrue(
                stride(from: 0, to: frame.count, by: 4).contains {
                    frame[$0] > 170 && frame[$0 + 2] < 130
                })
            XCTAssertTrue(
                stride(from: 0, to: frame.count, by: 4).contains {
                    frame[$0 + 2] > 170 && frame[$0] < 130
                })
        }
    }
}
