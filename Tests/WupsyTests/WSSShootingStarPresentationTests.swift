import AppKit
import XCTest

@testable import Wupsy

final class WSSShootingStarPresentationTests: XCTestCase {
    func testFrequencyDisplayConversionValidationAndActualSchedule() throws {
        let parameter = WSSShootingStarParameter.frequency
        XCTAssertEqual(parameter.displayRange, 0...120)
        var c = WSSShootingStarTests().configuration()
        for (display, stored, mean): (Double, Double, Double) in [
            (1, 0.1, 600), (2, 0.2, 300), (5, 0.5, 120), (10, 1, 60), (120, 12, 5),
        ] {
            try parameter.applyDisplayValue(display, to: &c.shootingStars)
            XCTAssertEqual(c.shootingStars.frequency, stored)
            XCTAssertEqual(parameter.displayValue(c.shootingStars), display)
            let offset = 0.1 + 0.8 * WSSShootingStarEvents.samples(seed: c.seed, slot: 0)[0]
            let onset = mean * offset
            XCTAssertTrue(WSSShootingStarEvents.events(c, at: onset - 0.01).isEmpty)
            let events = WSSShootingStarEvents.events(c, at: onset + 0.3)
            XCTAssertFalse(events.isEmpty)
            XCTAssertEqual(events, WSSShootingStarEvents.events(c, at: onset + 0.3))
            let decoded = try JSONDecoder().decode(
                WSSStarfieldConfiguration.self, from: JSONEncoder().encode(c))
            XCTAssertEqual(decoded.shootingStars.frequency, stored)
            XCTAssertEqual(WSSShootingStarEvents.events(decoded, at: onset + 0.3), events)
        }
        for invalid in [-1, 120.01, Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try parameter.applyDisplayValue(invalid, to: &c.shootingStars))
        }
        try parameter.applyDisplayValue(0, to: &c.shootingStars)
        XCTAssertFalse(c.shootingStars.isEffective)
        // Fractional display values remain accepted; no integral quantization.
        try parameter.applyDisplayValue(0.5, to: &c.shootingStars)
        XCTAssertEqual(c.shootingStars.frequency, 0.05)
    }
    func testSavedPerMinuteRatesRemainUntouchedIncludingPrecision() throws {
        for rate in [0.1, 0.2, 0.5, 1, 2, 6, 12, 1.23456789012345] {
            var c = WSSShootingStarTests().configuration()
            c.shootingStars.frequency = rate
            // This is exactly the old on-disk representation: frequency is per minute.
            let bytes = try JSONEncoder().encode(c)
            var reopened = try JSONDecoder().decode(WSSStarfieldConfiguration.self, from: bytes)
            XCTAssertEqual(
                WSSShootingStarParameter.frequency.displayValue(reopened.shootingStars), rate * 10)
            try WSSShootingStarParameter.frequency.applyDisplayValue(
                rate * 10, to: &reopened.shootingStars)
            XCTAssertEqual(reopened.shootingStars.frequency.bitPattern, rate.bitPattern)
            XCTAssertEqual(try JSONEncoder().encode(reopened).count, bytes.count)
            let t = WSSShootingStarTests().onset(c) + 0.3
            XCTAssertEqual(
                WSSShootingStarEvents.events(c, at: t),
                WSSShootingStarEvents.events(reopened, at: t))
        }
    }
    func testAllDirectionChoicesAndPreciseIntermediateAngles() {
        XCTAssertEqual(
            WSSShootingStarDirection.allCases.map(\.rawValue), [0, 45, 90, 135, 180, 225, 270, 315])
        let choices = WSSShootingStarDirection.rows.flatMap { $0.compactMap { $0 } }
        XCTAssertEqual(
            Set(choices.map(\.rawValue)), Set(WSSShootingStarDirection.allCases.map(\.rawValue)))
        XCTAssertEqual(choices.count, 8)
        XCTAssertEqual(WSSShootingStarDirection.selection(for: 360), .right)
        for direction in WSSShootingStarDirection.allCases {
            XCTAssertEqual(WSSShootingStarDirection.selection(for: direction.rawValue), direction)
            XCTAssertTrue(direction.symbol.hasPrefix("arrow."))
            XCTAssertFalse(direction.title.isEmpty)
            XCTAssertNotEqual(
                direction.title, "editor.starfield.shootingStars.direction." + direction.key)
        }
        for precise in [22.5, 91.125, 314.99] {
            XCTAssertNil(WSSShootingStarDirection.selection(for: precise))
        }
        // Other controls use identical units and limits as before.
        let c = WSSStarfieldShootingStars()
        for parameter in WSSShootingStarParameter.allCases where parameter != .frequency {
            XCTAssertEqual(parameter.displayRange, parameter.range)
            XCTAssertEqual(parameter.displayValue(c), parameter.value(c))
        }
    }
}

