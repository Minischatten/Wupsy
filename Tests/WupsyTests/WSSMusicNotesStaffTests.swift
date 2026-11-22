import Foundation
import XCTest
import simd

@testable import Wupsy

final class WSSMusicNotesStaffTests: XCTestCase {
    private typealias Point = SIMD2<Double>
    private typealias Path = WSSMusicNotesPath
    private typealias Geometry = WSSMusicNotesStaff.Geometry

    private let legacy = """
        {"format":"wss-scene","version":1,"title":"Notes","canvas":{"width":128,"height":96},
         "layers":[{"type":"musicNotes","visible":false,"region":{"x":0,"y":0,"width":100,"height":80},
         "musicNotes":{"count":12,"size":48,"color":{"red":1,"green":1,"blue":1},"opacity":0.85,
         "direction":90,"speed":24,"hover":false,"rotation":false,"seed":1,"symbols":["quarter"]}}]}
        """

    private let parameters = """
        {"enabled":false,"spacing":12,"width":1.5,"color":{"red":1,"green":1,"blue":1},"opacity":0.45}
        """

    private func decode(staff: String? = nil) throws -> WSSSceneDocumentV1 {
        let json =
            staff.map {
                legacy.replacingOccurrences(
                    of: "\"type\":\"musicNotes\"", with: "\"type\":\"musicNotes\",\"staff\":\($0)")
            } ?? legacy
        return try .decode(data: Data(json.utf8))
    }

    private func layer(in document: WSSSceneDocumentV1) throws -> WSSMusicNotesLayer {
        guard case .musicNotes(let notes) = document.layers[0].content else {
            throw WSSSceneError.invalid("expected musicNotes")
        }
        return notes
    }

    private func anchor(_ x: Double, _ y: Double) -> Path.Anchor {
        let point = Point(x, y)
        return .init(position: point, incoming: point, outgoing: point)
    }

    private func path(_ anchors: [Path.Anchor], closed: Bool = false) -> Path {
        .init(enabled: true, closed: closed, direction: .forward, anchors: anchors)
    }

    private func enabledLayer() throws -> WSSMusicNotesLayer {
        var notes = try layer(in: decode(staff: parameters))
        notes.visible = true
        notes.staff?.enabled = true
        return notes
    }

    private func verifyFinite(
        _ geometry: Geometry, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(geometry.lineRanges.count, 5, file: file, line: line)
        XCTAssertLessThanOrEqual(
            geometry.vertices.count, WSSMusicNotesStaff.maximumVertices, file: file, line: line)
        XCTAssertTrue(
            geometry.vertices.allSatisfy { $0.x.isFinite && $0.y.isFinite }, file: file, line: line)
        var end = 0
        for range in geometry.lineRanges {
            XCTAssertEqual(range.lowerBound, end, file: file, line: line)
            XCTAssertGreaterThan(range.count, 0, file: file, line: line)
            XCTAssertEqual(range.count % 3, 0, file: file, line: line)
            end = range.upperBound
        }
        XCTAssertEqual(end, geometry.vertices.count, file: file, line: line)
    }

