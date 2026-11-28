import AppKit
import SwiftUI
import XCTest

@testable import Wupsy

final class WSSSlimeFixedIntervalTests: XCTestCase {
    private func layer(_ mode: WSSSlimeConfiguration.Mode = .directDrop) -> WSSSlimeLayer {
        var configuration = WSSSlimeConfiguration()
        configuration.mode = mode
        configuration.timing = .fixedInterval
        configuration.speed = 2
        configuration.dropInterval = mode == .directDrop ? 0.6 : 2.5
        configuration.distance = 940
        return .init(
            transform: .init(center: [150, 1100], size: [32, 16]),
            configuration: configuration)
    }

    private func drawing(_ layer: WSSSlimeLayer) throws -> WSSSlimePrototype.Placement {
        .init(try layer.nativeTransform(), direction: layer.configuration.direction)
    }

    private func frames(_ layer: WSSSlimeLayer, _ time: Double) throws
        -> WSSSlimePrototype.FixedFrames
    {
        WSSSlimePrototype.fixedFrames(
            at: time, configuration: layer.configuration, drawing: try drawing(layer))
    }

    func testOverlapAndNewFilamentAfterRetraction() throws {
        let direct = layer()
        let group = try frames(direct, 1.85)
        XCTAssertGreaterThanOrEqual(group.previousDrops.count, 2)
        XCTAssertGreaterThan(group.source.visibility, 0)
        XCTAssertTrue(group.previousDrops.allSatisfy { $0.stem.isEmpty })
        XCTAssertEqual(try frames(direct, 0).previousDrops.count, 0)

        let hanging = layer(.hangingThread)
        let rest = try frames(hanging, 2.5)
        let regrowth = try frames(hanging, 3.25)
        XCTAssertGreaterThan(regrowth.previousDrops.count, 0)
        XCTAssertGreaterThan(regrowth.source.stem.last!.y, rest.source.stem.last!.y)
        let later = try frames(hanging, 4.6)
        XCTAssertGreaterThan(later.source.visibility, 0)
        XCTAssertGreaterThan(later.previousDrops.count, 0)
    }

    func testEarlierDropsActuallyRenderInSeparateLocalAreas() throws {
        let source = layer()
        let device = try WSSStaticTests().device()
        let scene = WSSScene(
            width: 320, height: 1200, background: [0.2, 0.25, 0.3],
            layers: [.slime(source)])
        let resources = try WSSStaticResources(
            scene: scene, assets: WSSStaticTests.Assets(values: [:]), device: device)
        let renderer = WSSCloudsTests()
        let time = 1.85
        let result = try renderer.render(resources, time: time, width: 320, height: 1200).0
        let resting = try renderer.render(resources, time: 0, width: 320, height: 1200).0
        let group = try frames(source, time)
        let centers = group.previousDrops.map {
            Int((100 + $0.drop.y - WSSSlimePrototype.anchor.y).rounded())
        }

        func pixel(_ data: Data, row: Int) -> Data {
            let offset = (row * 320 + 150) * 4
            return data[offset..<offset + 4]
        }
        for row in centers {
            XCTAssertNotEqual(pixel(result, row: row), pixel(resting, row: row))
        }
        let gap = (centers[0] + centers[1]) / 2
        XCTAssertEqual(pixel(result, row: gap), pixel(resting, row: gap))
    }

    func testDropPositionContinuesWhenNewCycleStarts() throws {
        for mode in WSSSlimeConfiguration.Mode.allCases {
            let source = layer(mode)
            let interval = Double(source.configuration.dropInterval)
            let before = try frames(source, interval - 0.00001).source
            let after = try XCTUnwrap(try frames(source, interval + 0.00001).previousDrops.last)
            XCTAssertGreaterThan(before.visibility, 0)
            for coordinate in 0..<4 {
                XCTAssertEqual(before.drop[coordinate], after.drop[coordinate], accuracy: 0.005)
            }
            XCTAssertEqual(before.visibility, after.visibility, accuracy: 0.0001)
        }
    }

