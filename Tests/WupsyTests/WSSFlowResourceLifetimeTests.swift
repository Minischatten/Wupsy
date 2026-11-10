import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSFlowResourceLifetimeTests: XCTestCase {
    var fixture: WSSVectorFieldEditingTests!
    var doc: WSSEditorDocument { fixture.doc }
    override func setUp() async throws {
        fixture = WSSVectorFieldEditingTests()
        try await fixture.setUp()
        doc.close()
        let field = WSSVectorFieldAsset(
            width: 64, height: 8192, vectors: Data(count: 64 * 8192 * 4),
            coverage: nil, isNeutral: true)
        try field.encodedNative().write(
            to: fixture.helper.project.handle.root.appendingPathComponent("assets/a.wssvf"))
        let region = WSSFlowRegion(width: 64, height: 2048, pixels: Data(count: 64 * 2048))
        try region.encoded().write(
            to: fixture.helper.project.handle.root.appendingPathComponent("assets/area.wssregion"))
        var model = fixture.helper.project.document
        guard case .image(var image) = model.layers[0].content,
            case .flow(var flow) = image.effects[2].native
        else { return XCTFail() }
        image.transform = .init(center: [64, 32], size: [128, 1])
        flow.edgeProtectionMode = .region
        flow.flowRegion = .init(value: "assets/area.wssregion")
        image.effects[2] = .init(
            parameters: .flow(flow), mask: nil, field: image.effects[2].fieldDefinition)
        model.layers[0].content = .image(image)
        try model.encoded().write(to: fixture.helper.item.url)
        fixture.helper.project = try await WSSEditorProjectLoader().load(fixture.helper.item)
        fixture.doc = fixture.makeDocument()
        _ = try fixture.select()
        await doc.directionCanvas.waitForLoad()
        await doc.waitForPreview()
    }
    override func tearDown() async throws {
        try await fixture.tearDown()
        fixture = nil
    }

    @discardableResult
    func stroke(erase: Bool = false) async throws -> WSSVectorFieldEdit {
        let session = doc.directionCanvas
        await session.waitForLoad()
        session.setDiameter(18.3)
        let geometry = try XCTUnwrap(session.geometry)
        let start = geometry.scene(SIMD2(0, 0.5))
        let end = geometry.scene(SIMD2(1, 0.5))
        XCTAssertTrue(session.begin(start, erase: erase))
        session.append(end)
        session.finish(end)
        await session.waitForFinish()
        await session.waitForLoad()
        return try await fixture.edit()
    }
    func assertContents(
        _ edit: WSSVectorFieldEdit, painted: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let expected: [UInt8] = painted ? [0, 60, 0, 0] : [0, 0, 0, 0]
        let bytes = edit.field.vectors
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            guard Array(bytes[offset..<(offset + 4)]) == expected else {
                return XCTFail("Wrong field value at \(offset)", file: file, line: line)
            }
        }
        XCTAssertTrue(
            try XCTUnwrap(edit.region).pixels.allSatisfy { $0 == (painted ? 255 : 0) },
            file: file, line: line)
    }
    func testAlternatingRealCanvasStrokesBeyondFormerGenerationQuota() async throws {
        // Every changed pair is >2 MiB; 80 accepted changes exceed the old 128-MiB quota.
        let start = ContinuousClock.now
        for index in 0..<80 {
            let edit = try await stroke(erase: index % 2 == 1)
            if let error = doc.directionCanvas.error {
                return XCTFail("Stroke \(index + 1) rejected: \(error)")
            }
            try assertContents(edit, painted: index % 2 == 0)
            if index == 59 { print("FLOW RESOURCE first60 duration", start.duration(to: .now)) }
            XCTAssertFalse(doc.interactionLocked)
            XCTAssertFalse(doc.directionCanvas.finalizing)
        }
        XCTAssertEqual(doc.state.sessionAssets.count, 4)
        let bytes = doc.state.sessionAssets.values.reduce(0) { $0 + $1.fingerprint.byteCount }
        print("FLOW RESOURCE long-session bytes", bytes)
        XCTAssertLessThan(bytes, 5 * 1024 * 1024)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        try assertContents(try await stroke(), painted: true)
        try assertContents(try await stroke(erase: true), painted: false)
        XCTAssertNil(doc.directionCanvas.error)
    }
    func vectors(_ value: UInt16) -> Data {
        var data = Data(count: 64 * 8192 * 4)
        data[0] = UInt8(truncatingIfNeeded: value)
        data[1] = UInt8(truncatingIfNeeded: value >> 8)
        return data
    }
    func replace(_ value: UInt16, checkpoint: WSSManifestWriter.Checkpoint? = nil) async throws {
        let edit = try await fixture.edit()
        _ = try await doc.replaceVectorField(
            edit, vectors: vectors(value), generationCheckpoint: checkpoint)
        await doc.waitForPreview()
        await doc.directionCanvas.waitForLoad()
    }
    func check(_ value: UInt16) async throws {
        let current = try await fixture.edit()
        XCTAssertEqual(current.field.vectors, vectors(value))
    }
    func testManyUndoRedoAndDiscardedRedoResourcesAreReleased() async throws {
        for i in 1...10 { try await replace(UInt16(0x3000 + i)) }
        XCTAssertEqual(doc.state.sessionAssets.count, 10)
        for i in (0..<10).reversed() {
            doc.undoManager.undo()
            try await check(i == 0 ? 0 : UInt16(0x3000 + i))
        }
        for i in 1...10 {
            doc.undoManager.redo()
            try await check(UInt16(0x3000 + i))
        }
        for _ in 0..<5 { doc.undoManager.undo() }
        await doc.waitForPreview()
        await doc.directionCanvas.waitForLoad()
        try await replace(0x3002)  // Existing immutable content, a new branch.
        XCTAssertFalse(doc.undoManager.canRedo)
        XCTAssertEqual(doc.state.sessionAssets.count, 5)
        try await check(0x3002)
        doc.undoManager.undo()
        try await check(0x3005)
        doc.undoManager.redo()
        try await check(0x3002)
    }
    func captureSave() throws -> WSSSaveSnapshot {
        var state = doc.state
        return try XCTUnwrap(state.beginSave())
    }
    func testAsyncSnapshotPinsResourcesAfterRedoBranchIsDiscarded() async throws {
        try await replace(0x3400)
        var snapshot: WSSSaveSnapshot? = try captureSave()
        doc.undoManager.undo()
        await doc.waitForPreview()
        let address = try XCTUnwrap(doc.effectAddress)
        try doc.setParameter(.flowSpeed, at: address, value: 41)
        await doc.waitForPreview()
        await doc.directionCanvas.waitForLoad()
        XCTAssertFalse(doc.undoManager.canRedo)
        XCTAssertEqual(doc.state.sessionAssets.count, 1)
        let generation = try XCTUnwrap(snapshot?.sessionAssets.values.first)
        XCTAssertEqual(
            try WSSVectorFieldAsset.decodeNative(generation.read()).vectors, vectors(0x3400))
        // This explicit handle is another actual owner, independently of the snapshot.
        snapshot = nil
        XCTAssertEqual(doc.state.sessionAssets.count, 1)
        withExtendedLifetime(generation) {}
    }
    func testReleasedSnapshotAndHistoryRestoreAvailableQuota() async throws {
        try await replace(0x3400)
        var snapshot: WSSSaveSnapshot? = try captureSave()
        XCTAssertEqual(snapshot?.sessionAssets.count, 1)
        doc.undoManager.undo()
        await doc.waitForPreview()
        try doc.setParameter(.flowSpeed, at: XCTUnwrap(doc.effectAddress), value: 41)
        await doc.waitForPreview()
        await doc.directionCanvas.waitForLoad()
        XCTAssertEqual(doc.state.sessionAssets.count, 1)
        snapshot = nil
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertEqual(
            WSSVectorFieldEditorBudget.remainingGenerationBytes(assets: doc.state.sessionAssets),
            128 * 1024 * 1024)
        try await replace(0x3800)
        try await check(0x3800)
    }
    func testFailedTemporaryWriteRetainsNoCandidateAndNextEditSucceeds() async throws {
        for point: WSSManifestWriter.Stage in [.assetPartialWrite, .assetFlush] {
            let model = doc.state.workingModel
            let catalog = doc.state.resourceCatalog
            do {
                try await replace(
                    0x3800,
                    checkpoint: { stage in
                        if stage == point { throw WSSImageImportError.storage }
                    })
                XCTFail("Fault was ignored")
            } catch {
                XCTAssertEqual((error as? WSSImageImportError), .storage)
            }
            XCTAssertEqual(doc.state.workingModel, model)
            XCTAssertEqual(doc.state.resourceCatalog, catalog)
            XCTAssertTrue(doc.state.sessionAssets.isEmpty)
            XCTAssertFalse(doc.vectorFieldMutationInProgress)
            XCTAssertFalse(doc.interactionLocked)
            XCTAssertFalse(doc.undoManager.canUndo)
            try await check(0)
        }
        try await replace(0x3800)
        try await check(0x3800)
    }
    func testUniqueHistoryTrimsToQuotaAndReopensWithoutDataLoss() async throws {
        for i in 1...250 {
            try await replace(UInt16(0x3000 + i))
            if [100, 250].contains(i) {
                print(
                    "BOUNDED LARGE FLOW", i, "undo", doc.directionUndoHistory.undoDepth,
                    "bytes",
                    doc.state.sessionAssets.values.reduce(0) { $0 + $1.fingerprint.byteCount })
            }
        }
        let depth = doc.directionUndoHistory.undoDepth
        XCTAssertGreaterThan(depth, 0)
        XCTAssertLessThan(depth, 250)
        XCTAssertLessThanOrEqual(
            doc.state.sessionAssets.values.reduce(0) { $0 + $1.fingerprint.byteCount },
            WSSVectorFieldEditorBudget.sessionGenerationLimit)
        print(
            "BOUNDED LARGE FLOW", "undo", depth, "bytes",
            doc.state.sessionAssets.values.reduce(0) { $0 + $1.fingerprint.byteCount })
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(doc.directionUndoHistory.undoDepth, depth)
        for i in (250 - depth..<250).reversed() {
            doc.undoManager.undo()
            try await check(UInt16(0x3000 + i))
        }
        XCTAssertFalse(doc.undoManager.canUndo)
        for i in (251 - depth)...250 {
            doc.undoManager.redo()
            try await check(UInt16(0x3000 + i))
        }
        doc.close()
        fixture.helper.project = try await WSSEditorProjectLoader().load(fixture.helper.item)
        fixture.doc = fixture.makeDocument()
        _ = try fixture.select()
        await doc.directionCanvas.waitForLoad()
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertFalse(doc.undoManager.canUndo)
        try await check(0x30fa)
        try assertContents(try await stroke(), painted: true)
        XCTAssertNil(doc.directionCanvas.error)
    }
    func testQuotaWriteFailureDoesNotTrimHistoryOrChangeState() async throws {
        for i in 1...63 { try await replace(UInt16(0x3000 + i)) }
        let model = doc.state.workingModel
        let paths = Set(doc.state.sessionAssets.keys)
        let depth = doc.directionUndoHistory.undoDepth
        for _ in 0..<3 {
            do {
                try await replace(
                    0x3100,
                    checkpoint: { stage in
                        if stage == .assetFlush { throw WSSImageImportError.storage }
                    })
                XCTFail("Expected fault")
            } catch { XCTAssertEqual(error as? WSSImageImportError, .storage) }
            XCTAssertEqual(doc.state.workingModel, model)
            XCTAssertEqual(Set(doc.state.sessionAssets.keys), paths)
            XCTAssertEqual(doc.directionUndoHistory.undoDepth, depth)
        }
        try await replace(0x3100)
        XCTAssertLessThan(doc.directionUndoHistory.undoDepth, depth)
        try await check(0x3100)
    }
    func testInFlightSnapshotsCannotBeEvictedForBudgetAndFailureKeepsHistory() async throws {
        var snapshots: [WSSSaveSnapshot] = []
        for i in 1...63 {
            try await replace(UInt16(0x3000 + i))
            snapshots.append(try captureSave())
        }
        let depth = doc.directionUndoHistory.undoDepth
        let model = doc.state.workingModel
        let paths = Set(doc.state.sessionAssets.keys)
        for _ in 0..<3 {
            do {
                try await replace(0x3100)
                XCTFail("Pinned resources cannot be evicted")
            } catch { XCTAssertEqual(error as? WSSVectorFieldEditError, .budget) }
            XCTAssertEqual(doc.directionUndoHistory.undoDepth, depth)
            XCTAssertEqual(doc.state.workingModel, model)
            XCTAssertEqual(Set(doc.state.sessionAssets.keys), paths)
        }
        XCTAssertEqual(snapshots.count, 63)
        snapshots.removeAll()
        try await replace(0x3100)
        try await check(0x3100)
        XCTAssertLessThan(doc.directionUndoHistory.undoDepth, depth)
    }
    func testCommitFailureCategoriesKeepEvidencePrivate() {
        let evidence = "/Users/Synthetic/Private/photo.png"
        let cases: [(Error, WSSDirectionCommitFailure.Category)] = [
            (WSSVectorFieldEditError.budget, .budget),
            (WSSImageImportError.storage, .storage),
            (WSSDocumentError.invalid(evidence), .validation),
            (WSSVectorFieldEditError.stale, .stale), (CancellationError(), .cancelled),
        ]
        for (cause, category) in cases {
            let failure = WSSDirectionCommitFailure(
                stage: .adoption, cause: cause, retainedVectorBytes: 100)
            XCTAssertEqual(failure.category, category)
            XCTAssertFalse(failure.message.contains(evidence))
            XCTAssertEqual(failure.retainedVectorBytes, 100)
        }
    }
    func testRepeatedPaintAndEraseNoOpsPreserveBytesAndHistory() async throws {
        try assertContents(try await stroke(), painted: true)
        let painted = doc.state.workingModel
        for _ in 0..<10 {
            try assertContents(try await stroke(), painted: true)
            XCTAssertNil(doc.directionCanvas.error)
            XCTAssertEqual(doc.state.workingModel, painted)
            XCTAssertEqual(doc.state.sessionAssets.count, 2)
        }
        try assertContents(try await stroke(erase: true), painted: false)
        let erased = doc.state.workingModel
        for _ in 0..<10 {
            try assertContents(try await stroke(erase: true), painted: false)
            XCTAssertNil(doc.directionCanvas.error)
            XCTAssertEqual(doc.state.workingModel, erased)
            XCTAssertEqual(doc.state.sessionAssets.count, 4)
        }
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, painted)
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, erased)
    }
    func testSecondResourceWriteFailureRollsBackFieldAndRegionTogether() async throws {
        let edit = try await fixture.edit()
        let model = doc.state.workingModel
        var writes = 0
        do {
            _ = try await doc.replaceVectorField(
                edit, vectors: vectors(0x3800),
                region: .init(
                    width: 64, height: 2048,
                    pixels: Data(repeating: 255, count: 64 * 2048)),
                generationCheckpoint: { stage in
                    if stage == .assetPartialWrite {
                        writes += 1
                        if writes == 2 { throw WSSImageImportError.storage }
                    }
                })
            XCTFail("Second-resource fault was ignored")
        } catch { XCTAssertEqual(error as? WSSImageImportError, .storage) }
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertFalse(doc.vectorFieldMutationInProgress)
        try await check(0)
        let next = try await stroke()
        XCTAssertNil(doc.directionCanvas.error)
        try assertContents(next, painted: true)
    }
}
