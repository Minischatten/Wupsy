import AppKit
import SwiftUI
import XCTest

@testable import Wupsy

@MainActor final class WSSStarfieldAuthoringTests: XCTestCase {
    var helper: WSSMaskEditingTests!
    var doc: WSSEditorDocument { helper.doc }
    override func setUp() async throws {
        helper = WSSMaskEditingTests()
        try await helper.setUp()
        try doc.addStarfield()
    }
    override func tearDown() async throws { try await helper.tearDown() }
    func testParametersColorTransactionsAndSaveReopen() async throws {
        let id = try XCTUnwrap(doc.selection?.layer)
        await doc.waitForPreview()
        let original = doc.state.workingModel
        let resources = doc.previewResources
        doc.undoManager.removeAllActions()
        try doc.setStarfield(.brightness, value: 1.234567891, layer: id)
        await doc.waitForPreview()
        XCTAssertTrue(resources.starfield === doc.previewResources.starfield)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, original)
        doc.undoManager.redo()
        let before = doc.state.workingModel
        doc.beginStarfieldColorInteraction(id)
        try doc.setStarfieldColor(.init(r: 0, g: 1, b: 0.5), layer: id, undo: false)
        try doc.setStarfieldColor(.init(r: 0.2, g: 0.4, b: 0.8), layer: id, undo: false)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        doc.undoManager.redo()
        let snapshot = doc.state.workingModel
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, snapshot)
        XCTAssertNil(doc.starfieldColorDrag)
        XCTAssertTrue(
            WSSStaticComposition.model(snapshot).layers.allSatisfy { $0.imageTransform != nil })
    }
    func testRepeatedColorsReachHostedPreviewAndMetal() async throws {
        let id = try XCTUnwrap(doc.selection?.layer)
        try doc.changeStarfield(id, name: "Enable galaxy") { $0.starfield.milkyWay.enabled = true }
        for layer in doc.identity.layers where layer.id != id {
            try doc.setVisibility(false, layer: layer.id)
        }
        doc.playing = false
        await doc.waitForPreview()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: WSSPreviewView(document: doc))
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        func preview(in view: NSView) -> WSSPreviewHost? {
            if let host = view as? WSSPreviewHost { return host }
            return view.subviews.lazy.compactMap { preview(in: $0) }.first
        }
        hosting.layoutSubtreeIfNeeded()
        for _ in 0..<100 where preview(in: hosting) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let host = try XCTUnwrap(preview(in: hosting))
        host.surface.measuresPerformance = true
        let player = try XCTUnwrap(host.surface.player)
        let metrics = try XCTUnwrap(player.metrics)
        XCTAssertTrue(player.view.isPaused)
        // Simulate a visible view that no longer draws from AppKit invalidation.
        player.view.enableSetNeedsDisplay = false
        player.view.draw()
        for _ in 0..<100 where metrics.snapshot().frames == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(metrics.snapshot().frames, 0)
        let prepared = player.resources
        var pixels = try WSSStarfieldTests().render(prepared)
        let colors: [WSSTrailColor] = [
            .init(r: 1, g: 0, b: 0), .init(r: 0, g: 1, b: 0), .init(r: 0, g: 0, b: 1),
        ]
        for role: WSSStarfieldColorRole in [.stars, .milkyWay] {
            doc.beginStarfieldColorInteraction(id, role: role)
            for color in colors {
                let frames = metrics.snapshot().frames
                let previous = doc.state.workingRevision
                try doc.setStarfieldColor(color, layer: id, role: role, undo: false)
                let revision = doc.state.workingRevision
                XCTAssertGreaterThan(revision, previous)
                await doc.waitForPreview()
                XCTAssertEqual(doc.previewRevision, revision)
                let resources = doc.previewResources
                for _ in 0..<100 where player.resources !== resources {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertTrue(host.surface.player === player)
                XCTAssertTrue(player.resources === resources)
                XCTAssertTrue(resources.starfield === prepared.starfield)
                XCTAssertTrue(resources.milkyWay === prepared.milkyWay)
                for _ in 0..<100 where metrics.snapshot().frames == frames {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertGreaterThan(metrics.snapshot().frames, frames)
                let updated = try WSSStarfieldTests().render(player.resources)
                XCTAssertNotEqual(updated, pixels, "Expected new pixels for \(role) and \(color)")
                pixels = updated
            }
            doc.endStarfieldColorInteraction()
        }
        player.view.enableSetNeedsDisplay = true
        doc.playing = true
        var current = player
        for enabled in [true, false, true, false] {
            let previous = current
            let frames = try XCTUnwrap(previous.metrics).snapshot().frames
            let elapsed = previous.elapsed
            try doc.changeStarfield(id, name: "Twinkle") { $0.starfield.twinkleEnabled = enabled }
            await doc.waitForPreview()
            let resources = doc.previewResources
            for _ in 0..<100 where host.surface.player?.resources !== resources {
                try await Task.sleep(for: .milliseconds(10))
            }
            current = try XCTUnwrap(host.surface.player)
            if enabled {
                XCTAssertFalse(current === previous)
                XCTAssertNil(previous.view.delegate)
                XCTAssertGreaterThanOrEqual(current.elapsed, elapsed)
            } else {
                XCTAssertTrue(current === previous)
            }
            XCTAssertTrue(current.resources === resources)
            XCTAssertTrue(current.resources.starfield === prepared.starfield)
            XCTAssertEqual(current.resources.scene.isAnimated, enabled)
            XCTAssertEqual(current.view.isPaused, !enabled)
            XCTAssertEqual(current.view.enableSetNeedsDisplay, !enabled)
            let currentMetrics = try XCTUnwrap(current.metrics)
            let targetFrames = enabled ? currentMetrics.snapshot().frames + 3 : frames + 1
            for _ in 0..<200 where currentMetrics.snapshot().frames < targetFrames {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThanOrEqual(currentMetrics.snapshot().frames, targetFrames)
            guard enabled else { continue }
            try await verifyDriftAndColorWhileRunning(id: id, host: host, player: current)
            for color in colors.prefix(2) {
                doc.playing = false
                for _ in 0..<100 where !current.view.isPaused {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertTrue(current.view.isPaused)
                XCTAssertTrue(host.surface.player === current)
                let pausedResources = current.resources
                let frozen = current.elapsed
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(current.elapsed, frozen)
                let paused = current
                let requested = ProcessInfo.processInfo.systemUptime
                doc.playing = true
                for _ in 0..<100 where host.surface.player === paused {
                    try await Task.sleep(for: .milliseconds(10))
                }
                current = try XCTUnwrap(host.surface.player)
                let resumed = current.elapsed
                XCTAssertFalse(current === paused)
                XCTAssertNil(paused.view.delegate)
                XCTAssertNil(paused.view.superview)
                XCTAssertTrue(current.resources === pausedResources)
                XCTAssertFalse(current.view.isPaused)
                XCTAssertGreaterThanOrEqual(resumed, frozen)
                XCTAssertLessThanOrEqual(
                    resumed, frozen + (ProcessInfo.processInfo.systemUptime - requested))
                let resumedMetrics = try XCTUnwrap(current.metrics)
                let afterResume = resumedMetrics.snapshot().frames
                for _ in 0..<200 where resumedMetrics.snapshot().frames < afterResume + 3 {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertGreaterThanOrEqual(resumedMetrics.snapshot().frames, afterResume + 3)

                try doc.setStarfieldColor(
                    color, layer: id, role: .milkyWay)
                await doc.waitForPreview()
                for _ in 0..<100 where current.resources !== doc.previewResources {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertTrue(host.surface.player === current)
                XCTAssertTrue(current.resources === doc.previewResources)
            }
        }
    }
    private func verifyDriftAndColorWhileRunning(
        id: WSSLayerID, host: WSSPreviewHost, player: WSSStaticPlayer
    ) async throws {
        let metrics = try XCTUnwrap(player.metrics)
        let view = player.view
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.driftX, 0)
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.driftY, 0)
        let input = WSSParameterTextField(
            value: 0, range: -10...10, title: WSSStarfieldParameter.driftX.title,
            maximumFractionDigits: 3, exactValue: 0, exactRange: -10...10,
            commitExact: { [self] in try doc.setStarfield(.driftX, value: $0, layer: id) },
            commit: { [self] in try doc.setStarfield(.driftX, value: Double($0), layer: id) })
        let field = NSTextField(string: "1")
        let coordinator = input.makeCoordinator()
        XCTAssertTrue(coordinator.control(field, textShouldEndEditing: NSTextView()))
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.driftX, 1)

        func awaitFrames() async throws {
            await doc.waitForPreview()
            let resources = doc.previewResources
            for _ in 0..<100 where player.resources !== resources {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(player.resources === resources)
            XCTAssertTrue(host.surface.player === player)
            XCTAssertTrue(player.view === view)
            XCTAssertFalse(view.isPaused)
            XCTAssertFalse(view.enableSetNeedsDisplay)
            let target = metrics.snapshot().frames + 3
            for _ in 0..<200 where metrics.snapshot().frames < target {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThanOrEqual(metrics.snapshot().frames, target)
        }
        try await awaitFrames()
        let previous = doc.state.workingRevision
        try doc.setStarfieldColor(.init(r: 0.25, g: 0.75, b: 0.5), layer: id)
        XCTAssertGreaterThan(doc.state.workingRevision, previous)
        try await awaitFrames()
        try doc.setStarfield(.driftX, value: 0, layer: id)
        try await awaitFrames()
        // Restore the starting color so the next cycle also commits a new color.
        try doc.setStarfieldColor(.init(r: 0, g: 0, b: 1), layer: id)
        try await awaitFrames()
    }
    func testCanvasTranslationIndependentScalingUndoAndNoRotation() async throws {
        let id = try XCTUnwrap(doc.selection?.layer)
        let original = try XCTUnwrap(doc.starfieldLayer(id)).starfield
        let transform = original.canvasTransform
        let native = try transform.native()
        XCTAssertEqual(
            WSSCanvasInteractionGeometry.handles(
                transform: native, origin: .zero, zoom: 1, height: 64, allowsRotation: false
            ).count, 4)
        XCTAssertFalse(doc.beginCanvasTransform(id, kind: .rotate))
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .move))
        var moved = transform
        moved.center[0] += 10
        moved.center[1] += 20
        try doc.updateCanvasTransform(moved)
        doc.endCanvasTransform()
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.x, original.x + 10)
        doc.undoManager.undo()
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield, original)
        doc.undoManager.redo()
        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .scale(0, independent: true)))
        moved.scale = [0.5, 0.75]
        try doc.updateCanvasTransform(moved)
        doc.endCanvasTransform()
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.width, original.width * 0.5)
        XCTAssertEqual(doc.starfieldLayer(id)?.starfield.height, original.height * 0.75)
        var rotated = transform
        rotated.rotation = 1
        XCTAssertThrowsError(try original.applying(rotated))
        try doc.setVisibility(false, layer: id)
        XCTAssertFalse(doc.canTransform(id))
        doc.undoManager.undo()
        XCTAssertTrue(doc.canTransform(id))
    }
}
