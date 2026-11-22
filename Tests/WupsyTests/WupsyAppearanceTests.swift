import AppKit
import SwiftUI
import XCTest

@testable import Wupsy

@MainActor final class WupsyAppearanceTests: XCTestCase {
    func testImageOpacitySliderFitsAtEveryInterfaceScale() throws {
        _ = NSApplication.shared
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = WupsyAppearance(defaults: defaults)
        var heights: [CGFloat] = []
        for scale in WupsyInterfaceScale.allCases {
            appearance.scale = scale
            let metrics = WupsyMetrics(scale: scale)
            let width = min(360, metrics.points(300)) - 2 * metrics.points(14)
            let host = NSHostingView(
                rootView: WupsyAppearanceScope(appearance) {
                    WSSImageOpacitySlider(
                        opacity: 1, update: { _ in XCTFail("Unexpected update") },
                        editingChanged: { _ in XCTFail("Unexpected editing") }
                    )
                    .frame(width: width)
                })
            let size = host.fittingSize
            XCTAssertEqual(size.width, width, accuracy: 1)
            XCTAssertGreaterThan(size.height, 12)
            XCTAssertLessThan(size.height, 50)
            heights.append(size.height)
        }
        XCTAssertGreaterThan(try XCTUnwrap(heights.last), try XCTUnwrap(heights.first))
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "WupsyAppearanceTests." + UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func find<T: NSView>(
        _ type: T.Type, in view: NSView, matching: (T) -> Bool = { _ in true }
    ) -> T? {
        if let match = view as? T, matching(match) { return match }
        for child in view.subviews {
            if let match = find(type, in: child, matching: matching) { return match }
        }
        return nil
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }

    func testDefaultsRoundedChoicesAndInvalidStoredValues() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(WupsyAppearance(defaults: defaults).scale, .standard)
        let appearance = WupsyAppearance(defaults: defaults)
        for scale in WupsyInterfaceScale.allCases {
            appearance.scale = scale
            XCTAssertEqual(WupsyAppearance(defaults: defaults).scale, scale)
            XCTAssertEqual(WupsyMetrics(scale: scale).target(20), CGFloat(scale.rawValue) / 5)
        }
        for invalid: Any in [0, 130, -150, "invalid", 125.5] {
            defaults.set(invalid, forKey: WupsyAppearance.key)
            XCTAssertEqual(WupsyAppearance(defaults: defaults).scale, .standard)
            XCTAssertEqual(defaults.integer(forKey: WupsyAppearance.key), 100)
        }
    }

    func testStandalonePanelAndNativeFieldsUpdateLive() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = WupsyAppearance(defaults: defaults)
        let host = WupsyPanelHostingView(
            appearance: appearance,
            root: WSSParameterTextField(value: 1.25, range: 0...10, title: "Test Value") { _ in }
                .wupsyControlFrame(width: 170))
        let panel = NSPanel(
            contentRect: NSRect(x: 50, y: 50, width: 170, height: 75),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderFront(nil)
        defer { panel.close() }
        host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(
            find(NSTextField.self, in: host) {
                $0.accessibilityLabel() == "Test Value"
            })
        let hint = try XCTUnwrap(
            find(NSTextField.self, in: host) {
                $0 !== field && $0.font?.pointSize == 10
            })
        for scale in [WupsyInterfaceScale.large, .largest, .standard] {
            appearance.scale = scale
            try await waitUntil {
                hint.font?.pointSize == 10 * scale.factor
                    && field.font?.pointSize == NSFont.systemFontSize * scale.factor
                    && abs(panel.contentRect(forFrameRect: panel.frame).width - 170 * scale.factor)
                        < 1
            }
            XCTAssertEqual(field.accessibilityLabel(), "Test Value")
            XCTAssertEqual(field.controlSize, WupsyMetrics(scale: scale).nativeControlSize)
        }
    }

