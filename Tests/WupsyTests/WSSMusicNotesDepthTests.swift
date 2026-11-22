import MetalKit
import XCTest

@testable import Wupsy

final class WSSMusicNotesDepthTests: XCTestCase {
    func testDepthStrictRoundTripBoundariesAndBudget() throws {
        let id = UUID()
        var depth = WSSMusicNotesDepth(target: id)
        depth.changes = [.init(position: 25, side: .behind), .init(position: 75, side: .inFront)]
        let encoded = try JSONEncoder().encode(depth)
        XCTAssertEqual(try JSONDecoder().decode(WSSMusicNotesDepth.self, from: encoded), depth)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("includesStaff"))
        depth.includesStaff = true
        let together = try JSONEncoder().encode(depth)
        XCTAssertEqual(try JSONDecoder().decode(WSSMusicNotesDepth.self, from: together), depth)
        let badScope = String(decoding: together, as: UTF8.self)
            .replacingOccurrences(of: #""includesStaff":true"#, with: #""includesStaff":"true""#)
        XCTAssertThrowsError(
            try JSONDecoder().decode(WSSMusicNotesDepth.self, from: Data(badScope.utf8)))
        for positions: [Float] in [
            [0], [100], [50, 50], [75, 25], [.infinity], [.nan], Array(1...9).map(Float.init),
        ] {
            depth.changes = positions.map { .init(position: $0, side: .behind) }
            XCTAssertThrowsError(try depth.validate())
        }
        let invalid = String(decoding: encoded, as: UTF8.self)
            .replacingOccurrences(of: "\"position\":25", with: "\"position\":null")
        XCTAssertThrowsError(
            try JSONDecoder().decode(WSSMusicNotesDepth.self, from: Data(invalid.utf8)))
    }

