import AppKit
import Darwin
import XCTest

@testable import Wupsy

@MainActor final class WSSEditorImageEditingTests: XCTestCase {
    var helper: WSSEditorWorkspaceTests!
    var doc: WSSEditorDocument!
    var store: ManagedWallpaperStore!
    override func setUp() async throws {
        helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
        let storage = helper.helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([helper.item!]).write(to: storage)
        let localStore = ManagedWallpaperStore(storage: storage)
        store = localStore
        let handle = helper.project.handle
        doc = WSSEditorDocument(
            project: helper.project,
            save: { snapshot in
                let candidate = try await WSSManifestSaveValidator().prepare(
                    snapshot, handle: handle)
                return try await localStore.commitWSSManifest(candidate)
            })
    }
    override func tearDown() async throws {
        doc.close()
        doc = nil
        store = nil
        try await helper.tearDown()
        helper = nil
    }
    func generation(_ width: Int = 12, _ height: Int = 8) async throws -> WSSImageGeneration {
        try await WSSImageImporter().normalize(
            WSSImageImportTests().image(width: width, height: height), extension: "png")
    }
    func snapshot() throws -> WSSSaveSnapshot {
        var state = doc.state
        return try XCTUnwrap(state.beginSave())
    }
    func candidate() async throws -> WSSValidatedManifestCandidate {
        try await WSSManifestSaveValidator().prepare(snapshot(), handle: helper.project.handle)
    }
    func assertUnchanged(
        _ model: WSSSceneDocumentV1, _ catalog: [String: WSSContentFingerprint],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(doc.state.workingModel, model, file: file, line: line)
        XCTAssertEqual(doc.state.resourceCatalog, catalog, file: file, line: line)
        XCTAssertFalse(doc.undoManager.canUndo, file: file, line: line)
    }
    func testCorruptImagePickerShowsLocalizedDetailWithoutDocumentMutation() async throws {
        let model = doc.state.workingModel
        let catalog = doc.state.resourceCatalog
        let file = helper.helper.root.appendingPathComponent("invalid-test.png")
        try Data("Synthetic invalid image".utf8).write(to: file)
        let disk = try helper.helper.snapshot()
        doc.chooseImageFile = { file }
        var title = ""
        var detail = ""
        doc.presentMessage = {
            title = $0
            detail = $1
        }
        await doc.chooseImage()
        XCTAssertEqual(title, EditorText.imageImportError.text)
        XCTAssertEqual(detail, EditorErrorPresentation.message(WSSImageImportError.corrupt))
        assertUnchanged(model, catalog)
        XCTAssertFalse(doc.isDirty)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertEqual(try helper.helper.snapshot(), disk)
    }
    func testPickerCancelHasNoMutationOrStaging() async throws {
        let model = doc.state.workingModel
        let catalog = doc.state.resourceCatalog
        let disk = try helper.helper.snapshot()
        doc.chooseImageFile = { nil }
        await doc.chooseImage()
        assertUnchanged(model, catalog)
        XCTAssertFalse(doc.isDirty)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertEqual(try helper.helper.snapshot(), disk)
    }
    func testAddDefaultsPlacementStableIdentityOneUndoAndPreview() async throws {
        let disk = try helper.helper.snapshot()
        let original = doc.state.workingModel
        let originalIDs = doc.identity
        let generation = try await generation()
        try await doc.installImage(generation)
        let addedID = try XCTUnwrap(doc.identity.layers.last?.id)
        guard case .image(let image) = doc.state.workingModel.layers.last?.content else {
            return XCTFail("missing image")
        }
        XCTAssertEqual(image.asset, generation.path)
        XCTAssertEqual(image.transform.center, [32, 32])
        XCTAssertEqual(image.transform.size, [12, 8])
        XCTAssertEqual(image.transform.scale, [1, 1])
        XCTAssertEqual(image.transform.rotation, 0)
        XCTAssertEqual(image.opacity, 1)
        XCTAssertEqual(image.composition, "sourceOver")
        XCTAssertTrue(image.visible)
        XCTAssertTrue(image.effects.isEmpty)
        XCTAssertEqual(image.definition?.uvScale, [1, 1])
        XCTAssertEqual(doc.selection, .layer(addedID))
        XCTAssertNil(doc.transformModeLayer)
        XCTAssertTrue(doc.isDirty)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        XCTAssertNotNil(doc.previewResources.images[.init(value: generation.path)])
        let resources = try await WSSStaticCanvasPreparation().prepare(
            doc.canvasModel, handle: helper.project.handle, catalog: doc.state.resourceCatalog,
            sessionAssets: doc.state.sessionAssets)
        XCTAssertNotNil(resources.images[.init(value: generation.path)])
        XCTAssertEqual(try helper.helper.snapshot(), disk)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertEqual(doc.identity, originalIDs)
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertFalse(doc.isDirty)
        doc.undoManager.redo()
        XCTAssertEqual(doc.identity.layers.last?.id, addedID)
        XCTAssertEqual(doc.state.workingModel.layers.last?.imageDefinition?.asset, generation.path)
        XCTAssertNotNil(try doc.state.sessionAssets[generation.path]?.read())
    }
    func testAddFitsProportionallyWithoutUpscaling() async throws {
        try await doc.installImage(generation(128, 32))
        XCTAssertEqual(doc.state.workingModel.layers.last?.imageTransform?.size, [64, 16])
        XCTAssertEqual(doc.state.workingModel.layers.last?.imageTransform?.center, [32, 32])
    }
    func testReplacePreservesLayerEffectsMasksIDsAndQuadAcrossAspectRatios() async throws {
        let id = doc.identity.layers[0].id
        try doc.setImage(.centerX, value: 20, layer: id)
        try doc.setImage(.rotation, value: 35, layer: id)
        try doc.setImage(.scaleX, value: 1.5, layer: id)
        try doc.setVisibility(false, layer: id)
        doc.undoManager.removeAllActions()
        let original = doc.state.workingModel
        let ids = doc.identity
        let replacement = try await generation(8, 40)
        try await doc.installImage(replacement, replacing: id)
        guard case .image(var actual) = doc.state.workingModel.layers[0].content,
            case .image(let previous) = original.layers[0].content
        else { return XCTFail("image") }
        XCTAssertEqual(actual.transform, previous.transform)
        XCTAssertEqual(actual.definition?.uvScale, [1, 1])
        actual.asset = previous.asset
        actual.definition = previous.definition
        XCTAssertEqual(actual, previous)
        XCTAssertEqual(doc.identity, ids)
        XCTAssertEqual(doc.state.workingModel.layers[1], original.layers[1])
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel.layers[0].imageDefinition?.asset, replacement.path)
        XCTAssertEqual(doc.identity, ids)
    }
    func testReplacePreservesExistingSamplingAndResetsOnlyImageUV() async throws {
        var model = helper.project.document
        guard case .image(var image) = model.layers[0].content else { return XCTFail("fixture") }
        let asset = try helper.project.assets.image(for: .init(value: image.asset))
        image.definition = .init(
            asset: image.asset, encoding: "image", width: asset.width,
            height: asset.height, uvScale: [0.5, 0.75], filter: "nearest", edge: "repeat",
            mipmapped: false)
        model.layers[0].content = .image(image)
        try model.encoded().write(to: helper.project.handle.entry)
        let loaded = try await WSSEditorProjectLoader().load(helper.item)
        doc.close()
        doc = WSSEditorDocument(project: loaded)
        let ids = doc.identity
        let replacement = try await generation(11, 17)
        try await doc.installImage(replacement, replacing: ids.layers[0].id)
        let contract = try XCTUnwrap(doc.state.workingModel.layers[0].imageDefinition)
        XCTAssertEqual(contract.filter, "nearest")
        XCTAssertEqual(contract.edge, "repeat")
        XCTAssertFalse(contract.mipmapped)
        XCTAssertEqual(contract.uvScale, [1, 1])
        XCTAssertEqual(contract.width, 11)
        XCTAssertEqual(contract.height, 17)
        XCTAssertEqual(doc.identity, ids)
    }
    func testStaleTargetAndInvalidCandidateDoNotMutateCatalogOrUndo() async throws {
        let model = doc.state.workingModel
        let catalog = doc.state.resourceCatalog
        do {
            try await doc.installImage(generation(), replacing: WSSLayerID())
            XCTFail("stale target accepted")
        } catch {}
        assertUnchanged(model, catalog)
        // Descriptor/content mismatch must fail full candidate preparation.
        let valid = try await generation()
        let invalid = try WSSImageGeneration(bytes: valid.read(), width: 99, height: 99)
        do {
            try await doc.installImage(invalid, replacing: doc.identity.layers[0].id)
            XCTFail("invalid accepted")
        } catch {
            guard case WSSImageImportError.incompatible = error else {
                return XCTFail("Expected incompatible, received \(error)")
            }
        }
        assertUnchanged(model, catalog)
        XCTAssertFalse(doc.isDirty)
    }
    func testTargetCapturedBeforePickerAndRejectedAfterDeletion() async throws {
        let id = doc.identity.layers[0].id
        let file = helper.helper.root.appendingPathComponent("input.png")
        try WSSImageImportTests().image().write(to: file)
        doc.chooseImageFile = {
            // Simulate an independently installed structural state while the picker
            // is pending; interactive deletion itself is now blocked during import.
            var model = self.doc.state.workingModel
            var ids = self.doc.identity
            model.layers.remove(at: 0)
            ids.layers.remove(at: 0)
            try? self.doc.mutate(
                model, name: "Fixture deletion", ids: ids,
                selected: .layer(ids.layers[0].id))
            return file
        }
        await doc.chooseImage(replacing: id)
        XCTAssertFalse(doc.identity.layers.contains { $0.id == id })
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertEqual(doc.state.workingModel.layers.count, 1)
    }
    func testLayerLimitRejectsAddWithoutMutation() async throws {
        var model = doc.state.workingModel
        model.layers = Array(repeating: model.layers[1], count: 128)
        let bytes = try model.encoded()
        try bytes.write(to: helper.project.handle.entry)
        let loaded = try await WSSEditorProjectLoader().load(helper.item)
        doc.close()
        doc = WSSEditorDocument(project: loaded)
        let catalog = doc.state.resourceCatalog
        do {
            try await doc.installImage(generation())
            XCTFail("limit ignored")
        } catch {}
        assertUnchanged(model, catalog)
    }
    func testAggregateDecodedBudgetFailureLeavesDocumentUnchanged() async throws {
        let model = doc.state.workingModel
        let catalog = doc.state.resourceCatalog
        let large = try await generation(8192, 4096)
        do {
            try await doc.installImage(large)
            XCTFail("decoded budget ignored")
        } catch {
            guard case WSSImageImportError.decodedBudget = error else {
                return XCTFail("Expected decodedBudget, received \(error)")
            }
        }
        assertUnchanged(model, catalog)
        XCTAssertFalse(doc.isDirty)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
    }
    func testAddReplaceMultipleGenerationsSaveReopenAndUndoAfterSave() async throws {
        let before = try helper.helper.snapshot()
        let added = try await generation()
        let replaced = try await generation(10, 16)
        try await doc.installImage(added)
        try await doc.installImage(replaced, replacing: doc.identity.layers[0].id)
        let model = doc.state.workingModel
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(doc.isDirty)
        let loaded = try await WSSEditorProjectLoader().load(helper.item)
        XCTAssertEqual(loaded.document, model)
        XCTAssertEqual(Set(loaded.diskBasis.assets.keys), model.referencedPaths)
        for (path, bytes) in before where !path.hasSuffix("scene.wss.json") {
            XCTAssertEqual(try helper.helper.snapshot()[path], bytes)
        }
        doc.undoManager.undo()
        XCTAssertTrue(doc.isDirty)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        let resaved = await doc.save()
        XCTAssertTrue(resaved)
        doc.undoManager.redo()
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
    }
    func testSnapshotIncludesExactlyReferencedSessionGenerations() async throws {
        let a = try await generation()
        let b = try await generation(13, 9)
        let id = doc.identity.layers[1].id
        try await doc.installImage(a, replacing: id)
        try await doc.installImage(b, replacing: id)
        let snapshot = try snapshot()
        XCTAssertEqual(Set(snapshot.sessionAssets.keys), [b.path])
        XCTAssertEqual(Set(snapshot.resourceCatalog!.keys), snapshot.model.referencedPaths)
        XCTAssertNotNil(doc.state.sessionAssets[a.path])
        XCTAssertNotNil(doc.state.sessionAssets[b.path])
    }
    func testEveryAssetAndManifestFaultKeepsOldAuthorityAndRetryWorks() async throws {
        let original = try Data(contentsOf: helper.project.handle.entry)
        for stage: WSSManifestWriter.Stage in [
            .assetWrite, .assetPartialWrite, .assetFlush, .assetClose, .assetPublish,
            .afterAssetPublish, .createTemp, .partialWrite, .flush, .close, .beforeCommit, .replace,
        ] {
            let generation = try await generation()
            try await doc.installImage(generation, replacing: doc.identity.layers[1].id)
            let candidate = try await candidate()
            do {
                _ = try await store.commitWSSManifest(
                    candidate, checkpoint: { if $0 == stage { throw WSSImageImportError.storage } })
                XCTFail("injected failure succeeded")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: helper.project.handle.entry), original)
            let old = try await WSSEditorProjectLoader().load(helper.item)
            XCTAssertEqual(old.document, helper.project.document)
            XCTAssertTrue(doc.isDirty)
            let files = try FileManager.default.contentsOfDirectory(
                atPath: helper.project.handle.root.appendingPathComponent("assets").path)
            XCTAssertFalse(files.contains { $0.hasPrefix(".wss-asset-") })
        }
        let retry = await doc.save()
        XCTAssertTrue(retry)
        let loaded = try await WSSEditorProjectLoader().load(helper.item)
        XCTAssertEqual(loaded.document, doc.state.workingModel)
    }
    func testManifestLastAndPublishedOrphanRemainsNonAuthoritative() async throws {
        let old = try Data(contentsOf: helper.project.handle.entry)
        let generation = try await generation()
        try await doc.installImage(generation)
        let candidate = try await candidate()
        var sawAsset = false
        do {
            _ = try await store.commitWSSManifest(
                candidate,
                checkpoint: { stage in
                    if stage == .beforeCommit {
                        XCTAssertEqual(try Data(contentsOf: self.helper.project.handle.entry), old)
                        XCTAssertEqual(
                            try WSSAssetIO.read(
                                root: self.helper.project.handle.root, path: generation.path,
                                limit: generation.fingerprint.byteCount), try generation.read())
                        sawAsset = true
                        throw WSSImageImportError.storage
                    }
                })
            XCTFail("manifest failure ignored")
        } catch {}
        XCTAssertTrue(sawAsset)
        XCTAssertEqual(try Data(contentsOf: helper.project.handle.entry), old)
        let loaded = try await WSSEditorProjectLoader().load(helper.item)
        XCTAssertFalse(loaded.document.referencedPaths.contains(generation.path))
        let receipt = try await store.commitWSSManifest(candidate)
        XCTAssertEqual(receipt.diskBasis.assets[generation.path], generation.fingerprint)
    }
    func testCollisionAndSymlinkNeverOverwriteExistingTargets() async throws {
        let manifest = try Data(contentsOf: helper.project.handle.entry)
        for symlink in [false, true] {
            let generation = try await generation()
            try await doc.installImage(generation, replacing: doc.identity.layers[1].id)
            let candidate = try await candidate()
            let target = helper.project.handle.root.appendingPathComponent(generation.path)
            let sentinel = helper.helper.root.appendingPathComponent(
                "sentinel-" + UUID().uuidString)
            let bytes = Data("never replace".utf8)
            try bytes.write(to: sentinel)
            if symlink {
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: sentinel)
            } else {
                try bytes.write(to: target)
            }
            do {
                _ = try await store.commitWSSManifest(candidate)
                XCTFail("collision accepted")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
            if !symlink { XCTAssertEqual(try Data(contentsOf: target), bytes) }
            XCTAssertEqual(try Data(contentsOf: helper.project.handle.entry), manifest)
        }
    }
    func testPublishedGenerationFingerprintMutationRejectsRetry() async throws {
        let generation = try await generation()
        try await doc.installImage(generation)
        let candidate = try await candidate()
        let manifest = try Data(contentsOf: helper.project.handle.entry)
        do {
            _ = try await store.commitWSSManifest(
                candidate,
                checkpoint: { stage in
                    if stage == .afterAssetPublish { throw WSSImageImportError.storage }
                })
            XCTFail("fault not injected")
        } catch {}
        let target = helper.project.handle.root.appendingPathComponent(generation.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try Data(repeating: 0, count: generation.fingerprint.byteCount).write(to: target)
        do {
            _ = try await store.commitWSSManifest(candidate)
            XCTFail("tampered generation reused")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: helper.project.handle.entry), manifest)
        XCTAssertTrue(doc.isDirty)
    }
    func testSessionCatalogDoesNotPermitDuplicateOwnership() async throws {
        let generation = try await generation()
        var state = doc.state
        try state.retainGeneration(generation)
        XCTAssertThrowsError(try state.retainGeneration(generation))
        XCTAssertEqual(state.resourceCatalog[generation.path], generation.fingerprint)
        XCTAssertEqual(try state.sessionAssets[generation.path]?.read(), try generation.read())
        let refs = Set(state.resourceCatalog.keys)
        XCTAssertTrue(doc.state.workingModel.referencedPaths.isSubset(of: refs))
        state.close()
        XCTAssertTrue(state.sessionAssets.isEmpty)
    }
    func testOwnershipRecheckedAfterAssetCloseBeforePublication() async throws {
        let generation = try await generation()
        try await doc.installImage(generation)
        let candidate = try await candidate()
        let original = try Data(contentsOf: helper.project.handle.entry)
        let storage = helper.helper.root.appendingPathComponent("library.json")
        do {
            _ = try await store.commitWSSManifest(
                candidate,
                checkpoint: { stage in
                    if stage == .assetPublish {
                        try JSONEncoder().encode([Wallpaper]()).write(to: storage)
                    }
                })
            XCTFail("removed ownership accepted")
        } catch { XCTAssertEqual(error as? WSSSaveError, .targetDisappeared) }
        XCTAssertEqual(try Data(contentsOf: helper.project.handle.entry), original)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: helper.project.handle.root.appendingPathComponent(generation.path).path))
    }
    func testExternalConflictBeforePublicationDoesNotInstallGeneration() async throws {
        let generation = try await generation()
        try await doc.installImage(generation)
        let candidate = try await candidate()
        try Data("external change".utf8).write(to: helper.project.handle.entry)
        do {
            _ = try await store.commitWSSManifest(candidate)
            XCTFail("conflict accepted")
        } catch { XCTAssertEqual(error as? WSSSaveError, .externalConflict) }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: helper.project.handle.root.appendingPathComponent(generation.path).path))
    }
}
