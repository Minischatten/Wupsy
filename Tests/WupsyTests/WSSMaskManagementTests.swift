import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import Wupsy

@MainActor final class WSSMaskManagementTests: XCTestCase {
    var helper: WSSMaskEditingTests!
    var doc: WSSEditorDocument { helper.doc }
    override func setUp() async throws {
        helper = WSSMaskEditingTests()
        try await helper.setUp()
        _ = try helper.target()
    }
    override func tearDown() async throws { try await helper.tearDown() }
    func pixels() async throws -> Data {
        let target = try XCTUnwrap(doc.selectedMaskTarget)
        return try await WSSMaskPreparation().read(
            doc.resolveMaskTarget(target),
            model: doc.state.workingModel, handle: doc.project.handle,
            generations: doc.state.sessionAssets, basis: doc.state.diskBasis
        ).pixels
    }
    func unmask() async throws {
        try await doc.manageMask(.remove)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        doc.undoManager.removeAllActions()
    }
    func testCreateBlackUndoRedoAndSelectionDoesNotCreate() async throws {
        try await unmask()
        let original = doc.state.workingModel
        let target = try XCTUnwrap(doc.maskManagementTarget)
        doc.select(.layer(target.layerID))
        doc.select(.effect(target.layerID, try XCTUnwrap(target.effectID)))
        XCTAssertFalse(doc.isDirty)
        XCTAssertNil(doc.selectedMaskTarget)
        XCTAssertNotNil(doc.maskManagementTarget)
        XCTAssertTrue(doc.canManageMask(.create))
        XCTAssertTrue(doc.canManageMask(.replace))
        XCTAssertFalse(doc.canManageMask(.remove))
        try await doc.manageMask(.create)
        let created = doc.state.workingModel
        let path = try XCTUnwrap(helper.mask(created))
        let black = try await pixels()
        XCTAssertEqual(black, Data(repeating: 0, count: 64 * 64))
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.state.sessionAssets.count, 1)
        XCTAssertFalse(doc.canManageMask(.create))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: doc.project.handle.root.appendingPathComponent(path).path))
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, created)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
    }
    func testBrushAutoCreateAndStrokeHaveSeparateUndoWithEscapeCancellation() async throws {
        try await unmask()
        let original = doc.state.workingModel
        let session = doc.maskCanvas
        XCTAssertNil(session.loaded)
        session.setBrush(true)
        await session.waitForBrushActivation()
        XCTAssertTrue(session.brushEnabled)
        let created = doc.state.workingModel
        XCTAssertNotEqual(created, original)
        let point = try XCTUnwrap(session.geometry).scene(SIMD2(32, 32))
        session.setDiameter(8)
        XCTAssertTrue(session.begin(point, erase: false))
        XCTAssertTrue(session.escape())
        XCTAssertEqual(doc.state.workingModel, created)
        XCTAssertTrue(session.begin(point, erase: false))
        session.finish(point)
        await session.waitForFinish()
        XCTAssertNotEqual(doc.state.workingModel, created)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, created)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertNil(doc.selectedMaskTarget)
        XCTAssertNil(session.loaded)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        doc.undoManager.redo()
        XCTAssertNotNil(doc.selectedMaskTarget)
    }
    func testClearFillNoOpsSharedCOWAndRemoveUndoRedo() async throws {
        let original = doc.state.workingModel
        let shared = helper.mask(original, effect: 1)
        let files = try helper.helper.helper.snapshot()
        for (action, value) in [(WSSMaskAction.clear, UInt8(0)), (.fill, UInt8(255))] {
            let before = doc.state.workingModel
            try await doc.manageMask(action)
            let after = doc.state.workingModel
            XCTAssertNotEqual(helper.mask(after), shared)
            XCTAssertEqual(helper.mask(after, effect: 1), shared)
            let scalar = try await pixels()
            XCTAssertEqual(scalar, Data(repeating: value, count: 2))
            let count = doc.state.sessionAssets.count
            let revision = doc.state.workingRevision
            try await doc.manageMask(action)
            XCTAssertEqual(doc.state.sessionAssets.count, count)
            XCTAssertEqual(doc.state.workingRevision, revision)
            doc.undoManager.undo()
            XCTAssertEqual(doc.state.workingModel, before)
            doc.undoManager.redo()
            XCTAssertEqual(doc.state.workingModel, after)
        }
        let filled = doc.state.workingModel
        try await doc.manageMask(.remove)
        XCTAssertNil(doc.selectedMaskTarget)
        XCTAssertNotNil(doc.maskManagementTarget)
        XCTAssertNil(helper.mask(doc.state.workingModel))
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, filled)
        doc.undoManager.redo()
        XCTAssertNil(helper.mask(doc.state.workingModel))
        XCTAssertEqual(try helper.helper.helper.snapshot(), files)
    }
    func testReplacementPNGJPEGRedSemanticsUndoCancelInvalidAndSymlink() async throws {
        XCTAssertEqual(WSSMaskAction.replace.rawValue, "Import Mask…")
        let root = helper.helper.helper.root
        for (type, ext) in [(UTType.png, "png"), (.jpeg, "jpg")] {
            let url = root.appendingPathComponent("replacement." + ext)
            let bytes = try WSSImageImportTests().image(type)
            try bytes.write(to: url)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
            let props = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let expected = try WSSMaskAsset.decode(
                bytes, width: XCTUnwrap(props[kCGImagePropertyPixelWidth] as? Int),
                height: XCTUnwrap(props[kCGImagePropertyPixelHeight] as? Int), uvScale: SIMD2(1, 1))
            let before = doc.state.workingModel
            try await doc.manageMask(.replace, file: url)
            let after = doc.state.workingModel
            let scalar = try await pixels()
            XCTAssertEqual(scalar, expected.pixels)
            XCTAssertTrue(scalar.allSatisfy { $0 > 150 && $0 < 240 })
            doc.undoManager.undo()
            XCTAssertEqual(doc.state.workingModel, before)
            doc.undoManager.redo()
            XCTAssertEqual(doc.state.workingModel, after)
        }
        let before = doc.state.workingModel
        let count = doc.state.sessionAssets.count
        let undoName = doc.undoManager.undoActionName
        doc.chooseMaskFile = { nil }
        await doc.chooseMaskReplacement()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertEqual(doc.undoManager.undoActionName, undoName)
        let invalid = root.appendingPathComponent("invalid.png")
        try Data("bad".utf8).write(to: invalid)
        let symlink = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: invalid)
        for file in [invalid, symlink] {
            do {
                try await doc.manageMask(.replace, file: file)
                XCTFail("accepted invalid file")
            } catch {}
        }
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertEqual(doc.state.sessionAssets.count, count)
        XCTAssertEqual(doc.undoManager.undoActionName, undoName)
    }
    func testRevertAndSelectionOverlayAndSaveAsSelfContained() async throws {
        let original = doc.state.workingModel
        let session = doc.maskCanvas
        await session.waitForLoad()
        try await doc.manageMask(.fill)
        await session.waitForLoad()
        XCTAssertEqual(session.loaded?.resolved.path, helper.mask(doc.state.workingModel))
        let ids = doc.identity.layers[1]
        doc.select(.effect(ids.id, ids.effects[0]))
        await session.waitForLoad()
        XCTAssertEqual(session.loaded?.resolved.target.layerID, ids.id)
        _ = try helper.target()
        for action in [WSSMaskAction.clear, .fill, .remove] {
            try await doc.manageMask(action)
            doc.revert()
            XCTAssertEqual(doc.state.workingModel, original)
            await session.waitForLoad()
            XCTAssertEqual(session.loaded?.resolved.path, helper.mask(original))
        }
        try await doc.manageMask(.remove)
        try await doc.manageMask(.create)
        let snapshot = try WSSSaveAsSnapshot(
            document: doc.state.workingModel, state: doc.state,
            source: doc.project.handle, name: "Mask copy")
        let receipt = try await helper.store.saveWSSAs(snapshot)
        XCTAssertEqual(receipt.project.document, snapshot.model)
        XCTAssertEqual(Set(receipt.project.diskBasis.assets.keys), snapshot.model.referencedPaths)
        for path in snapshot.model.referencedPaths {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: receipt.project.handle.root.appendingPathComponent(path).path))
        }
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, doc.state.workingModel)
        // Only this isolated fixture is removed; the copied project must remain usable.
        try FileManager.default.removeItem(at: doc.project.handle.root)
        let independent = try await WSSEditorProjectLoader().load(receipt.project.handle.wallpaper)
        XCTAssertEqual(independent.document, snapshot.model)
    }
    func testAllSupportedSlotsAndUnsupportedVectorFields() async throws {
        let fixtures = WSSEditorLivePreviewTests()
        try await fixtures.setUp()
        defer { try? fixtures.helper.tearDownWithError() }
        for name in [
            "WSS-Ripple-v1", "WSS-Clouds-v1", "WSS-Flow-v1",

        ] {
            let loaded = try await fixtures.project(name)
            let value = WSSEditorDocument(project: loaded)
            defer { value.close() }
            let ids = value.identity.layers[0]
            value.select(.effect(ids.id, ids.effects[0]))
            if name == "WSS-Flow-v1" {
                XCTAssertNil(value.maskManagementTarget)
                for action in WSSMaskAction.allCases { XCTAssertFalse(value.canManageMask(action)) }
                continue
            }
            let before = value.state.workingModel
            try await value.manageMask(.remove)
            try await value.manageMask(.create)
            await value.waitForPreview()
            XCTAssertTrue(value.previewIsCurrent)
            value.undoManager.undo()
            value.undoManager.undo()
            XCTAssertEqual(value.state.workingModel, before)
        }
    }
    func testInvalidSelectionAndLocksFailClosed() async throws {
        let original = doc.state.workingModel
        let ids = doc.identity.layers[0]
        for selection: WSSEditorSelection? in [
            nil, .effect(ids.id, WSSEffectID()), .effect(WSSLayerID(), ids.effects[0]),
        ] {
            doc.selection = selection
            XCTAssertNil(doc.maskManagementTarget)
            for action in WSSMaskAction.allCases { XCTAssertFalse(doc.canManageMask(action)) }
            do {
                try await doc.manageMask(.create)
                XCTFail("invalid selection")
            } catch {}
        }
        _ = try helper.target()
        doc.interactionLocked = true
        XCTAssertFalse(doc.canManageMask(.remove))
        doc.interactionLocked = false
        XCTAssertEqual(doc.state.workingModel, original)
    }
    func testCreationResolutionUsesLocalGeometryAndExistingLimits() async throws {
        for (size, expected) in [
            ([Float(64), 32], [64, 32]), ([8192, 8192], [5792, 5792]),
            ([1920, 1080], [1920, 1080]),
        ] {
            let bitmap = try await WSSMaskPreparation().blackMask(size: size)
            XCTAssertEqual([bitmap.width, bitmap.height], expected)
            XCTAssertEqual(bitmap.uvScale, SIMD2(1, 1))
            XCTAssertLessThanOrEqual(bitmap.pixels.count, 32 * 1024 * 1024)
        }
    }
}