    func testLibraryAndEditorShareLiveScaleAtSmallWindowSizes() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = WupsyAppearance(defaults: defaults)
        let fixtures = WSSEditorLivePreviewTests()
        try await fixtures.setUp()
        addTeardownBlock { @MainActor in try await fixtures.tearDown() }
        let loaded = try await fixtures.project("WSS-Music-Notes-Paths")
        let root = fixtures.helper.root
        let library = Library(
            maintenance: MaintenanceCoordinator(),
            storage: root.appendingPathComponent("library.json"),
            defaults: defaults, restoreOnLaunch: false, targetScreens: { [] })
        let playlist = WallpaperPlaylist(
            library: library, storage: root.appendingPathComponent("playlists.json"),
            defaults: defaults, restoreOnLaunch: false)
        let widgets = DesktopWidgets(defaults: defaults)
        let editors = WSSEditorCoordinator(lookup: { try library.wallpaperForEditor(id: $0) })
        let libraryWindow = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 1040, height: 740),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        libraryWindow.isReleasedWhenClosed = false
        let libraryHost = NSHostingView(
            rootView: WupsyAppearanceScope(appearance) {
                // The probe observes the same environment as the actual Library view.
                LibraryView().environmentObject(library).environmentObject(editors)
                    .environmentObject(widgets).environmentObject(playlist)
                    .defaultAppStorage(defaults)
                    .overlay(alignment: .bottomTrailing) { AppearanceProbe() }
            })
        libraryWindow.contentView = libraryHost
        libraryWindow.orderFront(nil)
        defer { libraryWindow.close() }

        let document = WSSEditorDocument(project: loaded)
        document.initialCanvasZoom = 1
        let editor = WSSEditorWindowController(
            document: document, onClose: {}, sizePreferences: .init(defaults: defaults),
            appearance: appearance)
        defer {
            document.close()
            editor.close()
        }
        let window = try XCTUnwrap(editor.window)
        let rootView = try XCTUnwrap(window.contentView)
        window.setContentSize(WSSEditorWindowSize.minimumContent)
        window.orderFront(nil)
        rootView.layoutSubtreeIfNeeded()

        let canvas = try XCTUnwrap(find(WSSCanvasScrollView.self, in: rootView))
        let preview = try XCTUnwrap(find(WSSPreviewHost.self, in: rootView))
        let player = try XCTUnwrap(preview.surface.player)
        let id = try XCTUnwrap(document.selection?.layer)
        document.beginMusicNotesPathEditing(id)
        canvas.update(document, zoom: 1)
        let original = document.state.workingModel
        let resolution = player.resolution
        let libraryResolution = library.sceneRenderResolution
        let fixedZoom = canvas.presentationZoom
        try await waitUntil {
            self.find(NSTextField.self, in: libraryHost) {
                $0.identifier?.rawValue == "test.wupsy.appearance" && $0.intValue == 100
            } != nil
        }
        // Measure the actual window after the hosting view installs its initial
        // layout. The content view can include native title-bar space.
        libraryHost.layoutSubtreeIfNeeded()
        let editorSize = rootView.bounds.size
        let librarySize = libraryWindow.frame.size

        for scale in [WupsyInterfaceScale.large, .largest, .standard] {
            appearance.scale = scale
            try await waitUntil {
                canvas.interfaceMetrics.scale == scale
                    && self.find(NSTextField.self, in: libraryHost) {
                        $0.identifier?.rawValue == "test.wupsy.appearance"
                            && $0.intValue == scale.rawValue
                    } != nil
            }
            XCTAssertEqual(canvas.presentationZoom, fixedZoom)
            XCTAssertEqual(player.resolution, resolution)
            XCTAssertEqual(library.sceneRenderResolution, libraryResolution)
            XCTAssertEqual(document.state.workingModel, original)
            XCTAssertEqual(canvas.surface.musicNotesPathOverlay.metrics.scale, scale)
            rootView.layoutSubtreeIfNeeded()
            XCTAssertEqual(rootView.bounds.size, editorSize)
            XCTAssertEqual(libraryWindow.frame.width, librarySize.width, accuracy: 1)
            XCTAssertLessThan(abs(libraryWindow.frame.height - librarySize.height), 64)
            let canvasFrame = canvas.convert(canvas.bounds, to: rootView)
            XCTAssertGreaterThan(canvasFrame.width, 200)
            XCTAssertGreaterThan(canvasFrame.height, 200)
            XCTAssertGreaterThanOrEqual(canvasFrame.minX, -1)
            XCTAssertLessThanOrEqual(canvasFrame.maxX, rootView.bounds.maxX + 1)
            XCTAssertTrue(canvas.surface.showsMusicNotesPath)
            XCTAssertTrue(preview.surface.player === player)
        }

        try document.changeMusicNotes(id, name: "Count") { $0.count = 8 }
        document.undoManager.undo()
        XCTAssertEqual(document.state.workingModel, original)
        document.undoManager.redo()
        XCTAssertEqual(document.musicNotesLayer(id)?.notes.count, 8)
    }

    func testCanvasHitAreaGrowsWithoutMovingPathOrTransformCenters() async throws {
        let fixtures = WSSEditorLivePreviewTests()
        try await fixtures.setUp()
        addTeardownBlock { @MainActor in try await fixtures.tearDown() }
        let document = WSSEditorDocument(
            project: try await fixtures.project("WSS-Music-Notes-Paths"))
        defer { document.close() }
        let id = try XCTUnwrap(document.selection?.layer)
        let canvas = WSSCanvasScrollView(document: document)
        defer { canvas.shutdown() }
        canvas.update(document, zoom: 1)
        let transform = try XCTUnwrap(document.workingScene.layers[0].canvasTransform)
        let corner = canvas.viewPoint(for: transform.point(SIMD2(-0.5, -0.5)))
        let transformProbe = CGPoint(x: corner.x - 11, y: corner.y)
        XCTAssertNil(canvas.canvasHit(at: transformProbe))
        canvas.interfaceMetrics = WupsyMetrics(scale: .largest)
        XCTAssertEqual(canvas.canvasHit(at: transformProbe), .corner(id, 0))
        XCTAssertEqual(canvas.viewPoint(for: transform.point(SIMD2(-0.5, -0.5))), corner)

        document.beginMusicNotesPathEditing(id)
        canvas.update(document, zoom: 1)
        let overlay = canvas.surface.musicNotesPathOverlay
        let anchor = try XCTUnwrap(overlay.path?.anchors.first)
        let center = overlay.viewport(anchor.position)
        let probe = CGPoint(x: center.x + 10, y: center.y)
        XCTAssertEqual(overlay.handle(at: probe), .anchor(0))
        canvas.interfaceMetrics = WupsyMetrics()
        XCTAssertNil(overlay.handle(at: probe))
        XCTAssertEqual(overlay.viewport(anchor.position), center)
    }
}

private struct AppearanceProbe: NSViewRepresentable {
    @Environment(\.wupsyMetrics) private var metrics
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.identifier = .init("test.wupsy.appearance")
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        field.intValue = Int32(metrics.scale.rawValue)
    }
}