    func testLegacyAndDisabledSettingsRoundTrip() throws {
        let old = try decode()
        let oldLayer = try layer(in: old)
        let encodedOld = try old.encoded()
        XCTAssertFalse(String(decoding: encodedOld, as: UTF8.self).contains("\"staff\""))
        XCTAssertNil(oldLayer.staff)
        XCTAssertNil(try oldLayer.preparedStaff())

        var doc = try decode(staff: parameters)
        var notes = try layer(in: doc)
        XCTAssertEqual(notes.staff, WSSMusicNotesStaff())
        XCTAssertNil(try notes.preparedStaff())
        notes.staff?.spacing = 17
        notes.staff?.opacity = 0.3
        doc.layers[0].content = .musicNotes(notes)
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: doc.encoded()), doc)
        XCTAssertEqual(notes.notes, oldLayer.notes)
        XCTAssertEqual(notes.phases(at: 96), oldLayer.phases(at: 96))
        XCTAssertEqual(notes.isAnimated, oldLayer.isAnimated)
    }

    func testStrictDecoderRejectsInvalidHiddenDisabledStaff() throws {
        for invalid in ["null", "true", "[]", "{}"] {
            XCTAssertThrowsError(try decode(staff: invalid))
        }
        for (original, replacements) in [
            (
                "\"enabled\":false",
                ["\"enabled\":0", "\"enabled\":null", "\"enabled\":false,\"unknown\":1"]
            ),
            (
                "\"spacing\":12",
                ["\"spacing\":0", "\"spacing\":257", "\"spacing\":1e999", "\"spacing\":\"12\""]
            ),
            (
                "\"width\":1.5",
                ["\"width\":0", "\"width\":0.125", "\"width\":12", "\"width\":null"]
            ),
            ("\"red\":1", ["\"red\":2", "\"red\":null", "\"red\":1,\"alpha\":1"]),
            ("\"opacity\":0.45", ["\"opacity\":-1", "\"opacity\":1.001", "\"opacity\":null"]),
        ] {
            for invalid in replacements {
                XCTAssertThrowsError(
                    try decode(staff: parameters.replacingOccurrences(of: original, with: invalid)))
            }
        }
        var staff = WSSMusicNotesStaff()
        staff.spacing = .nan
        XCTAssertThrowsError(try staff.validate())
        staff.spacing = 12
        staff.width = .infinity
        XCTAssertThrowsError(try staff.validate())
        XCTAssertNoThrow(
            try decode(
                staff: parameters.replacingOccurrences(
                    of: "\"spacing\":12", with: "\"spacing\":256")))
        XCTAssertNoThrow(
            try decode(
                staff: parameters.replacingOccurrences(of: "\"width\":1.5", with: "\"width\":0.25"))
        )
    }

    func testLinearStaffSpansRectangleWithEvenNormalSpacing() throws {
        var notes = try enabledLayer()
        notes.path = path([anchor(0, 0), anchor(1, 0)])
        notes.path?.enabled = false
        for direction: Float in [0, 45, 90, 180, 225, 270] {
            notes.notes.direction = direction
            let staff = try XCTUnwrap(notes.preparedStaff())
            XCTAssertFalse(staff.closed)
            XCTAssertFalse(staff.hasTightTurns)
            XCTAssertEqual(staff.origin, Point(50, 40))
            let heading = notes.heading
            let normal = Point(-heading.y, heading.x)
            for (index, range) in staff.lineRanges.enumerated() {
                let vertices = staff.vertices[range].map { Point($0) }
                let across = vertices.map { simd_dot($0, normal) }
                let along = vertices.map { simd_dot($0, heading) }
                let offset = Double(index - 2) * 12
                XCTAssertEqual(range.count, 6)
                XCTAssertEqual(across.min()!, offset - 0.75, accuracy: 1e-5)
                XCTAssertEqual(across.max()!, offset + 0.75, accuracy: 1e-5)
                let end = heading * along.max()!
                XCTAssertEqual(max(abs(end.x) / 50, abs(end.y) / 40), 1, accuracy: 1e-6)
            }
        }
    }

    func testOpenCubicEndsAndGeometryIndependentOfPlaybackAndStyle() throws {
        var notes = try enabledLayer()
        notes.region = .init(x: 0, y: 0, width: 300, height: 80)
        let first = Path.Anchor(position: .zero, incoming: .zero, outgoing: Point(0.3, 0))
        let last = Path.Anchor(
            position: Point(1, 1), incoming: Point(0.7, 1), outgoing: Point(1, 1))
        let curve = path([first, last])
        notes.path = curve
        let before = try curve.prepare(in: notes.region)
        let staff = try XCTUnwrap(notes.preparedStaff())
        verifyFinite(staff)
        XCTAssertFalse(staff.closed)
        XCTAssertFalse(staff.hasTightTurns)
        let center = staff.lineRanges[2]
        let vertices = staff.vertices[center]
        XCTAssertEqual(vertices.first!.x, 0, accuracy: 0.1)
        XCTAssertEqual(vertices.first!.y, -0.75, accuracy: 0.001)
        XCTAssertEqual(vertices.last!.x, 300, accuracy: 0.1)
        XCTAssertEqual(vertices.last!.y, 80.75, accuracy: 0.001)
        notes.path?.direction = .reverse
        notes.notes.speed = 0
        notes.notes.direction = 5
        notes.notes.hover = true
        notes.region = .init(x: 50, y: 0, width: 300, height: 80)
        notes.staff?.color.red = 0.2
        notes.staff?.opacity = 0
        XCTAssertEqual(try notes.preparedStaff(), staff)
        XCTAssertEqual(try notes.path?.prepare(in: notes.region), before)
        notes.region = .init(x: 50, y: 0, width: 300, height: 120)
        XCTAssertNotEqual(try notes.preparedStaff(), staff)
        notes.region = .init(x: 50, y: 0, width: 300, height: 80)
        notes.staff?.width = 2
        XCTAssertNotEqual(try notes.preparedStaff(), staff)
        notes.staff?.enabled = false
        XCTAssertNil(try notes.preparedStaff())
        notes.staff?.enabled = true
        XCTAssertEqual(notes.staff?.width, 2)
    }

    func testClosedSeamSharesBothBoundaryVertices() throws {
        var notes = try enabledLayer()
        notes.path = path([anchor(0, 0), anchor(1, 0), anchor(1, 1), anchor(0, 1)], closed: true)
        let staff = try XCTUnwrap(notes.preparedStaff())
        verifyFinite(staff)
        XCTAssertTrue(staff.closed)
        for range in staff.lineRanges {
            let first = Set(staff.vertices[range.prefix(6)])
            let last = Set(staff.vertices[range.suffix(6)])
            XCTAssertEqual(first.intersection(last).count, 2)
        }
    }

    func testSharpHalfTurnFoldAndSelfCrossingStayBounded() throws {
        var notes = try enabledLayer()
        let shapes: [(Path, Bool)] = [
            (path([anchor(0, 0), anchor(0.9, 0), anchor(0.4, 0.8)]), true),
            (path([anchor(0, 0), anchor(1, 0), anchor(0, 0.01)]), true),
            (
                path(
                    [anchor(0, 0), anchor(0.1, 0), anchor(0.1, 0.1), anchor(0, 0.1)], closed: true),
                true
            ),
            (path([anchor(0, 0), anchor(1, 1), anchor(0, 1), anchor(1, 0)]), true),
        ]
        for (curve, tight) in shapes {
            notes.path = curve
            let staff = try XCTUnwrap(notes.preparedStaff())
            verifyFinite(staff)
            XCTAssertEqual(staff.hasTightTurns, tight)
            var other = try enabledLayer()
            other.path = curve
            XCTAssertEqual(try other.preparedStaff(), staff)
        }
        XCTAssertEqual(WSSMusicNotesStaff.maximumVertices, 245_760)
    }
}