    func testFallIsIndependentOfIntervalAndGrowthSpeed() throws {
        for mode in WSSSlimeConfiguration.Mode.allCases {
            var source = layer(mode)
            let draw = try drawing(source)
            let fixed = WSSSlimePrototype.FixedTiming(
                configuration: source.configuration, drawing: draw)
            let reference = try frames(source, fixed.releaseTime + 0.1).source
            source.configuration.dropInterval = 12
            XCTAssertEqual(try frames(source, fixed.releaseTime + 0.1).source, reference)
            source.configuration.speed = 1.25
            let slower = WSSSlimePrototype.FixedTiming(
                configuration: source.configuration, drawing: draw)
            let after = try frames(source, slower.releaseTime + 0.1).source
            XCTAssertEqual(after.drop, reference.drop)
            XCTAssertEqual(after.visibility, reference.visibility)

            source.configuration.distance = 24
            let short = WSSSlimePrototype.FixedTiming(
                configuration: source.configuration, drawing: draw)
            let endpoint = try frames(source, short.releaseTime + short.fallDuration).source
            XCTAssertEqual(endpoint.visibility, 0)
            XCTAssertEqual(endpoint.drop.y - WSSSlimePrototype.anchor.y, 24, accuracy: 0.001)
        }
    }

    func testBudgetLimitsAndMinimumAndRest() throws {
        var source = layer()
        source.transform.size[1] = 4
        source.configuration.distance = WSSSlimeLayer.maximumDistance
        let transform = try source.nativeTransform()
        let timing = source.fixedTiming(transform: transform)
        source.configuration.dropInterval = timing.minimumInterval
        XCTAssertEqual(try source.fallingCapacity(transform: transform), 8)
        let scene = WSSScene(
            width: 320, height: 1200, layers: Array(repeating: .slime(source), count: 8))
        XCTAssertNoThrow(try scene.validate())
        var full = scene
        full.layers.append(.slime(layer()))
        XCTAssertThrowsError(try full.validate()) {
            guard case WSSSlimeTimingError.sceneCapacity = $0 else { return XCTFail("\($0)") }
        }
        source.configuration.dropInterval = timing.minimumInterval - 0.002
        XCTAssertThrowsError(try source.fallingCapacity(transform: transform))
        source.configuration.speed = 0
        source.configuration.cycleOffset = 0.9
        XCTAssertEqual(try source.fallingCapacity(transform: transform), 0)
        XCTAssertEqual(try frames(source, 1e20).previousDrops.count, 0)
        XCTAssertEqual(try frames(source, 1e20).source.visibility, 0)
    }

    func testOffsetAndDirectAccessWithoutFrameHistory() throws {
        var source = layer()
        source.configuration.dropInterval = 1
        let reference = try frames(source, 8.875)
        _ = try frames(source, 1e20)
        _ = try frames(source, 0)
        let repeated = try frames(source, 8.875)
        XCTAssertEqual(repeated.source, reference.source)
        XCTAssertEqual(repeated.previousDrops, reference.previousDrops)
        let distant = try frames(source, 1e12 + 0.875)
        XCTAssertEqual(distant.source, reference.source)
        XCTAssertEqual(distant.previousDrops, reference.previousDrops)
        source.configuration.cycleOffset = 0.25
        let shifted = try frames(source, 8.625)
        XCTAssertEqual(shifted.source, reference.source)
        XCTAssertEqual(shifted.previousDrops, reference.previousDrops)
        XCTAssertTrue(try frames(source, 0).previousDrops.isEmpty)
    }

