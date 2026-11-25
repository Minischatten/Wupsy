import AppKit
import MetalKit
import XCTest

@testable import Wupsy

@MainActor final class PerformanceDiagnosisTests: XCTestCase {
    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "PerformanceDiagnosisTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testUnavailableAndZeroValuesRemainDistinctAcrossLanguages() {
        let english = PerformanceValueFormat(locale: Locale(identifier: "en_US"))
        let german = PerformanceValueFormat(locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(english.number(nil, digits: 1), "—")
        XCTAssertEqual(english.number(.infinity, digits: 1), "—")
        XCTAssertEqual(english.number(0, digits: 1), "0.0")
        XCTAssertEqual(german.number(29.5, digits: 1), "29,5")
        XCTAssertEqual(german.memory(1_572_864), "1,5 MiB")
        XCTAssertEqual(english.memory(nil), "—")
        XCTAssertEqual(english.pixels(1920, 1080), "1,920 × 1,080")
        XCTAssertEqual(german.pixels(nil, 1080), "—")
        XCTAssertTrue(german.milliseconds(0.125).hasPrefix("0,125"))
        XCTAssertEqual(german.milliseconds(nil), "—")
        for text in ProductText.allCases where text.rawValue.hasPrefix("performance.") {
            XCTAssertNotEqual(text.localized(language: "de"), "Wupsy")
            XCTAssertNotEqual(text.localized(language: "en"), "Wupsy")
        }
    }

    func testSharedProcessResourcesUseOneWindowAndResetWhenClosed() throws {
        var time = 10.0
        var cpu: Double? = 40
        var cpuQueries = 0
        var footprintQueries = 0
        var metalQueries = 0
        let sampler = PerformanceResourceSampler(
            now: { time },
            processCPUSeconds: {
                cpuQueries += 1
                return cpu
            },
            footprint: {
                footprintQueries += 1
                return 42
            })
        let defaults = try isolatedDefaults()
        let desktop = PerformanceDiagnosis(
            defaults: defaults, detailsKey: "test.desktop",
            resourceSampler: sampler)
        let editor = PerformanceDiagnosis(
            defaults: defaults, detailsKey: "test.editor",
            resourceSampler: sampler)
        XCTAssertNil(sampler.processReading())
        desktop.setActive(true)
        desktop.sample()
        XCTAssertEqual(cpuQueries, 0)
        desktop.showsDetails = true
        desktop.sample()
        XCTAssertEqual(desktop.details?.footprint, 42)
        XCTAssertNil(desktop.details?.cpuFraction)
        editor.setActive(true)
        editor.showsDetails = true
        editor.sample()
        XCTAssertEqual(cpuQueries, 1)
        XCTAssertEqual(footprintQueries, 1)
        for _ in 0..<2 {
            XCTAssertEqual(
                sampler.metalBytes(registryID: 1) {
                    metalQueries += 1
                    return 24
                }, 24)
        }
        XCTAssertEqual(metalQueries, 1)

        time = 12
        cpu = 43
        editor.sample()
        desktop.sample()
        XCTAssertEqual(desktop.details?.cpuFraction, 1.5)
        XCTAssertEqual(editor.details?.cpuFraction, 1.5)
        XCTAssertEqual(cpuQueries, 2)
        XCTAssertEqual(footprintQueries, 2)
        XCTAssertEqual(
            PerformanceValueFormat(locale: Locale(identifier: "en_US")).percent(1.5), "150.0%")

        desktop.setActive(false)
        time = 13
        editor.sample()
        XCTAssertEqual(editor.details?.cpuFraction, 0)
        cpu = nil
        time = 14
        editor.sample()
        XCTAssertNil(editor.details?.cpuFraction)
        editor.showsDetails = false
        editor.sample()
        XCTAssertNil(sampler.processReading())
        XCTAssertEqual(cpuQueries, 4)
        editor.showsDetails = true
        cpu = 60
        time = 20
        editor.sample()
        XCTAssertNil(editor.details?.cpuFraction)
        editor.setActive(false)
    }

