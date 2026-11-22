import MetalKit
import XCTest

@testable import Wupsy

final class WSSMusicNotesPerspectiveTests: XCTestCase {
    func testPerspectivesValidateAndInterpolate() throws {
        var perspective = WSSMusicNotesPerspective()
        XCTAssertFalse(perspective.enabled)
        XCTAssertEqual(perspective.factor(at: 0), 1)
        XCTAssertEqual(perspective.factor(at: 0.5), 0.65, accuracy: 1e-6)
        XCTAssertEqual(perspective.factor(at: 1), 0.3, accuracy: 1e-6)
        (perspective.start, perspective.end) = (perspective.end, perspective.start)
        XCTAssertEqual(perspective.factor(at: 0), 0.3, accuracy: 1e-6)
        XCTAssertEqual(perspective.factor(at: 1), 1)
        XCTAssertEqual(
            try JSONDecoder().decode(
                WSSMusicNotesPerspective.self, from: JSONEncoder().encode(perspective)), perspective
        )
        for json in [
            #"{"enabled":false,"start":null,"end":10}"#,
            #"{"enabled":false,"start":9,"end":100}"#,
            #"{"enabled":true,"start":100,"end":201}"#,
            #"{"enabled":true,"start":100,"end":1e999}"#,
            #"{"enabled":true,"start":100,"end":30,"future":10}"#,
        ] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    WSSMusicNotesPerspective.self, from: Data(json.utf8)))
        }
    }

    func testGPUDefaultReverseAndClosedPerspective() throws {
        let device = try WSSStaticTests().device()
        var layer = WSSMusicNotesLayer(region: .init(x: 0, y: 0, width: 256, height: 128))
        layer.path = .editorDefault
        layer.notes.count = 2
        layer.notes.size = 32
        layer.notes.speed = 0
        layer.notes.symbols = [.quarter]
        layer.notes.color = .init(red: 0, green: 1, blue: 0)
        layer.notes.opacity = 1
        var staff = WSSMusicNotesStaff()
        staff.enabled = true
        staff.color = .init(red: 1, green: 0, blue: 0)
        staff.width = 3
        staff.opacity = 1
        layer.staff = staff

        func frame(_ time: Double = 0) throws -> Data {
            let resources = try WSSStaticResources(
                scene: .init(width: 256, height: 128, layers: [.musicNotes(layer)]),
                assets: WSSStaticTests.Assets(values: [:]), device: device)
            return try WSSStormLightingRenderTests().render(
                resources, time: time, width: 256, height: 128
            ).0
        }

        func redRows(_ frame: Data, x: Int) -> [Int] {
            (0..<128).filter { frame[($0 * 256 + x) * 4 + 2] > 45 }
        }
        func greenArea(_ frame: Data, isLeft: Bool) -> Int {
            stride(from: 1, to: frame.count, by: 4).count {
                (($0 / 4 % 256) < 128) == isLeft && frame[$0] > 70
            }
        }

        let original = try frame()
        layer.perspective = .init()
        XCTAssertEqual(try frame(), original)
        layer.perspective?.enabled = true
        let tapered = try frame()
        XCTAssertGreaterThan(greenArea(tapered, isLeft: true), greenArea(tapered, isLeft: false))
        let left = redRows(tapered, x: 50)
        let right = redRows(tapered, x: 205)
        XCTAssertGreaterThan(left.count, right.count)
        XCTAssertGreaterThan(left.last! - left.first!, right.last! - right.first!)
        XCTAssertLessThan(abs(left.last! + left.first! - 127), 2)
        XCTAssertLessThan(abs(right.last! + right.first! - 127), 2)

        layer.perspective?.start = 30
        layer.perspective?.end = 100
        let opposite = try frame()
        XCTAssertGreaterThan(greenArea(opposite, isLeft: false), greenArea(opposite, isLeft: true))
        layer.notes.hover = true
        layer.notes.rotation = true
        XCTAssertNotEqual(try frame(0.5), try frame())
        layer.notes.hover = false
        layer.notes.rotation = false

        layer.perspective?.start = 100
        XCTAssertEqual(try frame(), original)
        layer.path = WSSMusicNotesPath.EditorTemplate.ellipsePath.makePath(direction: .forward)
        layer.perspective?.end = 30
        let closed = try frame()
        layer.perspective?.enabled = false
        XCTAssertEqual(try frame(), closed)
    }
}
