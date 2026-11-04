import XCTest

@testable import Wupsy

@MainActor final class WSSEditorEffectSelectionTests: XCTestCase {
    var helper: WSSEditorProjectTests!
    var item: Wallpaper!
    var project: WSSLoadedEditorProject!
    override func setUp() async throws {
        helper = WSSEditorProjectTests()
        try helper.setUpWithError()
        item = try helper.native()
        var json = helper.fixtures.document(clouds: true, mask: true)
        var clouds = (json["layers"] as! [[String: Any]])[0]
        var ripples = clouds
        ripples["effects"] = [
            WSSSceneCodecTests().ripple(mask: "assets/mask.png"),
            WSSSceneCodecTests().ripple(mask: "assets/mask.png"),
        ]
        var cloudEffects = clouds["effects"] as! [[String: Any]]
        cloudEffects[0]["mask"] = "assets/cloud-mask.png"
        clouds["effects"] = cloudEffects
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: item.root).appendingPathComponent("assets/mask.png"),
            to: URL(fileURLWithPath: item.root).appendingPathComponent("assets/cloud-mask.png"))
        json["layers"] = [ripples, clouds]
        try JSONSerialization.data(withJSONObject: json).write(to: item.url)
        project = try await WSSEditorProjectLoader().load(item)
    }
    override func tearDown() async throws { try helper.tearDownWithError() }
    func editor() -> WSSEditorDocument { WSSEditorDocument(project: project) }
    func parameters(_ doc: WSSEditorDocument) -> [WSSEditorParameter] {
        let addresses = doc.selectedInspection.compactMap(\.editableAddress)
        return WSSEditorParameter.allCases.filter { parameter in
            addresses.contains { parameter.value(in: doc.state.workingModel, at: $0) != nil }
        }
    }
    func testNormalInspectorOmitsDiagnosticsWithoutChangingInternalInspection() throws {
        let doc = editor()
        defer { doc.close() }
        for row in doc.structureRows {
            doc.select(row.id)
            let diagnostics = doc.selectedInspection
            let model = doc.state.workingModel
            let resources = doc.previewResources
            let summaries = doc.inspectorSections
            XCTAssertFalse(summaries.isEmpty)
            XCTAssertTrue(summaries.allSatisfy { $0.rows.isEmpty })
            XCTAssertFalse(
                summaries.contains { $0.title == "Image asset" || $0.title.hasSuffix(" · Mask") })
            XCTAssertEqual(
                summaries.compactMap(\.editableAddress), diagnostics.compactMap(\.editableAddress))
            XCTAssertTrue(diagnostics.contains { !$0.rows.isEmpty })
            XCTAssertEqual(doc.state.workingModel, model)
            XCTAssertTrue(doc.previewResources === resources)
            XCTAssertFalse(doc.isDirty)
        }
    }
    func testInspectionOwnersAndTargetsRemainTypedWithRepeatedEffects() throws {
        let doc = editor()
        defer { doc.close() }
        doc.select(.layer(doc.identity.layers[0].id))
        let sections = doc.inspection
        let image = try XCTUnwrap(sections.first { $0.kind == .imageAsset })
        XCTAssertEqual(image.assetPaths.count, 1)
        XCTAssertFalse(image.entries.filter { $0.kind == .usedBy }.isEmpty)
        for index in 0..<2 {
            let selected = WSSInspectionSection.selected(sections, effectIndex: index)
            XCTAssertFalse(selected.isEmpty)
            XCTAssertTrue(selected.allSatisfy { $0.target == .effect(index) })
            let mask = try XCTUnwrap(selected.first { $0.kind == .mask })
            XCTAssertEqual(mask.assetPaths, ["assets/mask.png"])
            XCTAssertTrue(mask.entries.contains { $0.kind == .usedBy && !$0.value.isEmpty })
            XCTAssertFalse(mask.assetPaths.contains("assets/cloud-mask.png"))
        }
    }

    func testProductionRowsExposeEveryEffectAsIndependentSelectableItem() throws {
        let doc = editor()
        defer { doc.close() }
        let rows = doc.structureRows
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 0, 1])
        XCTAssertEqual(
            rows.filter { $0.depth == 1 }.map(\.title),
            [
                EditorText.effectOrdinal.format(1, EditorText.effectRipple.text),
                EditorText.effectOrdinal.format(2, EditorText.effectRipple.text),
                EditorText.effectOrdinal.format(1, EditorText.effectClouds.text),
            ])
        XCTAssertEqual(Set(rows.map(\.id)).count, 5)
        for row in rows {
            doc.select(row.id)
            XCTAssertEqual(doc.selection, row.id)
            XCTAssertEqual(doc.identity.layers[doc.selectedLayer].id, row.id.layer)
            if row.depth == 1 {
                XCTAssertNotNil(doc.effectAddress)
                XCTAssertNotNil(doc.editTarget?.effect)
            }
        }
    }
    func testSingleEffectLayerRemainsAnIndependentLayerAndEffectRow() async throws {
        var model = project.document
        model.layers.remove(at: 0)
        try model.encoded().write(to: item.url)
        let doc = WSSEditorDocument(project: try await WSSEditorProjectLoader().load(item))
        defer { doc.close() }
        XCTAssertEqual(doc.structureRows.map(\.depth), [0, 1])
        let effect = doc.structureRows[1]
        doc.select(effect.id)
        XCTAssertEqual(
            parameters(doc),
            [
                .cloudsIntensity, .cloudsDensity, .cloudsScale, .cloudsVelocityX, .cloudsVelocityY,
                .cloudsBrightness,
            ])
        XCTAssertTrue(
            doc.selectedInspection.contains {
                $0.title == EditorText.effectHeading(index: 0, name: EditorText.effectClouds.text)
            })
    }
    func testSelectionCyclePreservesWorkingStateDirtyCanvasAndLiveResources() throws {
        let doc = editor()
        defer { doc.close() }
        let rows = doc.structureRows.filter { $0.depth == 1 }
        let original = doc.state.workingModel
        let canvas = doc.canvasModel
        let preview = doc.previewResources
        for row in rows + [rows[0]] {
            doc.select(row.id)
            XCTAssertEqual(doc.editTarget?.layer, row.id.layer)
            XCTAssertEqual(doc.canvasModel, canvas)
            XCTAssertTrue(doc.previewResources === preview)
            XCTAssertEqual(doc.state.workingModel, original)
            XCTAssertFalse(doc.isDirty)
        }
        XCTAssertEqual(doc.selection, rows[0].id)
        XCTAssertEqual(
            parameters(doc),
            [
                .rippleAmplitude, .rippleWavelength, .rippleTravelSpeed, .rippleStretch,
                .rippleDirection, .rippleStructureRotation, .rippleEvolution, .rippleLateralDetail,
            ])
        XCTAssertEqual(doc.state.workingRevision, 0)
    }
    func testReorderUndoRedoOtherLayerMoveAndDeleteUndoPreserveEffectIdentity() throws {
        let doc = editor()
        defer { doc.close() }
        let originalIDs = doc.identity
        let rippleB = doc.structureRows[2].id
        let owning = rippleB.layer
        let other = originalIDs.layers[1].id
        doc.select(rippleB)
        try doc.moveLayer(owning, by: 1)
        XCTAssertEqual(doc.selection, rippleB)
        XCTAssertEqual(doc.effectAddress, .init(layerIndex: 1, effectIndex: 1))
        doc.undoManager.undo()
        XCTAssertEqual(doc.effectAddress, .init(layerIndex: 0, effectIndex: 1))
        doc.undoManager.redo()
        XCTAssertEqual(doc.effectAddress, .init(layerIndex: 1, effectIndex: 1))
        try doc.moveLayer(other, by: 1)
        XCTAssertEqual(doc.selection, rippleB)
        XCTAssertEqual(doc.effectAddress, .init(layerIndex: 0, effectIndex: 1))
        XCTAssertEqual(doc.identity.layers[0].effects, originalIDs.layers[0].effects)
        doc.select(.layer(owning))
        try doc.deleteLayer(owning)
        XCTAssertNotEqual(doc.selection, rippleB)
        XCTAssertTrue(doc.structureRows.contains { $0.id == doc.selection })
        doc.undoManager.undo()
        XCTAssertEqual(doc.selection, .layer(owning))
        XCTAssertEqual(doc.identity.layers[0], originalIDs.layers[0])
        XCTAssertEqual(doc.structureRows[2].id, rippleB)
    }
    func testSelectedInspectorExposesSupportedParametersAndOwnResources() throws {
        let doc = editor()
        defer { doc.close() }
        let effects = doc.structureRows.filter { $0.depth == 1 }
        for (index, row) in effects.enumerated() {
            doc.select(row.id)
            XCTAssertEqual(
                parameters(doc),
                index < 2
                    ? [
                        .rippleAmplitude, .rippleWavelength, .rippleTravelSpeed, .rippleStretch,
                        .rippleDirection, .rippleStructureRotation, .rippleEvolution,
                        .rippleLateralDetail,
                    ]
                    : [
                        .cloudsIntensity, .cloudsDensity, .cloudsScale, .cloudsVelocityX,
                        .cloudsVelocityY, .cloudsBrightness,
                    ])
            let address = try XCTUnwrap(doc.effectAddress)
            XCTAssertTrue(
                doc.selectedInspection.allSatisfy {
                    $0.title.hasPrefix(
                        EditorText.effectHeading(index: address.effectIndex, name: ""))
                })
            let expectedMask = index < 2 ? "assets/mask.png" : "assets/cloud-mask.png"
            let otherMask = index < 2 ? "assets/cloud-mask.png" : "assets/mask.png"
            XCTAssertTrue(
                doc.selectedInspection.contains {
                    $0.rows.contains { $0.0 == "Asset" && $0.1 == expectedMask }
                })
            XCTAssertFalse(
                doc.selectedInspection.contains {
                    $0.rows.contains { $0.0 == "Asset" && $0.1 == otherMask }
                })
        }
        doc.select(effects[0].id)
        let first = doc.editTarget
        doc.select(effects[1].id)
        XCTAssertNotEqual(doc.editTarget, first)  // shared path, distinct use/identity.
    }
    func testParameterEditsAfterRowSelectionPreservePreviewCanvasUndoSaveAndRevert() async throws {
        let storage = helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([item!]).write(to: storage)
        let store = ManagedWallpaperStore(storage: storage)
        let handle = project.handle
        let doc = WSSEditorDocument(
            project: project,
            save: { snapshot in
                let candidate = try await WSSManifestSaveValidator().prepare(
                    snapshot, handle: handle)
                return try await store.commitWSSManifest(candidate)
            })
        defer { doc.close() }
        let original = doc.state.workingModel
        let canvas = doc.canvasModel
        let effects = doc.structureRows.filter { $0.depth == 1 }
        for row in [effects[1], effects[2]] {
            doc.select(row.id)
            let address = try XCTUnwrap(doc.effectAddress)
            for parameter in parameters(doc) {
                let old = try XCTUnwrap(parameter.value(in: doc.state.workingModel, at: address))
                let value =
                    parameter == .cloudsScale ? Float(4096) : parameter.validRange.upperBound
                doc.beginSlider(parameter, at: address)
                try doc.updateSlider(parameter, at: address, value: (old + value) / 2)
                try doc.updateSlider(parameter, at: address, value: value)
                doc.endSlider()
                await doc.waitForPreview()
                XCTAssertEqual(parameter.value(in: doc.state.workingModel, at: address), value)
                XCTAssertTrue(doc.previewIsCurrent)
                XCTAssertEqual(
                    doc.previewResources.scene.imageLayers[address.layerIndex].effects,
                    doc.workingScene.imageLayers[address.layerIndex].effects)
                XCTAssertEqual(doc.canvasModel, canvas)
                doc.undoManager.undo()
                XCTAssertEqual(doc.state.workingModel, original)
                XCTAssertFalse(doc.undoManager.canUndo)
                XCTAssertFalse(doc.isDirty)
            }
        }
        doc.select(effects[1].id)
        let address = try XCTUnwrap(doc.effectAddress)
        // Outside the slider range, but a valid text value.
        try doc.setParameter(.rippleAmplitude, at: address, value: 200)
        XCTAssertEqual(
            WSSEditorParameter.rippleAmplitude.value(
                in: doc.state.workingModel, at: .init(layerIndex: 0, effectIndex: 0)), 6)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(item)
        XCTAssertEqual(reopened.document, doc.state.workingModel)
        try doc.setParameter(.rippleAmplitude, at: address, value: 210)
        doc.revert()
        XCTAssertEqual(
            WSSEditorParameter.rippleAmplitude.value(in: doc.state.workingModel, at: address), 200)
        XCTAssertEqual(doc.selection, effects[1].id)
        XCTAssertFalse(doc.isDirty)
    }
    func testExistingNativeChainsRemainOrdered() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for name in [
            "WSS-Ripple-v1", "WSS-Ripple-Chain-v1", "WSS-Flow-Ripple-v1",
            "WSS-Clouds-v2", "WSS-Rain-v1",
        ] {
            let target = helper.root.appendingPathComponent("Wallpapers/WSS/" + name)
            try FileManager.default.copyItem(
                at: repo.appendingPathComponent("Test-Wallpaper/" + name), to: target)
            let item = Wallpaper(
                title: name, path: target.appendingPathComponent("scene.wss.json").path,
                root: target.path, kind: .scene,
                managed: .init(directory: "WSS/" + name, entry: "scene.wss.json"),
                sceneSource: .nativeWSS)
            let doc = WSSEditorDocument(project: try await WSSEditorProjectLoader().load(item))
            defer { doc.close() }
            let expected = doc.identity.layers.reduce(0) { $0 + 1 + $1.effects.count }
            XCTAssertEqual(doc.structureRows.count, expected, name)
            for row in doc.structureRows where row.depth == 1 {
                doc.select(row.id)
                XCTAssertFalse(doc.selectedInspection.isEmpty, name)

            }
            XCTAssertFalse(doc.isDirty)
        }
    }

}
