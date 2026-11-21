import AppKit
import XCTest
import simd

@testable import Wupsy

@MainActor final class WSSMusicNotesPathEditorTests: XCTestCase {
    private var fixtures: WSSEditorLivePreviewTests!
    private var loaded: WSSLoadedEditorProject!
    private var doc: WSSEditorDocument!

    override func setUp() async throws {
        fixtures = WSSEditorLivePreviewTests()
        try await fixtures.setUp()
        loaded = try await fixtures.project("WSS-Music-Notes-Paths")
        let project = try XCTUnwrap(loaded)
        let storage = fixtures.helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([project.handle.wallpaper]).write(to: storage)
        let store = ManagedWallpaperStore(storage: storage)
        doc = WSSEditorDocument(
            project: project,
            save: { snapshot in
                let candidate = try await WSSManifestSaveValidator().prepare(
                    snapshot, handle: project.handle)
                return try await store.commitWSSManifest(candidate)
            })
    }

    override func tearDown() async throws {
        doc.close()
        await doc.waitForDraftCleanup()
        try await fixtures.tearDown()
    }

    private func findCanvas(in view: NSView) -> WSSCanvasScrollView? {
        if let canvas = view as? WSSCanvasScrollView { return canvas }
        return view.subviews.lazy.compactMap { self.findCanvas(in: $0) }.first
    }

    private func point(_ vector: SIMD2<Double>) -> CGPoint {
        CGPoint(x: vector.x, y: vector.y)
    }

    func testInitialFramePathModeMouseAndDocumentSwitch() async throws {
        let first = doc.identity.layers[0].id
        let second = doc.identity.layers[1].id
        let windowController = WSSEditorWindowController(document: doc, onClose: {})
        defer { windowController.close() }
        windowController.showWindow(nil)
        let window = try XCTUnwrap(windowController.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let canvas = try XCTUnwrap(findCanvas(in: content))
        try await Task.sleep(for: .milliseconds(50))
        canvas.layoutSubtreeIfNeeded()
        XCTAssertEqual(doc.selection, .layer(first))
        XCTAssertEqual(doc.transformModeLayer, first)
        XCTAssertTrue(canvas.surface.showsTransformHandles)
        XCTAssertTrue(canvas.surface.showsMusicNotesPath)
        let passiveOverlay = canvas.surface.musicNotesPathOverlay
        let passiveAnchor = try XCTUnwrap(passiveOverlay.path?.anchors.first)
        XCTAssertFalse(passiveOverlay.isEditing)
        XCTAssertNil(passiveOverlay.hitTest(point(passiveOverlay.viewport(passiveAnchor.position))))
        XCTAssertNil(
            passiveOverlay.handle(at: point(passiveOverlay.viewport(passiveAnchor.position))))

        doc.beginMusicNotesPathEditing(first)
        canvas.update(doc, zoom: nil)
        XCTAssertTrue(canvas.surface.showsMusicNotesPath)
        XCTAssertFalse(canvas.surface.showsTransformHandles)
        XCTAssertNotNil(canvas.surface.pathGuideTransform)
        XCTAssertFalse(doc.beginCanvasTransform(first, kind: .move))

        let path = try XCTUnwrap(doc.musicNotesLayer(first)?.path)
        let overlay = canvas.surface.musicNotesPathOverlay
        XCTAssertNil(canvas.canvasHit(at: point(overlay.viewport(.zero))))
        let anchor = point(overlay.viewport(path.anchors[0].position))
        let start = point(overlay.viewport(path.editorSegment(0).point(at: 0.41)))
        func mouse(_ type: NSEvent.EventType, at location: CGPoint, clicks: Int = 1) throws
            -> NSEvent
        {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: canvas.surface.convert(location, to: nil),
                    modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: clicks, pressure: 1))
        }
        canvas.beginInteraction(try mouse(.leftMouseDown, at: anchor))
        canvas.dragInteraction(
            try mouse(.leftMouseDragged, at: CGPoint(x: anchor.x + 12, y: anchor.y)))
        canvas.endInteraction(try mouse(.leftMouseUp, at: CGPoint(x: anchor.x + 12, y: anchor.y)))
        XCTAssertGreaterThan(
            try XCTUnwrap(doc.musicNotesLayer(first)?.path?.anchors[0].position.x), 0)
        doc.undoManager.undo()
        canvas.update(doc, zoom: nil)

