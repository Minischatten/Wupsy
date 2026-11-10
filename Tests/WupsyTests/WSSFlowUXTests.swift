import AppKit
import SwiftUI
import XCTest

@testable import Wupsy

@MainActor final class WSSFlowUXTests: XCTestCase {
    var fixture: WSSFlowRegionEditingTests!
    var doc: WSSEditorDocument { fixture.doc }
    var session: WSSDirectionCanvasSession { doc.directionCanvas }
    override func setUp() async throws {
        fixture = WSSFlowRegionEditingTests()
        try await fixture.setUp()
        session.updateQueries([SIMD2(0.3, 0.5), SIMD2(0.5, 0.5), SIMD2(0.7, 0.5)])
    }
    override func tearDown() async throws {
        try await fixture.tearDown()
        fixture = nil
    }
    func frame(_ resources: WSSStaticResources) throws -> Data {
        try WSSEditorLivePreviewTests().frame(resources, time: 0.35, width: 128)
    }
    func begin(erase: Bool = false) async throws {
        session.setEnabled(true)
        await session.waitForLoad()
        session.setDiameter(48)
        let geometry = try XCTUnwrap(session.geometry)
        XCTAssertTrue(session.begin(geometry.scene(SIMD2(0.2, 0.5)), erase: erase))
        session.append(geometry.scene(SIMD2(0.8, 0.5)))
        await session.waitForFeedback()
        XCTAssertNotNil(session.liveResources, session.error ?? "missing live preview")
    }
    func finish() async throws {
        session.finish(try XCTUnwrap(session.geometry).scene(SIMD2(0.8, 0.5)))
        await session.waitForFinish()
        await session.waitForLoad()
        await doc.waitForPreview()
    }
    func testLivePaintUsesSamePlayerPipelineAndCancelRestoresExactFrame() async throws {
        let model = doc.state.workingModel
        await doc.waitForPreview()
        let original = doc.previewResources
        let before = try frame(original)
        let surface = WSSPreviewSurface(document: doc)
        defer { surface.shutdown() }
        let player = try XCTUnwrap(surface.player)
        try await begin()
        let live = try XCTUnwrap(session.liveResources)
        XCTAssertTrue(live === doc.editorPreviewResources)
        XCTAssertTrue(live.flow?.replace === original.flow?.replace)
        XCTAssertTrue(live.images.values.first?.texture === original.images.values.first?.texture)
        XCTAssertNotEqual(try frame(live), before)
        XCTAssertTrue(session.samples.contains { $0.vector.x > 0 })
        XCTAssertTrue(try XCTUnwrap(session.transientState?.region).pixels.contains(255))
        XCTAssertEqual(doc.state.workingModel, model)
        surface.update(resources: doc.editorPreviewResources, playing: false)
        XCTAssertTrue(surface.player === player)
        XCTAssertTrue(player.resources === live)
        XCTAssertTrue(session.escape())
        surface.update(resources: doc.editorPreviewResources, playing: false)
        XCTAssertTrue(surface.player === player)
        XCTAssertTrue(player.resources === original)
        XCTAssertEqual(try frame(doc.editorPreviewResources), before)
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertTrue(session.brushEnabled)
        XCTAssertNil(session.transientState)
        XCTAssertFalse(session.escape())
        XCTAssertTrue(session.brushEnabled)
        XCTAssertTrue(session.overlayVisible)
    }
    func testLiveEraseFrameArrowsRegionCancelAndCommitAgree() async throws {
        try await begin()
        let paintedLive = try frame(doc.editorPreviewResources)
        try await finish()
        XCTAssertEqual(try frame(doc.previewResources), paintedLive)
        let painted = doc.state.workingModel
        let original = try frame(doc.previewResources)
        try await begin(erase: true)
        let erasedLive = try frame(doc.editorPreviewResources)
        XCTAssertNotEqual(erasedLive, original)
        XCTAssertTrue(session.samples.isEmpty)
        XCTAssertTrue(try XCTUnwrap(session.transientState?.region).pixels.allSatisfy { $0 == 0 })
        XCTAssertEqual(doc.state.workingModel, painted)
        XCTAssertTrue(session.escape())
        XCTAssertEqual(try frame(doc.editorPreviewResources), original)
        XCTAssertFalse(session.samples.isEmpty)
        try await begin(erase: true)
        let finalLive = try frame(doc.editorPreviewResources)
        try await finish()
        XCTAssertEqual(try frame(doc.previewResources), finalLive)
        XCTAssertNil(session.liveResources)
        XCTAssertTrue(session.samples.isEmpty)
        doc.undoManager.undo()
        await session.waitForLoad()
        await doc.waitForPreview()
        XCTAssertEqual(doc.state.workingModel, painted)
        XCTAssertEqual(try frame(doc.editorPreviewResources), original)
        doc.undoManager.redo()
        await session.waitForLoad()
        await doc.waitForPreview()
        XCTAssertEqual(try frame(doc.editorPreviewResources), finalLive)
    }
    func testDirectSelectionEditingAndStableIdentityAcrossSwitchesAndReorder() async throws {
        try await fixture.stroke()
        session.setEnabled(false)
        await session.waitForLoad()
        let firstModel = doc.state.workingModel
        let first = try XCTUnwrap(session.loaded)
        let firstEffect = try XCTUnwrap(doc.selection)
        XCTAssertTrue(session.overlayVisible)
        XCTAssertTrue(session.brushEnabled)
        XCTAssertFalse(session.requiresExplicitActivation)
        XCTAssertFalse(session.isDrawing)
        XCTAssertFalse(session.samples.isEmpty)
        let assets = doc.state.sessionAssets.count
        let preview = doc.previewResources
        try doc.addEffect(.flow)
        session.setEnabled(false)
        await session.waitForLoad()
        let second = try XCTUnwrap(session.loaded)
        XCTAssertNotEqual(second.resolved.regionID, first.resolved.regionID)
        XCTAssertTrue(session.samples.isEmpty)
        doc.select(firstEffect)
        await session.waitForLoad()
        XCTAssertEqual(session.loaded?.region, first.region)
        XCTAssertFalse(session.samples.isEmpty)
        let layer = first.resolved.target.layerID
        let effect = first.resolved.target.effectID
        try doc.moveEffect(layer, effect: effect, to: 1)
        await session.waitForLoad()
        XCTAssertEqual(session.loaded?.resolved.target.effectID, effect)
        XCTAssertEqual(session.loaded?.region, first.region)
        try doc.moveLayer(layer, to: 1)
        await session.waitForLoad()
        XCTAssertEqual(session.loaded?.region, first.region)
        try doc.addEffect(.ripple)
        await session.waitForLoad()
        XCTAssertFalse(session.overlayVisible)
        XCTAssertNil(session.loaded)
        XCTAssertNotEqual(doc.state.workingModel, firstModel)
        XCTAssertGreaterThan(doc.state.sessionAssets.count, assets)
        XCTAssertNotNil(preview)
    }
    func testExistingNeutralRegionRemainsVisibleAndEditableAfterSaveReopen() async throws {
        try await fixture.stroke(magnitude: 0)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let model = doc.state.workingModel
        session.setEnabled(false)
        let selected = try XCTUnwrap(doc.selection)
        doc.select(.layer(selected.layer))
        doc.select(selected)
        await session.waitForLoad()
        XCTAssertTrue(session.overlayVisible)
        XCTAssertTrue(session.brushEnabled)
        XCTAssertTrue(try XCTUnwrap(session.loaded?.region).pixels.contains(255))
        XCTAssertTrue(session.samples.allSatisfy { $0.vector == .zero })
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertFalse(doc.isDirty)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        let copy = WSSEditorDocument(project: reopened)
        defer { copy.close() }
        copy.select(.effect(copy.identity.layers[0].id, copy.identity.layers[0].effects[0]))
        await copy.directionCanvas.waitForLoad()
        XCTAssertTrue(copy.directionCanvas.overlayVisible)
        XCTAssertTrue(copy.directionCanvas.brushEnabled)
        XCTAssertFalse(copy.directionCanvas.requiresExplicitActivation)
        XCTAssertEqual(copy.directionCanvas.loaded?.region, session.loaded?.region)
        XCTAssertFalse(copy.isDirty)
    }
    func testSelectedAccentAndArrowsReadableWithNeutralAndLongVectors() throws {
        let field = try WSSVectorFieldPaintTests().field(width: 2, height: 2, vector: SIMD2(1, 1))
        let region = WSSFlowRegion(width: 2, height: 2, pixels: Data(repeating: 255, count: 4))
        let area = try WSSDirectionArea.make(
            field, region: region, accent: .init(red: 0, green: 0.48, blue: 1))
        let bytes = try XCTUnwrap(area.image.dataProvider?.data) as Data
        XCTAssertEqual(bytes[0], 0)
        XCTAssertGreaterThan(bytes[2], bytes[1])
        XCTAssertGreaterThan(bytes[3], 80)
        XCTAssertEqual(WSSEditorOverlayAccent.selected.rgba.w, 0.35)
        let neutral = try WSSVectorFieldPaintTests().field(width: 2, height: 2)
        XCTAssertEqual(
            try XCTUnwrap(
                WSSDirectionArea.make(
                    neutral, region: region, accent: .init(red: 0, green: 0.48, blue: 1)
                ).image.dataProvider?.data) as Data, bytes)
    }
    func testEdgeControlPreservesDecimalAboveSliderMaximumWithoutRangeHint() async throws {
        let address = try XCTUnwrap(doc.effectAddress)
        try doc.setParameter(.flowEdgeProtection, at: address, value: 4095.125)
        let model = doc.state.workingModel
        let revision = doc.state.workingRevision
        XCTAssertEqual(
            WSSEditorParameter.flowEdgeProtection.sliderRange(in: model, at: address).upperBound,
            127.5)
        XCTAssertEqual(WSSEditorParameter.flowEdgeProtection.validRange, 0...4096)
        let input = WSSParameterTextField(
            value: 4095.125, range: WSSEditorParameter.flowEdgeProtection.validRange,
            title: "Randberuhigung"
        ) { try self.doc.setParameter(.flowEdgeProtection, at: address, value: $0) }
        let coordinator = input.makeCoordinator()
        let field = NSTextField(string: "4095,125")
        XCTAssertTrue(coordinator.accept(field))
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertEqual(doc.state.workingRevision, revision)
        field.stringValue = "4096"
        XCTAssertTrue(coordinator.accept(field))
        field.stringValue = "4096.125"
        XCTAssertFalse(coordinator.accept(field))
        XCTAssertEqual(
            WSSEditorParameter.flowEdgeProtection.value(in: doc.state.workingModel, at: address),
            4096)
    }

