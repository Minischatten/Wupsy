import AppKit
import MetalKit
import XCTest
import simd

@testable import Wupsy

final class WSSTrailLengthTests: XCTestCase {
    func configuration(_ length: Float? = nil) -> WSSTrailConfiguration {
        var c = WSSTrailTests().configuration()
        c.maxLength = length
        c.lifetime = 2
        c.fadeIn = 0
        c.fadeOut = 0
        c.emissionRate = 4
        return c
    }
    func simulation(_ length: Float?, end: Double = 1) throws -> WSSTrailSimulation {
        var s = try WSSTrailSimulation(configuration: configuration(length))
        s.update(time: 0, pointer: .zero)
        s.update(time: end, pointer: SIMD2(Float(end) * 100, 0))
        return s
    }
    func testOptionalCodecAbsenceAndValue() throws {
        for length: Float? in [nil, 0.001, 100, 16384] {
            let c = configuration(length)
            let data = try JSONEncoder().encode(c)
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(json["maxLength"] != nil, length != nil)
            XCTAssertEqual(try JSONDecoder().decode(WSSTrailConfiguration.self, from: data), c)
        }
    }
    func testStrictInvalidLengthCodec() throws {
        var json =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration()))
            as! [String: Any]
        for value: Any in [0, -1, 16385, "100", true, NSNull()] {
            json["maxLength"] = value
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    WSSTrailConfiguration.self, from: JSONSerialization.data(withJSONObject: json)))
        }
        for value: Float in [.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try WSSTrailSimulation(configuration: configuration(value)))
        }
        json["maxLength"] = 10
        json["unknown"] = 1
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                WSSTrailConfiguration.self, from: JSONSerialization.data(withJSONObject: json)))
    }
    func testUnlimitedPreservesAllEmissions() throws {
        let s = try simulation(nil)
        XCTAssertEqual(s.samples.count, 5)
        XCTAssertEqual(s.samples.first?.position.x, 0)
        XCTAssertEqual(s.samples.last?.position.x, 100)
    }
    func testInterpolatedBoundaryBirthAndSeedCoordinate() throws {
        let full = try simulation(nil)
        let clipped = try simulation(37.5)
        XCTAssertEqual(clipped.samples.count, 3)
        let boundary = try XCTUnwrap(clipped.samples.first)
        XCTAssertEqual(boundary.position.x, 62.5)
        XCTAssertEqual(boundary.birth, 0.625)
        XCTAssertEqual(
            boundary.colorCoordinate,
            (full.samples[2].colorCoordinate + full.samples[3].colorCoordinate) / 2,
            accuracy: 0.000001)
        XCTAssertLessThanOrEqual(clipped.samples.count, full.samples.count)
    }
    func testExactBoundaryAndVeryShortLength() throws {
        XCTAssertEqual(try simulation(50).samples.map(\.position.x), [50, 75, 100])
        let short = try simulation(0.001)
        XCTAssertEqual(short.samples.count, 2)
        XCTAssertEqual(
            short.samples.last!.position.x - short.samples.first!.position.x, 0.001,
            accuracy: 0.00001)
    }
    func testStillnessAndReversal() throws {
        var s = try simulation(30)
        s.update(time: 1.25, pointer: SIMD2(75, 0))
        let distance = zip(s.samples, s.samples.dropFirst()).reduce(Float(0)) {
            $0 + simd_distance($1.0.position, $1.1.position)
        }
        XCTAssertEqual(distance, 30, accuracy: 0.00001)
        for i in 6...16 { s.update(time: Double(i) / 4, pointer: SIMD2(75, 0)) }
        XCTAssertTrue(s.vertices(time: 4).isEmpty)
    }
    func testLifetimeAndLengthIndependent() throws {
        var c = configuration(1000)
        c.lifetime = 0.5
        var s = try WSSTrailSimulation(configuration: c)
        for i in 0...4 { s.update(time: Double(i) / 4, pointer: SIMD2(Float(i) * 25, 0)) }
        XCTAssertEqual(s.samples.first?.birth, 0.75)
        XCTAssertEqual(try simulation(10).samples.first?.position.x, 90)
    }

    func testPaletteModesRoundtrip() throws {
        for count in [1, 2, 3, 16] {
            for mode in [WSSTrailConfiguration.ColorMode.sampleRandom, .ageGradient] {
                var c = configuration()
                c.colors = (0..<count).map { .init(r: Float($0) / Float(count), g: 0.3, b: 0.6) }
                c.colorMode = mode
                XCTAssertEqual(
                    try JSONDecoder().decode(
                        WSSTrailConfiguration.self, from: JSONEncoder().encode(c)), c)
            }
        }
    }
    func testAgeGradientEndpointsAndMidpoint() {
        var c = configuration()
        c.colorMode = .ageGradient
        c.colors = [.init(r: 0, g: 0.7, b: 1), .init(r: 1, g: 0.25, b: 0)]
        XCTAssertEqual(c.color(0), c.colors[0].rgb)
        XCTAssertEqual(c.color(1), c.colors[1].rgb)
        XCTAssertEqual(c.color(0.5), SIMD3(0.5, 0.475, 0.5))
    }
    func testManagedColorAdapterKnownSRGBAndRoundtrip() throws {
        let c = try XCTUnwrap(
            WSSTrailColorAdapter.linear(NSColor(srgbRed: 0.5, green: 0, blue: 1, alpha: 0.2)))
        XCTAssertEqual(c.r, 0.214041, accuracy: 0.0001)
        XCTAssertEqual(c.g, 0, accuracy: 0.0001)
        XCTAssertEqual(c.b, 1, accuracy: 0.0001)
        let back = try XCTUnwrap(WSSTrailColorAdapter.linear(WSSTrailColorAdapter.system(c)))
        XCTAssertEqual(back.r, c.r, accuracy: 0.000001)
        XCTAssertEqual(WSSTrailColorAdapter.system(c).alphaComponent, 1)
    }
}

