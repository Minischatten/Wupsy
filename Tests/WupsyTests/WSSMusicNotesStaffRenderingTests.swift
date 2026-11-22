import MetalKit
import XCTest

@testable import Wupsy

final class WSSMusicNotesStaffRenderingTests: XCTestCase {
    private func layer() -> WSSMusicNotesLayer {
        var staff = WSSMusicNotesStaff()
        staff.enabled = true
        staff.color = .init(red: 1, green: 0, blue: 0)
        staff.width = 3
        staff.spacing = 12
        staff.opacity = 0.5
        var notes = WSSMusicNotesLayer.Configuration()
        notes.direction = 0
        notes.count = 0
        return .init(region: .init(x: 16, y: 16, width: 96, height: 96), notes: notes, staff: staff)
    }

    private func model(_ layers: [WSSMusicNotesLayer], canvas: Int = 128) throws
        -> WSSSceneDocumentV1
    {
        let header = """
            {"format":"wss-scene","version":1,"title":"Staff","background":[0,0,0],
             "canvas":{"width":\(canvas),"height":\(canvas)},"layers":[]}
            """
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: Any])
        json["layers"] = try layers.map {
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(WSSSceneDocumentV1.Layer(content: .musicNotes($0))))
        }
        return try .decode(data: JSONSerialization.data(withJSONObject: json))
    }

    private func resources(_ model: WSSSceneDocumentV1) throws -> WSSStaticResources {
        try WSSStaticResources(
            scene: model.scene(), assets: WSSStaticTests.Assets(values: [:]),
            device: WSSStaticTests().device())
    }

    private func render(_ resources: WSSStaticResources, time: Double = 0, size: Int = 128) throws
        -> Data
    {
        try WSSStormLightingRenderTests().render(
            resources, time: time, width: size, height: size
        ).0
    }

    private func pixel(_ frame: Data, _ x: Int, _ y: Int, size: Int = 128) -> [UInt8] {
        let i = ((size - y - 1) * size + x) * 4
        return Array(frame[i..<(i + 4)])
    }

    private func anchor(_ x: Double, _ y: Double) -> WSSMusicNotesPath.Anchor {
        let point = SIMD2(x, y)
        return .init(position: point, incoming: point, outgoing: point)
    }

    func testInactiveStaffMatchesLegacyAnimatedNotes() throws {
        var notes = layer()
        notes.notes.count = 5
        notes.notes.hover = true
        notes.notes.rotation = true
        notes.staff?.enabled = false
        let disabled = try resources(model([notes]))
        notes.staff = nil
        let legacy = try resources(model([notes]))
        XCTAssertTrue(disabled.musicNotesStaffs.isEmpty)
        XCTAssertNil(disabled.musicNotesStaffRenderer)
        for time in [0.0, 0.31, 1.7] {
            XCTAssertEqual(try render(disabled, time: time), try render(legacy, time: time))
        }
    }

    func testLinesWithoutVisibleNotesAndFractionalPixelCoverage() throws {
        var notes = layer()
        notes.staff?.width = 1.5
        let onlyStaff = try resources(model([notes]))
        let frame = try render(onlyStaff)
        let center = pixel(frame, 64, 64)
        XCTAssertEqual(center[0], 0)
        XCTAssertEqual(center[1], 0)
        XCTAssertGreaterThan(center[2], 0)
        XCTAssertLessThan(center[2], 128)
        XCTAssertEqual(pixel(frame, 64, 67), [0, 0, 0, 255])
        XCTAssertEqual(pixel(frame, 64, 52), center)
        XCTAssertEqual(pixel(frame, 15, 64), [0, 0, 0, 255])
        XCTAssertEqual(try render(onlyStaff, size: 256).count, 256 * 256 * 4)
        XCTAssertEqual(try render(onlyStaff, time: 4), frame)
        notes.notes.count = 12
        notes.notes.opacity = 0
        notes.notes.speed = 0
        XCTAssertEqual(try render(resources(model([notes])), time: 77), frame)
        notes.visible = false
        let hidden = try resources(model([notes]))
        XCTAssertTrue(hidden.musicNotesStaffs.isEmpty)
        XCTAssertEqual(pixel(try render(hidden), 64, 64), [0, 0, 0, 255])
    }

    func testLayerOrderAndNoteTransparency() throws {
        var lower = layer()
        var upper = layer()
        upper.staff?.color = .init(red: 0, green: 0, blue: 1)
        XCTAssertEqual(
            pixel(try render(resources(model([lower, upper]))), 64, 64), [128, 0, 64, 255])
        XCTAssertEqual(
            pixel(try render(resources(model([upper, lower]))), 64, 64), [64, 0, 128, 255])

        lower.path = .init(
            enabled: true, closed: false, direction: .forward,
            anchors: [anchor(0, 0.5), anchor(1, 0.5)])
        lower.staff?.width = 8
        lower.notes.count = 1
        lower.notes.speed = 0
        lower.notes.opacity = 0.5
        lower.notes.color = .init(red: 0, green: 1, blue: 0)
        let composited = try render(resources(model([lower])))
        lower.staff?.enabled = false
        let notesOnly = try render(resources(model([lower])))
        var overlapped = 0
        for y in 61...66 {
            for x in 49...79 {
                let note = pixel(notesOnly, x, y)
                let combined = pixel(composited, x, y)
                XCTAssertEqual(combined[1], note[1])
                XCTAssertEqual(Double(combined[2]), 128 * (1 - Double(note[1]) / 255), accuracy: 1)
                if note[1] > 0 { overlapped += 1 }
            }
        }
        XCTAssertGreaterThan(overlapped, 0)
    }

    func testCrossingCoverageAndClosedSeam() throws {
        var notes = layer()
        notes.path = .init(
            enabled: true, closed: false, direction: .forward,
            anchors: [anchor(0, 0), anchor(1, 1), anchor(0, 1), anchor(1, 0)])
        let frame = try render(resources(model([notes])))
        XCTAssertEqual(pixel(frame, 63, 63)[2], 128)
        XCTAssertEqual(pixel(frame, 40, 40)[2], 128)
        XCTAssertEqual(frame.enumerated().filter { $0.offset % 4 == 2 }.map(\.element).max(), 128)
        notes.path = .init(
            enabled: true, closed: true, direction: .reverse,
            anchors: [anchor(0, 0), anchor(1, 0), anchor(1, 1), anchor(0, 1)])
        notes.notes.speed = 0
        let closed = try render(resources(model([notes])))
        for point in [(16, 16), (16, 17), (17, 16), (111, 111), (64, 16), (16, 64)] {
            XCTAssertEqual(pixel(closed, point.0, point.1)[2], 128)
        }
    }

    func testTypicalAndComplexStaffAllocateOnlyUsedVertexBytes() throws {
        var typical = layer()
        typical.region = .init(x: 0, y: 0, width: 528, height: 108)
        typical.path = .init(
            enabled: true, closed: false, direction: .forward,
            anchors: [
                .init(position: SIMD2(0, 0.22), incoming: SIMD2(0, 0.22), outgoing: SIMD2(0.35, 1)),
                .init(position: SIMD2(1, 0.78), incoming: SIMD2(0.65, 0), outgoing: SIMD2(1, 0.78)),
            ])
        var complex = layer()
        complex.region = .init(x: 0, y: 0, width: 2048, height: 2048)
        let k = 2.0 / 3.0 * (sqrt(2.0) - 1)
        let loop: [WSSMusicNotesPath.Anchor] = [
            .init(
                position: SIMD2(1, 0.5), incoming: SIMD2(1, 0.5 - k), outgoing: SIMD2(1, 0.5 + k)),
            .init(
                position: SIMD2(0.5, 1), incoming: SIMD2(0.5 + k, 1), outgoing: SIMD2(0.5 - k, 1)),
            .init(
                position: SIMD2(0, 0.5), incoming: SIMD2(0, 0.5 + k), outgoing: SIMD2(0, 0.5 - k)),
            .init(
                position: SIMD2(0.5, 0), incoming: SIMD2(0.5 - k, 0), outgoing: SIMD2(0.5 + k, 0)),
        ]
        complex.path = .init(
            enabled: true, closed: true, direction: .forward,
            anchors: Array(repeating: loop, count: 4).flatMap { $0 })
        let prepared = try resources(model([typical, complex], canvas: 2048))
        let typicalMesh = try XCTUnwrap(prepared.musicNotesStaffs[0])
        let complexMesh = try XCTUnwrap(prepared.musicNotesStaffs[1])
        XCTAssertEqual(complexMesh.buffer.length, 983_040)
        XCTAssertLessThanOrEqual(complexMesh.buffer.length, WSSMusicNotesStaff.maximumVertices * 8)
        XCTAssertEqual(typicalMesh.buffer.length, 26_880)
        XCTAssertEqual(
            typicalMesh.buffer.length, try XCTUnwrap(typical.preparedStaff()).vertices.count * 8)
        XCTAssertEqual(
            complexMesh.buffer.length, try XCTUnwrap(complex.preparedStaff()).vertices.count * 8)
        let frame = try render(prepared, size: 512)
        XCTAssertGreaterThan(pixel(frame, 256, 511, size: 512)[2], 0)
        XCTAssertLessThanOrEqual(
            frame.enumerated().filter { $0.offset % 4 == 2 }.map(\.element).max()!, 192)
    }

    func testExactUploadAndResourcesReuseAcrossPlaybackAndStyle() throws {
        var notes = layer()
        notes.path = .init(
            enabled: true, closed: false, direction: .forward,
            anchors: [anchor(0, 0.5), anchor(1, 0.5)])
        let initial = try model([notes])
        let first = try resources(initial)
        let mesh = try XCTUnwrap(first.musicNotesStaffs[0])
        let geometry = try XCTUnwrap(notes.preparedStaff())
        XCTAssertEqual(
            mesh.buffer.length, geometry.vertices.count * MemoryLayout<SIMD2<Float>>.stride)
        let frame = try render(first)
        let projection = WSSMusicNotesStaffRenderer.Projection(
            outputSize: SIMD2(128, 128), canvas: SIMD2(128, 128), crop: SIMD2(1, 1),
            origin: SIMD2(16, 64))
        let mask = try XCTUnwrap(mesh.mask(for: projection))
        XCTAssertLessThan(mask.texture.width * mask.texture.height, 128 * 128)
        XCTAssertEqual(try render(first), frame)
        XCTAssertTrue(mask.texture === mesh.mask(for: projection)?.texture)

        notes.notes.speed = 0
        notes.notes.direction = 270
        notes.notes.rotation = true
        notes.notes.hover = true
        notes.path?.direction = .reverse
        let motion = try model([notes])
        let motionResources = try XCTUnwrap(first.updatingTransforms(from: initial, to: motion))
        XCTAssertTrue(mesh === motionResources.musicNotesStaffs[0])
        XCTAssertEqual(try render(motionResources, time: 40), frame)

        notes.staff?.opacity = 0.25
        notes.region = .init(x: 24, y: 16, width: 96, height: 96)
        let style = try model([notes])
        let styleResources = try XCTUnwrap(first.updatingTransforms(from: initial, to: style))
        XCTAssertTrue(mesh === styleResources.musicNotesStaffs[0])
        XCTAssertEqual(pixel(try render(styleResources), 64, 64)[2], 64)

        notes.staff?.spacing = 16
        let shape = try XCTUnwrap(first.updatingTransforms(from: initial, to: model([notes])))
        XCTAssertFalse(mesh === shape.musicNotesStaffs[0])
        XCTAssertTrue(first.musicNotes === shape.musicNotes)
        XCTAssertTrue(first.musicNotesStaffRenderer === shape.musicNotesStaffRenderer)
    }
}
