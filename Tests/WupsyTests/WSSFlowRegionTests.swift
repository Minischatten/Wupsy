import MetalKit
import XCTest

@testable import Wupsy

final class WSSFlowRegionTests: XCTestCase {
    func region(_ rows: [String]) -> WSSFlowRegion {
        WSSFlowRegion(
            width: rows[0].count, height: rows.count,
            pixels: Data(rows.joined().map { $0 == "#" ? 255 : 0 }))
    }
    func testBinaryFormatResolutionLimitsAndMalformedResources() throws {
        for size in [SIMD2<Float>(1, 1), SIMD2(12, 7), SIMD2(8192, 8192), SIMD2(8192, 1)] {
            let value = try WSSFlowRegion.empty(size: size)
            XCTAssertLessThanOrEqual(value.width, 2048)
            XCTAssertLessThanOrEqual(value.height, 2048)
            XCTAssertEqual(try WSSFlowRegion.decode(value.encoded()), value)
        }
        XCTAssertEqual(try WSSFlowRegion.empty(size: SIMD2(8192, 8192)).width, 2048)
        XCTAssertEqual(try WSSFlowRegion.empty(size: SIMD2(13, 7)).width, 13)
        for bad in [
            WSSFlowRegion(width: 0, height: 1, pixels: Data()),
            WSSFlowRegion(width: 1, height: 1, pixels: Data([128])),
            WSSFlowRegion(width: 2049, height: 1, pixels: Data(count: 2049)),
        ] {
            XCTAssertThrowsError(try bad.encoded())
        }
        let bytes = try region(["#"]).encoded()
        XCTAssertThrowsError(try WSSFlowRegion.decode(bytes + Data([0])))
        XCTAssertThrowsError(try WSSFlowRegion.decode(Data(bytes.dropLast())))
    }
    func testPersistedModeDefaultsAndStrictRegionDescriptorValidation() throws {
        func decode(_ extras: [String: Any]) throws -> WSSSceneDocumentV1.Effect {
            var object: [String: Any] = [
                "type": "flow",
                "flowMap": [
                    "format": "wss-vector-field-f16", "version": 1, "asset": "assets/a.wssvf",
                ], "edgeProtectionPixels": 64,
            ]
            object.merge(extras) { _, new in new }
            return try JSONDecoder().decode(
                WSSSceneDocumentV1.Effect.self, from: JSONSerialization.data(withJSONObject: object)
            )
        }
        let old = try decode([:])
        guard case .flow(let legacy) = old.native else { return XCTFail() }
        XCTAssertEqual(legacy.edgeProtectionMode, .imageBounds)
        XCTAssertNil(legacy.flowRegion)
        let descriptor: [String: Any] = [
            "format": "wss-flow-region-r8", "version": 1, "asset": "assets/a.wssregion",
        ]
        let authored = try decode(["edgeProtectionMode": "region", "flowRegion": descriptor])
        XCTAssertEqual(
            try JSONDecoder().decode(
                WSSSceneDocumentV1.Effect.self, from: JSONEncoder().encode(authored)), authored)
        for extras: [String: Any] in [
            ["edgeProtectionMode": "region"], ["flowRegion": descriptor],
            ["edgeProtectionMode": "unknown"],
            [
                "edgeProtectionMode": "region",
                "flowRegion": [
                    "format": "wss-flow-region-r8", "version": 1, "asset": "../bad.wssregion",
                ],
            ],
        ] {
            XCTAssertThrowsError(try decode(extras))
        }
        var candidate = authored
        XCTAssertThrowsError(
            try candidate.updateParameters { effect in
                if case .flow(var flow) = effect {
                    flow.flowRegion = WSSAssetID(value: "assets/b.wssregion")
                    effect = .flow(flow)
                }
            })
    }
    // Independent geometric oracle: enumerate exposed segments and project a local
    // cell center onto each finite segment. No center-to-center EDT in this oracle.
    func oracle(_ r: WSSFlowRegion, size: SIMD2<Float>, x: Int, y: Int) -> Float {
        let step = SIMD2(Double(size.x) / Double(r.width), Double(size.y) / Double(r.height))
        let point = SIMD2(Double(x) + 0.5, Double(y) + 0.5) * step
        var best = Double.infinity
        func active(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < r.width && y < r.height && r.pixels[y * r.width + x] == 255
        }
        for yy in 0..<r.height {
            for xx in 0..<r.width where active(xx, yy) {
                for side in 0..<4 {
                    if active(
                        xx + (side == 0 ? -1 : side == 1 ? 1 : 0),
                        yy + (side == 2 ? -1 : side == 3 ? 1 : 0))
                    {
                        continue
                    }
                    let a =
                        SIMD2(Double(xx + (side == 1 ? 1 : 0)), Double(yy + (side == 3 ? 1 : 0)))
                        * step
                    let b = a + (side < 2 ? SIMD2(0, step.y) : SIMD2(step.x, 0))
                    let delta = b - a
                    let t = max(
                        0,
                        min(
                            1,
                            ((point.x - a.x) * delta.x + (point.y - a.y) * delta.y)
                                / (delta.x * delta.x + delta.y * delta.y)))
                    let d = point - (a + delta * t)
                    best = min(best, hypot(d.x, d.y))
                }
            }
        }
        return Float(best) * (active(x, y) ? 1 : -1)
    }
    func testAnalyticCellBoundariesRectanglesDiagonalsHolesAndAnisotropy() throws {
        let shapes = [
            region(["#"]), region(["####", "####", "####"]),
            region(["....", ".##.", ".##.", "...."]),
            region(["####", "###.", "##..", "#..."]),
            region(["#####", "#...#", "#...#", "#####"]),
            region(["#...#", "#####", "#...#"]),
        ]
        for shape in shapes {
            for size in [SIMD2<Float>(20, 20), SIMD2(70, 11)] {
                let distances = try WSSFlowRegionDistance.make(shape, size: size)
                for y in 0..<shape.height {
                    for x in 0..<shape.width {
                        XCTAssertEqual(
                            distances[y * shape.width + x], oracle(shape, size: size, x: x, y: y),
                            accuracy: 0.0001)
                    }
                }
            }
        }
        XCTAssertEqual(try WSSFlowRegionDistance.make(region(["#"]), size: SIMD2(6, 10)), [3])
        XCTAssertEqual(
            try WSSFlowRegionDistance.make(region(["..."]), size: SIMD2(6, 10)), [0, 0, 0])
    }
    func testCacheIgnoresTransportControlsAndInvalidatesImageSizeAndRegion() throws {
        let cache = WSSFlowRegionDistanceCache()
        let r = region(["##", "##"])
        let first = try cache.distance(r, size: SIMD2(20, 10))
        XCTAssertEqual(try cache.distance(r, size: SIMD2(20, 10)), first)
        XCTAssertEqual(cache.computations, 1)
        _ = try cache.distance(r, size: SIMD2(40, 10))
        _ = try cache.distance(region(["#.", "##"]), size: SIMD2(40, 10))
        XCTAssertEqual(cache.computations, 3)
        XCTAssertThrowsError(
            try WSSFlowRegionDistance.make(r, size: SIMD2(20, 10), workingByteLimit: 0))
    }
    func testMaximumAxisAndExtremeAspectDistanceRemainInLocalPixels() throws {
        let r = WSSFlowRegion(width: 2048, height: 1, pixels: Data(repeating: 255, count: 2048))
        let distance = try WSSFlowRegionDistance.make(r, size: SIMD2(8192, 4))
        XCTAssertEqual(distance.count, 2048)
        XCTAssertTrue(distance.allSatisfy { $0 == 2 })
        let tall = WSSFlowRegion(width: 1, height: 2048, pixels: r.pixels)
        XCTAssertEqual(try WSSFlowRegionDistance.make(tall, size: SIMD2(4, 8192)), distance)
        XCTAssertThrowsError(try WSSFlowRegionDistance.make(r, size: SIMD2(.infinity, 4)))
    }
    func testBinaryBrushNeutralizeEraseAndDisconnectedPaths() throws {
        let empty = try WSSFlowRegion.empty(size: SIMD2(64, 64))
        let points = [SIMD2<Double>(0.1, 0.5), SIMD2(0.3, 0.5), SIMD2(0.7, 0.5), SIMD2(0.9, 0.5)]
        let brush = try WSSVectorBrush(diameter: 8, magnitude: 0, operation: .direction)
        let painted = try empty.painted(
            imageSize: SIMD2(64, 64), points: points, subpaths: [2], brush: brush)
        XCTAssertTrue(painted.pixels.contains(255))
        XCTAssertEqual(painted.pixels[32 * 64 + 32], 0)
        XCTAssertEqual(
            try painted.painted(
                imageSize: SIMD2(64, 64), points: points, subpaths: [2],
                brush: WSSVectorBrush(diameter: 8, magnitude: 0, operation: .neutralize)), painted)
        XCTAssertEqual(
            try painted.painted(
                imageSize: SIMD2(64, 64), points: points, subpaths: [2],
                brush: WSSVectorBrush(diameter: 8, magnitude: 0, operation: .erase)), empty)
        XCTAssertThrowsError(
            try empty.painted(
                imageSize: SIMD2(64, 64), points: points, subpaths: [2], brush: brush,
                retainedBytes: WSSVectorFieldEditorBudget.workingDataLimit))
    }
    struct Assets: WSSImageAssetSource {
        var region: WSSFlowRegion
        var field: WSSVectorFieldAsset
        func flowRegion(for id: WSSAssetID) throws -> WSSFlowRegion { region }
        func vectorField(for id: WSSAssetID) throws -> WSSVectorFieldAsset { field }
        func image(for id: WSSAssetID) throws -> WSSImageAsset {
            WSSImageAsset(width: 64, height: 64, payload: .rgba8(WSSFlowTests().pixels(size: 64)))
        }
    }
    func frame(
        _ region: WSSFlowRegion, vector: SIMD2<Float>, coverage: UInt8?, n: Float, density: Int = 1,
        enabled: Bool = true
    ) throws -> Data {
        let original = try WSSVectorFieldPaintTests().field(width: 8, height: 8, vector: vector)
        let field = WSSVectorFieldAsset(
            width: 8, height: 8, vectors: original.vectors,
            coverage: coverage.map { Data(repeating: $0, count: 64) },
            isNeutral: vector == .zero || coverage == 0)
        let flow = WSSFlowEffect(
            flowMap: WSSAssetID(value: "field"), strength: 8, edgeProtectionPixels: n,
            edgeProtectionMode: .region, flowRegion: WSSAssetID(value: "region"))
        let scene = WSSScene(
            width: 64, height: 64,
            layers: [
                WSSImageLayer(
                    asset: WSSAssetID(value: "image"),
                    transform: WSSImageTransform(center: SIMD2(32, 32), size: SIMD2(64, 64)),
                    composition: .replace,
                    effects: enabled ? [.flow(flow)] : [])
            ])
        let resources = try WSSStaticResources(
            scene: scene, assets: Assets(region: region, field: field),
            device: WSSStaticTests().device())
        return try WSSRippleChainTests().render(
            resources, time: 0.35, width: 64 * density, height: 64 * density
        ).0
    }
    func testGPURegionGateCoverageZeroMagnitudeAndFade() throws {
        let full = region([
            "########", "########", "########", "########", "########", "########", "########",
            "########",
        ])
        let island = region([
            "........", ".##..##.", ".##..##.", "........", ".######.", ".#....#.", ".######.",
            "........",
        ])
        let empty = WSSFlowRegion(width: 8, height: 8, pixels: Data(count: 64))
        let original = try frame(full, vector: .zero, coverage: nil, n: 0, enabled: false)
        XCTAssertEqual(try frame(empty, vector: SIMD2(1, 0), coverage: nil, n: 0), original)
        XCTAssertEqual(try frame(full, vector: SIMD2(1, 0), coverage: 0, n: 0), original)
        XCTAssertEqual(try frame(full, vector: .zero, coverage: nil, n: 12), original)
        for vector: SIMD2<Float> in [SIMD2(0.001, 0), SIMD2(1, 0), SIMD2(1, 1)] {
            for n: Float in [0, 0.001, 12, 4096] {
                let result = try frame(island, vector: vector, coverage: 128, n: n)
                // Outside both islands, including their internal hole, remains byte exact.
                for (x, y) in [(2, 2), (30, 30), (30, 44), (62, 62)] {
                    let offset = (y * 64 + x) * 4
                    XCTAssertEqual(result[offset..<offset + 4], original[offset..<offset + 4])
                }
            }
        }
        XCTAssertNotEqual(try frame(full, vector: SIMD2(1, 0), coverage: nil, n: 0), original)
        XCTAssertNotEqual(
            try frame(full, vector: SIMD2(1, 0), coverage: nil, n: 0),
            try frame(full, vector: SIMD2(1, 0), coverage: nil, n: 16))
        _ = try frame(island, vector: SIMD2(1, 1), coverage: 128, n: 12, density: 2)
    }
}