        canvas.beginInteraction(try mouse(.leftMouseDown, at: anchor))
        canvas.endInteraction(try mouse(.leftMouseUp, at: anchor))
        let grip = point(overlay.viewport(path.anchors[0].outgoing))
        XCTAssertEqual(overlay.handle(at: grip), .outgoing(0))
        let movedGrip = CGPoint(x: grip.x - 8, y: grip.y + 6)
        canvas.beginInteraction(try mouse(.leftMouseDown, at: grip))
        canvas.dragInteraction(try mouse(.leftMouseDragged, at: movedGrip))
        canvas.endInteraction(try mouse(.leftMouseUp, at: movedGrip))
        let newPath = try XCTUnwrap(doc.musicNotesLayer(first)?.path)
        XCTAssertLessThan(newPath.anchors[0].outgoing.x, path.anchors[0].outgoing.x)
        XCTAssertEqual(newPath.anchors[0].position, path.anchors[0].position)
        doc.undoManager.undo()
        canvas.update(doc, zoom: nil)

        canvas.beginInteraction(try mouse(.leftMouseDown, at: start, clicks: 2))
        XCTAssertEqual(doc.musicNotesLayer(first)?.path?.anchors.count, path.anchors.count + 1)
        let delete = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
        canvas.keyDown(with: delete)
        XCTAssertEqual(doc.musicNotesLayer(first)?.path?.anchors.count, path.anchors.count)

        doc.select(.layer(second))
        canvas.update(doc, zoom: nil)
        XCTAssertTrue(canvas.surface.showsMusicNotesPath)
        XCTAssertEqual(canvas.surface.musicNotesPathOverlay.path, doc.musicNotesLayer(second)?.path)
        XCTAssertFalse(canvas.surface.musicNotesPathOverlay.isEditing)
        XCTAssertTrue(canvas.surface.showsTransformHandles)
        XCTAssertEqual(doc.transformModeLayer, second)
        XCTAssertNil(canvas.surface.pathGuideTransform)
        doc.select(.layer(first))
        canvas.update(doc, zoom: nil)
        XCTAssertTrue(canvas.surface.showsTransformHandles)
        XCTAssertEqual(canvas.surface.musicNotesPathOverlay.path, doc.musicNotesLayer(first)?.path)
        try doc.setMusicNotesPathEnabled(false, layer: first)
        canvas.update(doc, zoom: nil)
        XCTAssertFalse(canvas.surface.showsMusicNotesPath)
        XCTAssertNotNil(doc.musicNotesLayer(first)?.path)