    func testWindowRestorationClampsToRetainedDisplayAndRecentersWhenRemoved() {
        let main = NSRect(x: 0, y: 0, width: 800, height: 600)
        let second = NSRect(x: -600, y: 50, width: 600, height: 500)
        let size = NSSize(width: 300, height: 220)
        let saved = NSPoint(x: -570, y: 450)
        XCTAssertEqual(
            DesktopPerformancePanel.restoredFrame(
                size: size, origin: saved, screens: [main, second], fallback: main
            ).origin,
            NSPoint(x: -570, y: 330))
        XCTAssertEqual(
            DesktopPerformancePanel.restoredFrame(
                size: size, origin: saved, screens: [main], fallback: main
            ).origin,
            NSPoint(x: 250, y: 190))
    }

    func testEffectiveContentCountsVisibleLayersAndNeutralStages() throws {
        let fixtures = WSSCloudsTests()
        XCTAssertEqual(
            try fixtures.resources().performanceContentCounts,
            SceneContentCounts(visibleLayers: 1, effectiveEffects: 1))
        XCTAssertEqual(
            try fixtures.resources(WSSCloudsEffect(intensity: 0)).performanceContentCounts,
            SceneContentCounts(visibleLayers: 1, effectiveEffects: 0))
        var scene = fixtures.scene()
        var hidden = try XCTUnwrap(scene.imageLayers.first)
        hidden.visible = false
        scene.layers.append(.image(hidden))
        let resource = try WSSStaticResources(
            scene: scene,
            assets: WSSStaticTests.Assets(values: [
                fixtures.image: WSSImageAsset(
                    width: 1, height: 1, payload: .rgba8(Data([40, 80, 120, 255])))
            ]), device: WSSStaticTests().device())
        XCTAssertEqual(
            resource.performanceContentCounts,
            SceneContentCounts(visibleLayers: 1, effectiveEffects: 1))
    }

    func testPanelSelectionAndEditorHostMaintainIndependentMeasurementLifetimes() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { throw XCTSkip("Desktop display required") }
        let defaults = try isolatedDefaults()
        let (root, item) = try ScenePlaybackTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try await ScenePlayback.prepare(for: item)
        let first = Renderer(
            wallpaper: item, screen: screen, scenePlayback: prepared, onError: { XCTFail($0) })
        let second = Renderer(
            wallpaper: item, screen: screen, scenePlayback: prepared, onError: { XCTFail($0) })
        defer {
            first.stop()
            second.stop()
        }
        let desktop = try XCTUnwrap(first.scene as? WSSStaticPlayer)
        let other = try XCTUnwrap(second.scene as? WSSStaticPlayer)
        let left = DesktopPerformancePanel.Choice(id: .number(1), name: "One")
        let right = DesktopPerformancePanel.Choice(id: .number(2), name: "Two")
        var candidates = [(left, first), (right, second)]
        let controller = DesktopPerformancePanel(
            defaults: defaults, targets: { candidates },
            status: { LibraryPlaybackStatus.ready.title })
        defer { controller.close() }

