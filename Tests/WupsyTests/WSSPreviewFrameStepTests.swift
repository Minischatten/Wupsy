import AppKit
@preconcurrency import Metal
import MetalKit
import XCTest
import os

@testable import Wupsy

@MainActor final class WSSPreviewFrameStepTests: XCTestCase {
    private let fixture = WSSEditorLivePreviewTests()

    override func setUp() async throws { try await fixture.setUp() }
    override func tearDown() async throws { try await fixture.tearDown() }

    func testFrameIndexPreservesOffGridAnchorAndRestartsAtZero() {
        let anchor = 0.123456789
        var position = WSSPreviewFramePosition(anchor: anchor)
        for _ in 0..<900 { _ = position.step(.forward, fps: 30) }
        for _ in 0..<899 { _ = position.step(.backward, fps: 30) }
        XCTAssertEqual(position.step(.backward, fps: 30), anchor)
        for _ in 0..<3 { _ = position.step(.backward, fps: 30) }
        XCTAssertEqual(position.step(.backward, fps: 30), 0)
        XCTAssertEqual(position.step(.forward, fps: 30), 1.0 / 30)
        XCTAssertEqual(position.step(.backward, fps: 30), 0)
        XCTAssertEqual(position.step(.forward, fps: 24), 1.0 / 24)
    }

    func testFrameControlsHaveLocalizedLabelsAndAvailableSymbols() {
        for (direction, english, german): (WSSPreviewFrameDirection, String, String) in [
            (.backward, "Previous frame", "Einzelbild zurück"),
            (.forward, "Next frame", "Einzelbild vor"),
        ] {
            XCTAssertEqual(direction.title.localized(language: "en"), english)
            XCTAssertEqual(direction.title.localized(language: "de"), german)
            XCTAssertNotNil(
                NSImage(systemSymbolName: direction.symbol, accessibilityDescription: nil))
        }
    }

    private func open(
        _ document: WSSEditorDocument, time: Double
    ) -> (WSSPreviewHost, NSWindow) {
        document.playing = false
        document.initialPreviewTime = time
        let host = WSSPreviewHost(document: document)
        let window = makeWindow(host)
        return (host, window)
    }

    private func makeWindow(_ content: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.center()
        window.orderFrontRegardless()
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        return window
    }

