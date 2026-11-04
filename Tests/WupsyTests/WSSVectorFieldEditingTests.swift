import AppKit
import Darwin
import MetalKit
import XCTest

@testable import Wupsy

@MainActor final class WSSVectorFieldEditingTests: XCTestCase {
    var helper: WSSEditorWorkspaceTests!
    var doc: WSSEditorDocument!
    var store: ManagedWallpaperStore!

    override func setUp() async throws {
        helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
        let root = helper.project.handle.root
        let field = try sourceField()
        try field.encodedNative().write(to: root.appendingPathComponent("assets/a.wssvf"))
        try field.encodedNative().write(to: root.appendingPathComponent("assets/b.wssvf"))
        let base = try WSSNativeSceneTests().png(
            Array(WSSFlowTests().pixels()), width: 128, height: 128)
        try base.write(to: root.appendingPathComponent("assets/base.png"))
        var model = helper.project.document
        guard case .image(var image) = model.layers[0].content else { return XCTFail() }
        image.asset = "assets/base.png"
        image.definition = nil
        image.transform = .init(center: [32, 32], size: [128, 128])
        image.effects = [
            try effect("flow", "a"), try effect("flow", "b"), try effect("flow", "a"),
        ]
        model.layers[0].content = .image(image)
        try model.encoded().write(to: helper.item.url)
        helper.project = try await WSSEditorProjectLoader().load(helper.item)
        let storage = helper.helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([helper.item!]).write(to: storage)
        store = ManagedWallpaperStore(storage: storage)
        doc = makeDocument()
    }
    override func tearDown() async throws {
        doc.close()
        doc = nil
        store = nil
        try await helper.tearDown()
        helper = nil
    }
    func makeDocument() -> WSSEditorDocument {
        let handle = helper.project.handle
        let localStore = store!
        return WSSEditorDocument(
            project: helper.project,
            save: { snapshot in
                let candidate = try await WSSManifestSaveValidator().prepare(
                    snapshot, handle: handle)
                return try await localStore.commitWSSManifest(candidate)
            })
    }
    func sourceField(coverage: Bool = true) throws -> WSSVectorFieldAsset {
        // Signed zero, positive/negative subnormal and a hidden nonzero vector.
        let words: [UInt16] = [0, 0x8000, 1, 0x8001, 0x3800, 0xb800, 0, 0]
        var vectors = Data()
        for word in words {
            var value = word.littleEndian
            withUnsafeBytes(of: &value) { vectors.append(contentsOf: $0) }
        }
        let candidate = WSSVectorFieldAsset(
            width: 4, height: 1, vectors: vectors,
            coverage: coverage ? Data([255, 128, 0, 255]) : nil, isNeutral: false)
        try candidate.validate()
        return candidate
    }
    func effect(_ type: String, _ field: String) throws -> WSSSceneDocumentV1.Effect {
        let descriptor: [String: Any] = [
            "format": WSSVectorFieldAsset.fileFormat, "version": 1,
            "asset": "assets/" + field + ".wssvf",
        ]
        guard type == "flow" else { throw WSSVectorFieldEditError.unsupported }
        let json: [String: Any] = [
            "type": "flow", "flowMap": descriptor, "speed": 30, "strength": 12,
        ]
        return try JSONDecoder().decode(
            WSSSceneDocumentV1.Effect.self,
            from: JSONSerialization.data(withJSONObject: json))
    }
    func select(_ index: Int = 2) throws -> WSSVectorFieldTarget {
        let ids = doc.identity.layers[0]
        doc.select(.effect(ids.id, ids.effects[index]))
        return try XCTUnwrap(doc.selectedVectorFieldTarget)
    }
    func fields(_ model: WSSSceneDocumentV1) throws -> [String] {
        guard case .image(let image) = model.layers[0].content else {
            throw WSSVectorFieldEditError.invalid
        }
        return image.effects.compactMap { $0.fieldDefinition?.asset.value }
    }
    func changed(_ edit: WSSVectorFieldEdit) -> Data {
        var bytes = edit.field.vectors
        bytes[0] = 0
        bytes[1] = 0x3c  // +1 X, leave the Y signed-zero and every other texel untouched.
        return bytes
    }
    func edit() async throws -> WSSVectorFieldEdit {
        try await doc.loadVectorField(select())
    }
    func mutate() async throws -> WSSVectorFieldEdit {
        let edit = try await edit()
        let applied = try await doc.replaceVectorField(edit, vectors: changed(edit))
        XCTAssertTrue(applied)
        return edit
    }
    func assertRejected(
        _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let model = doc.state.workingModel
        let catalog = doc.state.resourceCatalog
        let count = doc.state.sessionAssets.count
        let revision = doc.state.workingRevision
        do {
            try await operation()
            XCTFail("accepted invalid operation", file: file, line: line)
        } catch {}
        XCTAssertEqual(doc.state.workingModel, model, file: file, line: line)
        XCTAssertEqual(doc.state.resourceCatalog, catalog, file: file, line: line)
        XCTAssertEqual(doc.state.sessionAssets.count, count, file: file, line: line)
        XCTAssertEqual(doc.state.workingRevision, revision, file: file, line: line)
    }
    func testSharedFlowCopyOnWriteOneUndoRedoDirtyAndExactBytes() async throws {
        let before = doc.state.workingModel
        let ids = doc.identity
        let disk = try helper.helper.snapshot()
        let edit = try await mutate()
        let after = doc.state.workingModel
        let paths = try fields(after)
        XCTAssertEqual(Array(paths.prefix(2)), ["assets/a.wssvf", "assets/b.wssvf"])
        XCTAssertNotEqual(paths[2], paths[0])
        XCTAssertEqual(doc.identity, ids)
        XCTAssertEqual(try helper.helper.snapshot(), disk)
        XCTAssertTrue(doc.isDirty)
        let generation = try XCTUnwrap(doc.state.sessionAssets[paths[2]])
        XCTAssertEqual(generation.kind, .vectorField)
        let result = try WSSVectorFieldAsset.decodeNative(generation.read())
        XCTAssertEqual(result.width, edit.field.width)
        XCTAssertEqual(result.height, edit.field.height)
        XCTAssertEqual(result.coverage, edit.field.coverage)
        XCTAssertEqual(result.vectors, changed(edit))
        XCTAssertEqual(result.vectors.dropFirst(2), edit.field.vectors.dropFirst(2))
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, after)
        XCTAssertTrue(doc.state.sessionAssets[paths[2]] === generation)
        XCTAssertFalse(doc.undoManager.canRedo)
    }
    func testNoOpAndLoadDoNotDirtyStageOrPreparePreview() async throws {
        let resources = doc.previewResources
        let edit = try await edit()
        let result = try await doc.replaceVectorField(edit, vectors: edit.field.vectors)
        XCTAssertFalse(result)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertTrue(doc.previewResources === resources)
        XCTAssertEqual(doc.state.workingRevision, 0)
    }
    func testPreviewReadsNewSessionFieldAndRenderedOutputChanges() async throws {
        let before = try WSSEditorLivePreviewTests().frame(
            doc.previewResources, time: 0.2, width: 128)
        _ = try await mutate()
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        let paths = try fields(doc.state.workingModel)
        let stages = try XCTUnwrap(doc.previewResources.effectPlans[0]?.stages)
        XCTAssertFalse(stages[0].binding.field?.vectors === stages[2].binding.field?.vectors)
        let texture = try XCTUnwrap(
            doc.previewResources.vectorFields?.fields[.init(value: paths[2])]?.vectors)
        var bytes = Data(count: 16)
        bytes.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 1), mipmapLevel: 0)
        }
        XCTAssertEqual(bytes[1], 0x3c)
        let after = try WSSEditorLivePreviewTests().frame(
            doc.previewResources, time: 0.2, width: 128)
        XCTAssertNotEqual(before, after)
    }
    func testSaveReopenUndoRedoSaveAndRevert() async throws {
        let original = doc.state.workingModel
        _ = try await mutate()
        let model = doc.state.workingModel
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(doc.isDirty)
        let reopened = try await WSSEditorProjectLoader().load(helper.item)
        XCTAssertEqual(reopened.document, model)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertTrue(doc.isDirty)
        doc.revert()
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertFalse(doc.isDirty)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, model)
        let next = try await doc.loadVectorField(select())
        var bytes = next.field.vectors
        bytes[1] = 0xb8
        try await doc.replaceVectorField(next, vectors: bytes)
        doc.revert()
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertFalse(doc.isDirty)
    }
    func testSaveAsBeforeAndAfterSaveHasIndependentPhysicalFieldAndRendersWithoutA() async throws {
        _ = try await mutate()
        let path = try fields(doc.state.workingModel)[2]
        let snapshot = try WSSSaveAsSnapshot(
            document: doc.state.workingModel, state: doc.state,
            source: doc.project.handle, name: "Before save")
        let first = try await store.saveWSSAs(snapshot)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let second = try await store.saveWSSAs(
            .init(
                document: doc.state.workingModel, state: doc.state,
                source: doc.project.handle, name: "After save"))
        let a = try FileManager.default.attributesOfItem(
            atPath: doc.project.handle.root.appendingPathComponent(path).path)
        for receipt in [first, second] {
            let b = try FileManager.default.attributesOfItem(
                atPath: receipt.project.handle.root.appendingPathComponent(path).path)
            XCTAssertNotEqual(a[.systemFileNumber] as? NSNumber, b[.systemFileNumber] as? NSNumber)
        }
        doc.close()
        try FileManager.default.removeItem(at: helper.project.handle.root)
        for receipt in [first, second] {
            let reopened = try await WSSEditorProjectLoader().load(receipt.project.handle.wallpaper)
            XCTAssertEqual(reopened.document, receipt.project.document)
            _ = try WSSEditorLivePreviewTests().frame(reopened.resources, time: 0.2, width: 128)
        }
    }
    func testSelectionAwayAndBackRevisionReorderDeleteAndUndoRejectOldCandidate() async throws {
        let edit = try await edit()
        doc.select(.layer(edit.resolved.target.layerID))
        _ = try select()
        await assertRejected {
            try await self.doc.replaceVectorField(edit, vectors: self.changed(edit))
        }
        let current = try await self.edit()
        try doc.moveEffect(
            current.resolved.target.layerID, effect: current.resolved.target.effectID, to: 0)
        await assertRejected {
            try await self.doc.replaceVectorField(current, vectors: self.changed(current))
        }
        let resolved = try doc.resolveVectorFieldTarget(current.resolved.target)
        XCTAssertEqual(resolved.target.effectID, current.resolved.target.effectID)
        let fresh = try await doc.loadVectorField(current.resolved.target)
        try await doc.replaceVectorField(fresh, vectors: changed(fresh))
        let paths = try fields(doc.state.workingModel)
        XCTAssertTrue(paths[0].hasSuffix(".wssvf"))
        XCTAssertNotEqual(paths[0], "assets/a.wssvf")
        XCTAssertEqual(paths[2], "assets/b.wssvf")
        doc.undoManager.undo()
        await assertRejected {
            try await self.doc.replaceVectorField(fresh, vectors: self.changed(fresh))
        }
        let deletion = try await doc.loadVectorField(current.resolved.target)
        try doc.deleteSelection()
        await assertRejected {
            try await self.doc.replaceVectorField(deletion, vectors: self.changed(deletion))
        }
        doc.undoManager.undo()
        let layerDeletion = try await doc.loadVectorField(
            try XCTUnwrap(doc.selectedVectorFieldTarget))
        doc.select(.layer(layerDeletion.resolved.target.layerID))
        try doc.deleteSelection()
        await assertRejected {
            try await self.doc.replaceVectorField(
                layerDeletion, vectors: self.changed(layerDeletion))
        }
    }
    func testWrongSessionIdentityAndParameterResourceReplacementRejected() async throws {
        let target = try select()
        for bad in [
            WSSVectorFieldTarget(
                sessionID: UUID(), layerID: target.layerID, effectID: target.effectID,
                slot: target.slot),
            .init(
                sessionID: target.sessionID, layerID: WSSLayerID(), effectID: target.effectID,
                slot: target.slot),
            .init(
                sessionID: target.sessionID, layerID: target.layerID, effectID: WSSEffectID(),
                slot: target.slot),
        ] {
            XCTAssertThrowsError(try doc.resolveVectorFieldTarget(bad))
        }
        guard case .image(let image) = doc.state.workingModel.layers[0].content else {
            return XCTFail()
        }
        var protected = image.effects[2]
        XCTAssertThrowsError(
            try protected.updateParameters { effect in
                guard case .flow(var flow) = effect else { return }
                flow.flowMap = .init(value: "assets/b.wssvf")
                effect = .flow(flow)
            })
        try doc.addEffect(.ripple)
        XCTAssertNil(doc.selectedVectorFieldTarget)
        await assertRejected { _ = try await self.doc.loadVectorField(target) }
    }
    func testMalformedReplacementAndChangedSourceFailWithoutMutation() async throws {
        let edit = try await edit()
        for bytes in [Data(), Data([0]), Data(repeating: 255, count: 16)] {
            await assertRejected { try await self.doc.replaceVectorField(edit, vectors: bytes) }
        }
        let file = helper.project.handle.root.appendingPathComponent(edit.resolved.path)
        try Data("corrupt".utf8).write(to: file)
        await assertRejected {
            try await self.doc.replaceVectorField(edit, vectors: self.changed(edit))
        }
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testMissingCorruptUnknownVersionOversizedSymlinkAndTraversalFailClosed() async throws {
        let target = try select()
        let file = helper.project.handle.root.appendingPathComponent("assets/a.wssvf")
        let original = try Data(contentsOf: file)
        for mode in 0..<5 {
            try? FileManager.default.removeItem(at: file)
            switch mode {
            case 0: break
            case 1: try Data("bad".utf8).write(to: file)
            case 2:
                var bytes = original
                bytes[8] = 2
                try bytes.write(to: file)
            case 3:
                XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
                let fd = open(file.path, O_WRONLY)
                XCTAssertEqual(ftruncate(fd, off_t(WSSVectorFieldAsset.byteLimit + 33)), 0)
                Darwin.close(fd)
            default:
                try FileManager.default.createSymbolicLink(
                    at: file,
                    withDestinationURL: helper.project.handle.root.appendingPathComponent(
                        "assets/b.wssvf"))
            }
            await assertRejected { _ = try await self.doc.loadVectorField(target) }
        }
        try FileManager.default.removeItem(at: file)
        try original.write(to: file)
        for path in ["../a.wssvf", "/a.wssvf", "assets/../../a.wssvf", "assets\\a.wssvf"] {
            XCTAssertThrowsError(try WSSNativeAssets.validatePath(path))
        }
    }
    func testPNGFieldLoadsWithoutPublishingConversion() async throws {
        let fixture = WSSEditorLivePreviewTests()
        try await fixture.setUp()
        defer { try? fixture.helper.tearDownWithError() }
        let loaded = try await fixture.project("WSS-Flow-v1")
        let pngDoc = WSSEditorDocument(project: loaded)
        defer { pngDoc.close() }
        let ids = pngDoc.identity.layers[0]
        pngDoc.select(.effect(ids.id, ids.effects[0]))
        let target = try XCTUnwrap(pngDoc.selectedVectorFieldTarget)
        XCTAssertEqual(target.slot, .flow)
        let edit = try await pngDoc.loadVectorField(target)
        XCTAssertGreaterThan(edit.field.width, 0)
        XCTAssertFalse(pngDoc.isDirty)
        XCTAssertTrue(pngDoc.state.sessionAssets.isEmpty)
        XCTAssertEqual(pngDoc.state.workingModel, loaded.document)
    }
    func testAbsentCoverageAndExistingLargeDimensionsStayExact() async throws {
        let field = WSSVectorFieldAsset(
            width: 1024, height: 1,
            vectors: Data(repeating: 0, count: 4096), coverage: nil, isNeutral: true)
        try field.encodedNative().write(
            to: helper.project.handle.root.appendingPathComponent("assets/a.wssvf"))
        doc.close()
        helper.project = try await WSSEditorProjectLoader().load(helper.item)
        doc = makeDocument()
        let edit = try await mutate()
        let generation = try XCTUnwrap(doc.state.sessionAssets.values.first)
        let result = try WSSVectorFieldAsset.decodeNative(generation.read())
        XCTAssertEqual(result.width, 1024)
        XCTAssertEqual(result.height, 1)
        XCTAssertNil(result.coverage)
        XCTAssertEqual(result.vectors.dropFirst(2), edit.field.vectors.dropFirst(2))
    }

    func saveCandidate() async throws -> WSSValidatedManifestCandidate {
        var state = doc.state
        let snapshot = try XCTUnwrap(state.beginSave())
        return try await WSSManifestSaveValidator().prepare(snapshot, handle: helper.project.handle)
    }
    func testPublicationFailuresKeepManifestAuthoritativeAndRetryUsesOwnedGeneration() async throws
    {
        _ = try await mutate()
        let candidate = try await saveCandidate()
        let original = try Data(contentsOf: helper.item.url)
        let path = try fields(doc.state.workingModel)[2]
        let generation = try XCTUnwrap(doc.state.sessionAssets[path])
        for failure: WSSManifestWriter.Stage in [
            .assetWrite, .assetPartialWrite, .assetFlush, .assetClose, .assetPublish,
            .afterAssetPublish, .beforeCommit, .replace,
        ] {
            var reached = false
            do {
                _ = try await store.commitWSSManifest(
                    candidate,
                    checkpoint: { stage in
                        if stage == failure {
                            reached = true
                            if stage == .beforeCommit {
                                XCTAssertEqual(try Data(contentsOf: self.helper.item.url), original)
                                let bytes = try WSSAssetIO.read(
                                    root: self.helper.project.handle.root,
                                    path: path, limit: generation.fingerprint.byteCount)
                                XCTAssertEqual(bytes, try generation.read())
                                _ = try WSSVectorFieldAsset.decodeNative(bytes)
                            }
                            throw WSSImageImportError.storage
                        }
                    })
                XCTFail("fault ignored")
            } catch {}
            XCTAssertTrue(reached)
            XCTAssertEqual(try Data(contentsOf: helper.item.url), original)
            let loaded = try await WSSEditorProjectLoader().load(helper.item)
            XCTAssertEqual(loaded.document, helper.project.document)
            XCTAssertTrue(doc.isDirty)
        }
        _ = try await store.commitWSSManifest(candidate)
        let reopened = try await WSSEditorProjectLoader().load(helper.item)
        XCTAssertEqual(reopened.document, doc.state.workingModel)
    }
    func testPublicationCollisionAndSymlinkCannotOverwriteEvenIdenticalBytes() async throws {
        _ = try await mutate()
        let candidate = try await saveCandidate()
        let original = try Data(contentsOf: helper.item.url)
        let path = try fields(doc.state.workingModel)[2]
        let generation = try XCTUnwrap(doc.state.sessionAssets[path])
        let target = helper.project.handle.root.appendingPathComponent(path)
        let source = helper.project.handle.root.appendingPathComponent("assets/a.wssvf")
        let sourceBytes = try Data(contentsOf: source)
        for symlink in [false, true] {
            if symlink {
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
            } else {
                try generation.read().write(to: target)
            }
            do {
                _ = try await store.commitWSSManifest(candidate)
                XCTFail("collision accepted")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
            XCTAssertEqual(try Data(contentsOf: helper.item.url), original)
            if !symlink { XCTAssertEqual(try Data(contentsOf: target), try generation.read()) }
            try FileManager.default.removeItem(at: target)
        }
        _ = try await store.commitWSSManifest(candidate)
    }
    func testPublishedFieldTamperingRejectsRetry() async throws {
        _ = try await mutate()
        let candidate = try await saveCandidate()
        let original = try Data(contentsOf: helper.item.url)
        do {
            _ = try await store.commitWSSManifest(
                candidate,
                checkpoint: { stage in
                    if stage == .afterAssetPublish { throw WSSImageImportError.storage }
                })
            XCTFail("fault ignored")
        } catch {}
        let path = try fields(doc.state.workingModel)[2]
        let file = helper.project.handle.root.appendingPathComponent(path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try Data("tampered".utf8).write(to: file)
        do {
            _ = try await store.commitWSSManifest(candidate)
            XCTFail("tampering accepted")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: helper.item.url), original)
        let loaded = try await WSSEditorProjectLoader().load(helper.item)
        XCTAssertEqual(loaded.document, helper.project.document)
    }
    func testSaveAsFailuresLeaveAAndWorkingGenerationAvailable() async throws {
        _ = try await mutate()
        let before = try helper.helper.snapshot()
        let model = doc.state.workingModel
        let path = try fields(model)[2]
        let bytes = try XCTUnwrap(doc.state.sessionAssets[path]).read()
        for failure: WSSSaveAsStage in [
            .resourceRead, .write, .flush, .close, .preparation, .projectPublish, .libraryCommit,
        ] {
            let snapshot = try WSSSaveAsSnapshot(
                document: model, state: doc.state,
                source: doc.project.handle, name: "Failure copy")
            var reached = false
            do {
                _ = try await store.saveWSSAs(
                    snapshot,
                    checkpoint: { stage in
                        if stage == failure {
                            reached = true
                            throw WSSSaveAsError.storage
                        }
                    })
                XCTFail("fault ignored")
            } catch {}
            XCTAssertTrue(reached)
            let after = try helper.helper.snapshot()
            for (key, value) in before { XCTAssertEqual(after[key], value) }
            XCTAssertEqual(doc.state.workingModel, model)
            XCTAssertEqual(try doc.state.sessionAssets[path]?.read(), bytes)
            XCTAssertTrue(doc.isDirty)
        }
        let snapshot = try WSSSaveAsSnapshot(
            document: model, state: doc.state,
            source: doc.project.handle, name: "Retry")
        let receipt = try await store.saveWSSAs(snapshot)
        XCTAssertEqual(receipt.project.document, snapshot.model)
    }
    func testGenerationAndStateEnforceVectorBudgetWithoutEvictingHistory() throws {
        XCTAssertEqual(WSSVectorFieldEditorBudget.sessionGenerationLimit, 128 * 1024 * 1024)
        XCTAssertEqual(WSSVectorFieldEditorBudget.workingDataLimit, 128 * 1024 * 1024)
        XCTAssertNoThrow(
            try WSSVectorFieldEditorBudget.validateWorkingData(byteCount: 128 * 1024 * 1024))
        for count in [-1, 128 * 1024 * 1024 + 1, Int.max] {
            XCTAssertThrowsError(
                try WSSVectorFieldEditorBudget.validateWorkingData(byteCount: count))
        }
        let small = try sourceField()
        XCTAssertThrowsError(try WSSEditorAssetGeneration.vectorField(small, remainingBudget: 1))
        let field = WSSVectorFieldAsset(
            width: 8192, height: 512,
            vectors: Data(repeating: 0, count: 16 * 1024 * 1024), coverage: nil, isNeutral: true)
        var state = doc.state
        for _ in 0..<7 {
            let generation = try WSSEditorAssetGeneration.vectorField(
                field,
                remainingBudget: WSSVectorFieldEditorBudget.remainingGenerationBytes(
                    assets: state.sessionAssets))
            try state.retainGeneration(generation)
        }
        let catalog = state.resourceCatalog
        let paths = Set(state.sessionAssets.keys)
        XCTAssertThrowsError(
            try WSSEditorAssetGeneration.vectorField(
                field,
                remainingBudget: WSSVectorFieldEditorBudget.remainingGenerationBytes(
                    assets: state.sessionAssets)))
        // The central state check also rejects a generation prepared elsewhere.
        let excess = try WSSEditorAssetGeneration.vectorField(
            field, remainingBudget: 128 * 1024 * 1024)
        XCTAssertThrowsError(try state.retainGeneration(excess))
        XCTAssertEqual(state.resourceCatalog, catalog)
        XCTAssertEqual(Set(state.sessionAssets.keys), paths)
        for generation in state.sessionAssets.values { _ = try generation.read() }
        XCTAssertThrowsError(
            try state.retainGeneration(try XCTUnwrap(state.sessionAssets.values.first)))
    }
    func testCopyOnWriteGPUAggregateBudgetFailureDoesNotAdoptAnything() async throws {
        let field = WSSVectorFieldAsset(
            width: 8192, height: 513,
            vectors: Data(repeating: 0, count: 8192 * 513 * 4), coverage: nil, isNeutral: true)
        try field.encodedNative().write(
            to: helper.project.handle.root.appendingPathComponent("assets/a.wssvf"))
        doc.close()
        helper.project = try await WSSEditorProjectLoader().load(helper.item)
        doc = makeDocument()
        let edit = try await self.edit()
        await assertRejected {
            try await self.doc.replaceVectorField(edit, vectors: self.changed(edit))
        }
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertFalse(doc.vectorFieldMutationInProgress)
    }
    func testReadOnlySourceIsNotOverwrittenAndVectorGenerationCannotBeInstalledAsImage()
        async throws
    {
        let file = helper.project.handle.root.appendingPathComponent("assets/a.wssvf")
        let bytes = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        _ = try await mutate()
        let generation = try XCTUnwrap(doc.state.sessionAssets.values.first)
        await assertRejected { try await self.doc.installImage(generation) }
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
}
