import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSMasklessHoverTests: XCTestCase {
    var helper: WSSMaskManagementTests!
    var doc: WSSEditorDocument { helper.doc }
    var mask: WSSMaskCanvasSession { doc.maskCanvas }
    override func setUp() async throws {
        _ = NSApplication.shared
        helper = WSSMaskManagementTests()
        try await helper.setUp()
        try await helper.unmask()
        mask.setDiameter(12)
    }
    override func tearDown() async throws {
        await mask.waitForFinish()
        try await helper.tearDown()
        helper = nil
    }
    func canvas() throws -> WSSCanvasScrollView {
        let controller = WSSEditorWindowController(document: doc, onClose: {})
        let root = try XCTUnwrap(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> WSSCanvasScrollView? {
            if let canvas = view as? WSSCanvasScrollView { return canvas }
            return view.subviews.lazy.compactMap(find).first
        }
        let value = try XCTUnwrap(find(root))
        value.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            value.shutdown()
            controller.close()
        }
        return value
    }
    func event(_ type: NSEvent.EventType, _ canvas: WSSCanvasScrollView, scene: SIMD2<Float>) throws
        -> NSEvent
    {
        if type == .mouseExited {
            return try XCTUnwrap(
                NSEvent.enterExitEvent(
                    with: type, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: canvas.window!.windowNumber,
                    context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        }
        return try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: canvas.surface.convert(canvas.viewPoint(for: scene), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: canvas.window!.windowNumber,
                context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
    }
    func testNativeMasklessHoverIsImmediateAndDataFreeForRippleAndClouds() async throws {
        let canvas = try canvas()
        for slot: WSSMaskSlot in [.ripple, .clouds] {
            if slot == .clouds {
                try doc.addEffect(.clouds)
                // Existing nil Clouds remain a supported direct-paint case.
                try await doc.manageMask(.remove)
                await doc.waitForPreview()
                let saved = await doc.save()
                XCTAssertTrue(saved)
                doc.undoManager.removeAllActions()
            }
            let model = doc.state.workingModel
            let revision = doc.state.workingRevision
            let assets = Set(doc.state.sessionAssets.keys)
            let resources = Set(doc.state.resourceCatalog.keys)
            XCTAssertEqual(doc.maskManagementTarget?.slot, slot)
            XCTAssertNil(mask.loaded)
            XCTAssertNil(doc.selectedMaskTarget)
            XCTAssertNil(mask.pixels)
            let geometry = try XCTUnwrap(mask.geometry)
            XCTAssertEqual(geometry.width, 64)
            XCTAssertEqual(geometry.height, 64)
            for point: SIMD2<Float> in [SIMD2(20, 20), SIMD2(32, 32), SIMD2(45, 40)] {
                canvas.surface.mouseMoved(with: try event(.mouseMoved, canvas, scene: point))
                let cursor = try XCTUnwrap(canvas.surface.maskCursor)
                XCTAssertEqual(mask.brushFootprint(at: cursor).count, 64)
            }
            let outside = SIMD2<Float>(-2, 32)
            canvas.surface.mouseMoved(with: try event(.mouseMoved, canvas, scene: outside))
            XCTAssertTrue(mask.brushFootprint(at: outside).isEmpty)
            canvas.surface.mouseExited(with: try event(.mouseExited, canvas, scene: SIMD2(32, 32)))
            XCTAssertNil(canvas.surface.maskCursor)
            XCTAssertEqual(doc.state.workingModel, model)
            XCTAssertEqual(doc.state.workingRevision, revision)
            XCTAssertEqual(Set(doc.state.sessionAssets.keys), assets)
            XCTAssertEqual(Set(doc.state.resourceCatalog.keys), resources)
            XCTAssertNil(doc.selectedMaskTarget)
            XCTAssertNil(mask.loaded)
            XCTAssertFalse(doc.isDirty)
            XCTAssertFalse(doc.undoManager.canUndo)
        }
    }
    func testFirstLazyStrokeKeepsExactHoverSizeAndGeometry() async throws {
        for kind: WSSAddableEffect in [.ripple, .clouds] {
            if kind == .clouds {
                try doc.addEffect(.clouds)
                try await doc.manageMask(.remove)
            }
            let center = SIMD2<Float>(32, 32)
            let before = mask.brushFootprint(at: center)
            let geometry = try XCTUnwrap(mask.geometry)
            XCTAssertEqual(before.count, 64)
            XCTAssertNil(doc.selectedMaskTarget)
            XCTAssertTrue(mask.begin(SIMD2(16, 32), erase: false))
            mask.finish(SIMD2(48, 32))
            await mask.waitForFinish()
            await mask.waitForLoad()
            XCTAssertNil(mask.error)
            XCTAssertNotNil(doc.selectedMaskTarget)
            XCTAssertTrue(try XCTUnwrap(mask.pixels).contains { $0 > 0 })
            XCTAssertEqual(mask.brushFootprint(at: center), before)
            XCTAssertEqual(mask.geometry?.width, geometry.width)
            XCTAssertEqual(mask.geometry?.height, geometry.height)
            XCTAssertEqual(mask.geometry?.uvScale, geometry.uvScale)
        }
    }
    func testMetadataOnlyGeometryPreservesLegacyUVScaleAndTransforms() throws {
        let bitmap = try WSSMaskBitmap(
            width: 100, height: 50, uvScale: SIMD2(0.5, 0.75), pixels: Data(count: 5000))
        let transform = WSSImageTransform(
            center: SIMD2(32, 32), size: SIMD2(64, 40), scale: SIMD2(1.6, 0.75), rotation: 0.4)
        let loaded = WSSMaskCanvasGeometry(transform: transform, bitmap: bitmap)
        let metadata = WSSMaskCanvasGeometry(
            transform: transform, width: bitmap.width, height: bitmap.height,
            uvScale: bitmap.uvScale)
        let center = loaded.scene(SIMD2(20, 20))
        XCTAssertEqual(metadata.texel(center), loaded.texel(center))
        XCTAssertEqual(
            metadata.footprint(center: center, diameter: 12),
            loaded.footprint(center: center, diameter: 12))
        XCTAssertEqual(metadata.scene(SIMD2(20, 20)), center)
    }
}
