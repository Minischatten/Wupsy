import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSNewVectorEffectTests: XCTestCase {
    var fixture: WSSDirectionCanvasTests!
    var doc: WSSEditorDocument { fixture.doc }
    override func setUp() async throws {
        fixture = WSSDirectionCanvasTests()
        try await fixture.setUp()
        var model = doc.state.workingModel
        guard case .image(var image) = model.layers[0].content else { return XCTFail() }
        image.effects = []
        image.transform.size = [256, 256]
        image.transform.center = [64, 64]
        model.layers[0].content = .image(image)
        try await fixture.reload(model)
        doc.select(.layer(doc.identity.layers[0].id))
    }
    override func tearDown() async throws {
        try await fixture.tearDown()
        fixture = nil
    }
    func currentEffect() throws -> WSSSceneDocumentV1.Effect {
        let address = try XCTUnwrap(doc.effectAddress)
        guard case .image(let image) = doc.state.workingModel.layers[address.layerIndex].content
        else { throw WSSVectorFieldEditError.invalid }
        return image.effects[address.effectIndex]
    }
    func paint(_ document: WSSEditorDocument, neutralize: Bool = false) async throws {
        let session = document.directionCanvas
        session.setEnabled(true)
        await session.waitForLoad()
        let geometry = try XCTUnwrap(session.geometry)
        XCTAssertNotNil(session.loaded)
        session.setDiameter(60)
        session.setOperation(neutralize ? .neutralize : .direction)
        let a = geometry.scene(SIMD2(0.2, 0.5))
        let b = geometry.scene(SIMD2(0.8, 0.5))
        XCTAssertTrue(session.begin(a, erase: false))
        session.finish(b)
        await session.waitForFinish()
        await session.waitForLoad()
        await document.waitForPreview()
        XCTAssertNil(session.error)
    }
    func testMenuEntriesAndDeterministicResolutionRule() throws {
        XCTAssertEqual(
            WSSAddableEffect.allCases.map(\.rawValue),
            ["Ripple", "Clouds", "Flow"])
        for (size, width, height): (SIMD2<Float>, Int, Int) in [
            (SIMD2(1920, 1080), 512, 288), (SIMD2(1080, 1920), 288, 512),
            (SIMD2(512, 512), 512, 512), (SIMD2(400, 200), 400, 200),
            (SIMD2(8192, 1), 512, 1), (SIMD2(1, 8192), 1, 512),
            (SIMD2(1000, 333), 512, 170), (SIMD2(0.2, 0.1), 1, 1),
        ] {
            let result = try WSSNewVectorField.dimensions(size)
            XCTAssertEqual(result.width, width)
            XCTAssertEqual(result.height, height)
        }
        for size: SIMD2<Float> in [
            SIMD2(.nan, 1), SIMD2(.infinity, 1), SIMD2(0, 1), SIMD2(8193, 1),
        ] {
            XCTAssertThrowsError(try WSSNewVectorField.dimensions(size))
        }
        XCTAssertThrowsError(try WSSNewVectorField.generation(SIMD2(512, 512), remainingBudget: 1))
    }
    func testNewFieldsDefaultsNeutralFramesAndOneUndoRedoSameGeneration() async throws {
        let before = doc.state.workingModel
        let ids = doc.identity
        let frames = try [0.0, 0.35, 1.2].map {
            try WSSEditorLivePreviewTests().frame(doc.previewResources, time: $0, width: 128)
        }
        for kind: WSSAddableEffect in [.flow] {
            XCTAssertTrue(doc.canAddEffect(kind))
            try doc.addEffect(kind)
            await doc.waitForPreview()
            let effect = try currentEffect()
            let path = try XCTUnwrap(effect.fieldDefinition?.asset.value)
            let generation = try XCTUnwrap(doc.state.sessionAssets[path])
            let field = try WSSVectorFieldAsset.decodeNative(generation.read())
            XCTAssertEqual(field.width, 256)
            XCTAssertEqual(field.height, 256)
            XCTAssertNil(field.coverage)
            XCTAssertTrue(field.isNeutral)
            XCTAssertTrue(field.vectors.allSatisfy { $0 == 0 })
            guard case .flow(let value) = effect.native else { return XCTFail() }
            XCTAssertEqual(value.speed, 40)
            XCTAssertEqual(value.strength, 12)
            XCTAssertEqual(value.edgeProtectionPixels, 0)
            for (index, time) in [0.0, 0.35, 1.2].enumerated() {
                XCTAssertEqual(
                    try WSSEditorLivePreviewTests().frame(
                        doc.previewResources, time: time, width: 128), frames[index])
            }
            let after = doc.state.workingModel
            let afterIDs = doc.identity
            XCTAssertEqual(doc.directionAvailability, .native)
            doc.directionCanvas.setEnabled(true)
            await doc.directionCanvas.waitForLoad()
            XCTAssertNotNil(doc.directionCanvas.loaded)
            XCTAssertTrue(doc.directionCanvas.samples.allSatisfy { $0.vector == .zero })
            doc.undoManager.undo()
            XCTAssertEqual(doc.state.workingModel, before)
            XCTAssertEqual(doc.identity, ids)
            XCTAssertFalse(doc.undoManager.canUndo)
            doc.undoManager.redo()
            XCTAssertEqual(doc.state.workingModel, after)
            XCTAssertEqual(doc.identity, afterIDs)
            XCTAssertTrue(doc.state.sessionAssets[path] === generation)
            doc.undoManager.undo()
        }
    }
    func testIndependentResourcesPaintNeutralizeAndStrokeUndoRedo() async throws {
        try doc.addEffect(.flow)
        let first = try XCTUnwrap(try currentEffect().fieldDefinition?.asset.value)
        try doc.addEffect(.flow)
        let second = try XCTUnwrap(try currentEffect().fieldDefinition?.asset.value)
        try doc.addEffect(.flow)
        let third = try XCTUnwrap(try currentEffect().fieldDefinition?.asset.value)
        XCTAssertEqual(Set([first, second, third]).count, 3)
        let before = doc.state.workingModel
        await doc.waitForPreview()
        let frame = try WSSEditorLivePreviewTests().frame(
            doc.previewResources, time: 0.35, width: 128)
        try await paint(doc)
        XCTAssertNotEqual(
            try WSSEditorLivePreviewTests().frame(doc.previewResources, time: 0.35, width: 128),
            frame)
        let painted = try currentEffect().fieldDefinition?.asset.value
        XCTAssertNotEqual(painted, third)
        XCTAssertTrue(
            try WSSVectorFieldAsset.decodeNative(XCTUnwrap(doc.state.sessionAssets[first]).read())
                .isNeutral)
        XCTAssertTrue(
            try WSSVectorFieldAsset.decodeNative(XCTUnwrap(doc.state.sessionAssets[second]).read())
                .isNeutral)
        let after = doc.state.workingModel
        let generation = doc.state.sessionAssets[painted!]
        doc.undoManager.undo()
        await doc.directionCanvas.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, before)
        doc.undoManager.redo()
        await doc.directionCanvas.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, after)
        XCTAssertTrue(doc.state.sessionAssets[painted!] === generation)
        try await paint(doc, neutralize: true)
        let neutralized = try WSSVectorFieldAsset.decodeNative(
            XCTUnwrap(doc.state.sessionAssets[currentEffect().fieldDefinition!.asset.value]).read())
        XCTAssertEqual(
            WSSDirectionSampling.samples(neutralized, at: [SIMD2(0.5, 0.5)])[0].vector, .zero)
        XCTAssertNil(neutralized.coverage)
    }
    func testReorderRemoveAndRevertPreserveEffectResourceIdentity() async throws {
        let before = doc.state.workingModel
        for kind: WSSAddableEffect in [.ripple, .flow, .flow, .flow] {
            try doc.addEffect(kind)
        }
        let ids = doc.identity.layers[0]
        let model = doc.state.workingModel
        let path = try currentEffect().fieldDefinition?.asset.value
        try doc.moveEffect(ids.id, effect: ids.effects[3], to: 0)
        XCTAssertEqual(try currentEffect().fieldDefinition?.asset.value, path)
        try doc.deleteSelection()
        doc.undoManager.undo()
        XCTAssertEqual(try currentEffect().fieldDefinition?.asset.value, path)
        doc.undoManager.redo()
        XCTAssertFalse(doc.identity.layers[0].effects.contains(ids.effects[3]))
        doc.undoManager.undo()
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, model)
        doc.revert()
        await doc.waitForPreview()
        XCTAssertEqual(doc.state.workingModel, before)
    }
    func testTwoFlowEditsStayStageLocal() async throws {
        try doc.addEffect(.flow)
        let first = try XCTUnwrap(doc.selection)
        try doc.addEffect(.flow)
        let secondPath = try XCTUnwrap(try currentEffect().fieldDefinition?.asset.value)
        let secondGeneration = try XCTUnwrap(doc.state.sessionAssets[secondPath])
        doc.select(first)
        try await paint(doc)
        XCTAssertNotEqual(try currentEffect().fieldDefinition?.asset.value, secondPath)
        XCTAssertTrue(doc.state.sessionAssets[secondPath] === secondGeneration)
        XCTAssertTrue(try WSSVectorFieldAsset.decodeNative(secondGeneration.read()).isNeutral)
    }
    func testSourceFailureDoesNotInstallEffectGenerationDirtyOrUndo() throws {
        let before = doc.state.workingModel
        let ids = doc.identity
        let manifest = try Data(contentsOf: doc.project.handle.wallpaper.url)
        let file = doc.project.handle.root.appendingPathComponent("assets/base.png")
        try Data("external corruption".utf8).write(to: file)
        XCTAssertThrowsError(try doc.addEffect(.flow))
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertEqual(doc.identity, ids)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertEqual(try Data(contentsOf: doc.project.handle.wallpaper.url), manifest)
    }
    func testGenerationBudgetFailureIsAtomic() async throws {
        var model = doc.state.workingModel
        guard case .image(var image) = model.layers[0].content else { return XCTFail() }
        image.transform.size = [512, 512]
        model.layers[0].content = .image(image)
        try await fixture.reload(model)
        doc.select(.layer(doc.identity.layers[0].id))
        let field = WSSVectorFieldAsset(
            width: 8192, height: 511, vectors: Data(repeating: 0, count: 8192 * 511 * 4),
            coverage: nil, isNeutral: true)
        for _ in 0..<8 {
            try doc.retainImageGeneration(
                WSSEditorAssetGeneration.vectorField(
                    field,
                    remainingBudget: WSSVectorFieldEditorBudget.remainingGenerationBytes(
                        assets: doc.state.sessionAssets)))
        }
        let before = doc.state.workingModel
        let ids = doc.identity
        let catalog = doc.state.resourceCatalog
        XCTAssertThrowsError(try doc.addEffect(.flow))
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertEqual(doc.identity, ids)
        XCTAssertEqual(doc.state.resourceCatalog, catalog)
        XCTAssertEqual(doc.state.sessionAssets.count, 8)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testLocalSizeIgnoresTransformUVScaleAndExistingFieldDoesNotResizeOnImageReplace()
        async throws
    {
        var model = doc.state.workingModel
        guard case .image(var image) = model.layers[0].content else { return XCTFail() }
        image.transform.size = [1920, 1080]
        image.transform.center = [10, 20]
        image.transform.scale = [2, 0.5]
        image.transform.rotation = 0.7
        image.definition = .init(
            asset: image.asset, encoding: "image", width: 128, height: 128, uvScale: [0.5, 0.75],
            filter: "linear", edge: "clamp", mipmapped: false)
        model.layers[0].content = .image(image)
        try await fixture.reload(model)
        doc.select(.layer(doc.identity.layers[0].id))
        try doc.addEffect(.flow)
        let path = try XCTUnwrap(try currentEffect().fieldDefinition?.asset.value)
        let generation = try XCTUnwrap(doc.state.sessionAssets[path])
        let field = try WSSVectorFieldAsset.decodeNative(generation.read())
        XCTAssertEqual(field.width, 512)
        XCTAssertEqual(field.height, 288)
        let replacement = try WSSImageGeneration(
            bytes:
                Data(WSSNativeSceneTests().png([255, 0, 0, 255], width: 1, height: 1)), width: 1,
            height: 1)
        try await doc.installImage(replacement, replacing: doc.identity.layers[0].id)
        XCTAssertTrue(doc.state.sessionAssets[path] === generation)
        XCTAssertEqual(try WSSVectorFieldAsset.decodeNative(generation.read()).width, 512)
    }
    func testDraftFlowBrushParametersFirstSaveReopenAndIndependentSaveAs() async throws {
        let helper = WSSDraftTests()
        try await helper.setUp()
        defer { try? helper.fixture.tearDownWithError() }
        let source = helper.root.appendingPathComponent("Pattern.png")
        try WSSNativeSceneTests().png(
            Array(WSSFlowTests().pixels(size: 256)), width: 256, height: 256
        ).write(to: source)
        let store = helper.store()
        for kind: WSSAddableEffect in [.flow] {
            let project = try await WSSDraftPreparation().create(image: source)
            let document = helper.editor(project, store: store)
            let draftRoot = project.handle.root
            defer { document.close() }
            let selected = document.identity.layers[0].id
            document.select(.layer(selected))
            try document.addEffect(kind)
            XCTAssertTrue(document.isUnpublished)
            XCTAssertEqual(document.state.sessionAssets.count, 2)
            await document.waitForPreview()
            let neutralFrame = try WSSEditorLivePreviewTests().frame(
                document.previewResources, time: 0.35, width: 128)
            try await paint(document)
            XCTAssertNotEqual(
                try WSSEditorLivePreviewTests().frame(
                    document.previewResources, time: 0.35, width: 128), neutralFrame)
            let address = try XCTUnwrap(document.effectAddress)
            try document.setParameter(.flowSpeed, at: address, value: 55)
            try document.setParameter(.flowStrength, at: address, value: 18)
            try document.setParameter(.flowEdgeProtection, at: address, value: 24.25)
            let saved = await document.save()
            XCTAssertTrue(saved)
            XCTAssertFalse(document.isUnpublished)
            XCTAssertFalse(FileManager.default.fileExists(atPath: draftRoot.path))
            guard case .image(let image) = document.state.workingModel.layers[0].content else {
                return XCTFail()
            }
            let path = try XCTUnwrap(image.effects[0].fieldDefinition?.asset.value)
            XCTAssertTrue(path.hasPrefix("assets/editor-"))
            XCTAssertTrue(path.hasSuffix(".wssvf"))
            let reopened = try await WSSEditorProjectLoader().load(
                document.project.handle.wallpaper)
            XCTAssertEqual(reopened.document, document.state.workingModel)
            let savedModel = document.state.workingModel
            try await paint(document, neutralize: true)
            document.revert()
            await document.directionCanvas.waitForLoad()
            await document.waitForPreview()
            XCTAssertEqual(document.state.workingModel, savedModel)
            let copy = try await store.saveWSSAs(
                .init(
                    document: document.state.workingModel, state: document.state,
                    source: document.project.handle, name: "New " + kind.rawValue + " Copy"))
            let a = document.project.handle.root.appendingPathComponent(path)
            let b = copy.project.handle.root.appendingPathComponent(path)
            XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: b))
            XCTAssertNotEqual(
                try FileManager.default.attributesOfItem(atPath: a.path)[.systemFileNumber]
                    as? NSNumber,
                try FileManager.default.attributesOfItem(atPath: b.path)[.systemFileNumber]
                    as? NSNumber)
            let originalRoot = document.project.handle.root
            document.close()
            try FileManager.default.removeItem(at: originalRoot)
            let independent = try await WSSEditorProjectLoader().load(copy.project.handle.wallpaper)
            _ = try WSSEditorLivePreviewTests().frame(independent.resources, time: 0.35, width: 128)
        }
    }
}
