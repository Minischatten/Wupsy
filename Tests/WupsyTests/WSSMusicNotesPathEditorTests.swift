import AppKit
import SwiftUI
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

    func testMusicNotesFrameEdgeAndCornerDragsWithZoomAndUndo() throws {
        let id = doc.identity.layers[0].id
        try doc.changeMusicNotesStaff(id, name: "Staff") { $0.enabled = true }
        let windowController = WSSEditorWindowController(document: doc, onClose: {})
        defer { windowController.close() }
        windowController.showWindow(nil)
        let window = try XCTUnwrap(windowController.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let canvas = try XCTUnwrap(findCanvas(in: content))
        let original = try XCTUnwrap(doc.musicNotesLayer(id))

        func event(_ type: NSEvent.EventType, _ location: CGPoint) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: canvas.surface.convert(location, to: nil),
                    modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
        }

        for (index, scale) in WupsyInterfaceScale.allCases.enumerated() {
            canvas.surface.interfaceMetrics = WupsyMetrics(scale: scale)
            canvas.update(doc, zoom: CGFloat(index + 1))
            canvas.contentView.scroll(to: CGPoint(x: 35, y: 25))
            canvas.reflectScrolledClipView(canvas.contentView)
            let native = try original.canvasTransform.native()
            let top = canvas.viewPoint(for: native.point(SIMD2(0, 0.5)))
            let right = canvas.viewPoint(for: native.point(SIMD2(0.5, 0)))
            let corner = canvas.viewPoint(for: native.point(SIMD2(0.5, 0.5)))
            XCTAssertEqual(canvas.canvasHit(at: top), .edge(id, 2))
            XCTAssertEqual(canvas.canvasHit(at: right), .edge(id, 1))
            XCTAssertEqual(canvas.canvasHit(at: corner), .corner(id, 2))
            let start = [top, right, corner][index]
            let target = CGPoint(x: start.x - 47, y: start.y + 52)
            canvas.beginInteraction(try event(.leftMouseDown, start))
            canvas.dragInteraction(try event(.leftMouseDragged, target))
            let updated = try XCTUnwrap(doc.musicNotesLayer(id))
            if index == 0 {
                XCTAssertEqual(updated.region.width, original.region.width)
            } else {
                XCTAssertLessThan(updated.region.width, original.region.width)
            }
            if index == 1 {
                XCTAssertEqual(updated.region.height, original.region.height)
            } else {
                XCTAssertLessThan(updated.region.height, original.region.height)
            }
            XCTAssertEqual(updated.region.x, original.region.x, accuracy: 0.001)
            XCTAssertEqual(updated.region.y, original.region.y, accuracy: 0.001)
            XCTAssertEqual(updated.path, original.path)
            XCTAssertNotEqual(try updated.preparedStaff(), try original.preparedStaff())
            canvas.endInteraction(try event(.leftMouseUp, target))
            doc.undoManager.undo()
            XCTAssertEqual(doc.musicNotesLayer(id), original)
            doc.undoManager.redo()
            XCTAssertEqual(doc.musicNotesLayer(id), updated)
            doc.undoManager.undo()
        }
    }

    func testIndependentRegionResizingKeepsOpenClosedAndLinearGeometryUsable() throws {
        for (index, width, height) in [(0, Float(600), Float(24)), (1, 24, 300)] {
            let id = doc.identity.layers[index].id
            try doc.changeMusicNotesStaff(id, name: "Staff") { $0.enabled = true }
            let original = try XCTUnwrap(doc.musicNotesLayer(id))
            XCTAssertTrue(doc.beginCanvasTransform(id, kind: .scale(2, independent: true)))
            let size = WSSSceneDocumentV1.Transform(center: [300, 180], size: [width, height])
            try doc.updateCanvasTransform(size)
            doc.endCanvasTransform()
            let resized = try XCTUnwrap(doc.musicNotesLayer(id))
            XCTAssertEqual(resized.path, original.path)
            XCTAssertEqual(resized.staff?.spacing, original.staff?.spacing)
            XCTAssertEqual(try resized.preparedStaff()?.closed, original.path?.closed)
            XCTAssertNotEqual(
                try resized.path?.prepare(in: resized.region),
                try original.path?.prepare(in: original.region))
            XCTAssertEqual(resized.notes, original.notes)
            try doc.setMusicNotesPathEnabled(false, layer: id)
            XCTAssertTrue(doc.beginCanvasTransform(id, kind: .move))
            let moved = WSSSceneDocumentV1.Transform(center: [310, 185], size: [width, height])
            try doc.updateCanvasTransform(moved)
            doc.endCanvasTransform()
            let linear = try XCTUnwrap(doc.musicNotesLayer(id))
            XCTAssertEqual(linear.region.width, width)
            XCTAssertEqual(linear.region.height, height)
            XCTAssertEqual(linear.region.x, resized.region.x + 10)
            XCTAssertEqual(linear.region.y, resized.region.y + 5)
            XCTAssertEqual(try linear.preparedStaff()?.vertices.count, 30)
            XCTAssertTrue(linear.isAnimated)
        }
    }

    func testSizeAndMotionFieldsAtEveryInterfaceScale() async throws {
        let id = doc.identity.layers[0].id
        try doc.changeMusicNotesPlacement(id, name: "Perspective") {
            var perspective = WSSMusicNotesPerspective()
            perspective.enabled = true
            $0.perspective = perspective
        }
        let suite = "WupsyMusicNotesSizeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = WupsyAppearance(defaults: defaults)
        let host = WupsyPanelHostingView(
            appearance: appearance,
            root: WSSMusicNotesParameterControls(document: doc, layer: id).wupsyControlFrame(
                width: 290))
        let panel = NSPanel(
            contentRect: NSRect(x: 40, y: 40, width: 290, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderFront(nil)
        defer { panel.close() }
        host.layoutSubtreeIfNeeded()

        func field(in view: NSView, matching title: String) -> NSTextField? {
            if let field = view as? NSTextField,
                let label = field.accessibilityLabel(),
                label == title || label.hasPrefix(title + " (")
            {
                return field
            }
            return view.subviews.lazy.compactMap { field(in: $0, matching: title) }.first
        }
        let motion = try XCTUnwrap(
            field(in: host, matching: WSSMusicNotesText.text("hoverFrequency")))
        let perspective = try XCTUnwrap(
            field(in: host, matching: WSSMusicNotesText.text("perspectiveEnd")))
        let field = try XCTUnwrap(field(in: host, matching: WSSMusicNotesText.text("size")))
        let coordinator = try XCTUnwrap(field.delegate as? WSSParameterTextField.Coordinator)
        for (scale, size) in zip(WupsyInterfaceScale.allCases, [256, 384, 512]) {
            appearance.scale = scale
            let expected = NSFont.systemFontSize * scale.factor
            for _ in 0..<50 where field.font?.pointSize != expected {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(field.font?.pointSize, expected)
            XCTAssertEqual(motion.font?.pointSize, expected)
            XCTAssertEqual(perspective.font?.pointSize, expected)
            field.stringValue = String(size)
            XCTAssertTrue(coordinator.accept(field))
            XCTAssertEqual(doc.musicNotesLayer(id)?.notes.size, Float(size))
        }
        field.stringValue = "513"
        XCTAssertFalse(coordinator.accept(field))
        XCTAssertEqual(doc.musicNotesLayer(id)?.notes.size, 512)
        doc.undoManager.undo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.notes.size, 384)
        doc.undoManager.redo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.notes.size, 512)
        let motionCoordinator = try XCTUnwrap(motion.delegate as? WSSParameterTextField.Coordinator)
        motion.stringValue = "0,375"
        XCTAssertTrue(motionCoordinator.accept(motion))
        XCTAssertEqual(doc.musicNotesLayer(id)?.notes.hoverFrequency, 0.375)
        let perspectiveCoordinator = try XCTUnwrap(
            perspective.delegate as? WSSParameterTextField.Coordinator)
        perspective.stringValue = "42,5"
        XCTAssertTrue(perspectiveCoordinator.accept(perspective))
        XCTAssertEqual(doc.musicNotesLayer(id)?.perspective?.end, 42.5)
        perspective.stringValue = "201"
        XCTAssertFalse(perspectiveCoordinator.accept(perspective))
        XCTAssertEqual(doc.musicNotesLayer(id)?.perspective?.end, 42.5)
    }

    func testFreeSymbolDragUndoAndPlacementSwitchPreservesSettings() throws {
        let id = doc.identity.layers[0].id
        let baseline = try XCTUnwrap(doc.musicNotesLayer(id))
        try doc.changeMusicNotesStaff(id, name: "Staff") { $0.enabled = true }
        try doc.changeMusicNotesPlacement(id, name: "Free") {
            $0.placement = .freeSingle
            var free = WSSMusicNotesLayer.SingleSymbol()
            free.symbol = .trebleClef
            free.size = 95
            $0.freeSymbol = free
            $0.freePosition = SIMD2(170, 140)
            var attached = WSSMusicNotesLayer.SingleSymbol()
            attached.symbol = .eighth
            $0.anchoredSymbol = attached
            $0.anchorPosition = 72
        }
        let controller = WSSEditorWindowController(document: doc, onClose: {})
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let canvas = try XCTUnwrap(findCanvas(in: content))
        for (index, scale) in WupsyInterfaceScale.allCases.enumerated() {
            canvas.surface.interfaceMetrics = WupsyMetrics(scale: scale)
            canvas.update(doc, zoom: CGFloat(index + 1))
            canvas.contentView.scroll(to: CGPoint(x: 25, y: 30))
            let start = canvas.viewPoint(for: SIMD2(170, 140))
            let end = canvas.viewPoint(for: SIMD2(190, 160))
            XCTAssertEqual(canvas.canvasHit(at: start), .image(id))
            XCTAssertFalse(canvas.surface.musicNotesPathOverlay.showsStaff)
            func event(_ type: NSEvent.EventType, _ at: CGPoint) throws -> NSEvent {
                try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: type, location: canvas.surface.convert(at, to: nil),
                        modifierFlags: [],
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 1))
            }
            canvas.beginInteraction(try event(.leftMouseDown, start))
            canvas.dragInteraction(try event(.leftMouseDragged, end))
            let moved = try XCTUnwrap(doc.musicNotesLayer(id))
            XCTAssertEqual(moved.singleCenter.x, 190, accuracy: 0.001)
            XCTAssertEqual(moved.singleCenter.y, 160, accuracy: 0.001)
            XCTAssertEqual(moved.region, baseline.region)
            XCTAssertEqual(moved.path, baseline.path)
            canvas.endInteraction(try event(.leftMouseUp, end))
            doc.undoManager.undo()
            XCTAssertEqual(doc.musicNotesLayer(id)?.freePosition, SIMD2(170, 140))
            doc.undoManager.redo()
            XCTAssertEqual(doc.musicNotesLayer(id), moved)
            doc.undoManager.undo()
        }
        try doc.changeMusicNotesPlacement(id, name: "Attached") { $0.placement = .anchoredSingle }
        let attached = try XCTUnwrap(doc.musicNotesLayer(id))
        XCTAssertEqual(attached.singleSymbol?.symbol, .eighth)
        XCTAssertEqual(attached.anchorPosition, 72)
        XCTAssertEqual(attached.freeSymbol?.symbol, .trebleClef)
        XCTAssertEqual(attached.staff?.enabled, true)
        XCTAssertFalse(attached.drawsStaff)
        try doc.changeMusicNotesPlacement(id, name: "Animated") { $0.placement = nil }
        XCTAssertEqual(doc.musicNotesLayer(id)?.drawsStaff, true)
        XCTAssertEqual(doc.musicNotesLayer(id)?.notes, baseline.notes)
        try doc.resetMusicNotes(id)
        XCTAssertNil(doc.musicNotesLayer(id)?.freeSymbol)
        XCTAssertNil(doc.musicNotesLayer(id)?.anchoredSymbol)
    }

    func testSpinInspectorScaleUndoAndModeRetention() async throws {
        let id = doc.identity.layers[0].id
        try doc.changeMusicNotesPlacement(id, name: "Free") {
            $0.placement = .freeSingle
            var symbol = WSSMusicNotesLayer.SingleSymbol()
            symbol.rotationMode = .continuous
            $0.freeSymbol = symbol
        }
        let suite = "WupsyMusicNotesSpinTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = WupsyAppearance(defaults: defaults)
        let host = WupsyPanelHostingView(
            appearance: appearance,
            root: WSSMusicNotesParameterControls(document: doc, layer: id).wupsyControlFrame(
                width: 290))
        let panel = NSPanel(
            contentRect: NSRect(x: 40, y: 40, width: 290, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderFront(nil)
        defer { panel.close() }
        host.layoutSubtreeIfNeeded()

        func periodField(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField,
                field.accessibilityLabel() == WSSMusicNotesText.text("spinPeriod")
            {
                return field
            }
            return view.subviews.lazy.compactMap(periodField).first
        }
        let field = try XCTUnwrap(periodField(host))
        let coordinator = try XCTUnwrap(field.delegate as? WSSParameterTextField.Coordinator)
        for (scale, period) in zip(WupsyInterfaceScale.allCases, [5, 120, 300]) {
            appearance.scale = scale
            let expected = NSFont.systemFontSize * scale.factor
            for _ in 0..<50 where field.font?.pointSize != expected {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(field.font?.pointSize, expected)
            field.stringValue = String(period)
            XCTAssertTrue(coordinator.accept(field))
            XCTAssertEqual(doc.musicNotesLayer(id)?.freeSymbol?.spinPeriod, Double(period))
        }
        field.stringValue = "301"
        XCTAssertFalse(coordinator.accept(field))
        doc.undoManager.undo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.freeSymbol?.spinPeriod, 120)
        doc.undoManager.redo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.freeSymbol?.spinPeriod, 300)
        try doc.changeMusicNotesPlacement(id, name: "Direction") {
            $0.freeSymbol?.spinDirection = .counterclockwise
        }
        doc.undoManager.undo()
        XCTAssertNil(doc.musicNotesLayer(id)?.freeSymbol?.spinDirection)
        doc.undoManager.redo()
        try doc.changeMusicNotesPlacement(id, name: "Rocking") {
            $0.freeSymbol?.rotationMode = .rocking
        }
        XCTAssertEqual(doc.musicNotesLayer(id)?.freeSymbol?.spinPeriod, 300)
        XCTAssertEqual(doc.musicNotesLayer(id)?.freeSymbol?.spinDirection, .counterclockwise)
        doc.undoManager.undo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.freeSymbol?.rotationMode, .continuous)
        doc.undoManager.redo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.freeSymbol?.rotationMode, .rocking)
        try doc.changeMusicNotesPlacement(id, name: "Axis") { $0.freeSymbol?.spinAxis = .vertical }
        XCTAssertEqual(doc.musicNotesLayer(id)?.freeSymbol?.spinAxis, .vertical)
        XCTAssertEqual(doc.musicNotesLayer(id)?.freeSymbol?.spinPeriod, 300)
        XCTAssertEqual(doc.musicNotesLayer(id)?.freeSymbol?.spinDirection, .counterclockwise)
        doc.undoManager.undo()
        XCTAssertNil(doc.musicNotesLayer(id)?.freeSymbol?.spinAxis)
        doc.undoManager.redo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.freeSymbol?.spinAxis, .vertical)
        try doc.resetMusicNotes(id)
        XCTAssertNil(doc.musicNotesLayer(id)?.freeSymbol)
        for (key, text) in [
            ("rotation", "Sanftes Schaukeln"), ("rotationStrength", "Schaukelstärke"),
            ("rotationFrequency", "Schaukelgeschwindigkeit"),
        ] {
            XCTAssertEqual(
                Localization.string(key: "editor.musicNotes." + key, language: "de"), text)
        }
    }

    func testTrebleClefSelectionUndoAndKeepsStaffGeometry() throws {
        let id = doc.identity.layers[0].id
        try doc.changeMusicNotesStaff(id, name: "Staff") { $0.enabled = true }
        let original = try XCTUnwrap(doc.musicNotesLayer(id))
        try doc.setMusicNoteSymbol(.trebleClef, enabled: true, layer: id)
        let updated = try XCTUnwrap(doc.musicNotesLayer(id))
        XCTAssertEqual(updated.notes.symbols, [.quarter, .eighth, .double, .trebleClef])
        XCTAssertEqual(try updated.preparedStaff(), try original.preparedStaff())
        doc.undoManager.undo()
        XCTAssertEqual(doc.musicNotesLayer(id), original)
        doc.undoManager.redo()
        XCTAssertEqual(doc.musicNotesLayer(id), updated)
        XCTAssertEqual(
            Localization.string(key: "editor.musicNotes.trebleClef", language: "de"),
            "Violinschlüssel")
        XCTAssertEqual(
            Localization.string(key: "editor.musicNotes.trebleClef", language: "en"),
            "Treble clef")
    }

    func testGentleMotionSliderUndoAndReset() async throws {
        let id = doc.identity.layers[0].id
        let original = try XCTUnwrap(doc.musicNotesLayer(id))
        XCTAssertTrue(doc.beginMusicNotesMotion(.hoverStrength, layer: id))
        try doc.setMusicNotesMotion(.hoverStrength, value: 8, layer: id)
        try doc.setMusicNotesMotion(.hoverStrength, value: 5, layer: id)
        await doc.waitForPreview()
        guard case .musicNotes(let live) = doc.previewResources.scene.layers[0] else {
            return XCTFail("Missing preview layer")
        }
        XCTAssertEqual(live.notes.hoverStrength, 5)
        doc.endMusicNotesMotion()
        doc.undoManager.undo()
        XCTAssertEqual(doc.musicNotesLayer(id), original)
        doc.undoManager.redo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.notes.hoverStrength, 5)
        try doc.setMusicNotesMotion(.rotationFrequency, value: 0.5, layer: id)
        doc.undoManager.undo()
        XCTAssertNil(doc.musicNotesLayer(id)?.notes.rotationFrequency)
        XCTAssertEqual(doc.musicNotesLayer(id)?.notes.hoverStrength, 5)
        XCTAssertThrowsError(try doc.setMusicNotesMotion(.hoverFrequency, value: 2, layer: id))
        try doc.resetMusicNotes(id)
        XCTAssertEqual(doc.musicNotesLayer(id)?.notes, .init())
        XCTAssertEqual(doc.musicNotesLayer(id)?.region, original.region)
    }

    func testStaffSettingsValidationUndoAndSave() async throws {
        let id = doc.identity.layers[0].id
        let baseline = try XCTUnwrap(doc.musicNotesLayer(id))
        XCTAssertNil(baseline.staff)
        try doc.changeMusicNotesStaff(id, name: "Staff") { $0.enabled = true }
        var expected = WSSMusicNotesStaff()
        expected.enabled = true
        XCTAssertEqual(doc.musicNotesLayer(id)?.staff, expected)
        XCTAssertThrowsError(
            try doc.changeMusicNotesStaff(id, name: "Width") { $0.width = 12 }
        ) { XCTAssertTrue($0 is WSSMusicNotesStaffInputError) }
        XCTAssertThrowsError(try doc.changeMusicNotesStaff(id, name: "Spacing") { $0.spacing = 1 })
        XCTAssertThrowsError(try doc.changeMusicNotesStaff(id, name: "Width") { $0.width = .nan })
        XCTAssertEqual(doc.musicNotesLayer(id)?.staff, expected)

        try doc.changeMusicNotesStaff(id, name: "Staff settings") {
            $0.spacing = 17
            $0.width = 3
        }
        try doc.changeMusicNotesStaff(id, name: "Color") { $0.color.red = 0.3 }
        doc.undoManager.undo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.staff?.color.red, 1)
        doc.undoManager.redo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.staff?.color.red, 0.3)
        let styled = try XCTUnwrap(doc.musicNotesLayer(id)?.staff)
        XCTAssertTrue(doc.beginMusicNotesStaffOpacity(id))
        try doc.setMusicNotesStaffOpacity(id, value: 0.32)
        await doc.waitForPreview()
        guard case .musicNotes(let live) = doc.previewResources.scene.layers[0] else {
            return XCTFail("Missing preview layer")
        }
        XCTAssertEqual(live.staff?.opacity, 0.32)
        XCTAssertEqual(live.notes, baseline.notes)
        try doc.setMusicNotesStaffOpacity(id, value: 0.7)
        doc.endMusicNotesStaffOpacity()
        doc.undoManager.undo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.staff, styled)
        doc.undoManager.redo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.staff?.opacity, 0.7)

        try doc.changeMusicNotesStaff(id, name: "Toggle") { $0.enabled = false }
        let disabled = try XCTUnwrap(doc.musicNotesLayer(id)?.staff)
        XCTAssertEqual(disabled.spacing, styled.spacing)
        XCTAssertEqual(disabled.width, styled.width)
        XCTAssertEqual(disabled.color, styled.color)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, doc.state.workingModel)
        doc.undoManager.undo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.staff?.enabled, true)
        doc.undoManager.redo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.staff, disabled)
        try doc.changeMusicNotesStaff(id, name: "Toggle") { $0.enabled = true }
        XCTAssertEqual(doc.musicNotesLayer(id)?.staff?.opacity, disabled.opacity)

        try doc.resetMusicNotes(id)
        let reset = try XCTUnwrap(doc.musicNotesLayer(id))
        XCTAssertNil(reset.staff)
        XCTAssertEqual(reset.region, baseline.region)
        var inactivePath = baseline.path
        inactivePath?.enabled = false
        XCTAssertEqual(reset.path, inactivePath)
        doc.undoManager.undo()
        XCTAssertEqual(doc.musicNotesLayer(id)?.staff?.enabled, true)
        XCTAssertEqual(doc.musicNotesLayer(id)?.path, baseline.path)
    }

    func testStaffNumericFieldUsesLiveInterfaceScaleAndShowsValidationError() async throws {
        let id = doc.identity.layers[0].id
        try doc.changeMusicNotesStaff(id, name: "Staff") { $0.enabled = true }
        let value = try XCTUnwrap(doc.musicNotesLayer(id))
        let suite = "WupsyStaffScaleTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = WupsyAppearance(defaults: defaults)
        let host = WupsyPanelHostingView(
            appearance: appearance,
            root: WSSMusicNotesStaffControls(document: doc, layer: id, value: value)
                .wupsyControlFrame(width: 290))
        let panel = NSPanel(
            contentRect: NSRect(x: 40, y: 40, width: 290, height: 330),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderFront(nil)
        defer { panel.close() }
        host.layoutSubtreeIfNeeded()

        func widthField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField,
                field.accessibilityLabel()?.hasPrefix(WSSMusicNotesText.text("staffWidth") + " (")
                    == true
            {
                return field
            }
            for child in view.subviews {
                if let field = widthField(in: child) { return field }
            }
            return nil
        }

        let field = try XCTUnwrap(widthField(in: host))
        let coordinator = try XCTUnwrap(field.delegate as? WSSParameterTextField.Coordinator)
        for scale in WupsyInterfaceScale.allCases {
            appearance.scale = scale
            let expected = NSFont.systemFontSize * scale.factor
            for _ in 0..<50 where field.font?.pointSize != expected {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(field.font?.pointSize, expected)
        }
        field.stringValue = "12"
        XCTAssertFalse(coordinator.accept(field))
        XCTAssertEqual(coordinator.hint?.isHidden, false)
        XCTAssertTrue(
            coordinator.hint?.stringValue.contains(
                WSSMusicNotesText.text("staffWidthLessThanSpacing"))
                == true)
        XCTAssertEqual(doc.musicNotesLayer(id)?.staff?.width, value.staff?.width)
    }

    func testStaffOverlaySelectionDraftAndViewportAtEveryInterfaceScale() throws {
        let first = doc.identity.layers[0].id
        let second = doc.identity.layers[1].id
        let canvas = WSSCanvasScrollView(document: doc)
        defer { canvas.shutdown() }
        let surface = canvas.surface
        let overlay = surface.musicNotesPathOverlay
        XCTAssertFalse(overlay.showsStaff)
        try doc.changeMusicNotesStaff(first, name: "Staff") { $0.enabled = true }
        surface.update(doc)
        XCTAssertTrue(overlay.showsStaff)
        XCTAssertTrue(surface.showsMusicNotesPath)
        XCTAssertTrue(surface.showsTransformHandles)

        for (index, scale) in WupsyInterfaceScale.allCases.enumerated() {
            surface.interfaceMetrics = WupsyMetrics(scale: scale)
            let zoom = CGFloat(index + 1)
            surface.configure(
                size: CGSize(width: 2000, height: 1200),
                imageSize: CGSize(width: 640 * zoom, height: 360 * zoom))
            let layer = try XCTUnwrap(doc.musicNotesLayer(first))
            let start = try XCTUnwrap(layer.path?.anchors.first)
            let origin = try XCTUnwrap(overlay.staffViewportOrigin)
            XCTAssertEqual(origin.x, overlay.viewport(start.position).x, accuracy: 0.01)
            XCTAssertEqual(origin.y, overlay.viewport(start.position).y, accuracy: 0.01)
            XCTAssertEqual(
                origin.x, overlay.imageOrigin.x + CGFloat(layer.region.x) * zoom, accuracy: 0.01)
            XCTAssertNil(overlay.hitTest(origin))
            XCTAssertNil(overlay.handle(at: origin))
            overlay.imageOrigin.x += 20
            overlay.imageOrigin.y -= 10
            let panned = try XCTUnwrap(overlay.staffViewportOrigin)
            XCTAssertEqual(panned.x, origin.x + 20, accuracy: 0.01)
            XCTAssertEqual(panned.y, origin.y - 10, accuracy: 0.01)
        }

        doc.beginMusicNotesPathEditing(first)
        surface.update(doc)
        XCTAssertFalse(surface.showsTransformHandles)
        let origin = try XCTUnwrap(overlay.staffViewportOrigin)
        XCTAssertEqual(overlay.handle(at: origin), .anchor(0))
        XCTAssertTrue(doc.beginMusicNotesPathGesture(.anchor(0)))
        doc.dragMusicNotesPath(by: SIMD2(0.06, 0.04))
        surface.updateMusicNotesPath(doc)
        XCTAssertNotEqual(overlay.staffViewportOrigin, origin)
        doc.finishMusicNotesPathGesture(cancel: true)
        surface.updateMusicNotesPath(doc)
        XCTAssertEqual(overlay.staffViewportOrigin, origin)
        doc.leaveMusicNotesPathEditing(restoreTransform: true)
        surface.update(doc)
        XCTAssertTrue(surface.showsTransformHandles)

        doc.select(.layer(second))
        surface.update(doc)
        XCTAssertFalse(overlay.showsStaff)
        doc.select(.layer(first))
        try doc.setMusicNotesPathEnabled(false, layer: first)
        surface.update(doc)
        XCTAssertTrue(overlay.showsStaff)
        XCTAssertFalse(surface.showsMusicNotesPath)
        try doc.changeMusicNotesStaff(first, name: "Staff") { $0.enabled = false }
        surface.update(doc)
        XCTAssertFalse(overlay.showsStaff)
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

    func testSmoothAnchorIsExplicitUndoableAndReopensWithUpdatedPreview() async throws {
        let id = doc.identity.layers[0].id
        let loadedModel = loaded.document
        XCTAssertEqual(doc.state.workingModel, loadedModel)
        XCTAssertFalse(doc.canSmoothMusicNotesPathAnchor(on: id))
        let image = try await WSSEditorImageEditingTests().generation()
        try await doc.installImage(image)
        let target = try XCTUnwrap(doc.selection?.layer)
        try doc.setMusicNotesDepthTarget(target, for: id)
        try doc.changeMusicNotesPlacement(id, name: "Perspective and depth") {
            var perspective = WSSMusicNotesPerspective()
            perspective.enabled = true
            perspective.start = 35
            $0.perspective = perspective
            $0.depth?.changes = [.init(position: 40, side: .behind)]
            $0.depth?.includesStaff = true
            var staff = WSSMusicNotesStaff()
            staff.enabled = true
            $0.staff = staff
        }
        let original = try XCTUnwrap(doc.musicNotesLayer(id)?.path)
        doc.select(.layer(id))
        doc.beginMusicNotesPathEditing(id)
        XCTAssertFalse(doc.canSmoothMusicNotesPathAnchor(on: id))
        XCTAssertTrue(doc.beginMusicNotesPathGesture(.outgoing(0)))
        doc.dragMusicNotesPath(by: SIMD2(0, -0.07))
        doc.finishMusicNotesPathGesture()
        let dragged = try XCTUnwrap(doc.musicNotesLayer(id))
        let draggedPath = try XCTUnwrap(dragged.path)
        XCTAssertEqual(
            draggedPath.anchors[0].outgoing, original.anchors[0].outgoing + SIMD2(0, -0.07))
        XCTAssertEqual(draggedPath.anchors[0].incoming, original.anchors[0].incoming)
        doc.undoManager.removeAllActions()
        await doc.waitForPreview()
        let previewBefore = try fixtures.frame(doc.previewResources, time: 0, width: 320)
        doc.musicNotesPathAnchor = -1
        XCTAssertFalse(doc.canSmoothMusicNotesPathAnchor(on: id))
        try doc.smoothMusicNotesPathAnchor(on: id)
        doc.musicNotesPathAnchor = 0
        doc.interactionLocked = true
        XCTAssertFalse(doc.canSmoothMusicNotesPathAnchor(on: id))
        try doc.smoothMusicNotesPathAnchor(on: id)
        doc.interactionLocked = false
        XCTAssertFalse(doc.undoManager.canUndo)

        XCTAssertTrue(doc.canSmoothMusicNotesPathAnchor(on: id))
        try doc.smoothMusicNotesPathAnchor(on: id)
        let smoothed = try XCTUnwrap(doc.musicNotesLayer(id))
        XCTAssertNotEqual(smoothed.path, draggedPath)
        XCTAssertEqual(smoothed.perspective, dragged.perspective)
        XCTAssertEqual(smoothed.depth, dragged.depth)
        XCTAssertEqual(smoothed.staff, dragged.staff)
        XCTAssertEqual(smoothed.path?.direction, draggedPath.direction)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        XCTAssertEqual(WSSMusicNotesDepth.plan(for: doc.previewResources.scene), [2: [0]])
        XCTAssertTrue(doc.previewResources.musicNotesStaffs.keys.contains(0))
        XCTAssertNotEqual(
            try fixtures.frame(doc.previewResources, time: 0, width: 320), previewBefore)
        try doc.smoothMusicNotesPathAnchor(on: id)
        doc.undoManager.undo()
        XCTAssertEqual(doc.musicNotesLayer(id), dragged)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        XCTAssertEqual(doc.musicNotesLayer(id), smoothed)

        let saved = await doc.save()
        XCTAssertTrue(saved)
        let reopened = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(reopened.document, doc.state.workingModel)
    }

    func testSmoothClosedTwoAnchorPathCreatesNoUndo() throws {
        let id = doc.identity.layers[0].id
        try doc.applyMusicNotesPathTemplate(.straightPath, layer: id)
        let region = try XCTUnwrap(doc.musicNotesLayer(id)?.region)
        try doc.changeMusicNotesPath(id, name: "Close path") {
            try $0?.setClosed(true, in: region)
        }
        let original = doc.state.workingModel
        doc.undoManager.removeAllActions()
        doc.beginMusicNotesPathEditing(id)
        doc.musicNotesPathAnchor = 0
        XCTAssertTrue(doc.canSmoothMusicNotesPathAnchor(on: id))
        try doc.smoothMusicNotesPathAnchor(on: id)
        XCTAssertEqual(doc.state.workingModel, original)
        XCTAssertFalse(doc.undoManager.canUndo)
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
        XCTAssertEqual(doc.musicNotesLayer(id)?.path?.anchors.count, 2)
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

    func testAnchorDragKeepsItsInitialMappingAcrossRelayoutAndUIScale() throws {
        let id = doc.identity.layers[0].id
        let controller = WSSEditorWindowController(document: doc, onClose: {})
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let canvas = try XCTUnwrap(findCanvas(in: content))
        doc.beginMusicNotesPathEditing(id)
        let original = try XCTUnwrap(doc.musicNotesLayer(id))

        func event(_ type: NSEvent.EventType, _ at: CGPoint) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: at, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1))
        }

        for (index, scale) in WupsyInterfaceScale.allCases.enumerated() {
            canvas.interfaceMetrics = WupsyMetrics(scale: scale)
            let zoom = CGFloat(index + 1)
            canvas.update(doc, zoom: zoom)
            canvas.contentView.scroll(to: CGPoint(x: 25, y: 30))
            let overlay = canvas.surface.musicNotesPathOverlay
            let anchor = try XCTUnwrap(original.path?.anchors.first)
            let position = canvas.surface.convert(point(overlay.viewport(anchor.position)), to: nil)
            canvas.beginInteraction(try event(.leftMouseDown, position))
            XCTAssertEqual(doc.musicNotesPathGesture?.handle, .anchor(0))
            // A fit/layout update changes the live overlay scale during the gesture.
            canvas.surface.configure(
                size: CGSize(width: 1580, height: 900), imageSize: CGSize(width: 622, height: 350))
            canvas.dragInteraction(try event(.leftMouseDragged, position))
            XCTAssertEqual(doc.musicNotesPathGesture?.draft, original.path)
            let end = CGPoint(x: position.x + 12, y: position.y + 8)
            canvas.dragInteraction(try event(.leftMouseDragged, end))
            let draft = try XCTUnwrap(doc.musicNotesPathGesture?.draft.anchors.first?.position)
            XCTAssertEqual(
                draft.x, anchor.position.x + 12 / (Double(zoom) * Double(original.region.width)),
                accuracy: 1e-8)
            XCTAssertEqual(
                draft.y, anchor.position.y + 8 / (Double(zoom) * Double(original.region.height)),
                accuracy: 1e-8)
            canvas.endInteraction(try event(.leftMouseUp, end))
            XCTAssertEqual(doc.musicNotesLayer(id)?.path?.anchors.first?.position, draft)
            doc.undoManager.undo()
            XCTAssertEqual(doc.musicNotesLayer(id), original)
        }
    }

    func testPerspectivePersistsThroughClosedPathAndUndo() throws {
        let id = doc.identity.layers[0].id
        let original = try XCTUnwrap(doc.musicNotesLayer(id))
        try doc.changeMusicNotesPlacement(id, name: "Perspective") {
            var perspective = WSSMusicNotesPerspective()
            perspective.enabled = true
            $0.perspective = perspective
        }
        let tapered = try XCTUnwrap(doc.musicNotesLayer(id))
        XCTAssertNotNil(tapered.activePerspective)
        XCTAssertEqual(tapered.path, original.path)
        XCTAssertEqual(tapered.region, original.region)
        try doc.changeMusicNotesPath(id, name: "Close") {
            try $0?.setClosed(true, in: original.region)
        }
        XCTAssertNil(doc.musicNotesLayer(id)?.activePerspective)
        XCTAssertEqual(doc.musicNotesLayer(id)?.perspective, tapered.perspective)
        let persisted = doc.state.workingModel
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: persisted.encoded()), persisted)
        try doc.changeMusicNotesPath(id, name: "Open") {
            try $0?.setClosed(false, in: original.region)
        }
        XCTAssertEqual(doc.musicNotesLayer(id), tapered)
        doc.undoManager.undo()
        XCTAssertNil(doc.musicNotesLayer(id)?.activePerspective)
        doc.undoManager.redo()
        XCTAssertEqual(doc.musicNotesLayer(id), tapered)
        try doc.resetMusicNotes(id)
        XCTAssertNil(doc.musicNotesLayer(id)?.perspective)
        doc.undoManager.undo()
        XCTAssertEqual(doc.musicNotesLayer(id), tapered)
    }

    func testPathTypeAndTemplatesSurvivePreviewTransferAndUndo() async throws {
        let id = doc.identity.layers[0].id
        try doc.changeMusicNotesPlacement(id, name: "Depth") {
            var depth = WSSMusicNotesDepth(target: UUID())
            depth.changes = [
                .init(position: 40, side: .behind), .init(position: 75, side: .inFront),
            ]
            $0.depth = depth
        }
        let original = try XCTUnwrap(doc.musicNotesLayer(id))
        let window = WSSEditorWindowController(document: doc, onClose: {})
        defer { window.close() }
        window.showWindow(nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(doc.musicNotesPathEditLayer)
        try doc.changeMusicNotesPath(id, name: "Closed") {
            try $0?.setClosed(true, in: original.region)
        }
        XCTAssertEqual(doc.musicNotesLayer(id)?.path?.closed, true)
        XCTAssertEqual(doc.musicNotesLayer(id)?.path?.anchors, original.path?.anchors)
        let togglePreview = try XCTUnwrap(doc.togglePreviewExpansion)
        togglePreview()
        XCTAssertTrue(doc.previewExpanded)
        togglePreview()
        XCTAssertFalse(doc.previewExpanded)
        XCTAssertEqual(doc.musicNotesLayer(id)?.path?.closed, true)

        doc.beginMusicNotesPathEditing(id)
        try doc.changeMusicNotesPath(id, name: "Open") {
            try $0?.setClosed(false, in: original.region)
        }
        XCTAssertEqual(doc.musicNotesLayer(id), original)
        try doc.applyMusicNotesPathTemplate(.ellipsePath, layer: id)
        let ellipse = try XCTUnwrap(doc.musicNotesLayer(id))
        XCTAssertEqual(ellipse.path?.anchors.count, 4)
        XCTAssertEqual(ellipse.path?.closed, true)
        XCTAssertEqual(ellipse.depth, original.depth)
        XCTAssertEqual(ellipse.notes, original.notes)
        XCTAssertEqual(ellipse.staff, original.staff)
        let persisted = doc.state.workingModel
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: persisted.encoded()), persisted)
        doc.undoManager.undo()
        XCTAssertEqual(doc.musicNotesLayer(id), original)
        doc.undoManager.redo()
        XCTAssertEqual(doc.musicNotesLayer(id), ellipse)
        try doc.applyMusicNotesPathTemplate(.straightPath, layer: id)
        XCTAssertEqual(doc.musicNotesLayer(id)?.path?.anchors.count, 2)
        XCTAssertEqual(doc.musicNotesLayer(id)?.path?.closed, false)
        XCTAssertEqual(doc.musicNotesLayer(id)?.depth, original.depth)
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
        XCTAssertEqual(original.anchors.count, 2)
        XCTAssertFalse(original.canRemoveAnchor)
        _ = try original.prepare(
            in: XCTUnwrap(doc.musicNotesLayer(doc.identity.layers[0].id)).region)
    }
}
