import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSPreviewPresentationTests: XCTestCase {
    var fixtures: WSSEditorLivePreviewTests!
    override func setUp() async throws {
        fixtures = WSSEditorLivePreviewTests()
        try await fixtures.setUp()
    }
    override func tearDown() async throws { try await fixtures.tearDown() }
    func hosted(_ doc: WSSEditorDocument) -> (WSSPreviewHost, NSWindow) {
        let host = WSSPreviewHost(document: doc)
        host.update(doc)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        return (host, window)
    }
    func settle() async throws { try await Task.sleep(nanoseconds: 40_000_000) }
    func testPlayingExpansionReusesExactSurfacePlayerResourcesAndTimeline() async throws {
        let loaded = try await fixtures.project("WSS-Flow-v1")
        let doc = WSSEditorDocument(project: loaded)
        let (host, window) = hosted(doc)
        defer {
            doc.close()
            window.close()
        }
        try await settle()
        let player = try XCTUnwrap(host.surface.player)
        let before = player.elapsed
        try await settle()
        XCTAssertGreaterThan(player.elapsed, before)  // Small preview works before expansion.
        let model = doc.state.workingModel
        let canvas = doc.canvasModel
        let time = player.elapsed
        let surface = host.surface
        host.expand()
        try await settle()
        let large = try XCTUnwrap(host.expandedWindow)
        XCTAssertTrue(doc.previewExpanded)
        XCTAssertTrue(host.surface === surface)
        XCTAssertTrue(host.surface.player === player)
        XCTAssertTrue(player.resources === loaded.resources)
        XCTAssertTrue(surface.window === large)
        XCTAssertEqual(
            surface.bounds.width / surface.bounds.height,
            CGFloat(loaded.scene.width) / CGFloat(loaded.scene.height), accuracy: 0.00001)
        XCTAssertFalse(host.subviews.contains { $0 === surface })
        XCTAssertGreaterThanOrEqual(player.elapsed, time)
        XCTAssertFalse(player.view.isPaused)
        let playingLarge = player.elapsed
        try await settle()
        XCTAssertGreaterThan(player.elapsed, playingLarge)
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertEqual(doc.canvasModel, canvas)
        XCTAssertFalse(doc.isDirty)
        XCTAssertTrue(doc.playing)
        host.restore()
        try await settle()
        XCTAssertNil(host.expandedWindow)
        XCTAssertFalse(large.isVisible)
        XCTAssertNil(large.contentView)
        XCTAssertTrue(surface.superview === host)
        XCTAssertTrue(surface.player === player)
        XCTAssertGreaterThanOrEqual(player.elapsed, playingLarge)
        XCTAssertFalse(player.view.isPaused)
        XCTAssertFalse(doc.previewExpanded)
        XCTAssertEqual(window.childWindows?.count ?? 0, 0)
    }
    func testPausedExpansionAndNativeClosePreserveFrozenTime() async throws {
        let doc = WSSEditorDocument(
            project: try await fixtures.project("WSS-Ripple-v1"))
        doc.playing = false
        let (host, window) = hosted(doc)
        defer {
            doc.close()
            window.close()
        }
        try await settle()
        let player = try XCTUnwrap(host.surface.player)
        let frozen = player.elapsed
        host.expand()
        try await settle()
        let large = try XCTUnwrap(host.expandedWindow)
        XCTAssertTrue(host.surface.player === player)
        XCTAssertEqual(player.elapsed, frozen)
        XCTAssertTrue(player.view.isPaused)
        XCTAssertFalse(doc.playing)
        large.performClose(nil)
        try await settle()
        XCTAssertNil(host.expandedWindow)
        XCTAssertTrue(host.surface.player === player)
        XCTAssertEqual(player.elapsed, frozen)
        XCTAssertTrue(player.view.isPaused)
        XCTAssertFalse(doc.previewExpanded)
        XCTAssertFalse(doc.isDirty)
    }
    func testExpandedWorkingResourcesUpdateAndSelectionDoesNotFilterEffects() async throws {
        let doc = WSSEditorDocument(project: try await fixtures.project("WSS-Flow-Ripple-v1"))
        let (host, window) = hosted(doc)
        defer {
            doc.close()
            window.close()
        }
        try await settle()
        host.expand()
        let originalPlayer = try XCTUnwrap(host.surface.player)
        let original = doc.previewResources.scene.imageLayers.map(\.effects)
        for row in doc.structureRows {
            doc.select(row.id)
            host.update(doc)
            XCTAssertTrue(host.surface.player === originalPlayer)
            XCTAssertEqual(
                host.surface.player?.resources.scene.imageLayers.map(\.effects), original)
            XCTAssertFalse(doc.isDirty)
        }
        let layer = try XCTUnwrap(doc.identity.layers.first { $0.effects.count == 2 })
        doc.select(.effect(layer.id, layer.effects[1]))
        let address = try XCTUnwrap(doc.effectAddress)
        try doc.setParameter(.rippleAmplitude, at: address, value: 24)
        await doc.waitForPreview()
        host.update(doc)
        let updated = try XCTUnwrap(host.surface.player)
        XCTAssertTrue(updated.resources === doc.previewResources)
        XCTAssertNotNil(updated.resources.flow)
        XCTAssertNil(originalPlayer.view.delegate)
        XCTAssertTrue(host.surface.window === host.expandedWindow)
        host.restore()
        XCTAssertTrue(host.surface.player === updated)
        XCTAssertEqual(
            updated.resources.scene.imageLayers.map(\.effects),
            doc.workingScene.imageLayers.map(\.effects))
    }
    func testDocumentCloseStopsExpandedPlayerAndReleasesPresentation() async throws {
        let doc = WSSEditorDocument(
            project: try await fixtures.project("WSS-Ripple-v1"))
        let (host, window) = hosted(doc)
        defer { window.close() }
        try await settle()
        host.expand()
        let large = try XCTUnwrap(host.expandedWindow)
        var player = host.surface.player
        weak var released = player
        XCTAssertNotNil(player?.resources.ripple)
        doc.close()
        XCTAssertNil(host.expandedWindow)
        XCTAssertFalse(large.isVisible)
        XCTAssertNil(large.contentView)
        XCTAssertNil(host.surface.player)
        XCTAssertNil(player?.view.delegate)
        XCTAssertNil(doc.togglePreviewExpansion)
        XCTAssertFalse(doc.previewExpanded)
        player = nil
        XCTAssertNil(released)
        host.shutdown()
    }
    func testActualWorkspaceExpandActionUsesAlreadyRunningSmallPlayer() async throws {
        let doc = WSSEditorDocument(project: try await fixtures.project("WSS-Flow-v1"))
        let controller = WSSEditorWindowController(document: doc, onClose: {})
        defer {
            doc.close()
            controller.close()
        }
        controller.showWindow(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        func host(_ view: NSView) -> WSSPreviewHost? {
            if let value = view as? WSSPreviewHost { return value }
            return view.subviews.lazy.compactMap { host($0) }.first
        }
        for _ in 0..<5 { try await settle() }
        let presentation = try XCTUnwrap(host(try XCTUnwrap(controller.window?.contentView)))
        let player = try XCTUnwrap(presentation.surface.player)
        let before = player.elapsed
        try await settle()
        XCTAssertGreaterThan(player.elapsed, before)
        XCTAssertNotNil(doc.togglePreviewExpansion)
        doc.togglePreviewExpansion?()
        try await settle()
        XCTAssertTrue(presentation.surface.player === player)
        XCTAssertTrue(doc.previewExpanded)
        XCTAssertTrue(WSSEditorCoordinator.document(in: presentation.expandedWindow) === doc)
        XCTAssertFalse(player.view.isPaused)
        doc.togglePreviewExpansion?()
        try await settle()
        XCTAssertTrue(presentation.surface.player === player)
        XCTAssertFalse(doc.previewExpanded)
        XCTAssertFalse(doc.isDirty)
    }
    func testTransferPreservesTrailSessionAndClearsLocalPointer() async throws {
        let loaded = try await fixtures.project("WSS-Rain-v1")
        var model = loaded.document
        var trail = model.layers[0]
        trail.content = .trail(WSSTrailTests().configuration(), visible: true)
        model.layers.append(trail)
        try model.encoded().write(to: loaded.handle.entry)
        let project = try await WSSEditorProjectLoader().load(loaded.handle.wallpaper)
        let doc = WSSEditorDocument(project: project)
        // Freeze automatic trail advancement while testing presentation transfer.
        // A running nil-pointer frame legitimately resets manually seeded trail samples.
        doc.playing = false
        let (host, window) = hosted(doc)
        defer {
            doc.close()
            window.close()
        }
        try await settle()
        let player = try XCTUnwrap(host.surface.player)
        let index = model.layers.count - 1
        _ = try WSSPreviewTests().render(
            player.resources, size: CGSize(width: 64, height: 64), time: player.elapsed,
            trail: player.trailContext, pointer: SIMD2(10, 20))
        XCTAssertGreaterThan(player.trailContext.sampleCount(index: index), 0)
        host.expand()
        XCTAssertTrue(host.surface.player === player)
        XCTAssertNil(player.currentPointer())
        XCTAssertGreaterThan(player.trailContext.sampleCount(index: index), 0)
        host.restore()
        XCTAssertTrue(host.surface.player === player)
        XCTAssertNil(player.currentPointer())
        XCTAssertGreaterThan(player.trailContext.sampleCount(index: index), 0)
    }

}
