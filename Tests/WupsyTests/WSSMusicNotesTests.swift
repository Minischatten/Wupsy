import MetalKit
import XCTest

@testable import Wupsy

final class WSSMusicNotesTests: XCTestCase {
    private let region = WSSSceneDocumentV1.Region(x: 8, y: 8, width: 48, height: 48)

    private func model(_ layer: WSSMusicNotesLayer, canvas: Int = 64) throws -> WSSSceneDocumentV1 {
        let node = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(WSSSceneDocumentV1.Layer(content: .musicNotes(layer))))
        return try WSSSceneDocumentV1.decode(
            data: JSONSerialization.data(withJSONObject: [
                "format": "wss-scene", "version": 1, "title": "Synthetic notes",
                "canvas": ["width": canvas, "height": canvas], "layers": [node],
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
        XCTAssertEqual(layer.notes.size, 48)
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
            ("count", -1), ("count", 129), ("count", 1.5), ("size", 3), ("size", 513),
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

    func testSpinPeriodDirectionAndLegacyFallback() throws {
        var symbol = WSSMusicNotesLayer.SingleSymbol()
        XCTAssertEqual(symbol.effectiveRotationMode(legacyRocking: true), .rocking)
        XCTAssertEqual(symbol.effectiveRotationMode(legacyRocking: false), .none)
        XCTAssertEqual(symbol.spinPhase(at: 15), -0.25)
        symbol.rotationMode = .continuous
        for period in [5.0, 60, 120, 300] {
            symbol.spinPeriod = period
            for direction in WSSMusicNotesLayer.SpinDirection.allCases {
                symbol.spinDirection = direction
                let quarter: Float = direction == .clockwise ? -0.25 : 0.25
                XCTAssertEqual(symbol.spinPhase(at: period / 4), quarter)
                XCTAssertEqual(symbol.spinPhase(at: period / 2), quarter * 2)
                XCTAssertEqual(symbol.spinPhase(at: period), 0)
                XCTAssertEqual(symbol.spinPhase(at: period * 1e9 + period / 4), quarter)
            }
        }
        let decoded = try JSONDecoder().decode(
            WSSMusicNotesLayer.SingleSymbol.self, from: JSONEncoder().encode(symbol))
        XCTAssertEqual(decoded, symbol)
        for invalid in [4.99, 300.01, .infinity, .nan] {
            symbol.spinPeriod = invalid
            XCTAssertThrowsError(try symbol.validate())
        }

        let json = """
            {"symbol":"quarter","size":48,"color":{"red":1,"green":1,"blue":1},"opacity":1,
             "rotationMode":"continuous","spinPeriod":60,"spinDirection":"clockwise","spinAxis":"vertical"}
            """
        for (old, invalid) in [
            (#""continuous""#, #""unknown""#), (#""clockwise""#, #""unknown""#),
            ("60", "null"), ("60", "301"), ("60", "1e999"),
            (#""vertical""#, #""horizontal""#), (#""vertical""#, "null"),
        ] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    WSSMusicNotesLayer.SingleSymbol.self,
                    from: Data(json.replacingOccurrences(of: old, with: invalid).utf8)))
        }
    }

    func testGPUSingleSpinOrientationsAndLegacyRocking() throws {
        let device = try WSSStaticTests().device()
        var layer = WSSMusicNotesLayer(region: .init(x: 0, y: 0, width: 512, height: 512))
        layer.notes.rotation = true
        let a = SIMD2<Double>(0.5, 0.2)
        let b = SIMD2<Double>(0.5, 0.8)
        layer.path = .init(
            enabled: true, closed: false, direction: .forward,
            anchors: [
                .init(position: a, incoming: a, outgoing: a),
                .init(position: b, incoming: b, outgoing: b),
            ])
        var symbol = WSSMusicNotesLayer.SingleSymbol()
        symbol.size = 160
        symbol.opacity = 1

        func render(_ layer: WSSMusicNotesLayer, _ time: Double) throws -> Data {
            let resources = try WSSStaticResources(
                scene: model(layer, canvas: 512).scene(),
                assets: WSSStaticTests.Assets(values: [:]), device: device)
            return try WSSStormLightingRenderTests().render(
                resources, time: time, width: 256, height: 256
            ).0
        }

        func centroid(_ pixels: Data) -> SIMD2<Double> {
            var sum = SIMD2<Double>.zero
            var weight = 0.0
            for i in stride(from: 2, to: pixels.count, by: 4) {
                let red = Double(pixels[i])
                sum += SIMD2(Double(i / 4 % 256) - 127.5, Double(i / 4 / 256) - 127.5) * red
                weight += red
            }
            return sum / weight
        }

        for placement in [WSSMusicNotesLayer.Placement.freeSingle, .anchoredSingle] {
            layer.placement = placement
            layer.alignToPath = true
            let free = placement == .freeSingle
            func updated(_ symbol: WSSMusicNotesLayer.SingleSymbol) -> WSSMusicNotesLayer {
                var value = layer
                if free { value.freeSymbol = symbol } else { value.anchoredSymbol = symbol }
                return value
            }
            symbol.rotationMode = nil
            let legacy = try render(updated(symbol), 0.75)
            symbol.rotationMode = .rocking
            XCTAssertEqual(try render(updated(symbol), 0.75), legacy)
            symbol.rotationMode = WSSMusicNotesLayer.SingleRotationMode.none
            let still = updated(symbol)
            XCTAssertFalse(still.isAnimated)
            XCTAssertEqual(try render(still, 0.75), try render(still, 5))
            symbol.rotationMode = .continuous
            symbol.spinDirection = .clockwise
            let spinning = updated(symbol)
            XCTAssertTrue(spinning.isAnimated)
            let zeroFrame = try render(spinning, 0)
            XCTAssertEqual(zeroFrame, try render(still, 0))
            XCTAssertEqual(zeroFrame, try render(spinning, 60))
            let zero = centroid(zeroFrame)
            let quarter = try centroid(render(spinning, 15))
            let half = try centroid(render(spinning, 30))
            XCTAssertEqual(quarter.x, -zero.y, accuracy: 0.05)
            XCTAssertEqual(quarter.y, zero.x, accuracy: 0.05)
            XCTAssertEqual(half.x, -zero.x, accuracy: 0.05)
            XCTAssertEqual(half.y, -zero.y, accuracy: 0.05)

            symbol.spinDirection = .counterclockwise
            let reverse = updated(symbol)
            XCTAssertEqual(try render(reverse, 15), try render(spinning, 45))
            var floating = reverse
            floating.notes.hover = true
            XCTAssertNotEqual(try render(floating, 15), try render(reverse, 15))
            let neutral = WSSStaticComposition.model(try model(floating, canvas: 512))
            XCTAssertFalse(try WSSStaticComposition.scene(neutral).isAnimated)
        }
    }

    func testGPUVerticalSpinPreservesPivotAndProjectsBothFaces() throws {
        let device = try WSSStaticTests().device()
        var layer = WSSMusicNotesLayer(region: .init(x: 0, y: 0, width: 512, height: 512))
        let a = SIMD2<Double>(0.5, 0.2)
        let b = SIMD2<Double>(0.5, 0.8)
        layer.path = .init(
            enabled: true, closed: false, direction: .forward,
            anchors: [
                .init(position: a, incoming: a, outgoing: a),
                .init(position: b, incoming: b, outgoing: b),
            ])
        var symbol = WSSMusicNotesLayer.SingleSymbol()
        symbol.symbol = .trebleClef
        symbol.size = 200
        symbol.opacity = 1
        symbol.rotationMode = .continuous

        func render(_ value: WSSMusicNotesLayer, _ time: Double) throws -> Data {
            let model = try model(value, canvas: 512)
            XCTAssertEqual(try WSSSceneDocumentV1.decode(data: model.encoded()), model)
            let resources = try WSSStaticResources(
                scene: model.scene(), assets: WSSStaticTests.Assets(values: [:]), device: device)
            return try WSSStormLightingRenderTests().render(
                resources, time: time, width: 256, height: 256
            ).0
        }

        for (index, placement) in [WSSMusicNotesLayer.Placement.freeSingle, .anchoredSingle]
            .enumerated()
        {
            layer.placement = placement
            layer.alignToPath = true
            let free = placement == .freeSingle
            func updated(_ symbol: WSSMusicNotesLayer.SingleSymbol) -> WSSMusicNotesLayer {
                var value = layer
                if free { value.freeSymbol = symbol } else { value.anchoredSymbol = symbol }
                return value
            }
            symbol.spinPeriod = index == 0 ? 60 : 120
            let period = try XCTUnwrap(symbol.spinPeriod)
            symbol.spinAxis = nil
            let legacyQuarter = try render(updated(symbol), period / 4)
            symbol.spinAxis = .imagePlane
            XCTAssertEqual(try render(updated(symbol), period / 4), legacyQuarter)
            symbol.spinAxis = .vertical
            symbol.spinDirection = .clockwise
            let value = updated(symbol)
            let front = try render(value, 0)
            let side = try render(value, period / 4)
            let back = try render(value, period / 2)
            let otherSide = try render(value, period * 0.75)
            XCTAssertEqual(front, try render(value, period))
            XCTAssertEqual(front, try render(value, period * 1e9))
            XCTAssertEqual(side, otherSide)
            let lit = (0..<256 * 256).filter { front[$0 * 4 + 2] > 16 }
            XCTAssertFalse(lit.isEmpty)
            XCTAssertTrue(stride(from: 2, to: side.count, by: 4).allSatisfy { side[$0] == 0 })
            var mismatches = 0
            for y in 0..<256 {
                for x in 0..<256 {
                    let reflected = free ? (y * 256 + 255 - x) : ((255 - y) * 256 + x)
                    if abs(Int(front[(y * 256 + x) * 4 + 2]) - Int(back[reflected * 4 + 2])) > 2 {
                        mismatches += 1
                    }
                }
            }
            XCTAssertLessThan(mismatches, 8)
            func extents(_ frame: Data) -> SIMD2<Int> {
                let pixels = (0..<256 * 256).filter { frame[$0 * 4 + 2] > 16 }
                let xs = pixels.map { $0 % 256 }
                let ys = pixels.map { $0 / 256 }
                return SIMD2(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
            }
            let frontExtent = extents(front)
            let reduced = try render(value, period / 6)
            let reducedExtent = extents(reduced)
            XCTAssertLessThan(reducedExtent[index], frontExtent[index])
            XCTAssertEqual(
                Double(reducedExtent[1 - index]), Double(frontExtent[1 - index]), accuracy: 1)
            symbol.spinDirection = .counterclockwise
            XCTAssertEqual(try render(updated(symbol), period / 6), reduced)
            var floating = value
            floating.notes.hover = true
            XCTAssertNotEqual(try render(floating, period / 6), reduced)
        }
    }

    func testSinglePlacementPersistenceValidationAndQuietPlayback() throws {
        var layer = WSSMusicNotesLayer(region: .init(x: 0, y: 0, width: 20, height: 20))
        var single = WSSMusicNotesLayer.SingleSymbol()
        single.size = 512
        single.symbol = .trebleClef
        layer.freeSymbol = single
        layer.freePosition = SIMD2(500, 300)
        layer.anchorPosition = 100
        layer.alignToPath = true
        for mode in WSSMusicNotesLayer.Placement.allCases {
            layer.placement = mode
            let doc = try model(layer, canvas: 1024)
            XCTAssertEqual(try WSSSceneDocumentV1.decode(data: doc.encoded()), doc)
        }
        layer.placement = .freeSingle
        XCTAssertEqual(layer.drawnSingleSize, 512)
        XCTAssertFalse(layer.isAnimated)
        layer.notes.hover = true
        layer.notes.hoverStrength = 0
        XCTAssertFalse(layer.isAnimated)
        layer.notes.hoverStrength = 12
        XCTAssertTrue(layer.isAnimated)
        layer.notes.hover = false
        layer.freePosition = SIMD2(Float.infinity, 300)
        XCTAssertThrowsError(try layer.validate())
        layer.freePosition = SIMD2(500, 300)
        layer.anchorPosition = 101
        XCTAssertThrowsError(try model(layer, canvas: 1024))
        layer.anchorPosition = 100
        let valid = String(decoding: try model(layer, canvas: 1024).encoded(), as: UTF8.self)
        for (old, invalid) in [
            (#""placement":"freeSingle""#, #""placement":null"#),
            (#""placement":"freeSingle""#, #""placement":"invalid""#),
            (#""symbol":"trebleClef""#, #""symbol":"trebleClef","extra":1"#),
            (#""freePosition":[500,300]"#, #""freePosition":[500]"#),
        ] {
            XCTAssertTrue(valid.contains(old))
            XCTAssertThrowsError(
                try WSSSceneDocumentV1.decode(
                    data: Data(valid.replacingOccurrences(of: old, with: invalid).utf8)))
        }
    }

    func testFixedSymbolsRenderAtEndpointsAndIgnoreTravel() throws {
        let device = try WSSStaticTests().device()
        var layer = WSSMusicNotesLayer(region: .init(x: 64, y: 64, width: 896, height: 896))
        layer.notes.count = 0
        layer.notes.opacity = 0
        layer.placement = .anchoredSingle
        let anchors = [SIMD2<Double>(0.25, 0.25), SIMD2(0.75, 0.25), SIMD2(0.5, 0.75)].map {
            WSSMusicNotesPath.Anchor(position: $0, incoming: $0, outgoing: $0)
        }
        var staff = WSSMusicNotesStaff()
        staff.enabled = true
        layer.staff = staff

        func frame(_ layers: [WSSMusicNotesLayer], time: Double = 0) throws -> Data {
            var scene = try model(layers[0], canvas: 1024).scene()
            scene.layers = layers.map { .musicNotes($0) }
            let resources = try WSSStaticResources(
                scene: scene, assets: WSSStaticTests.Assets(values: [:]), device: device)
            XCTAssertTrue(resources.musicNotesStaffs.isEmpty)
            return try WSSStormLightingRenderTests().render(
                resources, time: time, width: 256, height: 256
            ).0
        }

        for closed in [false, true] {
            layer.path = .init(enabled: true, closed: closed, direction: .reverse, anchors: anchors)
            layer.anchorPosition = 0
            let start = try frame([layer])
            layer.anchorPosition = 50
            let middle = try frame([layer])
            XCTAssertNotEqual(middle, start)
            XCTAssertEqual(try frame([layer], time: 23), middle)
            layer.anchorPosition = 100
            let end = try frame([layer])
            if closed { XCTAssertEqual(end, start) } else { XCTAssertNotEqual(end, start) }

            layer.anchorPosition = 0
            var moved = anchors[0]
            moved.position.x += 0.03
            moved.incoming.x += 0.03
            moved.outgoing.x += 0.03
            layer.path?.anchors[0] = moved
            XCTAssertNotEqual(try frame([layer]), start)

            layer.notes.hover = true
            layer.notes.rotation = true
            XCTAssertNotEqual(try frame([layer]), try frame([layer], time: 0.91))
            layer.notes.hover = false
            layer.notes.rotation = false
        }

        layer.placement = .freeSingle
        layer.region = .init(x: 0, y: 0, width: 1, height: 1)
        layer.path = nil
        layer.freePosition = SIMD2(512, 512)
        var symbol = WSSMusicNotesLayer.SingleSymbol()
        symbol.opacity = 1
        for choice in WSSMusicNoteSymbol.allCases {
            symbol.symbol = choice
            symbol.size = 4
            layer.freeSymbol = symbol
            let small = try frame([layer])
            symbol.size = 512
            layer.freeSymbol = symbol
            let large = try frame([layer])
            XCTAssertGreaterThan(
                large.filter { $0 == 255 }.count, small.filter { $0 == 255 }.count + 500)
        }
        symbol.symbol = .quarter
        symbol.color = .init(red: 1, green: 0, blue: 0)
        layer.freeSymbol = symbol
        var covering = layer
        covering.freeSymbol?.color = .init(red: 0, green: 0, blue: 1)
        let blue = try frame([covering])
        let center = try XCTUnwrap(stride(from: 0, to: blue.count, by: 4).first { blue[$0] == 255 })
        let overlapped = try frame([layer, covering])
        XCTAssertEqual(overlapped[center], 255)
        XCTAssertEqual(overlapped[center + 2], 0)
        let reversed = try frame([covering, layer])
        XCTAssertEqual(reversed[center], 0)
        XCTAssertEqual(reversed[center + 2], 255)
        covering.visible = false
        XCTAssertEqual(try frame([layer, covering]), try frame([layer]))
    }

    func testTrebleClefRoundTripRenderingAndProportions() throws {
        XCTAssertEqual(WSSMusicNoteSymbol.trebleClef.atlasIndex, 3)
        var layer = WSSMusicNotesLayer(region: .init(x: 0, y: 0, width: 1200, height: 1200))
        layer.notes.count = 1
        // Keep a single linear sprite away from the periodic seam for the silhouette measurement.
        layer.notes.seed = try XCTUnwrap(
            (0..<UInt32(128)).first { seed in
                let instance = WSSMusicNotesLayer.instances(seed: seed)[0]
                return (0.25...0.75).contains(instance.x) && (0.3...0.7).contains(instance.y)
            })
        layer.notes.speed = 0
        layer.notes.symbols = [.trebleClef]
        let anchors = [SIMD2<Double>(0.25, 0.45), SIMD2(0.75, 0.45), SIMD2(0.5, 0.65)].map {
            WSSMusicNotesPath.Anchor(position: $0, incoming: $0, outgoing: $0)
        }
        let paths = [false, true].map {
            WSSMusicNotesPath(enabled: true, closed: $0, direction: .reverse, anchors: anchors)
        }
        func frame(_ layer: WSSMusicNotesLayer, time: Double = 0) throws -> Data {
            let scene = try model(layer, canvas: 1200)
            XCTAssertEqual(try WSSSceneDocumentV1.decode(data: scene.encoded()), scene)
            return try WSSStormLightingRenderTests().render(
                resources(scene), time: time, width: 600, height: 600
            ).0
        }
        for path in [nil, paths[0], paths[1]] {
            layer.path = path
            var previousHeight = 0
            for size: Float in [48, 192, 512] {
                layer.notes.size = size
                let pixels = try frame(layer)
                var minX = 600
                var maxX = -1
                var minY = 600
                var maxY = -1
                for index in stride(from: 2, to: pixels.count, by: 4) where pixels[index] > 45 {
                    let x = index / 4 % 600
                    let y = index / 4 / 600
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
                let width = maxX - minX + 1
                let height = maxY - minY + 1
                XCTAssertGreaterThan(height, previousHeight)
                XCTAssertGreaterThan(width, 0)
                XCTAssertEqual(Double(height) / Double(width), 2.4, accuracy: 0.35)
                previousHeight = height
            }
            var moving = layer
            moving.notes.speed = 40
            moving.notes.hover = true
            moving.notes.rotation = true
            XCTAssertNotEqual(try frame(moving), try frame(moving, time: 0.64))
        }
        layer.notes.symbols = WSSMusicNoteSymbol.allCases
        layer.notes.count = 16
        let mixed = try frame(layer)
        layer.notes.symbols.removeLast()
        XCTAssertNotEqual(try frame(layer), mixed)
        layer.notes.symbols = [.trebleClef, .trebleClef]
        XCTAssertThrowsError(try model(layer, canvas: 1200))
    }

    func testGentleMotionLegacyDefaultsAndStrictOptionalFields() throws {
        var layer = WSSMusicNotesLayer(region: region)
        layer.notes.hover = true
        layer.notes.rotation = true
        let legacy = try model(layer)
        let encoded = try legacy.encoded()
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let layers = try XCTUnwrap(root["layers"] as? [[String: Any]])
        let config = try XCTUnwrap(layers[0]["musicNotes"] as? [String: Any])
        for parameter in WSSMusicNotesLayer.MotionParameter.allCases {
            XCTAssertNil(config[parameter.rawValue])
            for bad: Any in [
                NSNull(), "0.5", parameter.range.lowerBound - 1, parameter.range.upperBound + 1,
            ] {
                var invalid = config
                invalid[parameter.rawValue] = bad
                var node = layers[0]
                node["musicNotes"] = invalid
                var scene = root
                scene["layers"] = [node]
                XCTAssertThrowsError(
                    try WSSSceneDocumentV1.decode(
                        data: JSONSerialization.data(withJSONObject: scene)))
            }
        }
        XCTAssertEqual(layer.notes.hoverAmount, 0.12)
        XCTAssertEqual(layer.notes.rotationAmount * 0.32, 0.32)
        for time in [0.0, 0.25, 3.73, 1e12] {
            func legacyPhase(_ rate: Double) -> Float {
                Float(time.truncatingRemainder(dividingBy: 1 / rate) * rate)
            }
            XCTAssertEqual(
                layer.oscillationPhases(at: time), SIMD2(legacyPhase(0.23), legacyPhase(0.13)))
        }

        layer.notes.speed = 0
        layer.notes.hoverStrength = 0
        layer.notes.rotationStrength = 0
        XCTAssertFalse(layer.isAnimated)
        XCTAssertEqual(layer.oscillationPhases(at: 0.25), .zero)
        layer.notes.hoverFrequency = .infinity
        XCTAssertThrowsError(try layer.validate())
        layer.notes.hoverFrequency = .nan
        XCTAssertThrowsError(try layer.validate())
    }

    func testGPUDefaultAndCustomGentleMotionInAllPathModes() throws {
        var layer = WSSMusicNotesLayer(region: .init(x: 0, y: 0, width: 1200, height: 1200))
        layer.notes.hover = true
        layer.notes.rotation = true
        layer.notes.size = 512
        layer.notes.speed = 24
        layer.notes.count = 1
        layer.notes.seed = 29
        var staff = WSSMusicNotesStaff()
        staff.enabled = true
        layer.staff = staff
        let anchors = [SIMD2<Double>(0.25, 0.45), SIMD2(0.75, 0.45), SIMD2(0.5, 0.65)].map {
            WSSMusicNotesPath.Anchor(position: $0, incoming: $0, outgoing: $0)
        }
        let paths = [false, true].map {
            WSSMusicNotesPath(enabled: true, closed: $0, direction: .reverse, anchors: anchors)
        }
        func rendered(_ layer: WSSMusicNotesLayer, time: Double = 0.73) throws -> Data {
            let model = try model(layer, canvas: 1200)
            XCTAssertEqual(try WSSSceneDocumentV1.decode(data: model.encoded()), model)
            return try WSSStormLightingRenderTests().render(
                resources(model), time: time, width: 384, height: 384
            ).0
        }
        for path in [nil, paths[0], paths[1]] {
            layer.path = path
            let legacyFrame = try rendered(layer)
            var adjusted = layer
            adjusted.notes.hoverStrength = 12
            adjusted.notes.rotationStrength = 100
            adjusted.notes.hoverFrequency = 0.23
            adjusted.notes.rotationFrequency = 0.13
            XCTAssertEqual(try rendered(adjusted), legacyFrame)
            adjusted.notes.hoverStrength = 25
            adjusted.notes.hoverFrequency = 0.75
            XCTAssertNotEqual(try rendered(adjusted), legacyFrame)
            let hoverOnly = try rendered(adjusted)
            adjusted.notes.rotationStrength = 200
            adjusted.notes.rotationFrequency = 0.59
            XCTAssertNotEqual(try rendered(adjusted), hoverOnly)
            XCTAssertEqual(try adjusted.preparedStaff(), try layer.preparedStaff())
            XCTAssertEqual(
                try adjusted.path?.prepare(in: adjusted.region),
                try layer.path?.prepare(in: layer.region))
            adjusted.notes.hoverStrength = 0
            adjusted.notes.rotationStrength = 0
            var disabled = adjusted
            disabled.notes.hover = false
            disabled.notes.rotation = false
            XCTAssertEqual(try rendered(adjusted), try rendered(disabled))
        }
    }

    func testLargeSymbolsRoundTripAndGrowInEveryMotionMode() throws {
        let device = try WSSStaticTests().device()
        var layer = WSSMusicNotesLayer(region: .init(x: 0, y: 0, width: 1200, height: 1200))
        layer.notes.count = 1
        layer.notes.symbols = [.quarter]
        layer.notes.seed = 29
        layer.notes.speed = 24
        let paths = [false, true].map { closed in
            WSSMusicNotesPath(
                enabled: true, closed: closed, direction: .forward,
                anchors: [SIMD2<Double>(0.25, 0.45), SIMD2(0.75, 0.45), SIMD2(0.5, 0.65)].map {
                    .init(position: $0, incoming: $0, outgoing: $0)
                })
        }
        var staff = WSSMusicNotesStaff()
        staff.enabled = true
        layer.staff = staff
        let phases = layer.phases(at: 0.25)
        for path in [nil, paths[0], paths[1]] {
            layer.path = path
            var previousArea = 0
            let geometry = try layer.preparedStaff()
            for size: Float in [48, 192, 256, 384, 512] {
                layer.notes.size = size
                XCTAssertEqual(try layer.preparedStaff(), geometry)
                XCTAssertEqual(layer.phases(at: 0.25), phases)
                let model = try model(layer, canvas: 1200)
                let reloaded = try WSSSceneDocumentV1.decode(data: model.encoded())
                XCTAssertEqual(reloaded, model)
                var scene = try reloaded.scene()
                var notesOnly = layer
                notesOnly.staff = nil
                scene.layers = [.musicNotes(notesOnly)]
                let resources = try WSSStaticResources(
                    scene: scene, assets: WSSStaticTests.Assets(values: [:]), device: device)
                let frame = try WSSStormLightingRenderTests().render(
                    resources, time: 0.25, width: 600, height: 600
                ).0
                let area = stride(from: 2, to: frame.count, by: 4).count { frame[$0] > 24 }
                XCTAssertGreaterThan(area, previousArea)
                previousArea = area
            }
        }
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
