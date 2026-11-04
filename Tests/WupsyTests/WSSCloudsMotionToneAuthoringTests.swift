import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSCloudsMotionToneAuthoringTests: XCTestCase {
    let address = WSSEffectAddress(layerIndex: 0, effectIndex: 0)
    let edits: [(WSSEditorParameter, Float)] = [
        (.cloudsVelocityX, -30.25), (.cloudsVelocityY, 16.5), (.cloudsBrightness, 0.35),
        (.cloudsSecondaryVelocityX, 11.75), (.cloudsSecondaryVelocityY, -4.25),
    ]
    func fixture(secondary: Bool) async throws -> (WSSEditorProjectTests, WSSLoadedEditorProject) {
        let (helper, project) = try await WSSEditorEditingTests().fixture(clouds: true)
        guard secondary else { return (helper, project) }
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: project.handle.entry))
                as? [String: Any])
        var layers = json["layers"] as! [[String: Any]]
        var effects = layers[0]["effects"] as! [[String: Any]]
        effects[0]["secondaryField"] = ["velocity": [-13, 5], "scale": 700]
        effects[0]["secondaryInfluence"] = 0.4
        effects[0]["softness"] = 0.3
        effects[0]["shadingAmount"] = 0.5
        effects[0]["shadingDirection"] = 37
        layers[0]["effects"] = effects
        json["layers"] = layers
        try JSONSerialization.data(withJSONObject: json).write(to: project.handle.entry)
        return (helper, try await WSSEditorProjectLoader().load(project.handle.wallpaper))
    }

    func testMutationsBoundsUnrelatedValuesAndUndoRedo() async throws {
        let (helper, project) = try await fixture(secondary: true)
        defer { try? helper.tearDownWithError() }
        let document = WSSEditorDocument(project: project)
        defer { document.close() }
        for (parameter, value) in edits {
            let before = document.state.workingModel
            let old = try XCTUnwrap(parameter.value(in: before, at: address))
            try document.setParameter(parameter, at: address, value: value)
            let edited = document.state.workingModel
            XCTAssertEqual(try parameter.applying(old, to: edited, at: address), before)
            await document.waitForPreview()
            XCTAssertEqual(
                document.previewResources.scene.imageLayers.map(\.effects),
                document.workingScene.imageLayers.map(\.effects))
            document.undoManager.undo()
            XCTAssertEqual(document.state.workingModel, before)
            document.undoManager.redo()
            XCTAssertEqual(document.state.workingModel, edited)
            for bound in [parameter.validRange.lowerBound, parameter.validRange.upperBound] {
                XCTAssertEqual(
                    parameter.value(
                        in: try parameter.applying(bound, to: before, at: address), at: address),
                    bound)
            }
            for bad in [
                Float.nan, .infinity, parameter.validRange.lowerBound - 1,
                parameter.validRange.upperBound + 1,
            ] {
                XCTAssertThrowsError(try document.setParameter(parameter, at: address, value: bad))
                XCTAssertEqual(document.state.workingModel, edited)
            }
        }
        let before = document.state.workingModel
        document.beginSlider(.cloudsVelocityX, at: address)
        for value: Float in [1, 2, 3] {
            try document.updateSlider(.cloudsVelocityX, at: address, value: value)
        }
        document.endSlider()
        document.undoManager.undo()
        XCTAssertEqual(document.state.workingModel, before)
        document.undoManager.redo()
        XCTAssertEqual(
            WSSEditorParameter.cloudsVelocityX.value(in: document.state.workingModel, at: address),
            3)
    }

    func testDefaultsAndLegacyAppearanceAreUnchanged() async throws {
        guard case .clouds(let new) = try WSSAddableEffect.clouds.definition().native else {
            return XCTFail("Clouds")
        }
        XCTAssertEqual(new, WSSCloudsEffect())
        XCTAssertEqual(new.velocity, SIMD2(12, 0))
        XCTAssertEqual(new.brightness, 1)
        XCTAssertFalse(new.isExtended)
        let (helper, project) = try await fixture(secondary: false)
        defer { try? helper.tearDownWithError() }
        let document = WSSEditorDocument(project: project)
        defer { document.close() }
        let before = document.state.workingModel
        XCTAssertNil(WSSEditorParameter.cloudsSecondaryVelocityX.value(in: before, at: address))
        XCTAssertThrowsError(
            try document.setParameter(.cloudsSecondaryVelocityY, at: address, value: 1))
        for parameter in [WSSEditorParameter.cloudsVelocityX, .cloudsVelocityY, .cloudsBrightness] {
            try document.setParameter(
                parameter, at: address, value: XCTUnwrap(parameter.value(in: before, at: address)))
        }
        XCTAssertEqual(document.state.workingModel, before)
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(document.undoManager.canUndo)
        XCTAssertEqual(
            document.previewResources.scene.imageLayers.map(\.effects),
            project.resources.scene.imageLayers.map(\.effects))
    }

    func testSaveReopenAndFormattingPreserveExactInput() async throws {
        let (helper, project) = try await fixture(secondary: true)
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
        for (parameter, text, expected): (WSSEditorParameter, String, Float) in [
            (.cloudsVelocityX, "-5,3263524", -5.3263524),
            (.cloudsBrightness, "0,45678912", 0.45678912),
        ] {
            let old = try XCTUnwrap(parameter.value(in: document.state.workingModel, at: address))
            var commits = 0
            let input = WSSParameterTextField(
                value: old, range: parameter.validRange, title: parameter.title,
                maximumFractionDigits: parameter.displayFractionDigits,
                locale: Locale(identifier: "de_DE")
            ) {
                commits += 1
                try document.setParameter(parameter, at: self.address, value: $0)
            }
            let coordinator = input.makeCoordinator()
            let field = NSTextField(string: input.presentation.display(old))
            XCTAssertTrue(coordinator.accept(field))
            XCTAssertEqual(commits, 0)
            field.stringValue = text
            XCTAssertTrue(coordinator.accept(field))
            XCTAssertTrue(coordinator.accept(field))
            XCTAssertEqual(commits, 1)
            XCTAssertEqual(
                parameter.value(in: document.state.workingModel, at: address)?.bitPattern,
                expected.bitPattern)
        }
        let expected = document.state.workingModel
        let saved = await document.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(project.handle.wallpaper)
        XCTAssertEqual(reopened.document, expected)
        let presentation = WSSParameterNumberPresentation(
            maximumFractionDigits: 2, locale: Locale(identifier: "de_DE"))
        for (value, text): (Float, String) in [
            (3, "3"), (1.5, "1,5"), (5.3263524, "5,33"), (-5.3263524, "-5,33"),
        ] {
            XCTAssertEqual(presentation.display(value), text)
        }
        for parameter in WSSEditorParameter.allCases where parameter.rawValue.hasPrefix("clouds") {
            XCTAssertEqual(parameter.displayFractionDigits, 2)
        }
    }

    func testNativeSpeedAndBrightnessHaveIndependentVisibleEffects() throws {
        let renderer = WSSCloudsExtensionTests()
        var moving = WSSCloudsEffect(
            velocity: SIMD2(12, 0), scale: 96, intensity: 1, density: 0.5, brightness: 0.8)
        let original = try renderer.render(moving, time: 0, size: 64)
        let later = try renderer.render(moving, time: 1, size: 64)
        XCTAssertNotEqual(original, later)
        moving.velocity.x = 24
        XCTAssertEqual(try renderer.render(moving, time: 0.5, size: 64), later)
        moving.velocity = .zero
        XCTAssertEqual(
            try renderer.render(moving, time: 0, size: 64),
            try renderer.render(moving, time: 1, size: 64))
        var dark = moving
        dark.brightness = 0
        let darker = try renderer.render(dark, size: 64)
        XCTAssertNotEqual(original, darker)
        var lightSum = 0
        var darkSum = 0
        for i in stride(from: 0, to: original.count, by: 4) {
            XCTAssertEqual(original[i + 3], darker[i + 3])
            lightSum += Int(original[i]) + Int(original[i + 1]) + Int(original[i + 2])
            darkSum += Int(darker[i]) + Int(darker[i + 1]) + Int(darker[i + 2])
        }
        XCTAssertGreaterThan(lightSum, darkSum)
        XCTAssertEqual(moving.intensity, dark.intensity)
        XCTAssertEqual(moving.density, dark.density)
    }
}