        let editorFixtures = WSSEditorLivePreviewTests()
        try await editorFixtures.setUp()
        addTeardownBlock { try await editorFixtures.tearDown() }
        let document = WSSEditorDocument(project: try await editorFixtures.project("WSS-Clouds-v2"))
        let host = WSSPreviewHost(document: document, performanceDefaults: defaults)
        let editorWindow = NSWindow(
            contentRect: NSRect(x: 80, y: 100, width: 440, height: 350),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        editorWindow.isReleasedWhenClosed = false
        editorWindow.contentView = host
        editorWindow.orderFront(nil)
        defer {
            host.shutdown()
            editorWindow.close()
        }
        let preview = try XCTUnwrap(host.surface.player)

        XCTAssertNil(controller.panel)
        XCTAssertNil(desktop.metrics)
        XCTAssertNil(preview.metrics)
        host.togglePerformance()
        controller.open()
        let initialPanel = try XCTUnwrap(controller.panel)
        controller.open()
        XCTAssertTrue(controller.panel === initialPanel)
        XCTAssertFalse(initialPanel.hidesOnDeactivate)
        XCTAssertTrue(initialPanel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(initialPanel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(initialPanel.collectionBehavior.contains(.canJoinAllApplications))
        XCTAssertFalse(initialPanel.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(initialPanel.isVisible)
        XCTAssertEqual(controller.selection, left.id)
        XCTAssertNotNil(desktop.metrics)
        XCTAssertNil(other.metrics)
        XCTAssertNotNil(preview.metrics)

        let compactHeight = initialPanel.frame.height
        controller.diagnosis.showsDetails = true
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertGreaterThan(initialPanel.frame.height, compactHeight)
        host.layoutSubtreeIfNeeded()
        let overlay = try XCTUnwrap(host.subviews.last)
        XCTAssertTrue(host.bounds.contains(overlay.frame), "\(overlay.frame) in \(host.bounds)")
        XCTAssertGreaterThan(overlay.frame.width, 200)
        XCTAssertEqual(controller.diagnosis.snapshot?.sessionID, desktop.sessionID)
        XCTAssertEqual(controller.diagnosis.details?.counts?.visibleLayers, 1)
        XCTAssertEqual(host.performanceDiagnosis.snapshot?.sessionID, preview.sessionID)
        if let frameWindow = host.performanceDiagnosis.snapshot?.frameWindow {
            print(
                "Editor diagnosis: GPU completions/s=\(frameWindow.gpuCompletionsPerSecond), "
                    + "presented FPS=\(String(describing: frameWindow.presentedFPS)), "
                    + "CPU samples=\(frameWindow.cpuSamples), GPU samples=\(frameWindow.gpu.gpuSamples)"
            )
        }
        let y = initialPanel.frame.midY
        controller.select(right.id)
        XCTAssertEqual(initialPanel.frame.midY, y)
        XCTAssertNil(controller.diagnosis.snapshot)
        XCTAssertNil(desktop.metrics)
        XCTAssertNotNil(other.metrics)
        XCTAssertNotNil(preview.metrics)

        candidates.removeLast()
        controller.reconcile()
        XCTAssertEqual(controller.selection, left.id)
        XCTAssertNil(other.metrics)
        XCTAssertNotNil(desktop.metrics)
        controller.diagnosis.sample()
        XCTAssertNotNil(controller.diagnosis.snapshot)
        desktop.pause()
        XCTAssertNil(controller.diagnosis.snapshot)
        XCTAssertEqual(controller.diagnosis.status, ProductText.performancePaused.text)
        desktop.play()
        XCTAssertNil(controller.diagnosis.snapshot)

        let point = initialPanel.frame.origin
        controller.close()
        XCTAssertNil(controller.panel)
        XCTAssertFalse(controller.diagnosis.active)
        XCTAssertNil(controller.diagnosis.snapshot)
        XCTAssertNil(desktop.metrics)
        XCTAssertNotNil(preview.metrics)
        XCTAssertEqual(
            defaults.array(forKey: "performance.desktop.origin") as? [Double],
            [Double(point.x), Double(point.y)])
        controller.open()
        XCTAssertNotNil(desktop.metrics)
        XCTAssertTrue(controller.diagnosis.showsDetails)

        first.setPaused(true)
        XCTAssertNil(controller.diagnosis.snapshot)
        XCTAssertNil(desktop.metrics)
        first.setPaused(false)
        for _ in 0..<100 where first.scene == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let resumed = try XCTUnwrap(first.scene as? WSSStaticPlayer)
        XCTAssertNotEqual(resumed.sessionID, desktop.sessionID)
        XCTAssertNotNil(resumed.metrics)
        XCTAssertNil(controller.diagnosis.snapshot)
        controller.diagnosis.sample()
        XCTAssertEqual(controller.diagnosis.snapshot?.sessionID, resumed.sessionID)

        host.expand()
        XCTAssertNotNil(host.expandedWindow)
        XCTAssertTrue(host.performanceDiagnosis.active)
        XCTAssertNotNil(host.surface.player?.metrics)
        host.restore()
        XCTAssertTrue(host.performanceDiagnosis.active)
        host.togglePerformance()
        XCTAssertFalse(host.performanceDiagnosis.active)
        XCTAssertNil(host.surface.player?.metrics)
        XCTAssertNotNil(resumed.metrics)
        host.togglePerformance()
        let finalPreview = try XCTUnwrap(host.surface.player)
        host.shutdown()
        XCTAssertFalse(host.performanceDiagnosis.active)
        XCTAssertNil(finalPreview.metrics)
        XCTAssertNotNil(resumed.metrics)
        candidates.removeAll()
        first.stop()
        controller.reconcile()
        XCTAssertNil(controller.diagnosis.snapshot)
        XCTAssertNil(resumed.metrics)
        XCTAssertTrue(controller.diagnosis.active)
        XCTAssertTrue(controller.choices.isEmpty)
    }
}