    private func wait(
        for predicate: () -> Bool, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for _ in 0..<120 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate(), message, file: file, line: line)
    }

    private func requirePresentation(
        _ player: WSSStaticPlayer, _ step: String
    ) async throws {
        XCTAssertTrue(player.hasPendingEditorFrame, step)
        try await wait(
            for: { !player.hasPendingEditorFrame },
            "Metal did not confirm presentation for \(step)")
    }

    func testSpatialSlimeStepsPresentInBothWindowsAndFirstResumeFrameUsesSelectedTime()
        async throws
    {
        let document = WSSEditorDocument(
            project: try await fixture.project("WSS-Slime-Spatial-v1"))
        let anchor = WSSSlimePrototype.release - 1.0 / 60
        let (host, window) = open(document, time: anchor)
        defer {
            host.shutdown()
            document.close()
            window.close()
        }
        let player = try XCTUnwrap(host.surface.player)
        let resources = player.resources
        let originalView = player.view
        let revision = document.state.workingRevision
        let strict = ProcessInfo.processInfo.environment["WUPSY_REQUIRE_METAL_PRESENTATION"] == "1"
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(
            host.surface.frameControls.forward,
            "visible=\(window.isVisible) host=\(host.bounds) surface=\(host.surface.bounds) metal=\(player.view.bounds) status=\(player.rendererStatus)"
        )
        _ = player.startMeasuring()
        document.stepPreviewFrame?(.forward)
        XCTAssertEqual(player.elapsed, anchor + 1.0 / 30)
        XCTAssertTrue(player.view === originalView)
        if strict { try await requirePresentation(player, "forward in the normal preview") }
        player.stopMeasuring()

        // Transfer synchronously before the queued backward draw can encode.
        _ = player.startMeasuring()
        document.stepPreviewFrame?(.backward)
        host.expand()
        XCTAssertTrue(host.surface.player === player)
        XCTAssertTrue(player.view.window === host.expandedWindow)
        XCTAssertFalse(player.view === originalView)
        XCTAssertNil(originalView.delegate)
        XCTAssertEqual(player.elapsed, anchor)
        if strict { try await requirePresentation(player, "backward across the window transfer") }
        player.stopMeasuring()

        let enlarged = try XCTUnwrap(host.expandedWindow)
        host.interfaceMetrics = WupsyMetrics(scale: .largest)
        enlarged.setContentSize(NSSize(width: 350, height: 300))
        let content = try XCTUnwrap(enlarged.contentView)
        content.layoutSubtreeIfNeeded()
        let buttons = content.subviews.compactMap { $0 as? NSButton }
        let previous = try XCTUnwrap(buttons.first { $0.toolTip == EditorText.previousFrame.text })
        let play = try XCTUnwrap(buttons.first { $0.toolTip == EditorText.playPreview.text })
        let next = try XCTUnwrap(buttons.first { $0.toolTip == EditorText.nextFrame.text })
        XCTAssertLessThan(previous.frame.maxX, play.frame.minX)
        XCTAssertLessThan(play.frame.maxX, next.frame.minX)
        XCTAssertTrue([previous, play, next].allSatisfy { content.bounds.contains($0.frame) })
        _ = player.startMeasuring()
        try await wait(for: { next.isEnabled }, "Expanded step button did not enable")
        next.performClick(nil)
        XCTAssertEqual(player.elapsed, anchor + 1.0 / 30)
        if strict { try await requirePresentation(player, "forward in the expanded preview") }
        player.stopMeasuring()
        host.restore()
        XCTAssertTrue(host.surface.player === player)
        XCTAssertTrue(player.resources === resources)
        XCTAssertTrue(player.view.isPaused)
        let target = player.elapsed
        _ = player.startMeasuring()
        try await Task.sleep(for: .milliseconds(500))
        let count = try XCTUnwrap(player.performanceSnapshot()).completions.frames
        try await Task.sleep(for: .milliseconds(420))
        XCTAssertEqual(player.performanceSnapshot()?.completions.frames, count)
        XCTAssertEqual(player.elapsed, target)
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(document.undoManager.canUndo)
        XCTAssertEqual(document.state.workingRevision, revision)

        // Exercise the existing renewal when resuming after continuous animation.
        document.playing = true
        host.update(document)
        try await wait(for: { player.elapsed > target }, "Initial playback did not resume")
        document.playing = false
        host.update(document)
        XCTAssertTrue(host.surface.player === player)
        document.stepPreviewFrame?(.forward)
        let resumeTarget = player.elapsed
        var encoded: [Double] = []
        host.surface.performancePlayerChanged = {
            host.surface.player?.onFrameEncoded = { time, _, _ in encoded.append(time) }
        }
        defer { host.surface.performancePlayerChanged = nil }
        document.playing = true
        host.update(document)
        let resumed = try XCTUnwrap(host.surface.player)
        XCTAssertFalse(resumed === player)
        XCTAssertTrue(resumed.resources === resources)
        XCTAssertFalse(host.surface.frameControls.forward)
        try await wait(for: { encoded.count >= 2 }, "No continuous frames after resume")
        XCTAssertEqual(encoded.first, resumeTarget)
        XCTAssertGreaterThan(encoded[1], resumeTarget)
    }

    func testMixedInputsAndMultipleTrailsClearOnlyAfterAnEffectiveStep() async throws {
        let document = WSSEditorDocument(project: try await fixture.project("WSS-Rain-v1"))
        try document.addTrail()
        try document.addTrail()
        await document.waitForPreview()
        let (host, window) = open(document, time: 0)
        defer {
            host.shutdown()
            document.close()
            window.close()
        }
        let player = try XCTUnwrap(host.surface.player)
        let resources = player.resources
        let indices = resources.scene.layers.indices.filter {
            if case .trail = resources.scene.layers[$0] { return true }
            return false
        }
        XCTAssertEqual(indices.count, 2)
        let texture = try WSSRippleChainTests().target(resources.device)
        for (time, point): (Double, SIMD2<Float>) in [(0, SIMD2(10, 10)), (0.25, SIMD2(40, 35))] {
            _ = try render(
                resources, to: texture, at: time, trail: player.trailContext, pointer: point)
        }
        XCTAssertTrue(indices.allSatisfy { player.trailContext.sampleCount(index: $0) > 1 })
        player.view.draw()  // A normal paused redraw keeps recorded samples.
        XCTAssertTrue(indices.allSatisfy { player.trailContext.sampleCount(index: $0) > 1 })

        try await wait(for: { host.surface.frameControls.forward }, "Paused controls unavailable")
        XCTAssertFalse(host.surface.frameControls.backward)
        document.stepPreviewFrame?(.backward)
        XCTAssertEqual(player.elapsed, 0)
        XCTAssertTrue(indices.allSatisfy { player.trailContext.sampleCount(index: $0) > 1 })

        document.stepPreviewFrame?(.forward)
        XCTAssertTrue(indices.allSatisfy { player.trailContext.sampleCount(index: $0) == 0 })
        for direction: WSSPreviewFrameDirection in [
            .forward, .forward, .backward, .backward, .forward, .backward, .backward, .backward,
            .forward, .forward, .backward,
        ] {
            document.stepPreviewFrame?(direction)
        }
        XCTAssertEqual(player.elapsed, 1.0 / 30)
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertTrue(indices.allSatisfy { player.trailContext.sampleCount(index: $0) == 0 })
        XCTAssertEqual(player.elapsed, 1.0 / 30)
    }

    func testMinimizingAndRestoringKeepsPausedTimeAndPresentsLatestStep() async throws {
        let doc = WSSEditorDocument(project: try await fixture.project("WSS-Slime-Spatial-v1"))
        let (host, window) = open(doc, time: 3)
        defer {
            host.shutdown()
            doc.close()
            window.close()
        }
        let player = try XCTUnwrap(host.surface.player)
        try await wait(for: { host.surface.frameControls.forward }, "Paused controls unavailable")
        doc.stepPreviewFrame?(.forward)
        doc.stepPreviewFrame?(.forward)
        window.miniaturize(nil)
        try await wait(for: { window.isMiniaturized }, "Preview window did not minimize")
        let frozen = 3 + 2.0 / 30
        XCTAssertEqual(player.elapsed, frozen)
        XCTAssertFalse(host.surface.frameControls.forward)
        doc.stepPreviewFrame?(.backward)
        XCTAssertEqual(player.elapsed, frozen)
        window.deminiaturize(nil)
        try await wait(
            for: { host.surface.frameControls.forward }, "Paused controls did not return")
        if ProcessInfo.processInfo.environment["WUPSY_REQUIRE_METAL_PRESENTATION"] == "1" {
            try await wait(
                for: { !player.hasPendingEditorFrame }, "Restored drawable did not present")
        }
        XCTAssertEqual(player.elapsed, frozen)
        XCTAssertTrue(host.surface.player === player)
        XCTAssertTrue(player.view.isPaused)
    }

    private final class InterruptibleMetalView: MTKView {
        var omitPass = false
        var omitDrawable = false
        var passRequests = 0

        override var currentRenderPassDescriptor: MTLRenderPassDescriptor? {
            passRequests += 1
            return omitPass ? nil : super.currentRenderPassDescriptor
        }

        override var currentDrawable: CAMetalDrawable? {
            omitDrawable ? nil : super.currentDrawable
        }
    }

    func testSlotsWakeOnCompletionAndMissingSurfaceResourcesHaveBoundedRetries() async throws {
        let resources = try await fixture.project("WSS-Slime-Spatial-v1").resources
        let size = CGSize(width: 120, height: 180)
        let view = InterruptibleMetalView(
            frame: NSRect(origin: .zero, size: size), device: resources.device)
        let player = WSSStaticPlayer(
            resources: resources, size: size, scale: 1, maxDimension: 480, fps: 30,
            resolution: .hiDPI, offset: 2, metalView: view,
            editorFrameStepping: true, onError: { XCTFail($0) })
        let window = makeWindow(view)
        let event = try XCTUnwrap(resources.device.makeSharedEvent())
        defer {
            event.signaledValue = 1
            player.stop()
            window.close()
        }
        try await Task.sleep(for: .milliseconds(140))
        var encoded: [Double] = []
        player.onFrameEncoded = { time, _, _ in encoded.append(time) }

        let blocker = try XCTUnwrap(resources.queue.makeCommandBuffer())
        blocker.encodeWaitForEvent(event, value: 1)
        blocker.commit()
        view.draw()
        view.draw()
        XCTAssertEqual(encoded, [2, 2])
        player.stepEditorFrame(to: 3, resetTrail: true)
        player.stepEditorFrame(to: 4, resetTrail: false)
        try await Task.sleep(for: .milliseconds(65))
        XCTAssertEqual(encoded, [2, 2])
        event.signaledValue = 1
        try await wait(
            for: { encoded.contains(4) }, "In-flight completion did not wake the request")
        XCTAssertFalse(encoded.contains(3))

        view.omitPass = true
        let passBaseline = view.passRequests
        player.stepEditorFrame(to: 5, resetTrail: false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue((1...3).contains(view.passRequests - passBaseline))
        let exhausted = view.passRequests
        try await Task.sleep(for: .milliseconds(130))
        XCTAssertEqual(view.passRequests, exhausted)
        XCTAssertFalse(encoded.contains(5))
        XCTAssertEqual(player.elapsed, 5)
        view.omitPass = false
        view.omitDrawable = true
        player.setEditorSurfaceAvailable(false)
        player.setEditorSurfaceAvailable(true)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertFalse(encoded.contains(5))
        view.omitDrawable = false
        player.setEditorSurfaceAvailable(false)
        player.setEditorSurfaceAvailable(true)
        try await wait(
            for: { encoded.contains(5) }, "Restored drawable did not draw the current target")
        XCTAssertTrue(view.isPaused)
    }

    func testSteppedDrawableMatchesDirectRenderForEveryAnalyticEffect() async throws {
        for (name, entry) in [
            ("WSS-Flow-v1", 1.23), ("WSS-Ripple-v1", 1.23), ("WSS-Flow-Ripple-v1", 1.23),
            ("WSS-Clouds-v2", 1.23), ("WSS-Rain-v1", 1.23), ("WSS-Storm-Lighting-v1", 0.0),
            ("WSS-Starfield-Shooting-Stars-v1", 1.23), ("WSS-Music-Notes-Paths", 1.23),
            ("WSS-Slime-Spatial-v1", 3.78),
        ] {
            let document = WSSEditorDocument(project: try await fixture.project(name))
            defer { document.close() }
            var entries = [entry]
            if name == "WSS-Clouds-v2" {
                try document.addFog()
                await document.waitForPreview()
                XCTAssertNotNil(document.editorPreviewResources.fog)
            } else if name == "WSS-Storm-Lighting-v1" {
                let scene = document.editorPreviewResources.scene
                let flash = try XCTUnwrap(
                    (1...180).map { Double($0) / 30 }.first {
                        WSSStormLightingFrame.illumination(scene: scene, at: $0).isEffective
                    })
                entries = [flash - 1.0 / 30]
            } else if name == "WSS-Slime-Spatial-v1" {
                let scene = document.editorPreviewResources.scene
                guard case .slime(let layer) = scene.layers.first else {
                    return XCTFail("Expected spatial Slime layer")
                }
                let placement = WSSSlimePrototype.Placement(
                    try layer.nativeTransform(), direction: layer.configuration.direction)
                func frame(_ time: Double) -> WSSSlimePrototype.Frame {
                    WSSSlimePrototype.frame(
                        at: time, configuration: layer.configuration,
                        anchorTilt: placement.anchorTilt,
                        longitudinalScale: placement.longitudinalScale)
                }
                let fade = try XCTUnwrap(
                    (120...300).map { Double($0) / 30 }.first { frame($0).visibility == 0 })
                let wrap = try XCTUnwrap(
                    (1...30).map { fade + Double($0) / 30 }.first {
                        frame($0).drop.y < frame($0 - 1.0 / 30).drop.y
                    })
                entries += [fade - 1.0 / 30, wrap - 1.0 / 30]
            }
            for time in entries {
                try await compareSteppedPixels(document, time: time, fixtureName: name)
            }
        }
    }

    private struct CapturedFrame {
        let time: Double
        let width: Int
        let height: Int
        let pixels: Data
    }

    private func compareSteppedPixels(
        _ document: WSSEditorDocument, time: Double, fixtureName: String
    ) async throws {
        let (host, window) = open(document, time: time)
        defer {
            host.shutdown()
            window.close()
        }
        let player = try XCTUnwrap(host.surface.player)
        player.view.framebufferOnly = false
        try await Task.sleep(for: .milliseconds(45))
        let capture = OSAllocatedUnfairLock<CapturedFrame?>(initialState: nil)
        player.onFrameEncoded = { time, command, texture in
            let width = texture.width
            let height = texture.height
            let stride = (width * 4 + 255) & ~255
            guard
                let buffer = texture.device.makeBuffer(
                    length: stride * height, options: .storageModeShared),
                let blit = command.makeBlitCommandEncoder()
            else { return XCTFail("Could not read the stepped drawable") }
            blit.copy(
                from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: buffer, destinationOffset: 0, destinationBytesPerRow: stride,
                destinationBytesPerImage: stride * height)
            blit.endEncoding()
            command.addCompletedHandler { command in
                guard command.status == .completed else { return }
                var pixels = Data()
                for row in 0..<height {
                    pixels.append(Data(bytes: buffer.contents() + row * stride, count: width * 4))
                }
                let frame = CapturedFrame(time: time, width: width, height: height, pixels: pixels)
                capture.withLock { $0 = frame }
            }
        }
        for (direction, expected): (WSSPreviewFrameDirection, Double) in [
            (.forward, time + 1.0 / 30), (.backward, time),
        ] {
            capture.withLock { $0 = nil }
            document.stepPreviewFrame?(direction)
            try await wait(
                for: { capture.withLock { $0?.time == expected } },
                "No drawable at the expected time for \(fixtureName)")
            let stepped = try XCTUnwrap(capture.withLock { $0 })
            XCTAssertEqual(stepped.time, expected, fixtureName)
            let resources = player.resources
            let direct = try WSSRippleChainTests().target(
                resources.device, width: stepped.width, height: stepped.height)
            let reference = try render(resources, to: direct, at: expected)
            XCTAssertTrue(
                stepped.pixels == reference, "Pixel mismatch for \(fixtureName) at \(expected)")
        }
    }

    private func render(
        _ resources: WSSStaticResources, to texture: MTLTexture, at time: Double,
        trail: WSSTrailRenderContext? = nil, pointer: SIMD2<Float>? = nil
    ) throws -> Data {
        let width = texture.width
        let height = texture.height
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let color = resources.scene.background
        pass.colorAttachments[0].clearColor = MTLClearColorMake(
            Double(color.x), Double(color.y), Double(color.z), 1)
        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
        try resources.encode(
            command: command, descriptor: pass, size: CGSize(width: width, height: height),
            time: time, rippleContext: WSSRippleRenderContext(device: resources.device),
            trailContext: trail, pointer: pointer, projection: .fullCanvas,
            advanceTrail: trail != nil)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return pixels
    }
}