    func testHostedCanvasToolsAndOptionalGeneratedDemo() async throws {
        if let path = ProcessInfo.processInfo.environment["WSS_FLOW_DEMO"] {
            let entry = URL(fileURLWithPath: path)
            let model = try WSSSceneDocumentV1.load(
                entry: entry, root: entry.deletingLastPathComponent())
            let resources = try WSSStaticResources(
                scene: model.scene(),
                assets: model.assetSource(root: entry.deletingLastPathComponent()),
                device: doc.previewResources.device)
            XCTAssertEqual(resources.flow?.regions.count, 2)
            XCTAssertNotNil(
                try WSSEditorLivePreviewTests().frame(resources, time: 0.35, width: 128))
        }
        try await fixture.stroke()
        let host = NSHostingView(rootView: WSSEditorView(document: doc))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1150, height: 760),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 1150, height: 760)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(session.brushEnabled)
        XCTAssertTrue(session.overlayVisible)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 1000)
        if let path = ProcessInfo.processInfo.environment["WSS_FLOW_EDITOR_SCREENSHOT"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(fileURLWithPath: path))
        }
    }

    func testFailedBasePreparationKeepsAuthoringWithoutObsoleteLiveBindings() async throws {
        try await fixture.stroke()
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let project = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        let failing = WSSEditorDocument(
            project: project, prepare: { _, _, _ in throw WSSVectorFieldEditError.budget })
        defer { failing.close() }
        failing.select(
            .effect(failing.identity.layers[0].id, failing.identity.layers[0].effects[0]))
        let directions = failing.directionCanvas
        directions.setEnabled(true)
        await directions.waitForLoad()
        try failing.setParameter(.flowStrength, at: XCTUnwrap(failing.effectAddress), value: 18)
        await failing.waitForPreview()
        await directions.waitForLoad()
        XCTAssertFalse(failing.previewIsCurrent)
        let before = failing.state.workingModel
        let geometry = try XCTUnwrap(directions.geometry)
        XCTAssertTrue(directions.begin(geometry.scene(SIMD2(0.2, 0.5)), erase: true))
        directions.append(geometry.scene(SIMD2(0.8, 0.5)))
        await directions.waitForFeedback()
        XCTAssertTrue(directions.isDrawing)
        XCTAssertNotNil(directions.transientState)
        XCTAssertNil(directions.liveResources)
        XCTAssertNil(directions.error)
        XCTAssertEqual(failing.state.workingModel, before)
        XCTAssertTrue(failing.editorPreviewResources === project.resources)
        directions.finish(geometry.scene(SIMD2(0.8, 0.5)))
        await directions.waitForFinish()
        XCTAssertNil(directions.error)
        XCTAssertNotEqual(failing.state.workingModel, before)
        await failing.waitForPreview()
        XCTAssertNotNil(failing.preparationError)
        XCTAssertNil(directions.liveResources)
        XCTAssertTrue(failing.editorPreviewResources === project.resources)
    }

    func testFlowRippleFlowSelectionIsImmediatelyEditableWithoutMutationOrExtraUndo() async throws {
        let selected = try XCTUnwrap(doc.selection)
        XCTAssertTrue(session.brushEnabled)
        XCTAssertFalse(session.requiresExplicitActivation)
        let beforeRipple = doc.state.workingModel
        try doc.addEffect(.ripple)
        let ripple = try XCTUnwrap(doc.selection)
        XCTAssertFalse(session.brushEnabled)
        let model = doc.state.workingModel
        let revision = doc.state.workingRevision
        let catalog = doc.state.resourceCatalog
        let count = doc.state.sessionAssets.count
        doc.select(selected)
        XCTAssertTrue(session.brushEnabled)
        XCTAssertFalse(session.requiresExplicitActivation)
        await session.waitForLoad()
        let first = try XCTUnwrap(session.loaded)
        doc.select(ripple)
        XCTAssertFalse(session.brushEnabled)
        doc.select(selected)
        XCTAssertTrue(session.brushEnabled)
        await session.waitForLoad()
        XCTAssertEqual(session.loaded?.resolved.target, first.resolved.target)
        XCTAssertEqual(session.loaded?.region, first.region)
        XCTAssertEqual(session.loaded?.field.vectors, first.field.vectors)
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertEqual(doc.state.workingRevision, revision)
        XCTAssertEqual(doc.state.resourceCatalog, catalog)
        XCTAssertEqual(doc.state.sessionAssets.count, count)
        // No disabled Flow mode can be manufactured by the former exit API.
        session.setEnabled(false)
        XCTAssertTrue(session.brushEnabled)
        XCTAssertFalse(session.requiresExplicitActivation)
        doc.undoManager.undo()
        await session.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, beforeRipple)
    }
    func testRevertAndFlowToFlowRestoreDirectEditingWithoutStrokeResidue() async throws {
        try await fixture.stroke()
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let selected = try XCTUnwrap(doc.selection)
        let savedRegion = try XCTUnwrap(session.loaded?.region)
        let firstID = try XCTUnwrap(session.loaded?.resolved.target.effectID)
        try await begin(erase: true)
        // Changing context cancels the live stroke through the existing path.
        doc.select(.layer(selected.layer))
        await session.waitForFeedback()
        XCTAssertFalse(session.brushEnabled)
        XCTAssertFalse(session.isDrawing)
        XCTAssertNil(session.liveResources)
        doc.select(selected)
        XCTAssertTrue(session.brushEnabled)
        await session.waitForLoad()
        XCTAssertEqual(session.loaded?.region, savedRegion)
        try doc.addEffect(.flow)
        let second = try XCTUnwrap(doc.selection)
        XCTAssertTrue(session.brushEnabled)
        await session.waitForLoad()
        XCTAssertNotEqual(session.loaded?.resolved.target.effectID, firstID)
        doc.select(selected)
        await session.waitForLoad()
        XCTAssertEqual(session.loaded?.region, savedRegion)
        doc.select(second)
        await session.waitForLoad()
        XCTAssertTrue(try XCTUnwrap(session.loaded?.region).pixels.allSatisfy { $0 == 0 })
        doc.revert()
        doc.select(selected)
        await session.waitForLoad()
        XCTAssertTrue(session.brushEnabled)
        XCTAssertFalse(session.requiresExplicitActivation)
        XCTAssertEqual(session.loaded?.region, savedRegion)
        XCTAssertFalse(doc.isDirty)
    }

    func testRippleSelectionKeepsScalarPaintingSeparateFromFlow() async throws {
        session.setEnabled(false)
        try doc.addEffect(.ripple)
        await doc.performMaskAction(.create)
        await doc.maskCanvas.waitForLoad()
        XCTAssertNotNil(doc.maskCanvas.loaded)
        XCTAssertFalse(session.overlayVisible)
        doc.maskCanvas.setBrush(true)
        XCTAssertTrue(doc.maskCanvas.brushEnabled)
        XCTAssertFalse(session.brushEnabled)
        doc.maskCanvas.setBrush(false)
    }

}