@MainActor final class WSSTrailAuthoringTests: XCTestCase {
    var helper: WSSMaskEditingTests!
    var doc: WSSEditorDocument { helper.doc }
    override func setUp() async throws {
        helper = WSSMaskEditingTests()
        try await helper.setUp()
    }
    override func tearDown() async throws { try await helper.tearDown() }
    func add() throws -> WSSLayerID {
        try doc.addTrail()
        return try XCTUnwrap(doc.selection?.layer)
    }
    func testAddDefaultsSelectionAssetsUndoRedoAndPreview() async throws {
        let before = doc.state.workingModel
        let ids = doc.identity
        let id = try add()
        let c = try XCTUnwrap(doc.trailLayer(id))
        let dimension = Float(min(before.canvas.width, before.canvas.height))
        XCTAssertEqual(c.maxLength, min(4096, max(1, dimension * 0.25)))
        XCTAssertEqual(c.width, min(24, max(2, dimension / 180)))
        XCTAssertEqual(c.colorMode, .ageGradient)
        XCTAssertEqual(c.colors, [.init(r: 0, g: 0.7, b: 1), .init(r: 1, g: 0.25, b: 0)])
        XCTAssertEqual(c.lifetime, 1)
        XCTAssertEqual(c.emissionRate, 32)
        XCTAssertEqual(c.fadeIn, 0.1)
        XCTAssertEqual(c.fadeOut, 0.9)
        XCTAssertEqual(c.opacity, 1)
        XCTAssertEqual(c.edgeSoftness, 0.65)
        XCTAssertEqual(c.seed, 1)
        XCTAssertEqual(doc.selection, .layer(id))
        XCTAssertEqual(doc.identity.layers.last?.id, id)
        XCTAssertEqual(doc.state.workingModel.referencedPaths, before.referencedPaths)
        XCTAssertTrue(doc.isDirty)
        await doc.waitForPreview()
        XCTAssertNotNil(doc.previewResources.trail)
        let added = doc.state.workingModel
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertEqual(doc.identity, ids)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, added)
    }
    func testParametersGroupedUndoAndInvalidAtomicity() throws {
        let id = try add()
        for (parameter, value): (WSSTrailParameter, Float) in [
            (.length, 100), (.lifetime, 2), (.width, 90),
        ] {
            let before = doc.state.workingModel
            doc.undoManager.removeAllActions()
            doc.beginTrailInteraction(id, name: parameter.title)
            try doc.setTrail(parameter, value: value / 2, layer: id, undo: false)
            try doc.setTrail(parameter, value: value, layer: id, undo: false)
            doc.endTrailInteraction()
            XCTAssertEqual(parameter.value(try XCTUnwrap(doc.trailLayer(id))), value)
            doc.undoManager.undo()
            XCTAssertEqual(doc.state.workingModel, before)
            XCTAssertFalse(doc.undoManager.canUndo)
            doc.undoManager.redo()
        }
        for (parameter, value): (WSSTrailParameter, Float) in [
            (.length, 16385), (.lifetime, 0), (.width, .nan),
        ] {
            let before = doc.state.workingModel
            XCTAssertThrowsError(try doc.setTrail(parameter, value: value, layer: id))
            XCTAssertEqual(doc.state.workingModel, before)
        }
    }
    func testLifetimeFadesAtomicUndoAndShortening() throws {
        let id = try add()
        let before = doc.state.workingModel
        doc.undoManager.removeAllActions()
        try doc.setTrail(.lifetime, value: 2, layer: id)
        XCTAssertEqual(doc.trailLayer(id)?.fadeIn, 0.2)
        XCTAssertEqual(doc.trailLayer(id)?.fadeOut, 1.8)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertFalse(doc.undoManager.canUndo)
        try doc.setTrail(.lifetime, value: 0.5, layer: id)
        XCTAssertEqual(doc.trailLayer(id)?.fadeIn, 0.05)
        XCTAssertEqual(doc.trailLayer(id)?.fadeOut, 0.45)
        try doc.state.workingModel.scene().validate()
    }
    func testPendingColorUndoBeforeDebounceFinishes() throws {
        let id = try add()
        let before = doc.state.workingModel
        doc.undoManager.removeAllActions()
        doc.beginTrailInteraction(id, name: EditorText.trailColor1.text)
        try doc.setTrailColor(.init(r: 0.1, g: 0.2, b: 0.3), index: 0, layer: id, undo: false)
        XCTAssertTrue(doc.undoManager.canUndo)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertNil(doc.trailDrag)
        doc.undoManager.redo()
        XCTAssertEqual(doc.trailLayer(id)?.colors[0], .init(r: 0.1, g: 0.2, b: 0.3))
    }
    func testColorsGroupedAndIndependentUndo() throws {
        let id = try add()
        let before = doc.state.workingModel
        doc.undoManager.removeAllActions()
        doc.beginTrailInteraction(id, name: EditorText.trailColor1.text)
        try doc.setTrailColor(.init(r: 0.1, g: 0.2, b: 0.3), index: 0, layer: id, undo: false)
        try doc.setTrailColor(.init(r: 0.2, g: 0.3, b: 0.4), index: 0, layer: id, undo: false)
        doc.endTrailInteraction()
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertFalse(doc.undoManager.canUndo)
        try doc.setTrailColor(.init(r: 1, g: 1, b: 1), index: 1, layer: id)
        XCTAssertEqual(doc.trailLayer(id)?.colors[1], .init(r: 1, g: 1, b: 1))
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
    }
    func testLegacySelectionConversionAndFullUndo() throws {
        let id = try add()
        for count in [1, 3, 16] {
            try doc.changeTrail(id, name: "Fixture") { c in
                c.colors = (0..<count).map { .init(r: Float($0) / Float(count), g: 0.2, b: 0.5) }
                c.colorMode = .sampleRandom
                c.maxLength = nil
            }
            let before = doc.state.workingModel
            let c = try XCTUnwrap(doc.trailLayer(id))
            doc.undoManager.removeAllActions()
            doc.select(.layer(doc.identity.layers[0].id))
            doc.select(.layer(id))
            _ = doc.inspectorSections
            XCTAssertEqual(doc.state.workingModel, before)
            XCTAssertFalse(doc.undoManager.canUndo)
            try doc.convertTrailColors(id)
            XCTAssertEqual(doc.trailLayer(id)?.colors, [c.colors.first!, c.colors.last!])
            XCTAssertEqual(doc.trailLayer(id)?.colorMode, .ageGradient)
            XCTAssertNil(doc.trailLayer(id)?.maxLength)
            doc.undoManager.undo()
            XCTAssertEqual(doc.state.workingModel, before)
            XCTAssertFalse(doc.undoManager.canUndo)
        }
    }
    func testReorderMultipleDeleteAndHistoryOwnerReset() async throws {
        let first = try add()
        let second = try add()
        try doc.setTrail(.width, value: 20, layer: second)
        let before = doc.state.workingModel
        await doc.waitForPreview()
        let old = doc.previewResources
        try doc.moveLayer(second, to: 0)
        await doc.waitForPreview()
        XCTAssertFalse(old.sharesPreparedResources(with: doc.previewResources))
        XCTAssertEqual(doc.trailLayer(first)?.width, 2)
        XCTAssertEqual(doc.trailLayer(second)?.width, 20)
        doc.select(.layer(first))
        try doc.deleteSelection()
        XCTAssertNil(doc.trailLayer(first))
        doc.undoManager.undo()
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
    }
    func testSaveReloadSaveAsRevert() async throws {
        let id = try add()
        try doc.setTrail(.length, value: 123.456, layer: id)
        let model = doc.state.workingModel
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, model)
        let snapshot = try WSSSaveAsSnapshot(
            document: model, state: doc.state, source: doc.project.handle, name: "Trail copy")
        let copy = try await helper.store.saveWSSAs(snapshot)
        XCTAssertEqual(copy.project.document, snapshot.model)
        try doc.setTrail(.width, value: 40, layer: id)
        doc.revert()
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertFalse(doc.isDirty)
    }
    func testCursorSimulationNeverChangesDocumentAndSeparateHistories() throws {
        _ = try add()
        _ = try add()
        let before = doc.state.workingModel
        let revision = doc.state.workingRevision
        var a = try WSSTrailSimulation(configuration: doc.trailLayer(doc.identity.layers.last!.id)!)
        var b = a
        a.update(time: 0, pointer: .zero)
        a.update(time: 0.2, pointer: SIMD2(20, 30))
        XCTAssertGreaterThan(a.samples.count, b.samples.count)
        b.update(time: 0, pointer: .zero)
        a.update(time: 0.3, pointer: nil)
        XCTAssertTrue(a.samples.isEmpty)
        XCTAssertEqual(b.samples.count, 1)
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertEqual(doc.state.workingRevision, revision)
    }
    func testSceneBudgetFailureIsAtomic() throws {
        let id = try add()
        try doc.changeTrail(id, name: "Budget") { c in
            c.lifetime = 8
            c.emissionRate = 512
        }
        let before = doc.state.workingModel
        XCTAssertThrowsError(try doc.addTrail())
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertThrowsError(try doc.setTrail(.lifetime, value: 9, layer: id))
        XCTAssertEqual(doc.state.workingModel, before)
    }
    func testPreciseNumericInputCommaPointAndUntouchedDisplay() throws {
        let id = try add()
        for (locale, text) in [("de_DE", "1,375"), ("en_US", "1.375")] {
            let input = WSSParameterTextField(
                value: 2, range: WSSTrailParameter.width.range,
                title: EditorText.trailWidth.text, maximumFractionDigits: 2,
                locale: Locale(identifier: locale)
            ) {
                try self.doc.setTrail(.width, value: $0, layer: id)
            }
            let coordinator = input.makeCoordinator()
            let field = NSTextField(string: text)
            XCTAssertTrue(coordinator.accept(field))
            XCTAssertEqual(doc.trailLayer(id)?.width, 1.375)
            XCTAssertTrue(coordinator.accept(field))
            XCTAssertEqual(doc.trailLayer(id)?.width, 1.375)
        }
        let before = doc.state.workingModel
        let input = WSSParameterTextField(
            value: 1.375, range: WSSTrailParameter.width.range,
            title: EditorText.trailWidth.text, maximumFractionDigits: 2,
            locale: Locale(identifier: "de_DE")
        ) {
            try self.doc.setTrail(.width, value: $0, layer: id)
        }
        XCTAssertTrue(input.makeCoordinator().accept(NSTextField(string: "1,38")))
        XCTAssertEqual(doc.state.workingModel, before)
    }
    func testLifetimeDoublePrecisionFocusInputAndUndo() throws {
        let id = try add()
        for original in [1.0050000001, 1.23456789012345, 1e-100] {
            try doc.setTrailLifetime(original, layer: id)
            let before = doc.state.workingModel
            let input = WSSParameterTextField(
                value: Float(original), range: WSSTrailParameter.lifetime.range,
                title: EditorText.trailLifetime.text, maximumFractionDigits: 2,
                locale: Locale(identifier: "de_DE"),
                exactValue: original, exactRange: Double.leastNonzeroMagnitude...10,
                commitExact: { try self.doc.setTrailLifetime($0, layer: id) },
                commit: { _ in XCTFail("Float path used") })
            let coordinator = input.makeCoordinator()
            let text = original.formatted(
                .number.grouping(.never).precision(.fractionLength(0...2)).locale(
                    Locale(identifier: "de_DE")))
            let field = NSTextField(string: text)
            XCTAssertTrue(coordinator.accept(field))
            XCTAssertEqual(doc.state.workingModel, before)
            coordinator.controlTextDidBeginEditing(
                Notification(name: NSControl.textDidBeginEditingNotification, object: field))
            XCTAssertEqual(field.stringValue, text)
            XCTAssertTrue(coordinator.accept(field))
            XCTAssertEqual(doc.state.workingModel, before)
            field.stringValue = "2,123456789012345"
            XCTAssertTrue(coordinator.accept(field))
            XCTAssertEqual(doc.trailLayer(id)?.lifetime, 2.123456789012345)
            XCTAssertTrue(coordinator.accept(field))
            XCTAssertEqual(doc.trailLayer(id)?.lifetime, 2.123456789012345)
            doc.undoManager.undo()
            XCTAssertEqual(doc.state.workingModel, before)
        }
    }
    func testNewLocalizationAndFallback() {
        for (resource, en, de): (EditorText, String, String) in [
            (.effectTrail, "Cursor Trail", "Maustrail"),
            (.trailColor1, "Color 1", "Farbe 1"), (.trailColor2, "Color 2", "Farbe 2"),
            (.trailLength, "Length", "Länge"), (.trailLifetime, "Lifetime", "Lebenszeit"),
            (.trailWidth, "Width", "Dicke"),
            (.trailCurve, "Curve amount", "Kurvenauslenkung"),
            (
                .trailCurveReset, "Reset curve amount to 0.15",
                "Kurvenauslenkung auf 0,15 zurücksetzen"
            ),
            (.trailConvert, "Edit as Two-Color Gradient", "Als Zwei-Farben-Verlauf bearbeiten"),
        ] {
            XCTAssertEqual(resource.localized(language: "en"), en)
            XCTAssertEqual(resource.localized(language: "de"), de)
            XCTAssertEqual(resource.localized(language: "zz"), en)
        }
        XCTAssertEqual(
            EditorErrorPresentation.message(WSSTrailAuthoringError.invalid, language: "de"),
            EditorText.trailCapacity.localized(language: "de"))
    }
    func testPreviewSleepAndSessionGatesResetState() async throws {
        let resources = try WSSPreviewTests().resources(trail: true)
        let surface = WSSPreviewSurface(resources: resources, onError: { _ in })
        let player = try XCTUnwrap(surface.player)
        let context = player.trailContext
        _ = try WSSPreviewTests().render(
            resources, size: CGSize(width: 64, height: 64), time: 0, trail: context, pointer: .zero)
        XCTAssertEqual(context.sampleCount(index: 1), 1)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(context.sampleCount(index: 1), 0)
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertNil(player.currentPointer())
        surface.shutdown()
        XCTAssertNil(surface.player)
    }
    func testCurveEditingResetPrecisionUndoSaveAndNativePreparation() async throws {
        let id = try add()
        let initial = try XCTUnwrap(doc.trailLayer(id))
        XCTAssertEqual(initial.curveSmoothing, 0.15)
        XCTAssertTrue(WSSTrailParameter.allCases.contains(.curveSmoothing))
        XCTAssertEqual(WSSTrailParameter.curveSmoothing.range, 0...0.5)
        try doc.setTrail(.curveSmoothing, value: 0.35, layer: id)
        var expected = initial
        expected.curveSmoothing = 0.35
        XCTAssertEqual(doc.trailLayer(id), expected)
        await doc.waitForPreview()
        let index = try XCTUnwrap(doc.identity.layers.firstIndex { $0.id == id })
        guard case .trail(let preview) = doc.previewResources.scene.layers[index] else {
            return XCTFail("Missing preview trail")
        }
        XCTAssertEqual(preview.configuration, expected)
        try doc.setTrail(
            .curveSmoothing, value: WSSTrailConfiguration.defaultCurveSmoothing, layer: id)
        XCTAssertEqual(doc.trailLayer(id), initial)
        doc.undoManager.undo()
        XCTAssertEqual(doc.trailLayer(id), expected)
        doc.undoManager.redo()
        XCTAssertEqual(doc.trailLayer(id), initial)
        let input = WSSParameterTextField(
            value: initial.curveSmoothing, range: 0...0.5,
            title: EditorText.trailCurve.text, maximumFractionDigits: 2,
            locale: Locale(identifier: "de_DE")
        ) {
            try self.doc.setTrail(.curveSmoothing, value: $0, layer: id)
        }
        XCTAssertTrue(input.makeCoordinator().accept(NSTextField(string: "0,234567")))
        expected.curveSmoothing = 0.234567
        XCTAssertEqual(doc.trailLayer(id), expected)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, doc.state.workingModel)
        let native = try await WSSStaticPreparation.shared.prepare(doc.project.handle.wallpaper)
        guard case .trail(let desktop) = native.scene.layers[index] else { return XCTFail() }
        XCTAssertEqual(desktop.configuration, expected)
        let before = doc.state.workingModel
        try doc.setTrail(.curveSmoothing, value: 0.234567, layer: id)
        XCTAssertEqual(doc.state.workingModel, before)
        for invalid: Float in [-1, .nan, .infinity, 0.51] {
            XCTAssertThrowsError(try doc.setTrail(.curveSmoothing, value: invalid, layer: id))
        }
        XCTAssertEqual(doc.state.workingModel, before)
    }

    func testLegacyTrailFileOpensCleanWithoutBeingRewritten() async throws {
        _ = try add()
        var json =
            try JSONSerialization.jsonObject(with: doc.state.workingModel.encoded())
            as! [String: Any]
        var layers = json["layers"] as! [[String: Any]]
        for i in layers.indices where layers[i]["type"] as? String == "cursorTrail" {
            var trail = layers[i]["trail"] as! [String: Any]
            trail.removeValue(forKey: "curveSmoothing")
            layers[i]["trail"] = trail
        }
        json["layers"] = layers
        let bytes = try JSONSerialization.data(withJSONObject: json)
        doc.close()
        try bytes.write(to: helper.helper.item.url)
        let project = try await WSSEditorProjectLoader().load(helper.helper.item)
        let opened = WSSEditorDocument(project: project)
        defer { opened.close() }
        XCTAssertFalse(opened.isDirty)
        XCTAssertFalse(opened.undoManager.canUndo)
        XCTAssertEqual(try Data(contentsOf: project.handle.entry), bytes)
        for layer in project.document.layers {
            if case .trail(let c, _) = layer.content { XCTAssertEqual(c.curveSmoothing, 0.15) }
        }
    }

}
