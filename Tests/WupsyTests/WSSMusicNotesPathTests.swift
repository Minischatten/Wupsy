import Foundation
import XCTest
import simd

@testable import Wupsy

final class WSSMusicNotesPathTests: XCTestCase {
    private typealias Path = WSSMusicNotesPath
    private typealias Point = SIMD2<Double>

    private func anchor(_ x: Double, _ y: Double) -> Path.Anchor {
        let p = Point(x, y)
        return .init(position: p, incoming: p, outgoing: p)
    }

    private func path(_ anchors: [Path.Anchor], closed: Bool = false) -> Path {
        .init(enabled: true, closed: closed, direction: .forward, anchors: anchors)
    }

    private func region(_ width: Float = 100, _ height: Float = 100) -> WSSSceneDocumentV1.Region {
        .init(x: 900_000, y: -900_000, width: width, height: height)
    }

    private func document() throws -> WSSSceneDocumentV1 {
        try .decode(
            data: Data(
                """
                {"format":"wss-scene","version":1,"title":"Notes","canvas":{"width":128,"height":96},
                 "layers":[{"type":"musicNotes","visible":false,"region":{"x":0,"y":0,"width":100,"height":80},
                 "musicNotes":{"count":12,"size":48,"color":{"red":1,"green":1,"blue":1},"opacity":0.85,
                 "direction":90,"speed":24,"hover":false,"rotation":false,"seed":1,"symbols":["quarter"]}}]}
                """.utf8))
    }

    func testClosingDefaultPathAcrossRegionShapes() throws {
        for width in [1, 2, 8, 24, 75, 120, 400, 640, 1000, 1920, 3000, 3840, 5000, 8192] {
            for height in [1, 2, 8, 24, 75, 120, 400, 640, 1000, 1920, 3000, 3840, 5000, 8192]
            where width * height <= 32 * 1024 * 1024 {
                let frame = region(Float(width), Float(height))
                var path = Path.editorDefault
                guard (try? path.prepare(in: frame)) != nil else { continue }
                XCTAssertNoThrow(try path.setClosed(true, in: frame), "\(width) × \(height)")
            }
        }
    }

    func testEllipseTemplateHasFourSmoothQuadrants() throws {
        for (width, height) in [(640, 360), (1920, 1080), (3840, 2160), (1200, 200), (200, 1200)] {
            let frame = region(Float(width), Float(height))
            let ellipse = Path.EditorTemplate.ellipsePath.makePath(direction: .reverse)
            XCTAssertTrue(ellipse.closed)
            XCTAssertEqual(ellipse.anchors.count, 4)
            let table = try ellipse.prepare(in: frame)
            XCTAssertEqual(table.samples.first, table.samples.last)
            for i in ellipse.anchors.indices {
                let anchor = ellipse.anchors[i]
                XCTAssertLessThan(
                    simd_distance(
                        anchor.outgoing - anchor.position, anchor.position - anchor.incoming), 1e-12
                )
                let segment = ellipse.editorSegment(i)
                for step in 1..<10 {
                    let point = segment.point(at: Double(step) / 10)
                    XCTAssertEqual(point.x > 0.5, i == 0 || i == 3)
                    XCTAssertEqual(point.y > 0.5, i < 2)
                }
            }
        }
    }

    func testPreservesExistingGripsWhenClosingAndReopening() throws {
        let frame = region(3840, 1920)
        var path = Path(
            enabled: true, closed: false, direction: .forward,
            anchors: [
                .init(
                    position: .init(0.15, 0.3), incoming: .init(0.11, 0.26),
                    outgoing: .init(0.28, 0.43)),
                .init(
                    position: .init(0.5, 0.55), incoming: .init(0.37, 0.55),
                    outgoing: .init(0.63, 0.55)),
                .init(
                    position: .init(0.85, 0.7), incoming: .init(0.72, 0.57),
                    outgoing: .init(0.89, 0.74)),
            ])
        let before = path
        try path.setClosed(true, in: frame)
        XCTAssertEqual(path.anchors, before.anchors)
        try path.setClosed(false, in: frame)
        XCTAssertEqual(path, before)
    }