        let other = WSSEditorDocument(project: loaded)
        defer { other.close() }
        let otherCanvas = WSSCanvasScrollView(document: other)
        XCTAssertNotEqual(doc.identity.layers[0].id, other.identity.layers[0].id)
        XCTAssertTrue(otherCanvas.surface.showsTransformHandles)
        XCTAssertTrue(otherCanvas.surface.showsMusicNotesPath)
        XCTAssertFalse(otherCanvas.surface.musicNotesPathOverlay.isEditing)
        otherCanvas.shutdown()
    }

    func testPathGuideMatchesMovedResizedRegionAndRestoresHandles() throws {
        let id = doc.identity.layers[0].id
        let canvas = WSSCanvasScrollView(document: doc)
        defer { canvas.shutdown() }
        XCTAssertTrue(canvas.surface.showsTransformHandles)
        XCTAssertNil(canvas.surface.pathGuideTransform)

        XCTAssertTrue(doc.beginCanvasTransform(id, kind: .scale(0, independent: true)))
        var transform = try XCTUnwrap(doc.musicNotesLayer(id)).canvasTransform
        transform.size = [220, 80]
        transform.center = [260, 240]
        try doc.updateCanvasTransform(transform)
        doc.endCanvasTransform()
        doc.beginMusicNotesPathEditing(id)
        for zoom in [0.25, 2.0] {
            canvas.update(doc, zoom: zoom)
            let guide = try XCTUnwrap(canvas.surface.pathGuideTransform)
            let overlay = canvas.surface.musicNotesPathOverlay
            for corner in [SIMD2<Double>(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)] {
                let position = guide.point(SIMD2<Float>(corner - SIMD2(repeating: 0.5)))
                let projected = canvas.viewPoint(for: position)
                XCTAssertEqual(projected.x, overlay.viewport(corner).x, accuracy: 0.01)
                XCTAssertEqual(projected.y, overlay.viewport(corner).y, accuracy: 0.01)
            }
            XCTAssertFalse(canvas.surface.showsTransformHandles)
        }
        doc.leaveMusicNotesPathEditing(restoreTransform: true)
        canvas.update(doc, zoom: nil)
        XCTAssertTrue(canvas.surface.showsTransformHandles)
        XCTAssertNil(canvas.surface.pathGuideTransform)
    }

    func testPreviewDraftUndoEscapeAndSaveReopen() async throws {
        let id = doc.identity.layers[0].id
        let baseline = doc.state.workingModel
        let original = try XCTUnwrap(doc.musicNotesLayer(id)?.path)
        let renderer = doc.previewResources.musicNotes
        doc.beginMusicNotesPathEditing(id)
        XCTAssertTrue(doc.beginMusicNotesPathGesture(.outgoing(0)))
        doc.dragMusicNotesPath(by: SIMD2(0.06, -0.07))
        XCTAssertEqual(
            doc.musicNotesPathGesture?.draft.anchors[0].outgoing,
            original.anchors[0].outgoing + SIMD2(0.06, -0.07))
        for _ in 0..<80 where doc.state.workingModel == baseline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await doc.waitForPreview()
        XCTAssertNotEqual(doc.state.workingModel, baseline)
        XCTAssertNotNil(doc.musicNotesPathGesture)
        XCTAssertTrue(doc.previewResources.musicNotes === renderer)
        XCTAssertTrue(doc.previewIsCurrent)
        XCTAssertTrue(doc.cancelTransformInteraction())
        XCTAssertEqual(doc.state.workingModel, baseline)
        XCTAssertNil(doc.musicNotesPathGesture)
        XCTAssertFalse(doc.undoManager.canUndo)

        XCTAssertTrue(doc.beginMusicNotesPathGesture(.anchor(0)))
        doc.dragMusicNotesPath(by: original.anchors[1].position - original.anchors[0].position)
        doc.finishMusicNotesPathGesture()
        XCTAssertEqual(doc.state.workingModel, baseline)
        XCTAssertFalse(doc.undoManager.canUndo)

        XCTAssertTrue(doc.beginMusicNotesPathGesture(.anchor(0)))
        doc.dragMusicNotesPath(by: SIMD2(0.04, 0.03))
        XCTAssertTrue(doc.canSave)
        let expected = try XCTUnwrap(doc.musicNotesPathGesture?.draft)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertNil(doc.musicNotesPathGesture)
        XCTAssertEqual(doc.musicNotesLayer(id)?.path, expected)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, doc.state.workingModel)
        XCTAssertTrue(doc.undoManager.canUndo)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, baseline)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.path, expected)
    }

    func testPathCommandsResetTypeAndBounds() throws {
        let id = doc.identity.layers[0].id
        let original = try XCTUnwrap(doc.musicNotesLayer(id)?.path)
        try doc.setMusicNotesPathEnabled(false, layer: id)
        XCTAssertEqual(doc.musicNotesLayer(id)?.path?.anchors, original.anchors)
        try doc.setMusicNotesPathEnabled(true, layer: id)
        XCTAssertEqual(doc.musicNotesLayer(id)?.path, original)
        try doc.changeMusicNotes(id, name: "Color and count") { $0.count = 8 }
        doc.beginMusicNotesPathEditing(id)
        try doc.resetMusicNotes(id)
        XCTAssertEqual(doc.musicNotesLayer(id)?.notes, .init())
        XCTAssertEqual(doc.musicNotesLayer(id)?.path?.anchors, original.anchors)
        XCTAssertEqual(doc.musicNotesLayer(id)?.path?.enabled, false)
        XCTAssertNil(doc.musicNotesPathEditLayer)
        XCTAssertEqual(doc.transformModeLayer, id)
        doc.undoManager.undo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.path, original)
        try doc.changeMusicNotesPath(id, name: "Delete") { $0 = nil }
        XCTAssertNil(doc.musicNotesLayer(id)?.path)
        doc.undoManager.undo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.path, original)
        try doc.changeMusicNotesPath(id, name: "Delete") { $0 = nil }
        try doc.setMusicNotesPathEnabled(true, layer: id)
        let created = try XCTUnwrap(doc.musicNotesLayer(id)?.path)
        XCTAssertEqual(created, .editorDefault)
        let region = try XCTUnwrap(doc.musicNotesLayer(id)).region
        try doc.changeMusicNotesPath(id, name: "Close") { try $0?.setClosed(true, in: region) }
        XCTAssertEqual(doc.musicNotesLayer(id)?.path?.closed, true)
        doc.undoManager.undo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.path, created)
        doc.undoManager.redo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.path?.closed, true)

        doc.beginMusicNotesPathEditing(id)
        doc.musicNotesPathAnchor = 0
        try doc.removeMusicNotesPathAnchor()
        XCTAssertEqual(doc.musicNotesLayer(id)?.path?.anchors.count, 3)
        var full = created
        while full.anchors.count < WSSMusicNotesPath.maximumAnchors {
            try full.insertAnchor(in: full.segmentCount - 1, at: 0.5)
        }
        XCTAssertThrowsError(try full.insertAnchor(in: 0, at: 0.5))
    }

    func testShortFadeHintDoesNotChangeSpeed() throws {
        let id = doc.identity.layers[0].id
        var layer = try XCTUnwrap(doc.musicNotesLayer(id))
        let p = SIMD2<Double>(0.50, 0.50)
        let q = SIMD2<Double>(0.51, 0.50)
        layer.path?.anchors = [
            .init(position: p, incoming: p, outgoing: p),
            .init(position: q, incoming: q, outgoing: q),
        ]
        layer.notes.speed = 256
        XCTAssertTrue(layer.hasShortOpenPathFade)
        XCTAssertEqual(layer.notes.speed, 256)
        layer.path?.enabled = false
        XCTAssertFalse(layer.hasShortOpenPathFade)
        layer.path?.enabled = true
        layer.notes.speed = 0
        XCTAssertFalse(layer.hasShortOpenPathFade)
    }

    func testSplitPreservesBothSegmentsAndSupportsClosingTwoAnchors() throws {
        var path = try XCTUnwrap(doc.musicNotesLayer(doc.identity.layers[0].id)?.path)
        let before = path.editorSegment(0)
        let split = 0.37
        XCTAssertEqual(try path.insertAnchor(in: 0, at: split), 1)
        for i in 0...100 {
            let t = Double(i) / 100
            let after =
                t <= split
                ? path.editorSegment(0).point(at: t / split)
                : path.editorSegment(1).point(at: (t - split) / (1 - split))
            XCTAssertLessThan(simd_distance(before.point(at: t), after), 1e-12)
        }
        var original = try XCTUnwrap(doc.musicNotesLayer(doc.identity.layers[0].id)?.path)
        XCTAssertFalse(original.canRemoveAnchor)
        let region = try XCTUnwrap(doc.musicNotesLayer(doc.identity.layers[0].id)).region
        try original.setClosed(true, in: region)
        XCTAssertTrue(original.closed)
        XCTAssertEqual(original.anchors.count, 3)
        XCTAssertFalse(original.canRemoveAnchor)
        _ = try original.prepare(
            in: XCTUnwrap(doc.musicNotesLayer(doc.identity.layers[0].id)).region)
    }
}