    func testCodecAndBothInspectorLanguages() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let legacy = WSSSlimeConfiguration()
        let data = try encoder.encode(legacy)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["timing"])
        XCTAssertNil(json["dropInterval"])
        let fixed = layer().configuration
        XCTAssertEqual(
            try decoder.decode(WSSSlimeConfiguration.self, from: encoder.encode(fixed)), fixed)
        var automatic = fixed
        automatic.timing = .automaticCycle
        XCTAssertEqual(
            try decoder.decode(WSSSlimeConfiguration.self, from: encoder.encode(automatic)),
            automatic)
        for (language, labels) in [
            ("de", ["Automatischer Zyklus", "Festes Tropfenintervall", "Tropfenintervall (s)"]),
            ("en", ["Automatic Cycle", "Fixed Drop Interval", "Drop Interval (s)"]),
        ] {
            for (key, label) in zip(["automaticCycle", "fixedInterval", "dropInterval"], labels) {
                XCTAssertEqual(
                    Localization.string(key: "editor.slime." + key, language: language), label)
            }
        }
    }

    @MainActor func testInspectorShowsIntervalOnlyForFixedTimingInBothModes() async throws {
        let helper = WSSMaskEditingTests()
        try await helper.setUp()
        do {
            let doc = try XCTUnwrap(helper.doc)
            try doc.addSlime()
            let id = try XCTUnwrap(doc.selection?.layer)
            let host = NSHostingView(rootView: WSSSlimeParameterControls(document: doc, layer: id))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 900),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.close() }

            func field(_ view: NSView, key: String) -> NSTextField? {
                if let field = view as? NSTextField,
                    field.accessibilityLabel() == WSSSlimeText.text(key)
                {
                    return field
                }
                return view.subviews.lazy.compactMap { field($0, key: key) }.first
            }

            func awaitField(_ key: String, present: Bool) async throws -> NSTextField? {
                for _ in 0..<100 {
                    host.layoutSubtreeIfNeeded()
                    let found = field(host, key: key)
                    if (found != nil) == present { return found }
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTFail("Unexpected visibility for \(key)")
                return nil
            }

            _ = try await awaitField("anchorX", present: true)
            for mode in WSSSlimeConfiguration.Mode.allCases {
                try doc.changeSlime(id, name: "Automatic") {
                    $0.configuration.mode = mode
                    $0.configuration.timing = .automaticCycle
                    $0.configuration.dropInterval = 5.25
                }
                let hidden = try await awaitField("dropInterval", present: false)
                XCTAssertNil(hidden)

                for _ in 0..<2 {
                    try doc.changeSlime(id, name: "Fixed") {
                        $0.configuration.timing = .fixedInterval
                    }
                    let field = try await awaitField("dropInterval", present: true)
                    XCTAssertNotNil(field)
                    XCTAssertEqual(doc.slimeLayer(id)?.configuration.dropInterval, 5.25)
                    try doc.changeSlime(id, name: "Automatic") {
                        $0.configuration.timing = .automaticCycle
                    }
                    let hidden = try await awaitField("dropInterval", present: false)
                    XCTAssertNil(hidden)
                    XCTAssertEqual(doc.slimeLayer(id)?.configuration.dropInterval, 5.25)
                }
            }
        } catch {
            try await helper.tearDown()
            throw error
        }
        try await helper.tearDown()
    }

    @MainActor func testEditorTimingUndoDuplicateAndSave() async throws {
        let helper = WSSMaskEditingTests()
        try await helper.setUp()
        do {
            let doc = try XCTUnwrap(helper.doc)
            try doc.addSlime()
            let id = try XCTUnwrap(doc.selection?.layer)
            try doc.changeSlime(id, name: "Fixed interval") {
                $0.configuration.timing = .fixedInterval
                $0.configuration.dropInterval = 5
            }
            let fixed = try XCTUnwrap(doc.slimeLayer(id)?.configuration)
            XCTAssertEqual(fixed.dropInterval, 5)
            XCTAssertThrowsError(
                try doc.changeSlime(id, name: "Too short") {
                    $0.configuration.dropInterval = 1
                })
            XCTAssertEqual(doc.slimeLayer(id)?.configuration, fixed)
            try doc.changeSlime(id, name: "Automatic") { $0.configuration.timing = .automaticCycle }
            XCTAssertEqual(doc.slimeLayer(id)?.configuration.dropInterval, 5)
            doc.undoManager.undo()
            XCTAssertEqual(doc.slimeLayer(id)?.configuration, fixed)
            doc.undoManager.redo()
            XCTAssertEqual(doc.slimeLayer(id)?.configuration.timing, .automaticCycle)
            doc.undoManager.undo()
            try await doc.duplicateLayer(id)
            let copy = try XCTUnwrap(doc.selection?.layer)
            XCTAssertNotEqual(copy, id)
            XCTAssertEqual(doc.slimeLayer(copy)?.configuration, fixed)
            let expected = doc.state.workingModel
            let saved = await doc.save()
            XCTAssertTrue(saved)
            let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
            XCTAssertEqual(reopened.document, expected)
        } catch {
            try await helper.tearDown()
            throw error
        }
        try await helper.tearDown()
    }
}