    @MainActor func testDepthTargetIdentitySurvivesReorderDeleteUndoAndRoundTrip() async throws {
        let fixtures = WSSEditorWorkspaceTests()
        try await fixtures.setUp()
        addTeardownBlock { @MainActor in try await fixtures.tearDown() }
        let doc = fixtures.document()
        defer { doc.close() }
        let image = doc.identity.layers[1].id
        try doc.addMusicNotes()
        let notes = try XCTUnwrap(doc.selection?.layer)
        try doc.setMusicNotesPathEnabled(true, layer: notes)
        try doc.setMusicNotesDepthTarget(image, for: notes)
        let depth = try XCTUnwrap(doc.musicNotesLayer(notes)?.depth)
        XCTAssertEqual(WSSMusicNotesDepth.plan(for: doc.workingScene), [1: [2]])
        try doc.changeMusicNotesPlacement(notes, name: "Staff scope") {
            $0.depth?.includesStaff = true
        }
        XCTAssertEqual(doc.musicNotesLayer(notes)?.depth?.includesStaff, true)
        doc.undoManager.undo()
        XCTAssertNil(doc.musicNotesLayer(notes)?.depth?.includesStaff)
        doc.undoManager.redo()
        XCTAssertEqual(doc.musicNotesLayer(notes)?.depth?.includesStaff, true)
        doc.undoManager.undo()
        try doc.moveLayer(image, to: 0)
        XCTAssertEqual(WSSMusicNotesDepth.plan(for: doc.workingScene), [0: [2]])
        let pending = doc.state.workingModel
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: pending.encoded()), pending)
        doc.select(.layer(image))
        try doc.deleteLayer(image)
        XCTAssertTrue(WSSMusicNotesDepth.plan(for: doc.workingScene).isEmpty)
        XCTAssertEqual(doc.musicNotesLayer(notes)?.depth, depth)
        doc.undoManager.undo()
        XCTAssertEqual(WSSMusicNotesDepth.plan(for: doc.workingScene), [0: [2]])
        try doc.resetMusicNotes(notes)
        XCTAssertNil(doc.musicNotesLayer(notes)?.depth)
        doc.undoManager.undo()
        XCTAssertEqual(doc.musicNotesLayer(notes)?.depth, depth)
    }

    func testGPUStaffDepthBlendsAndKeepsContinuousCoverage() throws {
        let device = try WSSStaticTests().device()
        let id = UUID()
        let asset = WSSAssetID(value: "foreground")
        var notes = WSSMusicNotesLayer(region: .init(x: 0, y: 0, width: 256, height: 128))
        notes.notes.count = 0
        var staff = WSSMusicNotesStaff()
        staff.enabled = true
        staff.color = .init(red: 1, green: 0, blue: 0)
        staff.opacity = 0.5
        staff.width = 3
        notes.staff = staff
        var depth = WSSMusicNotesDepth(target: id)
        depth.changes = [.init(position: 30, side: .behind), .init(position: 70, side: .inFront)]
        notes.depth = depth
        var image = WSSImageLayer(
            asset: asset, transform: .init(center: SIMD2(128, 64), size: SIMD2(256, 128)),
            depthID: id)

        func frame(alpha: UInt8) throws -> Data {
            let scene = WSSScene(
                width: 256, height: 128, layers: [.musicNotes(notes), .image(image)])
            let resources = try WSSStaticResources(
                scene: scene,
                assets: WSSStaticTests.Assets(values: [
                    asset: WSSImageAsset(
                        width: 1, height: 1, payload: .rgba8(Data([0, 0, 255, alpha])))
                ]), device: device)
            return try WSSStormLightingRenderTests().render(
                resources, time: 23, width: 256, height: 128
            ).0
        }
        func red(_ image: Data, _ x: Int, _ y: Int) -> Int {
            Int(image[((127 - y) * 256 + x) * 4 + 2])
        }

        for template in WSSMusicNotesPath.EditorTemplate.allCases {
            notes.path = template.makePath(direction: .forward)
            notes.depth?.includesStaff = nil
            let reference = try frame(alpha: 0)
            let notesOnly = try frame(alpha: 128)
            notes.depth?.includesStaff = true
            let routed = try frame(alpha: 128)
            XCTAssertNotEqual(routed, notesOnly)
            let transparent = try frame(alpha: 0)
            let difference = stride(from: 2, to: reference.count, by: 4).map {
                abs(Int(reference[$0]) - Int(transparent[$0]))
            }
            XCTAssertLessThanOrEqual(difference.max()!, 1)
            if template == .straightPath {
                let opaque = try frame(alpha: 255)
                for y in [40, 52, 64, 76, 88] {
                    XCTAssertEqual(red(routed, 60, y), 128)
                    XCTAssertEqual(Double(red(routed, 128, y)), 64, accuracy: 1)
                    XCTAssertEqual(red(routed, 196, y), 128)
                    XCTAssertEqual(red(opaque, 128, y), 0)
                    XCTAssertTrue((45...210).allSatisfy { red(transparent, $0, y) >= 127 })
                }
            }
            if template == .straightPath {
                var perspective = WSSMusicNotesPerspective()
                perspective.enabled = true
                notes.perspective = perspective
                let tapered = try frame(alpha: 128)
                let taperedTransparent = try frame(alpha: 0)
                XCTAssertEqual(red(tapered, 60, 64), red(taperedTransparent, 60, 64))
                XCTAssertEqual(
                    Double(red(tapered, 128, 64)), Double(red(taperedTransparent, 128, 64)) * 0.5,
                    accuracy: 1)
                XCTAssertEqual(red(tapered, 196, 64), red(taperedTransparent, 196, 64))
                XCTAssertTrue((45...210).allSatisfy { red(taperedTransparent, $0, 64) > 24 })
                notes.depth?.includesStaff = nil
                let taperedUnrouted = try frame(alpha: 0)
                XCTAssertLessThanOrEqual(
                    stride(from: 2, to: taperedUnrouted.count, by: 4).map {
                        abs(Int(taperedUnrouted[$0]) - Int(taperedTransparent[$0]))
                    }.max()!, 1)
                notes.depth?.includesStaff = true
                notes.perspective = nil
            }
            image.visible = false
            XCTAssertEqual(try frame(alpha: 255), reference)
            image.visible = true
        }
    }

    func testDepthPreservesTransparentEdgesAndClassifiesEachNote() throws {
        let device = try WSSStaticTests().device()
        let id = UUID()
        let asset = WSSAssetID(value: "foreground")
        var notes = WSSMusicNotesLayer(region: .init(x: 0, y: 0, width: 256, height: 128))
        notes.notes.count = 4
        notes.notes.size = 23
        notes.notes.opacity = 1
        notes.notes.speed = 0
        notes.notes.color = .init(red: 1, green: 0, blue: 0)
        notes.notes.symbols = [.quarter]
        let anchors = [SIMD2<Double>(0.1, 0.5), SIMD2(0.9, 0.5)]
        notes.path = .init(
            enabled: true, closed: false, direction: .forward,
            anchors: anchors.map {
                .init(position: $0, incoming: $0, outgoing: $0)
            })
        let transform = WSSImageTransform(center: SIMD2(128, 64), size: SIMD2(256, 128))
        var image = WSSImageLayer(asset: asset, transform: transform, depthID: id)

        func frame(alpha: UInt8, image: WSSImageLayer? = nil, time: Double = 23) throws -> Data {
            var layers: [WSSSceneLayer] = [.musicNotes(notes)]
            if let image { layers.append(.image(image)) }
            let scene = WSSScene(width: 256, height: 128, layers: layers)
            let resources = try WSSStaticResources(
                scene: scene,
                assets: WSSStaticTests.Assets(values: [
                    asset: WSSImageAsset(
                        width: 1, height: 1, payload: .rgba8(Data([0, 0, 255, alpha])))
                ]), device: device)
            return try WSSStormLightingRenderTests().render(
                resources, time: time, width: 256, height: 128
            ).0
        }

        let reference = try frame(alpha: 0)
        var depth = WSSMusicNotesDepth(target: id)
        depth.start = .behind
        depth.changes = [.init(position: 50, side: .inFront)]
        notes.depth = depth
        XCTAssertEqual(try frame(alpha: 0, image: image), reference)
        let opaque = try frame(alpha: 255, image: image)
        let half = try frame(alpha: 128, image: image)
        for quarter in 0..<4 {
            func peak(_ data: Data) -> Int {
                var value: UInt8 = 0
                for y in 0..<128 {
                    for x in (quarter * 64)..<((quarter + 1) * 64) {
                        value = max(value, data[(y * 256 + x) * 4 + 2])
                    }
                }
                return Int(value)
            }
            XCTAssertEqual(peak(reference), 255)
            XCTAssertEqual(peak(opaque), quarter < 2 ? 0 : 255)
            XCTAssertEqual(peak(half), quarter < 2 ? 127 : 255)
        }
        notes.notes.count = 1
        let closing = SIMD2<Double>(0.5, 0.8)
        notes.path?.anchors.append(.init(position: closing, incoming: closing, outgoing: closing))
        notes.path?.closed = true
        let length = try XCTUnwrap(notes.path?.prepare(in: notes.region)).length
        notes.notes.speed = Float(length / 4)
        notes.depth?.start = .inFront
        notes.depth?.changes = [
            .init(position: 60, side: .behind), .init(position: 90, side: .inFront),
        ]
        func hasRed(_ pixels: Data) -> Bool {
            stride(from: 2, to: pixels.count, by: 4).contains { pixels[$0] > 24 }
        }
        XCTAssertTrue(hasRed(try frame(alpha: 255, image: image, time: 0)))
        XCTAssertFalse(hasRed(try frame(alpha: 255, image: image, time: 1)))
        XCTAssertTrue(hasRed(try frame(alpha: 255, image: image, time: 1.99)))
        XCTAssertTrue(hasRed(try frame(alpha: 255, image: image, time: 2.01)))
        notes.path?.direction = .reverse
        XCTAssertTrue(hasRed(try frame(alpha: 255, image: image, time: 1)))
        XCTAssertFalse(hasRed(try frame(alpha: 255, image: image, time: 3)))
        notes.notes.count = 4
        notes.notes.speed = 0
        notes.path?.direction = .forward
        notes.path?.closed = false
        notes.path?.anchors.removeLast()
        image.visible = false
        XCTAssertEqual(try frame(alpha: 255, image: image), reference)
    }
}
