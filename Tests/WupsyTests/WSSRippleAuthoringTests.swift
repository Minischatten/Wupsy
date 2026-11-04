import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSRippleAuthoringTests: XCTestCase {
    let address = WSSEffectAddress(layerIndex: 0, effectIndex: 0)
    let edits: [(WSSEditorParameter, Float)] = [
        (.rippleStretch, 2.2), (.rippleDirection, 130), (.rippleStructureRotation, 90),
        (.rippleEvolution, 0.18), (.rippleLateralDetail, 3),
    ]

    func testEveryAdvancedParameterPreservesOthersAndSupportsUndoRedoAndPreview() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        let document = WSSEditorDocument(project: project)
        defer { document.close() }
        for (parameter, value) in edits {
            let before = document.state.workingModel
            let old = try XCTUnwrap(parameter.value(in: before, at: address))
            try document.setParameter(parameter, at: address, value: value)
            let edited = document.state.workingModel
            XCTAssertEqual(parameter.value(in: edited, at: address), value)
            XCTAssertEqual(try parameter.applying(old, to: edited, at: address), before)
            await document.waitForPreview()
            XCTAssertEqual(document.previewRevision, document.state.workingRevision)
            XCTAssertEqual(
                document.previewResources.scene.imageLayers.map(\.effects),
                document.workingScene.imageLayers.map(\.effects))
            document.undoManager.undo()
            XCTAssertEqual(document.state.workingModel, before)
            document.undoManager.redo()
            XCTAssertEqual(document.state.workingModel, edited)
            document.undoManager.undo()
        }
        // Continuous detail changes coalesce to one undo operation too.
        let before = document.state.workingModel
        document.beginSlider(.rippleLateralDetail, at: address)
        for value: Float in [2, 3, 4] {
            try document.updateSlider(.rippleLateralDetail, at: address, value: value)
        }
        document.endSlider()
        document.undoManager.undo()
        XCTAssertEqual(document.state.workingModel, before)
        document.undoManager.redo()
        XCTAssertEqual(
            WSSEditorParameter.rippleLateralDetail.value(
                in: document.state.workingModel, at: address), 4)
    }

    func testSeedExactTextInputBoundsNoOpAndUndoRedo() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        let document = WSSEditorDocument(project: project)
        defer { document.close() }
        for value in [0.0, 16_777_217, Double(UInt32.max) - 1, Double(UInt32.max)] {
            let before = document.state.workingModel
            let old = try XCTUnwrap(WSSEditorParameter.rippleSeed(in: before, at: address))
            let input = WSSParameterTextField(
                value: Float(old), range: 0...Float(UInt32.max), title: "Seed",
                maximumFractionDigits: 0, exactValue: Double(old),
                exactRange: 0...Double(UInt32.max),
                commitExact: { try document.setRippleSeed(at: self.address, value: $0) },
                commit: { _ in XCTFail("Seed must never pass through Float") })
            let coordinator = input.makeCoordinator()
            let field = NSTextField(string: String(format: "%.0f", value))
            XCTAssertTrue(coordinator.accept(field))
            let edited = document.state.workingModel
            XCTAssertEqual(WSSEditorParameter.rippleSeed(in: edited, at: address), UInt32(value))
            XCTAssertEqual(
                try WSSEditorParameter.applyingRippleSeed(Double(old), to: edited, at: address),
                before)
            let revision = document.state.workingRevision
            XCTAssertTrue(coordinator.accept(field))
            XCTAssertEqual(document.state.workingRevision, revision)
            document.undoManager.undo()
            XCTAssertEqual(document.state.workingModel, before)
            document.undoManager.redo()
            XCTAssertEqual(document.state.workingModel, edited)
            await document.waitForPreview()
            XCTAssertEqual(
                document.previewResources.scene.imageLayers.map(\.effects),
                document.workingScene.imageLayers.map(\.effects))
        }
        let before = document.state.workingModel
        for bad in [-1.0, 0.5, Double(UInt32.max) + 1, .nan, .infinity] {
            XCTAssertThrowsError(try document.setRippleSeed(at: address, value: bad))
            XCTAssertEqual(document.state.workingModel, before)
        }
        XCTAssertThrowsError(
            try document.setRippleSeed(at: .init(layerIndex: -1, effectIndex: 0), value: 1))
    }

    func testAdvancedBoundsAndDefaultsRemainModelCompatible() throws {
        let definition = try WSSAddableEffect.ripple.definition()
        guard case .ripple(let ripple) = definition.native else { return XCTFail("Ripple") }
        XCTAssertEqual(ripple, WSSRippleEffect())
        XCTAssertEqual(ripple.lateralDetail, 1)
        XCTAssertEqual(ripple.stretch, 1)
        XCTAssertEqual(ripple.direction, 180)
        XCTAssertEqual(ripple.structureRotation, 0)
        XCTAssertEqual(ripple.evolutionRate, 0.2)
        XCTAssertEqual(ripple.seed, 1)
        XCTAssertEqual(WSSEditorParameter.allCases.filter(\.isAdvancedRipple), edits.map(\.0))
        for (parameter, _) in edits {
            // Use an ordinary legacy Ripple document, including absent optional detail/rotation.
            var json = WSSNativeSceneTests().document()
            var layers = json["layers"] as! [[String: Any]]
            layers[0]["effects"] = [WSSSceneCodecTests().ripple()]
            json["layers"] = layers
            let model = try JSONDecoder().decode(
                WSSSceneDocumentV1.self, from: JSONSerialization.data(withJSONObject: json))
            for value in [parameter.validRange.lowerBound, parameter.validRange.upperBound] {
                let edited = try parameter.applying(value, to: model, at: address)
                XCTAssertEqual(parameter.value(in: edited, at: address), value)
            }
            for bad in [
                Float.nan, .infinity, parameter.validRange.lowerBound - 1,
                parameter.validRange.upperBound + 1,
            ] {
                XCTAssertThrowsError(try parameter.applying(bad, to: model, at: address))
            }
        }
        XCTAssertLessThan(WSSEditorParameter.rippleDirection.validRange.upperBound, 360)
        XCTAssertLessThan(WSSEditorParameter.rippleStructureRotation.validRange.upperBound, 360)
    }

    func testAllAdvancedValuesAndLargeSeedSaveAndReopen() async throws {
        let (helper, project) = try await WSSEditorEditingTests().fixture()
        defer { try? helper.tearDownWithError() }
        let storage = helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([project.handle.wallpaper]).write(to: storage)
        let store = ManagedWallpaperStore(storage: storage)
        let document = WSSEditorDocument(
            project: project,
            save: { snapshot in
                let candidate = try await WSSManifestSaveValidator().prepare(
                    snapshot, handle: project.handle)
                return try await store.commitWSSManifest(candidate)
            })
        defer { document.close() }
        for (parameter, value) in edits {
            try document.setParameter(parameter, at: address, value: value)
        }
        try document.setRippleSeed(at: address, value: Double(UInt32.max) - 1)
        let expected = document.state.workingModel
        let saved = await document.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(project.handle.wallpaper)
        XCTAssertEqual(reopened.document, expected)
        XCTAssertEqual(
            WSSEditorParameter.rippleSeed(in: reopened.document, at: address), UInt32.max - 1)
    }
}
