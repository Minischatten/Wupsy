import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSEditorEditingTests: XCTestCase {
    let address = WSSEffectAddress(layerIndex: 0, effectIndex: 0)
    func fixture(clouds: Bool = false) async throws -> (
        WSSEditorProjectTests, WSSLoadedEditorProject
    ) {
        let helper = WSSEditorProjectTests()
        try helper.setUpWithError()
        let item = try helper.native()
        if clouds {
            try JSONSerialization.data(withJSONObject: WSSNativeSceneTests().document(clouds: true))
                .write(to: item.url)
        } else {
            var json = WSSNativeSceneTests().document()
            var layer = (json["layers"] as! [[String: Any]])[0]
            let ripple = WSSSceneCodecTests().ripple()
            layer["effects"] = [ripple, ripple]
            json["layers"] = [layer, layer]
            try JSONSerialization.data(withJSONObject: json).write(to: item.url)
        }
        return (helper, try await WSSEditorProjectLoader().load(item))
    }
    func editor(_ project: WSSLoadedEditorProject, save: WSSEditorDocument.Save? = nil)
        -> WSSEditorDocument
    {
        WSSEditorDocument(project: project, save: save, prepare: { _, _, _ in project.resources })
    }
    func testAllSixParametersBoundsAddressingAndUnrelatedValues() async throws {
        for clouds in [false, true] {
            let (helper, project) = try await fixture(clouds: clouds)
            defer { try? helper.tearDownWithError() }
            for parameter in WSSEditorParameter.allCases {
                let doc = editor(project)
                defer { doc.close() }
                let location = clouds ? address : WSSEffectAddress(layerIndex: 1, effectIndex: 1)
                let supported = parameter.value(in: doc.state.workingModel, at: location) != nil
                if !supported {
                    XCTAssertThrowsError(try doc.setParameter(parameter, at: location, value: 1))
                    XCTAssertEqual(doc.state.workingRevision, 0)
                    continue
                }
                for value in [parameter.validRange.lowerBound, parameter.validRange.upperBound] {
                    let before = doc.state.workingModel
                    try doc.setParameter(parameter, at: location, value: value)
                    XCTAssertEqual(parameter.value(in: doc.state.workingModel, at: location), value)
                    let restored = try parameter.applying(
                        parameter.value(in: before, at: location)!, to: doc.state.workingModel,
                        at: location)
                    XCTAssertEqual(restored, before)
                }
                let before = doc.state.workingModel
                let revision = doc.state.workingRevision
                for bad in [
                    Float.nan, .infinity, parameter.validRange.upperBound + 1,
                    parameter.validRange.lowerBound - 1,
                ] {
                    XCTAssertThrowsError(try doc.setParameter(parameter, at: location, value: bad))
                }
                for bad in [
                    WSSEffectAddress(layerIndex: -1, effectIndex: 0),
                    .init(layerIndex: 0, effectIndex: 99),
                ] {
                    XCTAssertThrowsError(try doc.setParameter(parameter, at: bad, value: 1))
                }
                XCTAssertEqual(doc.state.workingModel, before)
                XCTAssertEqual(doc.state.workingRevision, revision)
                try doc.setParameter(
                    parameter, at: location, value: parameter.value(in: before, at: location)!)
                XCTAssertEqual(doc.state.workingRevision, revision)
            }
        }
    }
    func testUndoRedoSliderCoalescingRevertAndInspectorUseWorkingModel() async throws {
        let (helper, project) = try await fixture()
        defer { try? helper.tearDownWithError() }
        let doc = editor(project)
        defer { doc.close() }
        let original = doc.state.workingModel
        doc.beginSlider(.rippleAmplitude, at: address)
        for value in [Float(7), 8, 9, 10] {
            try doc.setParameter(.rippleAmplitude, at: address, value: value, registerUndo: false)
        }
        doc.endSlider()
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.state.workingRevision, 4)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(
            WSSEditorParameter.rippleAmplitude.value(in: doc.state.workingModel, at: address), 10)
        try doc.setParameter(.rippleWavelength, at: address, value: 240)
        doc.undoManager.undo()
        XCTAssertEqual(
            WSSEditorParameter.rippleWavelength.value(in: doc.state.workingModel, at: address), 120)
        doc.revert()
        XCTAssertFalse(doc.isDirty)
        doc.undoManager.undo()
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(
            doc.inspection.first { $0.editableAddress == address }?.title,
            EditorText.effectHeading(index: 0, name: EditorText.effectRipple.text))
        let history = doc.undoManager.canUndo
        doc.beginSlider(.rippleAmplitude, at: address)
        try doc.setParameter(.rippleAmplitude, at: address, value: 11, registerUndo: false)
        try doc.setParameter(.rippleAmplitude, at: address, value: 10, registerUndo: false)
        doc.endSlider()
        XCTAssertEqual(doc.undoManager.canUndo, history)
    }
    func testDiscreteSliderUpdatesAreUndoableAndNativePreviewUsesWorkingEffects() async throws {
        for clouds in [false, true] {
            let (helper, project) = try await fixture(clouds: clouds)
            defer { try? helper.tearDownWithError() }
            let doc = WSSEditorDocument(project: project)
            defer { doc.close() }
            let parameter: WSSEditorParameter = clouds ? .cloudsIntensity : .rippleAmplitude
            let value: Float = clouds ? 0.75 : 30
            try doc.updateSlider(parameter, at: address, value: value)
            await doc.waitForPreview()
            XCTAssertTrue(doc.undoManager.canUndo)
            XCTAssertFalse(doc.previewResources === project.resources)
            XCTAssertEqual(
                doc.previewResources.scene.imageLayers.map(\.effects),
                doc.workingScene.imageLayers.map(\.effects))
            XCTAssertEqual(doc.previewRevision, doc.state.workingRevision)
            doc.undoManager.undo()
            XCTAssertFalse(doc.isDirty)
            doc.undoManager.redo()
            XCTAssertTrue(doc.isDirty)
        }
    }
    func testSaveSnapshotNPreviewNPlusOneAndUndoHistory() async throws {
        let (helper, project) = try await fixture()
        defer { try? helper.tearDownWithError() }
        var continuation: CheckedContinuation<WSSSaveReceipt, Error>?
        var snapshot: WSSSaveSnapshot?
        var calls = 0
        let doc = editor(
            project,
            save: { value in
                calls += 1
                snapshot = value
                return try await withCheckedThrowingContinuation { continuation = $0 }
            })
        defer { doc.close() }
        let clean = await doc.save()
        XCTAssertTrue(clean)
        XCTAssertEqual(calls, 0)
        try doc.setParameter(.rippleAmplitude, at: address, value: 20)
        let task = Task { await doc.save() }
        while continuation == nil { await Task.yield() }
        try doc.setParameter(.rippleAmplitude, at: address, value: 30)
        await doc.waitForPreview()
        let n = try XCTUnwrap(snapshot)
        continuation?.resume(
            returning: WSSSaveReceipt(
                snapshot: n, diskBasis: n.diskBasis, outcome: .committed(warnings: [])))
        let success = await task.value
        XCTAssertTrue(success)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(doc.state.savedModel, n.model)
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.previewRevision, doc.state.workingRevision)
        doc.undoManager.undo()
        XCTAssertFalse(doc.isDirty)
        doc.undoManager.redo()
        XCTAssertTrue(doc.isDirty)
    }
    func testSaveErrorsWarningsAndInputGatePreserveWorkingState() async throws {
        let (helper, project) = try await fixture()
        defer { try? helper.tearDownWithError() }
        for error in [
            WSSSaveError.validationFailed("test"), .externalConflict, .targetDisappeared,
            .writeFailed("test"), .commitFailed("test"),
        ] {
            let doc = editor(project, save: { _ in throw error })
            try doc.setParameter(.rippleAmplitude, at: address, value: 20)
            var message = ""
            doc.presentMessage = { _, detail in message = detail }
            let result = await doc.save()
            XCTAssertFalse(result)
            XCTAssertTrue(doc.isDirty)
            XCTAssertFalse(doc.saving)
            XCTAssertFalse(message.isEmpty)
            if error == .externalConflict {
                XCTAssertEqual(
                    message,
                    EditorText.saveConflictDetail.format(EditorErrorPresentation.message(error)))
            }
            doc.close()
        }
        let doc = editor(
            project,
            save: {
                WSSSaveReceipt(
                    snapshot: $0, diskBasis: $0.diskBasis,
                    outcome: .committed(warnings: ["durability"]))
            })
        defer { doc.close() }
        try doc.setParameter(.rippleAmplitude, at: address, value: 20)
        doc.finishInput = { false }
        let blocked = await doc.save()
        XCTAssertFalse(blocked)
        doc.revert()
        XCTAssertTrue(doc.isDirty)
        doc.finishInput = { true }
        var warning = ""
        doc.presentMessage = { _, detail in warning = detail }
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(warning, "durability")
        XCTAssertTrue(doc.undoManager.canUndo)
    }
    func testPreviewSupersessionLastValueStaleErrorAndClose() async throws {
        let (helper, project) = try await fixture()
        defer { try? helper.tearDownWithError() }
        var calls: [(WSSSceneDocumentV1, CheckedContinuation<WSSStaticResources, Error>)] = []
        let doc = WSSEditorDocument(
            project: project,
            prepare: { model, _, _ in
                try await withCheckedThrowingContinuation { calls.append((model, $0)) }
            })
        doc.playing = false
        try doc.setParameter(.rippleAmplitude, at: address, value: 10)
        while calls.isEmpty { await Task.yield() }
        for value in [Float(20), 30, 40] {
            try doc.setParameter(.rippleAmplitude, at: address, value: value)
        }
        calls[0].1.resume(throwing: WSSSaveError.externalConflict)
        while calls.count < 2 { await Task.yield() }
        XCTAssertNil(doc.preparationError)
        XCTAssertEqual(doc.previewRevision, 0)
        XCTAssertEqual(WSSEditorParameter.rippleAmplitude.value(in: calls[1].0, at: address), 40)
        calls[1].1.resume(returning: project.resources)
        await doc.waitForPreview()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(doc.previewRevision, 4)
        XCTAssertFalse(doc.playing)
        try doc.setParameter(.rippleAmplitude, at: address, value: 50)
        while calls.count < 3 { await Task.yield() }
        try doc.setParameter(.rippleAmplitude, at: address, value: 60)
        calls[2].1.resume(returning: project.resources)
        while calls.count < 4 { await Task.yield() }
        XCTAssertEqual(doc.previewRevision, 4)
        doc.close()
        calls[3].1.resume(returning: project.resources)
        await Task.yield()
        XCTAssertEqual(doc.previewRevision, 4)
    }
    func testCurrentPreviewFailurePreservesWorkingModelAndRecovers() async throws {
        let (helper, project) = try await fixture()
        defer { try? helper.tearDownWithError() }
        var fail = true
        let doc = WSSEditorDocument(
            project: project,
            prepare: { _, _, _ in
                if fail { throw WSSSaveError.externalConflict }
                return project.resources
            })
        defer { doc.close() }
        try doc.setParameter(.rippleAmplitude, at: address, value: 20)
        await doc.waitForPreview()
        XCTAssertNotNil(doc.preparationError)
        XCTAssertTrue(doc.previewResources === project.resources)
        XCTAssertTrue(doc.isDirty)
        fail = false
        try doc.setParameter(.rippleAmplitude, at: address, value: 21)
        await doc.waitForPreview()
        XCTAssertNil(doc.preparationError)
        XCTAssertEqual(doc.previewRevision, doc.state.workingRevision)
    }
    func testActualDiskNSaveLeavesWorkingAndPreviewNPlusOneDirty() async throws {
        let (helper, project) = try await fixture()
        defer { try? helper.tearDownWithError() }
        let storage = helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([project.handle.wallpaper]).write(to: storage)
        let store = ManagedWallpaperStore(storage: storage)
        var gate: CheckedContinuation<Void, Never>?
        let doc = editor(
            project,
            save: { snapshot in
                await withCheckedContinuation { gate = $0 }
                let candidate = try await WSSManifestSaveValidator().prepare(
                    snapshot, handle: project.handle)
                return try await store.commitWSSManifest(candidate)
            })
        defer { doc.close() }
        try doc.setParameter(.rippleAmplitude, at: address, value: 20)
        let n = doc.state.workingModel
        let task = Task { await doc.save() }
        while gate == nil { await Task.yield() }
        try doc.setParameter(.rippleAmplitude, at: address, value: 30)
        await doc.waitForPreview()
        gate?.resume()
        let saved = await task.value
        XCTAssertTrue(saved)
        let disk = try WSSSceneDocumentV1.load(
            entry: project.handle.entry, root: project.handle.root)
        XCTAssertEqual(disk, n)
        XCTAssertEqual(doc.state.savedModel, n)
        XCTAssertEqual(
            WSSEditorParameter.rippleAmplitude.value(in: doc.state.workingModel, at: address), 30)
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.previewRevision, doc.state.workingRevision)
    }
    func testTextInputCommitInvalidEscapeAndFullRangeWithoutClamping() async throws {
        let (helper, project) = try await fixture()
        defer { try? helper.tearDownWithError() }
        let doc = editor(project)
        defer { doc.close() }
        try doc.setParameter(.rippleAmplitude, at: address, value: 200.12345)
        let value = WSSEditorParameter.rippleAmplitude.value(
            in: doc.state.workingModel, at: address)!
        let input = WSSParameterTextField(value: value, range: 0...256, title: "Amplitude") {
            try doc.setParameter(.rippleAmplitude, at: self.address, value: $0)
        }
        let coordinator = input.makeCoordinator()
        let field = NSTextField(string: String(value))
        let hint = NSTextField(labelWithString: "")
        coordinator.field = field
        coordinator.hint = hint
        let revision = doc.state.workingRevision
        XCTAssertTrue(coordinator.accept(field))
        XCTAssertEqual(doc.state.workingRevision, revision)
        for text in ["-", "nan", "257", "hello"] {
            field.stringValue = text
            XCTAssertFalse(coordinator.accept(field))
            XCTAssertFalse(hint.isHidden)
            XCTAssertEqual(doc.state.workingRevision, revision)
        }
        let handled = coordinator.control(
            field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertTrue(handled)
        XCTAssertEqual(field.stringValue, String(value))
        field.stringValue = "250,5"
        XCTAssertTrue(coordinator.accept(field))
        XCTAssertEqual(
            WSSEditorParameter.rippleAmplitude.value(in: doc.state.workingModel, at: address), 250.5
        )
        doc.undoManager.undo()
        XCTAssertEqual(
            WSSEditorParameter.rippleAmplitude.value(in: doc.state.workingModel, at: address), value
        )
    }
    func testRealEditedSaveReopenKeepsAssetsAndPlaylistAndRefreshesDesktop() async throws {
        let (helper, project) = try await fixture()
        defer { try? helper.tearDownWithError() }
        let storage = helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([project.handle.wallpaper]).write(to: storage)
        let suite = "WSSPhase3-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "conserve")
        defaults.set(false, forKey: "pauseOnBattery")
        let library = Library(storage: storage, defaults: defaults, restoreOnLaunch: false)
        defer { library.stop() }
        let playlist = WallpaperPlaylist(
            library: library, storage: helper.root.appendingPathComponent("playlists.json"),
            defaults: defaults, restoreOnLaunch: false)
        defer { playlist.shutdown() }
        guard case .accepted = await library.apply(project.handle.wallpaper).outcome else {
            return XCTFail("desktop failed")
        }
        let desktop = library.renderers.first?.scene
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let playlistBytes = try encoder.encode(playlist.state)
        let before = try helper.snapshot()
        let doc = editor(project, save: { try await library.saveWSSManifest($0) })
        defer { doc.close() }
        try doc.setParameter(.rippleAmplitude, at: .init(layerIndex: 1, effectIndex: 1), value: 22)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(doc.isDirty)
        let reopened = try await WSSEditorProjectLoader().load(project.handle.wallpaper)
        XCTAssertEqual(reopened.document, doc.state.savedModel)
        XCTAssertEqual(
            WSSEditorParameter.rippleAmplitude.value(in: reopened.document, at: address), 6)
        var after = try helper.snapshot()
        let key = "Wallpapers/WSS/Native/scene.wss.json"
        after[key] = before[key]
        XCTAssertEqual(after, before)
        XCTAssertFalse(library.renderers.first?.scene === desktop)
        XCTAssertEqual(try encoder.encode(playlist.state), playlistBytes)
    }
    func testFullPreparationPerformanceAndPlayerReplacementWhilePaused() async throws {
        for clouds in [false, true] {
            let (helper, project) = try await fixture(clouds: clouds)
            defer { try? helper.tearDownWithError() }
            let prep = WSSEditorPreviewPreparation()
            var durations: [Double] = []
            var resources = project.resources
            for _ in 0..<4 {
                let start = ProcessInfo.processInfo.systemUptime
                resources = try await prep.prepare(
                    project.document, basis: project.diskBasis, handle: project.handle)
                durations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            print("EDITOR PREPARATION \(clouds ? "Clouds" : "Ripple chain") ms: \(durations)")
            let doc = editor(project)
            let surface = WSSPreviewSurface(document: doc)
            surface.setPlaying(false)
            let old = try XCTUnwrap(surface.player)
            old.play()
            old.pause()
            let elapsed = old.elapsed
            let trailResources = try WSSPreviewTests().resources(trail: true)
            _ = try WSSPreviewTests().render(
                trailResources, size: CGSize(width: 32, height: 32),
                time: 3, trail: old.trailContext, pointer: SIMD2(10, 10))
            XCTAssertEqual(old.trailContext.sampleCount(index: 1), 1)
            surface.update(resources: resources, playing: false)
            let current = try XCTUnwrap(surface.player)
            XCTAssertFalse(old === current)
            XCTAssertEqual(old.trailContext.sampleCount(index: 1), 0)
            XCTAssertEqual(current.trailContext.sampleCount(index: 1), 0)
            XCTAssertEqual(current.elapsed, elapsed, accuracy: 0.001)
            XCTAssertTrue(current.view.isPaused)
            XCTAssertTrue(current.view.enableSetNeedsDisplay)
            XCTAssertNil(current.currentPointer())
            surface.shutdown()
            doc.close()
        }
    }
}