    func testLegacyAndPathRoundTripWithoutChangingLinearPlaybackState() throws {
        var doc = try document()
        guard case .musicNotes(var layer) = doc.layers[0].content else {
            return XCTFail("Missing musicNotes layer")
        }
        let legacy = try doc.encoded()
        XCTAssertNil(layer.path)
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("\"path\""))
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: legacy), doc)

        let original = layer
        for closed in [false, true] {
            var value = path([anchor(0, 0), anchor(1, 0), anchor(1, 1)], closed: closed)
            for direction: Path.Direction in [.forward, .reverse] {
                value.direction = direction
                for enabled in [true, false] {
                    value.enabled = enabled
                    layer.path = value
                    doc.layers[0].content = .musicNotes(layer)
                    let data = try doc.encoded()
                    XCTAssertEqual(try WSSSceneDocumentV1.decode(data: data), doc)
                    XCTAssertEqual(layer.phases(at: 300), original.phases(at: 300))
                    XCTAssertEqual(layer.isAnimated, original.isAnimated)
                    XCTAssertTrue(doc.referencedPaths.isEmpty)
                    let json = String(decoding: data, as: UTF8.self)
                    XCTAssertTrue(json.contains("\"position\":[0,0]"))
                }
            }
        }
    }

    func testStrictDecoderRejectsInvalidHiddenAndInactivePaths() throws {
        var doc = try document()
        guard case .musicNotes(var layer) = doc.layers[0].content else {
            return XCTFail("Missing musicNotes layer")
        }
        var value = path([anchor(0, 0), anchor(1, 1)])
        value.enabled = false
        layer.path = value
        doc.layers[0].content = .musicNotes(layer)
        let json = String(decoding: try doc.encoded(), as: UTF8.self)
        for (old, invalid) in [
            ("\"direction\":\"forward\"", "\"direction\":\"sideways\""),
            ("\"enabled\":false", "\"enabled\":null"),
            ("\"closed\":false", "\"closed\":false,\"unknown\":1"),
            ("\"incoming\":[0,0]", "\"incoming\":[0,0],\"unknown\":1"),
            ("\"outgoing\":[1,1]", "\"outgoing\":[1,1,1]"),
            ("\"outgoing\":[1,1]", "\"outgoing\":[1,1e999]"),
            ("\"position\":[1,1]", "\"position\":[0,0]"),
        ] {
            XCTAssertTrue(json.contains(old))
            XCTAssertThrowsError(
                try WSSSceneDocumentV1.decode(
                    data: Data(json.replacingOccurrences(of: old, with: invalid).utf8)), invalid)
        }
        let legacy = String(decoding: try document().encoded(), as: UTF8.self)
        XCTAssertThrowsError(
            try WSSSceneDocumentV1.decode(
                data: Data(
                    legacy.replacingOccurrences(
                        of: "\"type\":\"musicNotes\"", with: "\"type\":\"musicNotes\",\"path\":null"
                    ).utf8)))
    }

    func testAnchorLimitsDegenerateSegmentsAndFiniteValues() throws {
        XCTAssertThrowsError(try path([anchor(0, 0)]).prepare(in: region()))
        let two = [anchor(0, 0), anchor(1, 1)]
        XCTAssertNoThrow(try path(two, closed: true).prepare(in: region()))
        let sixteen = (0..<16).map { anchor(Double($0) / 15, 0) }
        XCTAssertEqual(try path(sixteen).prepare(in: region()).length, 100, accuracy: 1e-10)
        XCTAssertThrowsError(try path(sixteen + [anchor(1, 1)]).prepare(in: region()))
        XCTAssertThrowsError(try path(two + [anchor(0, 0)], closed: true).prepare(in: region()))
        XCTAssertThrowsError(try path([anchor(0, 0), anchor(0.00001, 0)]).prepare(in: region()))
        for invalid in [Double.nan, .infinity, -0.01, 1.01] {
            var bad = two
            bad[0].outgoing.x = invalid
            XCTAssertThrowsError(try path(bad).prepare(in: region()))
        }
        XCTAssertThrowsError(try path(two).prepare(in: region(.infinity, 1)))
        XCTAssertNoThrow(
            try path([
                anchor(0, 0), anchor(1, 1), anchor(0, 1), anchor(1, 0),
            ]).prepare(in: region()))
    }

    func testSharpJoinUsesFineTableAndRetracedPathKeepsFiniteTangents() throws {
        let corner = path([anchor(0, 0), anchor(1, 0), anchor(1, 1)])
        XCTAssertEqual(try corner.prepare(in: region(100, 80)).samples.count, 513)

        let retraced = path([anchor(0, 0), anchor(1, 0), anchor(0, 0)])
        let table = try retraced.prepare(in: region())
        let turn = table.samples[table.samples.count / 2]
        XCTAssertEqual(turn.position, SIMD2(100, 0))
        XCTAssertEqual(turn.tangent, SIMD2(-1, 0))
    }

    func testUniformDistanceWithNonuniformBezierAndAnisotropicScale() throws {
        let input = path([anchor(0, 0), anchor(1, 1)])
        let table = try input.prepare(in: region(300, 40))
        XCTAssertEqual(table, try input.prepare(in: region(300, 40)))
        XCTAssertEqual(MemoryLayout<Path.Table.Sample>.stride, 16)
        XCTAssertEqual(table.samples.count, 257)
        XCTAssertEqual(table.length, hypot(300, 40), accuracy: 1e-10)
        let direction = simd_normalize(Point(300, 40))
        for (i, sample) in table.samples.enumerated() {
            let expected = Point(300, 40) * (Double(i) / 256)
            XCTAssertLessThan(simd_distance(Point(sample.position), expected), 0.00003)
            XCTAssertLessThan(simd_distance(Point(sample.tangent), direction), 1e-6)
        }
    }

    func testSmoothClosedSeamAndTightCurveSpeed() throws {
        // Four standard cubic quarter-circle arcs, then nonuniformly scaled.
        let k = 0.5 * (4.0 / 3.0) * (sqrt(2.0) - 1)
        let loop = path(
            [
                .init(
                    position: Point(1, 0.5), incoming: Point(1, 0.5 - k),
                    outgoing: Point(1, 0.5 + k)),
                .init(
                    position: Point(0.5, 1), incoming: Point(0.5 + k, 1),
                    outgoing: Point(0.5 - k, 1)),
                .init(
                    position: Point(0, 0.5), incoming: Point(0, 0.5 + k),
                    outgoing: Point(0, 0.5 - k)),
                .init(
                    position: Point(0.5, 0), incoming: Point(0.5 - k, 0),
                    outgoing: Point(0.5 + k, 0)),
            ], closed: true)
        let table = try loop.prepare(in: region(240, 24))
        let first = try XCTUnwrap(table.samples.first)
        let last = try XCTUnwrap(table.samples.last)
        XCTAssertEqual(first, last)
        XCTAssertEqual(first.position, .zero)
        XCTAssertEqual(table.origin, Point(240, 12))
        XCTAssertEqual(first.tangent.x, 0, accuracy: 1e-5)
        XCTAssertEqual(first.tangent.y, 1, accuracy: 1e-5)
        XCTAssertTrue([257, 513].contains(table.samples.count))
        let step = table.length / Double(table.samples.count - 1)
        for (a, b) in zip(table.samples, table.samples.dropFirst()) {
            XCTAssertGreaterThan(simd_distance(Point(a.position), Point(b.position)) / step, 0.96)
            XCTAssertEqual(simd_length(a.tangent), 1, accuracy: 1e-6)
        }

        // Compare table interpolation with an independent, densely sampled cubic.
        let a = loop.anchors[0]
        let b = loop.anchors[1]
        let scale = Point(240, 24)
        var previous = a.position * scale
        var distance = 0.0
        for i in 1...4096 {
            let t = Double(i) / 4096
            let u = 1 - t
            let curve =
                a.position * (u * u * u) + a.outgoing * (3 * u * u * t)
                + b.incoming * (3 * u * t * t) + b.position * (t * t * t)
            let point = curve * scale
            distance += simd_distance(previous, point)
            let offset = distance / step
            let lower = Int(offset)
            let start = Point(table.samples[lower].position)
            let end = Point(table.samples[lower + 1].position)
            let interpolated = start + (end - start) * (offset - Double(lower))
            XCTAssertLessThan(simd_distance(point, table.origin + interpolated), 0.2)
            previous = point
        }
        XCTAssertEqual(table.length, 4 * distance, accuracy: 0.08)
    }

    func testShortPathStableTangentsAndSubdivisionBudget() throws {
        let short = path([
            .init(position: Point(0, 0), incoming: .zero, outgoing: Point(0, 0.03)),
            .init(position: Point(0.02, 0), incoming: Point(0.02, 0.03), outgoing: Point(0.02, 0)),
        ])
        let table = try short.prepare(in: region(1, 1))
        XCTAssertGreaterThan(table.length, 0.04)
        XCTAssertLessThan(table.length, 0.08)
        XCTAssertTrue(
            table.samples.allSatisfy {
                $0.position.x.isFinite && $0.position.y.isFinite
                    && abs(simd_length($0.tangent) - 1) < 1e-6
            })

        let farShort = try path([anchor(0.999998, 1), anchor(1, 1)])
            .prepare(in: region(8192, 1))
        XCTAssertEqual(farShort.samples.count, 257)
        for (a, b) in zip(farShort.samples, farShort.samples.dropFirst()) {
            XCTAssertGreaterThan(b.position.x, a.position.x)
        }

        let complex = (0..<16).map { i in
            let x = i.isMultiple(of: 2) ? 0.0 : 1.0
            return Path.Anchor(position: Point(x, 0), incoming: Point(x, 1), outgoing: Point(x, 1))
        }
        XCTAssertThrowsError(try path(complex).prepare(in: region(8192, 4096))) {
            XCTAssertEqual($0 as? WSSSceneError, .invalid("musicNotes path subdivision budget"))
        }
        XCTAssertEqual(Path.maximumSubdivisionDepth, 16)
        XCTAssertEqual(Path.maximumFlattenedEdges, 4096)
        XCTAssertEqual(Path.maximumSampleCount, 513)
    }
}
