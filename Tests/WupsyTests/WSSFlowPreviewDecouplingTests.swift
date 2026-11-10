import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSFlowPreviewDecouplingTests: XCTestCase {
    final class WeakGeneration {
        weak var value: WSSImageGeneration?
        init(_ value: WSSImageGeneration) { self.value = value }
    }
    @MainActor final class PreviewControl {
        var held: Set<Int> = [1]
        var failures: Set<Int> = []
        var cancellations: Set<Int> = []
        var ignoreCancellation = false
        var models: [WSSSceneDocumentV1] = []
        var resources: [[String: WeakGeneration]] = []
        var readAfterResume: Set<Int> = []
        private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
        private var observers: [Int: [XCTestExpectation]] = [:]
        let worker = WSSEditorPreviewPreparation()
        func waitUntilEntered(_ index: Int) async {
            if models.count >= index { return }
            let expectation = XCTestExpectation(description: "preview \(index) entered")
            observers[index, default: []].append(expectation)
            let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 10)
            XCTAssertEqual(result, .completed)
        }
        func release(_ index: Int) {
            held.remove(index)
            continuations.removeValue(forKey: index)?.resume()
        }
        func releaseAll() {
            held.removeAll()
            let pending = continuations.values
            continuations.removeAll()
            for continuation in pending { continuation.resume() }
        }
        func prepare(
            _ model: WSSSceneDocumentV1, basis: WSSProjectDiskBasis,
            handle: WSSProjectHandle, assets: [String: WSSImageGeneration],
            fallback: WSSStaticResources
        ) async throws -> WSSStaticResources {
            models.append(model)
            resources.append(assets.mapValues(WeakGeneration.init))
            let index = models.count
            if held.contains(index) {
                await withCheckedContinuation {
                    continuations[index] = $0
                    entered(index)
                }
            } else {
                entered(index)
            }
            for generation in assets.values { _ = try generation.read() }
            readAfterResume.insert(index)
            if ignoreCancellation, Task.isCancelled { return fallback }
            if failures.contains(index) { throw WSSSceneError.invalid("Synthetic preview failure") }
            if cancellations.contains(index) { throw CancellationError() }
            return try await worker.prepare(
                model, basis: basis, handle: handle, sessionAssets: assets)
        }
        func entered(_ index: Int) {
            for observer in observers.removeValue(forKey: index) ?? [] {
                observer.fulfill()
            }
        }
    }
    var fixture: WSSDirectionCanvasTests!
    var control: PreviewControl!
    var doc: WSSEditorDocument { fixture.doc }
    var session: WSSDirectionCanvasSession { fixture.session }
    override func setUp() async throws {
        fixture = WSSDirectionCanvasTests()
        try await fixture.setUp()
        control = PreviewControl()
        let control = control!
        let project = fixture.helper.helper.project!
        let store = fixture.helper.store!
        let handle = project.handle
        fixture.doc.close()
        fixture.helper.doc = WSSEditorDocument(
            project: project,
            save: { snapshot in
                let candidate = try await WSSManifestSaveValidator().prepare(
                    snapshot, handle: handle)
                return try await store.commitWSSManifest(candidate)
            },
            preparePreview: { model, basis, handle, assets in
                try await control.prepare(
                    model, basis: basis, handle: handle, assets: assets,
                    fallback: project.resources)
            })
        _ = try fixture.helper.select()
        try await fixture.enable()
    }
    override func tearDown() async throws {
        control.releaseAll()
        await doc.waitForPreview()
        try await fixture.tearDown()
        fixture = nil
        control = nil
    }
    func currentBytes() async throws -> Data {
        try await fixture.helper.edit().field.encodedNative()
    }
    @discardableResult func stroke(erase: Bool = false, magnitude: Float = 1) async throws -> Data {
        session.setMagnitude(magnitude)
        let start = try fixture.scene(SIMD2(0.05, 0.5))
        let end = try fixture.scene(SIMD2(0.4, 0.5))
        XCTAssertTrue(session.begin(start, erase: erase))
        session.append(end)
        session.finish(end)
        await session.waitForFinish()
        XCTAssertFalse(session.finalizing)
        XCTAssertFalse(doc.interactionLocked)
        XCTAssertNil(session.error)
        return try await currentBytes()
    }
    func testCommittedStrokeIsReadyWhileDocumentPreviewIsHeld() async throws {
        _ = try await stroke()
        await control.waitUntilEntered(1)
        XCTAssertFalse(session.finalizing)
        XCTAssertFalse(doc.interactionLocked)
        XCTAssertFalse(doc.previewIsCurrent)
        XCTAssertTrue(doc.canSave)
        XCTAssertTrue(doc.undoManager.canUndo)
        let timing = try XCTUnwrap(session.lastCommitTimings)
        print(
            "FLOW DECOUPLED ms", "paint", timing.paintMilliseconds,
            "adoption", timing.adoptionMilliseconds, "validation",
            doc.directionValidationMilliseconds,
            "inputReady", timing.inputReadyMilliseconds)
        // A second begin is accepted without waiting for source reload or preview.
        _ = try await stroke(erase: true)
        XCTAssertEqual(doc.directionUndoHistory.undoDepth, 2)
        XCTAssertEqual(control.models.count, 1)
        control.release(1)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        XCTAssertEqual(
            doc.previewResources.scene.imageLayers.map(\.effects),
            try doc.state.workingModel.scene().imageLayers.map(\.effects))
    }
    func test110QuickAlternatingStrokesCoalesceAndKeep100ExactUndoStates() async throws {
        var states = [try await currentBytes()]
        for index in 0..<110 {
            states.append(
                try await stroke(erase: index % 2 == 1, magnitude: index % 4 < 2 ? 0.5 : 1))
        }
        XCTAssertEqual(doc.directionUndoHistory.undoDepth, 100)
        XCTAssertEqual(doc.state.workingRevision, 110)
        XCTAssertEqual(control.models.count, 1)
        XCTAssertFalse(doc.previewIsCurrent)
        control.held.insert(2)
        control.release(1)
        await control.waitUntilEntered(2)
        XCTAssertEqual(doc.previewRevision, 0, "Stale first result must never publish")
        XCTAssertEqual(control.models[1], doc.state.workingModel)
        control.release(2)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        XCTAssertEqual(control.models.count, 2)
        for index in (10..<110).reversed() {
            doc.undoManager.undo()
            let value = try await currentBytes()
            XCTAssertEqual(value, states[index])
        }
        XCTAssertFalse(doc.undoManager.canUndo)
        for index in 11...110 {
            doc.undoManager.redo()
            let value = try await currentBytes()
            XCTAssertEqual(value, states[index])
        }
        XCTAssertFalse(doc.undoManager.canRedo)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
    }
    func testAuthoringFeedbackWorksWhileDocumentPreviewIsBehind() async throws {
        _ = try await stroke()
        await control.waitUntilEntered(1)
        let start = try fixture.scene(SIMD2(0.05, 0.5))
        let end = try fixture.scene(SIMD2(0.4, 0.5))
        XCTAssertTrue(session.begin(start, erase: true))
        session.append(end)
        await session.waitForAuthoringFeedback()
        XCTAssertNotNil(session.transientState)
        XCTAssertNil(session.feedbackFailure)
        XCTAssertTrue(session.isDrawing)
        session.finish(end)
        await session.waitForFinish()
        XCTAssertNil(session.error)
        XCTAssertEqual(doc.directionUndoHistory.undoDepth, 2)
    }
    func testSaveUndoRedoAndNewBranchWhilePreviewIsHeld() async throws {
        let first = try await stroke()
        let second = try await stroke(erase: true)
        await control.waitUntilEntered(1)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.previewIsCurrent)
        let reopened = try await WSSEditorProjectLoader().load(fixture.helper.helper.item)
        let source = try reopened.document.assetSource(root: reopened.handle.root)
        let path = try fixture.helper.fields(reopened.document)[2]
        XCTAssertEqual(try source.read(path, limit: 1024), second)
        doc.undoManager.undo()
        var bytes = try await currentBytes()
        XCTAssertEqual(bytes, first)
        doc.undoManager.redo()
        bytes = try await currentBytes()
        XCTAssertEqual(bytes, second)
        doc.undoManager.undo()
        _ = try await stroke(magnitude: 0.25)
        XCTAssertFalse(doc.undoManager.canRedo)
        XCTAssertEqual(doc.directionUndoHistory.undoDepth, 2)
        let expected = doc.state.workingModel
        control.release(1)
        await doc.waitForPreview()
        XCTAssertEqual(doc.state.workingModel, expected)
        XCTAssertTrue(doc.previewIsCurrent)
    }
    func testCurrentPreviewFailureDoesNotRejectStrokeAndNextPreviewRecovers() async throws {
        control.failures.insert(1)
        let accepted = try await stroke()
        control.release(1)
        await doc.waitForPreview()
        XCTAssertNotNil(doc.preparationError)
        XCTAssertNil(session.error)
        XCTAssertFalse(session.finalizing)
        let actual = try await currentBytes()
        XCTAssertEqual(actual, accepted)
        _ = try await stroke(erase: true)
        await doc.waitForPreview()
        XCTAssertNil(doc.preparationError)
        XCTAssertTrue(doc.previewIsCurrent)
    }
    func testStalePreviewFailureAndCancellationDoNotPoisonLatestState() async throws {
        control.failures.insert(1)
        control.cancellations.insert(2)
        _ = try await stroke()
        _ = try await stroke(erase: true)
        control.release(1)
        await doc.waitForPreview()
        XCTAssertNotNil(doc.preparationError)  // Current request 2 was cancelled.
        XCTAssertNil(session.error)
        _ = try await stroke(magnitude: 0.25)
        await doc.waitForPreview()
        XCTAssertNil(doc.preparationError)
        XCTAssertTrue(doc.previewIsCurrent)
    }
    func testSelectionSwitchWhilePreviewRunsKeepsBothTargetsAndNewestScene() async throws {
        _ = try await stroke()
        let firstTarget = try fixture.helper.fields(doc.state.workingModel)[2]
        _ = try fixture.helper.select(0)
        await session.waitForLoad()
        _ = try await stroke()
        let paths = try fixture.helper.fields(doc.state.workingModel)
        XCTAssertEqual(paths[2], firstTarget)
        XCTAssertNotEqual(paths[0], "assets/a.wssvf")
        control.release(1)
        await doc.waitForPreview()
        XCTAssertEqual(
            doc.previewResources.scene.imageLayers.map(\.effects),
            try doc.state.workingModel.scene().imageLayers.map(\.effects))
    }
    func testPreviewPinsOnlyItsResourcesAcrossHistoryTrimmingThenReleasesThem() async throws {
        for index in 1...105 {
            let edit = try await fixture.helper.edit()
            var bytes = edit.field.vectors
            let word = UInt16(0x3000 + index)
            bytes[0] = UInt8(truncatingIfNeeded: word)
            bytes[1] = UInt8(truncatingIfNeeded: word >> 8)
            _ = try await doc.replaceVectorField(edit, vectors: bytes)
            if index == 1 { await control.waitUntilEntered(1) }
        }
        let reference = try XCTUnwrap(control.resources[0].values.first)
        XCTAssertNotNil(reference.value)
        XCTAssertEqual(doc.directionUndoHistory.undoDepth, 100)
        XCTAssertEqual(control.resources[0].count, 1)
        control.release(1)
        await doc.waitForPreview()
        XCTAssertNil(reference.value)
        XCTAssertEqual(doc.state.sessionAssets.count, 101)
        XCTAssertTrue(doc.previewIsCurrent)
    }
    func testCloseWithUncooperativePreviewRetainsFilesAndCannotTouchAnotherDocument() async throws {
        _ = try await stroke()
        await control.waitUntilEntered(1)
        let reference = try XCTUnwrap(control.resources[0].values.first)
        let started = XCTestExpectation(description: "preview join attached")
        let old = doc
        let join = Task { @MainActor in
            started.fulfill()
            await old.waitForPreview()
        }
        await fulfillment(of: [started], timeout: 5)
        control.ignoreCancellation = true
        old.close()
        XCTAssertNotNil(reference.value)
        let other = fixture.helper.makeDocument()
        let model = other.state.workingModel
        control.release(1)
        await join.value
        XCTAssertTrue(control.readAfterResume.contains(1))
        XCTAssertNil(reference.value)
        XCTAssertEqual(old.previewRevision, 0)
        XCTAssertEqual(other.state.workingModel, model)
        XCTAssertEqual(other.previewRevision, 0)
        other.close()
    }
    func testSplittingSharedFieldsStillRejectsAggregateUploadBudgetWithoutChangingHistory()
        async throws
    {
        let large = WSSFlowResourceLifetimeTests()
        try await large.setUp()
        let helper = large.fixture!
        helper.doc.close()
        let root = helper.helper.project.handle.root
        let bytes = try WSSVectorFieldAsset(
            width: 64, height: 8192, vectors: Data(count: 64 * 8192 * 4),
            coverage: nil, isNeutral: true
        ).encodedNative()
        for index in 0..<15 {
            try bytes.write(to: root.appendingPathComponent("assets/budget-\(index).wssvf"))
        }
        var model = helper.helper.project.document
        guard case .image(var image) = model.layers[0].content else { return XCTFail() }
        image.effects = try (0..<15).map { try helper.effect("flow", "budget-\($0)") }
        image.effects.append(image.effects[0])  // Fifteen unique fields, sixteen consumers.
        model.layers[0].content = .image(image)
        try model.encoded().write(to: helper.helper.item.url)
        helper.helper.project = try await WSSEditorProjectLoader().load(helper.helper.item)
        helper.doc = helper.makeDocument()
        let target = try helper.select(15)
        let edit = try await helper.doc.loadVectorField(target)
        let before = helper.doc.state.workingModel
        do {
            _ = try await helper.doc.replaceVectorField(edit, vectors: large.vectors(0x3800))
            XCTFail("A sixteenth independent 2-MiB field exceeds the native upload budget")
        } catch { XCTAssertEqual(error as? WSSVectorFieldEditError, .budget) }
        XCTAssertEqual(helper.doc.state.workingModel, before)
        XCTAssertTrue(helper.doc.state.sessionAssets.isEmpty)
        XCTAssertFalse(helper.doc.undoManager.canUndo)
        try await large.tearDown()
    }
    func testActiveOptionalGPUPreviewDoesNotDelayMouseUpOrNextStroke() async throws {
        let entered = XCTestExpectation(description: "optional GPU work entered")
        var continuation: CheckedContinuation<Void, Never>?
        var completedWithoutCancellation = false
        session.livePreviewPreparation = { resources, address, state in
            await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
            completedWithoutCancellation = !Task.isCancelled
            return try resources.previewDirection(at: address, state: state)
        }
        let start = try fixture.scene(SIMD2(0.05, 0.5))
        let end = try fixture.scene(SIMD2(0.4, 0.5))
        XCTAssertTrue(session.begin(start, erase: false))
        session.append(end)
        await fulfillment(of: [entered], timeout: 10)
        // End and adopt while optional GPU work is still held at the barrier.
        session.finish(end)
        await session.waitForFinish()
        XCTAssertFalse(session.finalizing)
        XCTAssertTrue(session.begin(start, erase: true))
        session.append(end)
        session.finish(end)
        await session.waitForFinish()
        XCTAssertEqual(doc.directionUndoHistory.undoDepth, 2)
        continuation?.resume()
        await session.waitForFeedback()
        XCTAssertTrue(completedWithoutCancellation)
        XCTAssertNil(session.liveResources, "Old stroke's optional GPU result must not publish")
        XCTAssertNil(session.error)
        session.livePreviewPreparation = nil
    }
    func testOptionalPreviewFailureKeepsAuthoringAndCommitsExactFeedbackBytes() async throws {
        session.livePreviewPreparation = { _, _, _ in
            throw WSSSceneError.invalid("Synthetic optional GPU failure")
        }
        let start = try fixture.scene(SIMD2(0.05, 0.5))
        let end = try fixture.scene(SIMD2(0.4, 0.5))
        XCTAssertTrue(session.begin(start, erase: false))
        session.append(end)
        await session.waitForFeedback()
        XCTAssertTrue(session.isDrawing)
        XCTAssertEqual(session.feedbackFailure?.stage, .livePreview)
        XCTAssertNil(session.error)
        XCTAssertEqual(session.livePreviewAttemptCount, 1)
        let further = try fixture.scene(SIMD2(0.6, 0.5))
        session.append(further)
        await session.waitForFeedback()
        XCTAssertEqual(session.livePreviewAttemptCount, 1, "Do not retry per pointer sample")
        let expected = try XCTUnwrap(session.transientState).field.encodedNative()
        session.finish(further)
        await session.waitForFinish()
        let actual = try await currentBytes()
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(doc.directionUndoHistory.undoDepth, 1)
        XCTAssertNil(session.error)
        control.release(1)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        XCTAssertNil(doc.preparationError)
        session.livePreviewPreparation = nil
    }
    func testLargeSyntheticStrokePhaseMeasurements() async throws {
        let large = WSSFlowResourceLifetimeTests()
        try await large.setUp()
        var paint = 0.0
        var adoption = 0.0
        var validation = 0.0
        var ready = 0.0
        for index in 0..<8 {
            let result = try await large.stroke(erase: index % 2 == 1)
            try large.assertContents(result, painted: index % 2 == 0)
            let timing = try XCTUnwrap(large.doc.directionCanvas.lastCommitTimings)
            paint += timing.paintMilliseconds
            adoption += timing.adoptionMilliseconds
            validation += large.doc.directionValidationMilliseconds
            ready += timing.inputReadyMilliseconds
        }
        await large.doc.waitForPreview()
        XCTAssertTrue(large.doc.previewIsCurrent)
        print(
            "FLOW LARGE mean ms", "paint", paint / 8, "adoption", adoption / 8,
            "validation", validation / 8, "inputReady", ready / 8,
            "lastPreview", large.doc.preparationMilliseconds)
        try await large.tearDown()
    }

}
