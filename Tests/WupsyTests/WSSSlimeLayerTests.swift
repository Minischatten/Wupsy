import AppKit
import Metal
import SwiftUI
import XCTest
import simd

@testable import Wupsy

final class WSSSlimeLayerTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Test-Wallpaper/WSS-Slime-v1/scene.wss.json")

    private func load() throws -> WSSSceneDocumentV1 {
        try WSSSceneDocumentV1.decode(data: Data(contentsOf: Self.fixture))
    }

    private static let phaseFixture = fixture.deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("WSS-Slime-Cycles-v1/scene.wss.json")

    private func loadCycleFixture() throws -> WSSSceneDocumentV1 {
        try WSSSceneDocumentV1.decode(data: Data(contentsOf: Self.phaseFixture))
    }

    func testCycleOffsetValidationAndDeterministicLargestGap() throws {
        for (occupied, expected): ([Float], Float) in [
            ([], 0), ([0], 0.5), ([0.5, 0], 0.25), ([0.25, 0.5, 0], 0.75),
            ([0.75, 0.25], 0.5), ([0.5, 0, 0, 0.5], 0.25), ([0.25, 0.75, 0.5], 0),
        ] {
            XCTAssertEqual(WSSSlimeConfiguration.nextCycleOffset(occupied: occupied), expected)
        }
        let model = try loadCycleFixture()
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: model.encoded()), model)
        let raw = String(decoding: try Data(contentsOf: Self.phaseFixture), as: UTF8.self)
        for invalid in ["-0.01", "1", "1.1", "1e90", "null", #" "0.5" "#] {
            let json = raw.replacingOccurrences(
                of: "\"cycleOffset\": 0.5", with: "\"cycleOffset\": \(invalid)")
            XCTAssertNotEqual(json, raw)
            XCTAssertThrowsError(try WSSSceneDocumentV1.decode(data: Data(json.utf8)), invalid)
        }
        var config = WSSSlimeConfiguration()
        config.cycleOffset = .nan
        XCTAssertThrowsError(try config.validate())
        config.cycleOffset = Float(1).nextDown
        XCTAssertNoThrow(try config.validate())
    }

    func testCycleOffsetMovesWholeCycleWithoutChangingSpeed() {
        var base = WSSSlimeConfiguration()
        base.speed = 2
        var shifted = base
        shifted.cycleOffset = 0.25
        for time in [0.0, 0.75, 1.025, 1.2, 1.7, 2.625, 3.0, 3_500_001.5] {
            let reference = WSSSlimePrototype.frame(at: time + 0.875, configuration: base)
            XCTAssertEqual(WSSSlimePrototype.frame(at: time, configuration: shifted), reference)
        }
        XCTAssertEqual(
            WSSSlimePrototype.frame(at: 2.625, configuration: shifted),
            WSSSlimePrototype.frame(at: 0, configuration: base))
        XCTAssertNotEqual(
            WSSSlimePrototype.frame(at: 1.2, configuration: shifted),
            WSSSlimePrototype.frame(at: 1.2, configuration: base))
        shifted.speed = 0
        base.speed = 0
        XCTAssertEqual(
            WSSSlimePrototype.frame(at: 45, configuration: shifted),
            WSSSlimePrototype.frame(at: 0, configuration: base))
        XCTAssertEqual(shifted.cycleOffset, 0.25)
    }

    func testFourCycleOffsetsProduceDifferentMetalPixelsAtEqualSpeed() throws {
        var scene = try loadCycleFixture().scene()
        let device = try WSSStaticTests().device()
        let assets = WSSStaticTests.Assets(values: [:])
        let renderer = WSSCloudsTests()
        func render() throws -> Data {
            let resources = try WSSStaticResources(scene: scene, assets: assets, device: device)
            return try renderer.render(
                resources, time: 2.2, width: scene.width, height: scene.height
            ).0
        }
        let staggered = try render()
        XCTAssertEqual(try render(), staggered)
        for index in scene.layers.indices {
            guard case .slime(var layer) = scene.layers[index] else {
                return XCTFail("Missing Slime")
            }
            XCTAssertEqual(layer.configuration.speed, 1)
            layer.configuration.cycleOffset = 0
            scene.layers[index] = .slime(layer)
        }
        let synchronized = try render()
        for index in 0..<4 {
            let start = 64 + index * 160
            let differs = (65..<315).contains { row in
                let pixels = (row * scene.width + start) * 4
                return staggered[pixels..<pixels + 64 * 4] != synchronized[pixels..<pixels + 64 * 4]
            }
            XCTAssertEqual(differs, index > 0)
        }
    }

    private static let fallFixture = fixture.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("WSS-Slime-Fall-Distance-v1/scene.wss.json")

    func testFallDistanceLimitUsesSceneDirectionIndependentlyOfTransform() throws {
        let canvas = try WSSSceneDocumentV1.decode(data: Data(contentsOf: Self.fallFixture)).canvas
        var layer = WSSSlimeLayer(transform: .init(center: [0, 0], size: [80, 16]))
        XCTAssertEqual(layer.distanceInspectorLimit(canvas: canvas), 1440)
        layer.configuration.direction = 90
        XCTAssertEqual(layer.distanceInspectorLimit(canvas: canvas), 480, accuracy: 1)
        layer.configuration.direction = 135
        XCTAssertEqual(layer.distanceInspectorLimit(canvas: canvas), 1358, accuracy: 1)
        layer.transform.rotation = 0.9
        layer.transform.size = [24, 96]
        XCTAssertEqual(layer.distanceInspectorLimit(canvas: canvas), 1358, accuracy: 1)
        let landscape = try JSONDecoder().decode(
            WSSSceneDocumentV1.Canvas.self, from: Data(#"{"width":1920,"height":1080}"#.utf8))
        layer.configuration.direction = 90
        XCTAssertEqual(layer.distanceInspectorLimit(canvas: landscape), 1920, accuracy: 1)
        let small = try JSONDecoder().decode(
            WSSSceneDocumentV1.Canvas.self, from: Data(#"{"width":240,"height":180}"#.utf8))
        XCTAssertEqual(layer.distanceInspectorLimit(canvas: small), 450)
        layer.configuration.distance = 5000
        XCTAssertEqual(layer.distanceInspectorLimit(canvas: canvas), 5000)
        XCTAssertNoThrow(try layer.configuration.validate())
        layer.configuration.distance = WSSSlimeLayer.maximumDistance + 1
        XCTAssertThrowsError(try layer.configuration.validate())
    }

    private static let fallPixelsFixture = fallFixture.deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(
            "WSS-Slime-Fall-Pixels-v1/scene.wss.json")

    private static let spatialFixture = fallFixture.deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("WSS-Slime-Spatial-v1/scene.wss.json")

    func testFallDistanceInScenePixelsAcrossTransforms() throws {
        let model = try WSSSceneDocumentV1.decode(data: Data(contentsOf: Self.spatialFixture))
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: model.encoded()), model)
        let slime = WSSSlimePrototype.self
        for size: SIMD2<Float> in [[20, 16], [32, 32], [48, 64]] {
            for direction: Float in [0, 45, 90, 180, 315] {
                let transform = WSSImageTransform(center: [240, 720], size: size, rotation: 0.8)
                let drawing = slime.Placement(transform, direction: direction)
                for (length, width, dropSize): (Float, Float, Float) in [
                    (65, 11, 12), (235, 26, 30),
                ] {
                    for distance: Float in [24, length, 500, 1250] {
                        var configuration = WSSSlimeConfiguration()
                        configuration.distance = distance
                        configuration.length = length
                        configuration.width = width
                        configuration.dropSize = dropSize
                        func frame(_ time: Double) -> WSSSlimePrototype.Frame {
                            slime.frame(
                                at: time, configuration: configuration,
                                anchorTilt: drawing.anchorTilt,
                                longitudinalScale: drawing.longitudinalScale)
                        }
                        let start = frame(slime.release)
                        let travel = distance - (start.drop.y - slime.anchor.y)
                        XCTAssertGreaterThan(travel, 0)
                        let fallTime = sqrt(Double(travel / (96 * drawing.longitudinalScale)))
                        let end = frame(slime.release + fallTime + 0.01)
                        let displacement =
                            drawing.axisX * (end.drop.x - slime.anchor.x)
                            + drawing.axisY * (end.drop.y - slime.anchor.y)
                        XCTAssertEqual(
                            simd_dot(displacement, drawing.axisY), distance, accuracy: 0.001)
                        XCTAssertEqual(end.drop.x, start.drop.x)
                        XCTAssertEqual(end.visibility, 0, accuracy: 0.001)
                        XCTAssertGreaterThan(frame(slime.release + fallTime * 0.5).visibility, 0.9)
                        XCTAssertEqual(
                            frame(slime.release + 0.0001).drop.y, start.drop.y, accuracy: 0.001)
                        XCTAssertEqual(start.stem[0].z * 2, width, accuracy: 0.001)
                        XCTAssertEqual(start.drop.z * 2, dropSize, accuracy: 0.001)
                        let arc = zip(start.stem, start.stem.dropFirst()).reduce(Float.zero) {
                            $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)
                        }
                        XCTAssertLessThanOrEqual(arc, length + 0.001)
                        if distance >= 500 { XCTAssertEqual(arc, length, accuracy: 0.001) }
                    }
                }
            }
        }
    }

    func testMetalDropPositionsScaleWithOutputProjection() throws {
        let model = try WSSSceneDocumentV1.decode(data: Data(contentsOf: Self.fallPixelsFixture))
        let scene = try model.scene()
        let resources = try WSSStaticResources(
            scene: scene, assets: WSSStaticTests.Assets(values: [:]),
            device: WSSStaticTests().device())
        func dropPositions(outputScale: Int) throws -> [Double] {
            let width = scene.width * outputScale / 2
            let height = scene.height * outputScale / 2
            let pixels = try WSSCloudsTests().render(
                resources, time: 5.0, width: width, height: height, clearAlpha: 0
            ).0
            return try [90, 240, 390].map { center in
                let x = (center + 6) * outputScale / 2
                let rows = (140 * outputScale / 2..<900 * outputScale / 2).filter { row in
                    pixels[(row * width + x) * 4 + 3] > 100
                }
                let first = try XCTUnwrap(rows.first)
                let last = try XCTUnwrap(rows.last)
                return Double(first + last) / Double(outputScale)
            }
        }
        let reduced = try dropPositions(outputScale: 1)
        let native = try dropPositions(outputScale: 2)
        XCTAssertLessThan(native[0], native[1])
        XCTAssertLessThan(native[1], native[2])
        for (lhs, rhs) in zip(reduced, native) {
            XCTAssertEqual(lhs, rhs, accuracy: 2)
        }
    }

    func testMetalLongFallsReachNearFloorAfterOriginalCycle() throws {
        let model = try WSSSceneDocumentV1.decode(data: Data(contentsOf: Self.fallFixture))
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: model.encoded()), model)
        let scene = try model.scene()
        let resources = try WSSStaticResources(
            scene: scene, assets: WSSStaticTests.Assets(values: [:]),
            device: WSSStaticTests().device())
        let pixels = try WSSCloudsTests().render(
            resources, time: 7.25, width: scene.width, height: scene.height, clearAlpha: 0
        ).0
        func maxAlpha(_ x: Range<Int>) -> UInt8 {
            (1180..<1400).flatMap { row in
                x.map { pixels[(row * scene.width + $0) * 4 + 3] }
            }.max() ?? 0
        }
        XCTAssertEqual(maxAlpha(68..<112), 0)
        XCTAssertGreaterThan(maxAlpha(218..<262), 100)
        XCTAssertGreaterThan(maxAlpha(368..<412), 100)
    }

    func testFixtureRoundTripAndStrictValidation() throws {
        let data = try Data(contentsOf: Self.fixture)
        let model = try load()
        XCTAssertEqual(model.layers.count, 2)
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: model.encoded()), model)
        XCTAssertTrue(model.referencedPaths.isEmpty)
        let raw = String(decoding: data, as: UTF8.self)
        for (old, invalid) in [
            ("\"width\": 18,", "\"width\": 37,"),
            ("\"width\": 18,", "\"width\": null,"),
            ("\"width\": 18,", "\"width\": 1e99,"),
            ("\"width\": 18,", "\"width\": 18, \"viscosity\": 2,"),
            ("\"width\": 18,", ""),
            ("\"blue\": 0.15", "\"blue\": 0.15, \"alpha\": 1"),
            ("\"size\": [32, 32]", "\"size\": [32, 32], \"scale\": [1, 5]"),
            ("\"name\": \"Green filament\",", "\"name\": \"Green filament\", \"mask\": \"a.png\","),
        ] {
            XCTAssertTrue(raw.contains(old))
            XCTAssertThrowsError(
                try WSSSceneDocumentV1.decode(
                    data: Data(raw.replacingOccurrences(of: old, with: invalid).utf8)))
        }
        var scene = try model.scene()
        guard case .slime(var layer) = scene.layers[0] else { return XCTFail("Missing Slime") }
        layer.visible = false
        scene.layers = Array(repeating: .slime(layer), count: WSSSlimeLayer.maximumLayers + 1)
        XCTAssertThrowsError(try scene.validate())
        layer.configuration.distance = .nan
        scene.layers = [.slime(layer)]
        XCTAssertThrowsError(try scene.validate())
    }

    func testReflectionColorDefaultsRoundTripsAndRejectsInvalidComponents() throws {
        let model = try load()
        let raw = String(decoding: try model.encoded(), as: UTF8.self)
        XCTAssertFalse(raw.contains("reflectionColor"))
        func decode(_ value: String) throws -> WSSSceneDocumentV1 {
            let fixture = String(decoding: try Data(contentsOf: Self.fixture), as: UTF8.self)
            let json = fixture.replacingOccurrences(
                of: "\"opacity\": 1,", with: "\"reflectionColor\": \(value), \"opacity\": 1,")
            return try WSSSceneDocumentV1.decode(data: Data(json.utf8))
        }
        let explicit = try decode(#"{"red":0.87,"green":0.97,"blue":0.93}"#)
        XCTAssertEqual(model, explicit)
        XCTAssertEqual(try model.encoded(), try explicit.encoded())
        let custom = try decode(#"{"red":0,"green":0.22,"blue":1}"#)
        XCTAssertNotEqual(custom, model)
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: custom.encoded()), custom)
        for invalid in [
            "null", #"{"red":0,"green":0}"#, #"{"red":-0.01,"green":0,"blue":0}"#,
            #"{"red":0,"green":1.01,"blue":0}"#, #"{"red":0,"green":0,"blue":1e99}"#,
            #"{"red":0,"green":0,"blue":null}"#, #"{"red":0,"green":0,"blue":0,"alpha":1}"#,
        ] {
            XCTAssertThrowsError(try decode(invalid), invalid)
        }
        var config = WSSSlimeConfiguration()
        config.reflectionColor.blue = .nan
        XCTAssertThrowsError(try config.validate())
        XCTAssertThrowsError(try JSONEncoder().encode(config))
    }

    func testMetalReflectionColorAndIndependentMaterialControls() throws {
        var scene = try load().scene()
        guard case .slime(var layer) = scene.layers[0] else { return XCTFail("Missing Slime") }
        let device = try WSSStaticTests().device()
        let assets = WSSStaticTests.Assets(values: [:])
        let renderer = WSSCloudsTests()

        func render() throws -> Data {
            scene.layers = [.slime(layer)]
            let resources = try WSSStaticResources(scene: scene, assets: assets, device: device)
            return try renderer.render(resources, time: 4.4, width: 480, height: 360, clearAlpha: 0)
                .0
        }

        layer.configuration.color = .init(red: 0, green: 0, blue: 0)
        let defaultHighlights = try render()
        layer.configuration.reflectionColor = .init(red: 0, green: 0, blue: 0)
        let black = try render()
        XCTAssertGreaterThan(defaultHighlights.max() ?? 0, 0)
        XCTAssertNotEqual(defaultHighlights, black)
        for i in stride(from: 0, to: black.count, by: 4) {
            XCTAssertEqual(black[i] | black[i + 1] | black[i + 2], 0)
            XCTAssertEqual(black[i + 3], defaultHighlights[i + 3])
        }

        layer.configuration.color = .init(red: 0.02, green: 0.02, blue: 0.02)
        layer.configuration.reflectionColor = .init(red: 0.08, green: 0.08, blue: 0.08)
        let dark = try render()
        layer.configuration.color = .init(red: 0.35, green: 0.35, blue: 0.35)
        let gray = try render()
        XCTAssertNotEqual(dark, gray)
        var peakDark: UInt8 = 0
        for i in stride(from: 0, to: gray.count, by: 4) {
            peakDark = max(peakDark, dark[i])
            XCTAssertEqual(gray[i], gray[i + 1])
            XCTAssertEqual(gray[i], gray[i + 2])
            XCTAssertEqual(gray[i + 3], dark[i + 3])
        }
        XCTAssertGreaterThan(peakDark, 0)
        XCTAssertLessThan(peakDark, 20)

        layer.configuration.reflectionColor = .init(red: 1, green: 0.2, blue: 0)
        let colored = try render()
        XCTAssertTrue(
            stride(from: 0, to: colored.count, by: 4).contains {
                Int(colored[$0 + 2]) - Int(colored[$0]) > 25
            })
        layer.configuration.opacity = 0.5
        let halfOpacity = try render()
        XCTAssertTrue(
            zip(colored, halfOpacity).allSatisfy {
                abs(Int($0) - 2 * Int($1)) <= 1
            })
        layer.configuration.gloss = 0
        let noGloss = try render()
        XCTAssertNotEqual(noGloss, halfOpacity)
        layer.configuration.reflectionColor = .init(red: 0, green: 0, blue: 1)
        XCTAssertEqual(try render(), noGloss)
    }

    func testParameterizedMotionAndReleaseContinuity() {
        var config = WSSSlimeConfiguration()
        config.speed = 2
        config.length = 180
        config.width = 27
        config.dropSize = 26.6
        config.direction = 90
        config.distance = 100
        let pinch = WSSSlimePrototype.release / 2
        let at = WSSSlimePrototype.frame(at: pinch, configuration: config)
        let after = WSSSlimePrototype.frame(at: pinch + 0.0001, configuration: config)
        XCTAssertEqual(at.stem[0].z, 13.5)
        XCTAssertLessThan(at.stem.last!.y, WSSSlimePrototype.anchor.y + 100)
        for index in 0..<4 {
            XCTAssertEqual(at.drop[index], after.drop[index], accuracy: 0.001)
        }
        let fallen = WSSSlimePrototype.frame(at: pinch + 0.7, configuration: config)
        let placement = WSSSlimePrototype.Placement(
            .init(center: .zero, size: SIMD2(32, 32)), direction: config.direction)
        XCTAssertEqual(fallen.drop.x, at.drop.x)
        XCTAssertEqual(
            (placement.axisY * (fallen.drop.y - WSSSlimePrototype.anchor.y)).x, 100, accuracy: 0.001
        )
        XCTAssertEqual(fallen.visibility, 0)
        XCTAssertEqual(
            WSSSlimePrototype.frame(at: 2.25, configuration: config),
            WSSSlimePrototype.frame(at: 3_500_002.25, configuration: config))
    }

    @MainActor func testEditorTransformsIndependentLayersUndoAndSave() async throws {
        let helper = WSSMaskEditingTests()
        try await helper.setUp()
        do {
            try await exerciseEditor(helper.doc)
        } catch {
            try await helper.tearDown()
            throw error
        }
        try await helper.tearDown()
    }

    @MainActor func testAuthoringDistributesAndCopiesOffsetAndPreservesPreparedResources()
        async throws
    {
        let helper = WSSMaskEditingTests()
        try await helper.setUp()
        do {
            try await exerciseCycleEditor(helper.doc)
        } catch {
            try await helper.tearDown()
            throw error
        }
        try await helper.tearDown()
    }

    @MainActor private func exerciseCycleEditor(_ doc: WSSEditorDocument) async throws {
        var ids: [WSSLayerID] = []
        for expected: Float in [0, 0.5, 0.25, 0.75] {
            try doc.addSlime()
            let id = try XCTUnwrap(doc.selection?.layer)
            ids.append(id)
            XCTAssertEqual(doc.slimeLayer(id)?.configuration.cycleOffset, expected)
        }
        try doc.changeSlime(ids[1], name: "Spatial dimensions") {
            $0.configuration.distance = 500
            $0.configuration.length = 145
            $0.configuration.width = 22
            $0.configuration.dropSize = 31
        }
        try await doc.duplicateLayer(ids[1])
        let copy = try XCTUnwrap(doc.selection?.layer)
        XCTAssertNotEqual(copy, ids[1])
        XCTAssertEqual(doc.slimeLayer(copy)?.configuration, doc.slimeLayer(ids[1])?.configuration)
        XCTAssertEqual(doc.slimeLayer(copy)?.configuration.cycleOffset, 0.5)
        await doc.waitForPreview()
        let prepared = doc.previewResources
        try await setCycleOffsetFromInspector(37, document: doc, layer: copy)
        XCTAssertEqual(doc.slimeLayer(copy)?.configuration.cycleOffset, 0.37)
        XCTAssertEqual(
            ids.compactMap { doc.slimeLayer($0)?.configuration.cycleOffset }, [0, 0.5, 0.25, 0.75])
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        XCTAssertTrue(doc.previewResources.sharesPreparedResources(with: prepared))
        doc.undoManager.undo()
        XCTAssertEqual(doc.slimeLayer(copy)?.configuration.cycleOffset, 0.5)
        doc.undoManager.redo()
        XCTAssertEqual(doc.slimeLayer(copy)?.configuration.cycleOffset, 0.37)
        try doc.moveLayer(copy, to: 0)
        doc.select(.layer(ids[2]))
        try doc.deleteLayer(ids[2])
        XCTAssertEqual(doc.slimeLayer(ids[3])?.configuration.cycleOffset, 0.75)
        XCTAssertEqual(doc.slimeLayer(copy)?.configuration.cycleOffset, 0.37)
        let model = doc.state.workingModel
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let loaded = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(loaded.document, model)
    }

    @MainActor private func setCycleOffsetFromInspector(
        _ percent: Int, document: WSSEditorDocument, layer: WSSLayerID
    ) async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(
            rootView: WSSSlimeParameterControls(document: document, layer: layer))
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }

        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField,
                field.accessibilityLabel() == WSSSlimeText.text("cycleOffset")
            {
                return field
            }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        hosting.layoutSubtreeIfNeeded()
        for _ in 0..<100 where find(hosting) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let field = try XCTUnwrap(find(hosting))
        XCTAssertEqual(field.stringValue, "50")
        let coordinator = try XCTUnwrap(field.delegate as? WSSParameterTextField.Coordinator)
        field.stringValue = "100"
        XCTAssertFalse(coordinator.accept(field))
        field.stringValue = String(percent)
        XCTAssertTrue(coordinator.accept(field))
    }

    @MainActor private func exerciseEditor(_ doc: WSSEditorDocument) async throws {
        try doc.addSlime()
        let first = try XCTUnwrap(doc.selection?.layer)
        let original = try XCTUnwrap(doc.slimeLayer(first))
        XCTAssertEqual(doc.transformModeLayer, first)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        let resources = doc.previewResources

        doc.undoManager.removeAllActions()
        XCTAssertTrue(doc.beginCanvasTransform(first, kind: .move))
        var placement = original.transform
        placement.center[0] += 18
        placement.center[1] -= 6
        try doc.updateCanvasTransform(placement)
        doc.endCanvasTransform()
        XCTAssertEqual(doc.slimeLayer(first)?.transform, placement)
        doc.undoManager.undo()
        XCTAssertEqual(doc.slimeLayer(first), original)
        doc.undoManager.redo()
        XCTAssertEqual(doc.slimeLayer(first)?.transform, placement)
        XCTAssertTrue(doc.beginCanvasTransform(first, kind: .rotate))
        placement.rotation = 0.3
        try doc.updateCanvasTransform(placement)
        doc.endCanvasTransform()

        try doc.changeSlime(first, name: "Material") {
            $0.configuration.gloss = 0.25
            $0.configuration.color = .init(red: 0.9, green: 0.12, blue: 0.14)
            $0.configuration.speed = 1.25
            $0.transform.scale = [0.75, 1.5]
        }
        let oldMaterial = try XCTUnwrap(doc.slimeLayer(first))
        let firstReflection = WSSFogConfiguration.Color(red: 0.18, green: 0.22, blue: 0.1)
        try await setReflectionFromInspector(firstReflection, document: doc, layer: first)
        doc.undoManager.undo()
        XCTAssertEqual(doc.slimeLayer(first), oldMaterial)
        doc.undoManager.redo()
        var newMaterial = oldMaterial
        newMaterial.configuration.reflectionColor = firstReflection
        XCTAssertEqual(doc.slimeLayer(first), newMaterial)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        XCTAssertTrue(doc.previewResources.sharesPreparedResources(with: resources))
        guard case .slime(let live) = doc.previewResources.scene.layers.last else {
            return XCTFail("Missing Slime preview")
        }
        XCTAssertEqual(live, doc.slimeLayer(first))

        try doc.addSlime()
        let second = try XCTUnwrap(doc.selection?.layer)
        XCTAssertNotEqual(first, second)
        var next = original
        next.configuration.cycleOffset = 0.5
        XCTAssertEqual(doc.slimeLayer(second), next)
        try doc.renameLayer(first, to: "Red filament")
        try doc.moveLayer(first, to: 0)
        XCTAssertEqual(doc.identity.layers.first?.id, first)
        try doc.setVisibility(false, layer: first)
        XCTAssertEqual(doc.slimeLayer(first)?.visible, false)
        doc.undoManager.undo()
        XCTAssertEqual(doc.slimeLayer(first)?.visible, true)
        doc.undoManager.redo()
        XCTAssertEqual(doc.slimeLayer(first)?.visible, false)
        XCTAssertEqual(doc.slimeLayer(second), next)

        let secondReflection = WSSFogConfiguration.Color(red: 0.2, green: 0.5, blue: 0.9)
        try doc.changeSlime(second, name: "Reflection color") {
            $0.configuration.reflectionColor = secondReflection
        }
        XCTAssertEqual(doc.slimeLayer(first)?.configuration.reflectionColor, firstReflection)
        XCTAssertEqual(doc.slimeLayer(second)?.configuration.reflectionColor, secondReflection)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        guard case .slime(let secondLive) = doc.previewResources.scene.layers.last else {
            return XCTFail("Missing second Slime preview")
        }
        XCTAssertEqual(secondLive.configuration.reflectionColor, secondReflection)
        let beforeSpatial = doc.slimeLayer(second)?.configuration
        try doc.changeSlime(second, name: "Spatial dimensions") {
            $0.configuration.distance = 1250
            $0.configuration.length = 180
            $0.configuration.width = 27
            $0.configuration.dropSize = 33
        }
        let afterSpatial = doc.slimeLayer(second)?.configuration
        doc.undoManager.undo()
        XCTAssertEqual(doc.slimeLayer(second)?.configuration, beforeSpatial)
        doc.undoManager.redo()
        XCTAssertEqual(doc.slimeLayer(second)?.configuration, afterSpatial)

        let snapshot = doc.state.workingModel
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, snapshot)
    }

    @MainActor private func setReflectionFromInspector(
        _ color: WSSFogConfiguration.Color, document: WSSEditorDocument, layer: WSSLayerID
    ) async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 680),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(
            rootView: WSSSlimeParameterControls(document: document, layer: layer))
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }

        func colorWells(in view: NSView) -> [NSColorWell] {
            if let well = view as? NSColorWell { return [well] }
            return view.subviews.flatMap { colorWells(in: $0) }
        }

        hosting.layoutSubtreeIfNeeded()
        for _ in 0..<100 where colorWells(in: hosting).count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let wells = colorWells(in: hosting)
        XCTAssertEqual(wells.count, 2)
        XCTAssertTrue(wells.contains { $0.accessibilityLabel() == WSSSlimeText.text("color") })
        let reflectionWell = try XCTUnwrap(
            wells.first { $0.accessibilityLabel() == WSSSlimeText.text("reflectionColor") })
        reflectionWell.color = NSColor(
            srgbRed: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue),
            alpha: 1)
        XCTAssertTrue(reflectionWell.sendAction(reflectionWell.action, to: reflectionWell.target))
    }

    func testMetalTransformsStackingAndPerformanceCounts() throws {
        let device = try WSSStaticTests().device()
        let id = WSSAssetID(value: "foreground")
        let assets = WSSStaticTests.Assets(values: [
            id: .init(width: 1, height: 1, payload: .rgba8(Data([255, 0, 0, 255])))
        ])
        var scene = try load().scene()
        let image = WSSSceneLayer.image(
            .init(asset: id, transform: .init(center: SIMD2(135, 277), size: SIMD2(32, 24))))
        let left = (83 * 480 + 135) * 4
        let right = (92 * 480 + 335) * 4
        let renderer = WSSCloudsTests()

        func render(_ scene: WSSScene, time: Double = 3.2) throws -> Data {
            let resources = try WSSStaticResources(scene: scene, assets: assets, device: device)
            XCTAssertEqual(resources.performanceContentCounts.visibleLayers, scene.layers.count)
            XCTAssertEqual(resources.performanceContentCounts.effectiveEffects, 2)
            return try renderer.render(resources, time: time, width: 480, height: 360).0
        }

        let slime = try render(scene)
        XCTAssertGreaterThan(slime[left + 1], 0)
        XCTAssertGreaterThan(slime[right + 1], 0)
        XCTAssertNotEqual(slime[left..<left + 3], slime[right..<right + 3])
        XCTAssertNotEqual(slime, try render(scene, time: 0))
        XCTAssertEqual(slime, try render(scene))
        scene.layers.append(image)
        let above = try render(scene)
        XCTAssertEqual(Array(above[left..<left + 4]), [0, 0, 255, 255])
        XCTAssertEqual(above[right..<right + 4], slime[right..<right + 4])
        scene.layers.removeLast()
        scene.layers.insert(image, at: 0)
        let below = try render(scene)
        XCTAssertGreaterThan(below[left + 1], 0)
        XCTAssertLessThan(below[left + 2], 255)
        XCTAssertEqual(below[right..<right + 4], slime[right..<right + 4])
    }

    func testMetalAlignmentFixtureDrawsRotatedPadsAndContinuousFilaments() throws {
        let manifest = Self.fixture.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WSS-Slime-Alignment-v1/scene.wss.json")
        let doc = try WSSSceneDocumentV1.decode(data: Data(contentsOf: manifest))
        var scene = try doc.scene()
        XCTAssertEqual(scene.layers.count, 6)
        let device = try WSSStaticTests().device()
        let renderer = WSSCloudsTests()

        let full = try WSSStaticResources(
            scene: scene, assets: doc.assetSource(root: manifest.deletingLastPathComponent()),
            device: device)
        XCTAssertNotEqual(
            try renderer.render(full, width: scene.width, height: scene.height).0,
            try renderer.render(full, time: 3.2, width: scene.width, height: scene.height).0)

        scene.layers.removeFirst()
        let slimes = try WSSStaticResources(
            scene: scene, assets: WSSStaticTests.Assets(values: [:]), device: device)
        let still = try renderer.render(
            slimes, width: scene.width, height: scene.height, clearAlpha: 0
        ).0
        let growing = try renderer.render(
            slimes, time: 3.2, width: scene.width, height: scene.height, clearAlpha: 0
        ).0
        func alpha(_ bytes: Data, _ x: Int, _ y: Int) -> UInt8 {
            bytes[((scene.height - 1 - y) * scene.width + x) * 4 + 3]
        }
        XCTAssertGreaterThan(alpha(still, 102, 355), 100)
        XCTAssertEqual(alpha(still, 90, 367), 0)
        XCTAssertEqual(alpha(still, 580, 355), 0)
        XCTAssertGreaterThan(alpha(still, 592, 367), 100)
        for node in scene.layers {
            guard case .slime(let layer) = node else { return XCTFail("Missing Slime") }
            let transform = try layer.nativeTransform()
            let drawing = WSSSlimePrototype.Placement(
                transform, direction: layer.configuration.direction)
            let frame = WSSSlimePrototype.frame(
                at: 3.2, configuration: layer.configuration, anchorTilt: drawing.anchorTilt)
            for sample in frame.stem.prefix(7) {
                let local = SIMD2(sample.x, sample.y) - WSSSlimePrototype.anchor
                let point = transform.center + drawing.axisX * local.x + drawing.axisY * local.y
                XCTAssertGreaterThan(alpha(growing, Int(point.x), Int(point.y)), 90)
            }
        }
    }

    @MainActor func testIndependentPlayersPauseAndResume() async throws {
        let resources = try WSSStaticResources(
            scene: WSSSceneDocumentV1.decode(data: Data(contentsOf: Self.fallFixture)).scene(),
            assets: WSSStaticTests.Assets(values: [:]),
            device: WSSStaticTests().device())
        func player(offset: Double) -> WSSStaticPlayer {
            WSSStaticPlayer(
                resources: resources, size: CGSize(width: 160, height: 120), scale: 1,
                maxDimension: 160, fps: 30, resolution: .standard, offset: offset,
                onError: { XCTFail($0) })
        }
        let first = player(offset: 7.2)
        let second = player(offset: 3)
        defer {
            first.stop()
            second.stop()
        }
        first.play()
        second.play()
        first.pause()
        let paused = first.elapsed
        let otherStart = second.elapsed
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(first.elapsed, paused)
        XCTAssertGreaterThan(second.elapsed, otherStart)
        first.play()
        XCTAssertEqual(first.elapsed, paused, accuracy: 0.05)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertGreaterThan(first.elapsed, paused)
    }

    @MainActor func testSlimePresentsOnScreen() async throws {
        let strict = ProcessInfo.processInfo.environment["WUPSY_REQUIRE_METAL_PRESENTATION"] == "1"
        guard let screen = NSScreen.main else {
            if strict { return XCTFail("No physical screen available") }
            throw XCTSkip("No screen available")
        }
        let model = try WSSSceneDocumentV1.decode(data: Data(contentsOf: Self.spatialFixture))
        switch await MetalPresentationProbe.run(
            on: screen, scene: try model.scene(), sceneTime: 5.2)
        {
        case .confirmed: break
        case .failed(let reason): XCTFail(reason)
        case .notConfirmed:
            if strict {
                XCTFail("Slime Metal presentation was not confirmed")
            } else {
                throw XCTSkip("Slime Metal presentation was not confirmed")
            }
        }
    }
}