@MainActor final class WSSShootingStarPresentationAuthoringTests: XCTestCase {
    var helper: WSSMaskEditingTests!
    var doc: WSSEditorDocument { helper.doc }
    var id: WSSLayerID!
    override func setUp() async throws {
        helper = WSSMaskEditingTests()
        try await helper.setUp()
        try doc.addStarfield()
        id = try XCTUnwrap(doc.selection?.layer)
        await doc.waitForPreview()
        doc.undoManager.removeAllActions()
    }
    override func tearDown() async throws {
        doc.finishInput = nil
        try await helper.tearDown()
    }
    func testFrequencyNumericReturnUndoSaveAndLegacyRateReopen() async throws {
        let original = try XCTUnwrap(doc.starfieldLayer(id)).starfield
        let resources = doc.previewResources
        let input = WSSParameterTextField(
            value: 20, range: 0...120, title: WSSShootingStarParameter.frequency.title,
            maximumFractionDigits: 3, exactValue: 20, exactRange: 0...120,
            commitExact: { [self] in
                try doc.setShootingStarsDisplayValue(.frequency, value: $0, layer: id)
            },
            commit: { [self] in
                try doc.setShootingStarsDisplayValue(.frequency, value: Double($0), layer: id)
            })
        let coordinator = input.makeCoordinator()
        let field = NSTextField(string: "1")
        doc.finishInput = {
            XCTFail("Numeric commit must not reenter its field editor")
            return false
        }
        XCTAssertTrue(
            coordinator.control(
                field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))
            ))
        XCTAssertTrue(coordinator.control(field, textShouldEndEditing: NSTextView()))
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.shootingStars.frequency, 0.1)
        doc.finishInput = nil
        doc.undoManager.undo()
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield, original)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewResources.starfield === resources.starfield)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, doc.state.workingModel)
        // Existing per-minute settings are not migrated or silently divided on open.
        try doc.setShootingStars(.frequency, value: 6, layer: id)
        let legacySaved = await doc.save()
        XCTAssertTrue(legacySaved)
        let legacy = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        let layer = try XCTUnwrap(legacy.document.layers.last)
        guard case .starfield(let stars) = layer.content else {
            return XCTFail("Starfield expected")
        }
        XCTAssertEqual(stars.starfield.shootingStars.frequency, 6)
        XCTAssertEqual(
            WSSShootingStarParameter.frequency.displayValue(stars.starfield.shootingStars), 60)
    }
    func testArrowFinishesNumericDraftAndRejectsInvalidDraft() throws {
        let input = WSSParameterTextField(
            value: 315, range: 0...360, title: "Direction", maximumFractionDigits: 3,
            exactValue: 315, exactRange: 0...360,
            commitExact: { [self] in
                try doc.setShootingStarsDisplayValue(.direction, value: $0, layer: id)
            },
            commit: { [self] in
                try doc.setShootingStarsDisplayValue(.direction, value: Double($0), layer: id)
            })
        let coordinator = input.makeCoordinator()
        let field = NSTextField(string: "112.375")
        var resigns = 0
        doc.finishInput = {
            resigns += 1
            guard resigns <= 2 else {
                XCTFail("Recursive commit")
                return false
            }
            return coordinator.control(field, textShouldEndEditing: NSTextView())
        }
        try doc.selectShootingStarDirection(.up, layer: id)
        XCTAssertEqual(resigns, 1)
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.shootingStars.direction, 90)
        // The same synchronization used by updateNSView must show the selected arrow's angle.
        let next = WSSParameterTextField(
            value: 90, range: 0...360, title: "Direction", maximumFractionDigits: 3,
            exactValue: 90, exactRange: 0...360, commitExact: input.commitExact,
            commit: input.commit)
        coordinator.synchronize(next, in: field)
        XCTAssertEqual(field.stringValue, "90")
        XCTAssertTrue(coordinator.control(field, textShouldEndEditing: NSTextView()))
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.shootingStars.direction, 90)
        doc.undoManager.undo()
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.shootingStars.direction, 112.375)
        doc.undoManager.redo()
        field.stringValue = "999"
        try doc.selectShootingStarDirection(.left, layer: id)
        XCTAssertEqual(resigns, 2)
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.shootingStars.direction, 90)
        XCTAssertEqual(field.stringValue, "999")
        doc.finishInput = nil
    }
    func testEightChoicesAndNumericDirectionShareModelUndoAndSave() async throws {
        let original = try XCTUnwrap(doc.starfieldLayer(id)).starfield
        let resources = doc.previewResources
        for direction in WSSShootingStarDirection.allCases {
            let before = doc.state.workingModel
            try doc.selectShootingStarDirection(direction, layer: id)
            let value = try XCTUnwrap(doc.starfieldLayer(id)).starfield.shootingStars.direction
            XCTAssertEqual(value, direction.rawValue)
            XCTAssertEqual(WSSShootingStarDirection.selection(for: value), direction)
            if before != doc.state.workingModel {
                doc.undoManager.undo()
                XCTAssertEqual(doc.state.workingModel, before)
                doc.undoManager.redo()
            }
        }
        let baseline = doc.state.workingModel
        let input = WSSParameterTextField(
            value: 315, range: 0...360, title: "Direction", maximumFractionDigits: 3,
            exactValue: 315, exactRange: 0...360,
            commitExact: { [self] in
                try doc.setShootingStarsDisplayValue(.direction, value: $0, layer: id)
            },
            commit: { [self] in
                try doc.setShootingStarsDisplayValue(.direction, value: Double($0), layer: id)
            })
        let coordinator = input.makeCoordinator()
        XCTAssertTrue(coordinator.accept(NSTextField(string: "112.375")))
        let precise = try XCTUnwrap(doc.starfieldLayer(id)).starfield
        XCTAssertEqual(precise.shootingStars.direction, 112.375)
        XCTAssertNil(WSSShootingStarDirection.selection(for: precise.shootingStars.direction))
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, baseline)
        doc.undoManager.redo()
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewResources.starfield === resources.starfield)
        var expected = original
        expected.shootingStars.direction = 112.375
        XCTAssertEqual(precise, expected)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, doc.state.workingModel)
    }
}
