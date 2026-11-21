import AppKit
import SwiftUI
import XCTest

@testable import Wupsy

@MainActor final class WSSMusicNotesAuthoringTests: XCTestCase {
    private var helper: WSSMaskEditingTests!
    private var doc: WSSEditorDocument { helper.doc }

    override func setUp() async throws {
        helper = WSSMaskEditingTests()
        try await helper.setUp()
        try doc.addMusicNotes()
    }

    override func tearDown() async throws {
        try await helper.tearDown()
    }

    func testTransformParametersOrderUndoAndSaveReopen() async throws {
        let id = try XCTUnwrap(doc.selection?.layer)
        let defaults = try XCTUnwrap(doc.musicNotesLayer(id))
        XCTAssertEqual(defaults.notes.count, 12)
        XCTAssertEqual(doc.transformModeLayer, id)
        XCTAssertFalse(doc.beginCanvasTransform(id, kind: .rotate))
        doc.undoManager.removeAllActions()
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .move))
        var transform = defaults.canvasTransform
        transform.center[0] += 18
        transform.center[1] -= 6
        try doc.updateCanvasTransform(transform)
        doc.endCanvasTransform()
        XCTAssertEqual(doc.musicNotesLayer(id)?.region.x, defaults.region.x + 18)
        XCTAssertEqual(doc.musicNotesLayer(id)?.region.y, defaults.region.y - 6)
        doc.undoManager.undo()
        XCTAssertEqual(doc.musicNotesLayer(id), defaults)
        doc.undoManager.redo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.region.x, defaults.region.x + 18)

        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .scale(0, independent: true)))
        transform.scale = [0.5, 0.75]
        try doc.updateCanvasTransform(transform)
        doc.endCanvasTransform()
        XCTAssertEqual(doc.musicNotesLayer(id)?.region.width, defaults.region.width / 2)
        XCTAssertEqual(doc.musicNotesLayer(id)?.region.height, defaults.region.height * 0.75)

        try doc.changeMusicNotes(id, name: "Notes") {
            $0.symbols = [.eighth, .double]
            $0.speed = 0.125
            $0.color = .init(red: 0.25, green: 0.6, blue: 1)
        }
        try doc.moveLayer(id, to: 0)
        XCTAssertEqual(doc.identity.layers.first?.id, id)
        try doc.setVisibility(false, layer: id)
        doc.undoManager.undo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.visible, true)
        doc.undoManager.redo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.visible, false)

        let snapshot = doc.state.workingModel
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, snapshot)
    }

    func testResetPreservesLayerStateAndFogPresetAcrossSave() async throws {
        let notesID = try XCTUnwrap(doc.selection?.layer)
        try doc.changeMusicNotes(notesID, name: "Customize notes") {
            $0.count = 2
            $0.hover = true
            $0.symbols = [.double]
        }
        XCTAssertTrue(doc.beginCanvasTransform(notesID, kind: .move))
        var transform = try XCTUnwrap(doc.musicNotesLayer(notesID)).canvasTransform
        transform.center[0] += 10
        try doc.updateCanvasTransform(transform)
        doc.endCanvasTransform()
        try doc.setVisibility(false, layer: notesID)
        try doc.addFog(.atmosphere)
        let fogID = try XCTUnwrap(doc.selection?.layer)
        try doc.changeFog(fogID, name: "Customize Fog") { $0.height = 0.6 }
        try doc.setVisibility(false, layer: fogID)

        let before = doc.state.workingModel
        let identity = doc.identity
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, before)
        XCTAssertEqual(doc.fogLayer(fogID)?.preset, .atmosphere)

        doc.undoManager.removeAllActions()
        var defaultNotes = try XCTUnwrap(doc.musicNotesLayer(notesID))
        defaultNotes.notes = .init()
        try doc.resetMusicNotes(notesID)
        XCTAssertEqual(doc.musicNotesLayer(notesID), defaultNotes)
        XCTAssertEqual(doc.fogLayer(fogID)?.fog.height, 0.6)
        XCTAssertEqual(doc.identity, identity)
        let withDefaultNotes = doc.state.workingModel
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, withDefaultNotes)

        try doc.resetFog(fogID)
        XCTAssertEqual(doc.fogLayer(fogID)?.fog, WSSFogPreset.atmosphere.configuration)
        XCTAssertEqual(doc.fogLayer(fogID)?.visible, false)
        XCTAssertEqual(doc.musicNotesLayer(notesID), defaultNotes)
        XCTAssertEqual(doc.identity, identity)
        let withBothDefaults = doc.state.workingModel
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, withDefaultNotes)
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, withBothDefaults)
    }

    func testHostedPreviewVisibilityRestartAndRunningColorUpdates() async throws {
        let id = try XCTUnwrap(doc.selection?.layer)
        for other in doc.identity.layers where other.id != id {
            try doc.setVisibility(false, layer: other.id)
        }
        try doc.setVisibility(false, layer: id)
        await doc.waitForPreview()
        XCTAssertFalse(doc.previewResources.scene.isAnimated)
        let renderer = try XCTUnwrap(doc.previewResources.musicNotes)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(
            rootView: HStack {
                WSSPreviewView(document: doc)
                WSSMusicNotesParameterControls(document: doc, layer: id).frame(width: 230)
            })
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }

        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            return view.subviews.lazy.compactMap { find(type, in: $0) }.first
        }

        hosting.layoutSubtreeIfNeeded()
        for _ in 0..<100 where find(WSSPreviewHost.self, in: hosting) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let host = try XCTUnwrap(find(WSSPreviewHost.self, in: hosting))
        let colorWell = try XCTUnwrap(find(NSColorWell.self, in: hosting))
        let inactive = try XCTUnwrap(host.surface.player)
        XCTAssertTrue(inactive.view.isPaused)
        let elapsed = inactive.elapsed

        try doc.setVisibility(true, layer: id)
        await doc.waitForPreview()
        for _ in 0..<100 where host.surface.player === inactive {
            try await Task.sleep(for: .milliseconds(10))
        }
        let player = try XCTUnwrap(host.surface.player)
        XCTAssertFalse(player === inactive)
        XCTAssertNil(inactive.view.delegate)
        XCTAssertFalse(player.view.isPaused)
        XCTAssertGreaterThanOrEqual(player.elapsed, elapsed)
        XCTAssertTrue(player.resources.musicNotes === renderer)

        for color in [
            WSSFogConfiguration.Color(red: 1, green: 0, blue: 0.2),
            .init(red: 0.1, green: 1, blue: 0.3),
        ] {
            colorWell.color = NSColor(
                srgbRed: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue),
                alpha: 1)
            XCTAssertTrue(colorWell.sendAction(colorWell.action, to: colorWell.target))
            await doc.waitForPreview()
            let resources = doc.previewResources
            for _ in 0..<100 where player.resources !== resources {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(host.surface.player === player)
            XCTAssertTrue(player.resources === resources)
            XCTAssertTrue(resources.musicNotes === renderer)
            guard case .musicNotes(let layer) = player.resources.scene.layers.last else {
                return XCTFail("Missing preview music notes")
            }
            XCTAssertEqual(layer.notes.color, color)
            let target = player.metrics.snapshot().frames + 2
            for _ in 0..<150 where player.metrics.snapshot().frames < target {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThanOrEqual(player.metrics.snapshot().frames, target)
        }

        let steady = try WSSStormLightingRenderTests().render(player.resources, time: 1.5).0
        try doc.changeMusicNotes(id, name: "Hover") { $0.hover = true }
        await doc.waitForPreview()
        let hovering = doc.previewResources
        for _ in 0..<100 where player.resources !== hovering {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(host.surface.player === player)
        XCTAssertTrue(player.resources === hovering)
        XCTAssertTrue(hovering.musicNotes === renderer)
        XCTAssertNotEqual(
            steady, try WSSStormLightingRenderTests().render(hovering, time: 1.5).0)

        let elapsedBeforePath = player.elapsed
        var model = doc.state.workingModel
        var layer = try XCTUnwrap(doc.musicNotesLayer(id))
        let start = SIMD2<Double>(0.15, 0.25)
        let end = SIMD2<Double>(0.85, 0.75)
        layer.path = .init(
            enabled: true, closed: false, direction: .reverse,
            anchors: [
                .init(position: start, incoming: start, outgoing: start),
                .init(position: end, incoming: end, outgoing: end),
            ])
        model.layers[try XCTUnwrap(model.layers.indices.last)].content = .musicNotes(layer)
        try doc.mutate(model, name: "Path")
        await doc.waitForPreview()
        let withPath = doc.previewResources
        for _ in 0..<100 where player.resources !== withPath {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(host.surface.player === player)
        XCTAssertTrue(player.resources === withPath)
        XCTAssertTrue(withPath.musicNotes === renderer)
        XCTAssertEqual(withPath.musicNotesPaths.count, 1)
        XCTAssertGreaterThanOrEqual(player.elapsed, elapsedBeforePath)

        try doc.setVisibility(false, layer: id)
        await doc.waitForPreview()
        for _ in 0..<100 where !player.view.isPaused {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(host.surface.player === player)
        XCTAssertTrue(player.view.isPaused)
    }
}