extension WSSMaskManagementTests {
    func testManagementTargetRejectsInconsistentIdentityShapes() {
        let layer = doc.identity.layers[0]
        let selected = WSSEditorSelection.effect(layer.id, layer.effects[0])
        var shorter = doc.identity
        shorter.layers[0].effects.removeLast()
        var longer = doc.identity
        let extra = WSSEffectID()
        longer.layers[0].effects.append(extra)
        var missing = doc.identity
        missing.layers.removeLast()
        for ids in [shorter, longer, missing] {
            let snapshot = WSSEditorDocument.Snapshot(
                state: doc.state, identity: ids, selection: selected)
            XCTAssertNil(snapshot.maskManagementTarget)
        }
        XCTAssertNil(
            WSSEditorDocument.Snapshot(
                state: doc.state, identity: longer,
                selection: .effect(layer.id, extra)
            ).maskManagementTarget)
    }
    func testReplacementRejectsStalePickerTargetAndUsesRedInsteadOfAlpha() async throws {
        let url = helper.helper.helper.root.appendingPathComponent("red.png")
        try WSSNativeSceneTests().png([192, 20, 40, 80], width: 1, height: 1).write(to: url)
        try await doc.manageMask(.replace, file: url)
        let red = try await pixels()
        XCTAssertEqual(red, Data([192]))
        let before = doc.state.workingModel
        let ids = doc.identity.layers[1]
        var messages = 0
        doc.presentMessage = { _, _ in messages += 1 }
        doc.chooseMaskFile = {
            self.doc.select(.effect(ids.id, ids.effects[0]))
            return url
        }
        await doc.chooseMaskReplacement()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertEqual(messages, 1)
    }
    func testAutoCreateCancellationAndCloseDecisions() async throws {
        try await unmask()
        let original = doc.state.workingModel
        let session = doc.maskCanvas
        session.setBrush(true)
        session.setBrush(false)
        await session.waitForBrushActivation()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertFalse(doc.isDirty)
        try await doc.manageMask(.create)
        for choice in [WSSEditorDocument.CloseChoice.cancel, .discard] {
            doc.chooseClose = { choice }
            let result = await doc.resolveChanges()
            XCTAssertEqual(result, choice == .discard)
        }
        doc.chooseClose = { .save }
        let saved = await doc.resolveChanges()
        XCTAssertTrue(saved)
        XCTAssertFalse(doc.isDirty)
    }
    func testRevertCreateReplaceAndUVPreservation() async throws {
        let original = doc.state.workingModel
        let path = helper.helper.helper.root.appendingPathComponent("new.png")
        try WSSImageImportTests().image().write(to: path)
        try await doc.manageMask(.replace, file: path)
        doc.revert()
        XCTAssertEqual(doc.state.workingModel, original)
        try await doc.manageMask(.remove)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let unmasked = doc.state.workingModel
        try await doc.manageMask(.create)
        doc.revert()
        XCTAssertEqual(doc.state.workingModel, unmasked)
        XCTAssertNil(doc.selectedMaskTarget)
        XCTAssertNil(doc.maskCanvas.loaded)
    }
    func testClearFillPreserveExplicitUVContractAndSharedReference() async throws {
        let bitmap = try WSSMaskBitmap(
            width: 2, height: 1, uvScale: SIMD2(0.5, 0.75), pixels: Data([0, 255]))
        let definition = bitmap.definition(path: "assets/mask.png")
        var model = doc.state.workingModel
        if case .image(var image) = model.layers[0].content {
            image.effects = image.effects.map {
                .init(parameters: $0.native, mask: definition, field: $0.fieldDefinition)
            }
            model.layers[0].content = .image(image)
        }
        try model.encoded().write(to: helper.helper.item.url)
        helper.doc.close()
        helper.doc = helper.makeDocument(
            try await WSSEditorProjectLoader().load(helper.helper.item))
        _ = try helper.target()
        for action in [WSSMaskAction.clear, .fill] {
            try await doc.manageMask(action)
            guard case .image(let image) = doc.state.workingModel.layers[0].content else {
                return XCTFail()
            }
            XCTAssertEqual(image.effects[0].maskDefinition?.uvScale, [0.5, 0.75])
            XCTAssertEqual(image.effects[0].maskDefinition?.filter, "linear")
            XCTAssertEqual(image.effects[0].maskDefinition?.mipmapped, false)
            XCTAssertEqual(image.effects[1].maskDefinition, definition)
        }
    }
    func testOversizedImportAndInsufficientStagingBudgetFailWithoutMutation() async throws {
        let url = helper.helper.helper.root.appendingPathComponent("oversized.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(WSSImageImporter.inputLimit + 1))
        try handle.close()
        let before = doc.state.workingModel
        do {
            try await doc.manageMask(.replace, file: url)
            XCTFail("oversized source accepted")
        } catch {}
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertFalse(doc.undoManager.canUndo)
        let black = try await WSSMaskPreparation().blackMask(size: [16, 8])
        do {
            _ = try await WSSMaskPreparation().generation(black, remainingBudget: 0)
            XCTFail("staging budget ignored")
        } catch {}
    }
}
