import AppKit
import MetalKit
import SwiftUI
import XCTest

@testable import Wupsy

final class WSSFogTests: XCTestCase {
    func testPresetDefaults() throws {
        let ground = WSSFogPreset.ground.configuration
        let atmosphere = WSSFogPreset.atmosphere.configuration
        XCTAssertEqual(
            ground,
            .init(
                density: 0.48, softness: 0.75, driftX: 9, driftY: 0, scale: 1500,
                height: 0.38))
        XCTAssertEqual(
            atmosphere,
            .init(
                density: 0.23, softness: 0.9, driftX: 4, driftY: -0.5,
                scale: 2200, height: 1.5))
        XCTAssertEqual(ground.color, .init(red: 0.94, green: 0.95, blue: 0.96))
        try ground.validate()
        try atmosphere.validate()
    }

    func testManifestRoundTripAndValidation() throws {
        let data = Data(
            """
            {"format":"wss-scene","version":1,"title":"Fog","canvas":{"width":128,"height":96},
             "layers":[{"type":"fog","visible":false,"fog":{
              "density":0.44,"softness":0.73,"driftX":-4.25,"driftY":1.5,"scale":1200.5,
              "height":0.62,"color":{"red":0.12,"green":0.38,"blue":0.97}}}]}
            """.utf8)
        let document = try WSSSceneDocumentV1.decode(data: data)
        var expected = WSSFogConfiguration(
            density: 0.44, softness: 0.73, driftX: -4.25, driftY: 1.5, scale: 1200.5, height: 0.62)
        expected.color = .init(red: 0.12, green: 0.38, blue: 0.97)
        XCTAssertEqual(document.layers[0].content, .fog(.init(visible: false, fog: expected)))
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: document.encoded()), document)
        XCTAssertTrue(document.referencedPaths.isEmpty)

        let json = String(decoding: data, as: UTF8.self)
        for (old, invalid) in [
            ("\"height\":0.62", "\"height\":0"), ("\"blue\":0.97", "\"blue\":1.5"),
            ("\"blue\":0.97", "\"blue\":0.97,\"alpha\":0.5"),
            ("\"density\":0.44", "\"density\":null"),
            ("\"visible\":false", "\"visible\":false,\"preset\":\"unknown\""),
            ("\"visible\":false", "\"visible\":false,\"preset\":null"),
        ] {
            XCTAssertThrowsError(
                try WSSSceneDocumentV1.decode(
                    data: Data(json.replacingOccurrences(of: old, with: invalid).utf8)))
        }
    }

    @MainActor func testMotionAndStaticRendering() throws {
        var fog = WSSFogPreset.atmosphere.configuration
        fog.scale = 110
        var scene = WSSScene(width: 64, height: 64, layers: [.fog(.init(fog: fog))])
        XCTAssertTrue(scene.isAnimated)
        let device = try WSSStaticTests().device()
        let assets = WSSStaticTests.Assets(values: [:])
        let moving = try WSSStaticResources(scene: scene, assets: assets, device: device)
        let renderer = WSSCloudsTests()
        XCTAssertNotEqual(try renderer.render(moving).0, try renderer.render(moving, time: 8).0)

        fog.driftX = 0
        fog.driftY = 0
        scene.layers = [.fog(.init(fog: fog))]
        XCTAssertFalse(scene.isAnimated)
        let still = try WSSStaticResources(scene: scene, assets: assets, device: device)
        XCTAssertEqual(try renderer.render(still).0, try renderer.render(still, time: 1e12).0)
        for resources in [moving, still] {
            let player = WSSStaticPlayer(
                resources: resources, size: CGSize(width: 64, height: 64), scale: 1,
                maxDimension: 64, fps: 30, resolution: .standard, offset: 0,
                onError: { XCTFail($0) })
            player.play()
            XCTAssertEqual(player.view.isPaused, !resources.scene.isAnimated)
            XCTAssertEqual(player.view.enableSetNeedsDisplay, !resources.scene.isAnimated)
            player.stop()
        }

        fog.driftY = 1
        scene.layers = [.fog(.init(fog: fog))]
        XCTAssertTrue(scene.isAnimated)
        scene.layers = [.fog(.init(visible: false, fog: fog))]
        XCTAssertFalse(scene.isAnimated)
        fog.density = 0
        scene.layers = [.fog(.init(fog: fog))]
        XCTAssertFalse(scene.isAnimated)
    }

    func testTemporalWrapIsContinuous() throws {
        var fog = WSSFogPreset.atmosphere.configuration
        fog.scale = 32
        fog.driftX = -5
        fog.driftY = 0
        let scene = WSSScene(width: 64, height: 64, layers: [.fog(.init(fog: fog))])
        let resources = try WSSStaticResources(
            scene: scene, assets: WSSStaticTests.Assets(values: [:]),
            device: WSSStaticTests().device())
        let renderer = WSSCloudsTests()
        // The primary X phase crosses one full period at eight seconds.
        let before = try renderer.render(resources, time: 7.9999).0
        let after = try renderer.render(resources, time: 8.0001).0
        let largestStep = zip(before, after).map { abs(Int($0) - Int($1)) }.max()
        XCTAssertLessThanOrEqual(try XCTUnwrap(largestStep), 1)
    }

    func testGroundFadePremultipliedColorAndLayerOrder() throws {
        var settings = WSSFogPreset.ground.configuration
        settings.color = .init(red: 0, green: 0, blue: 1)
        let fog = WSSSceneLayer.fog(.init(fog: settings))
        let id = WSSAssetID(value: "foreground")
        let assets = WSSStaticTests.Assets(values: [
            id: .init(width: 1, height: 1, payload: .rgba8(Data([255, 0, 0, 255])))
        ])
        let foreground = WSSSceneLayer.image(
            .init(asset: id, transform: .init(center: SIMD2(32, 32), size: SIMD2(64, 64))))
        let device = try WSSStaticTests().device()
        let renderer = WSSCloudsTests()
        func render(_ layers: [WSSSceneLayer]) throws -> Data {
            let resources = try WSSStaticResources(
                scene: .init(width: 64, height: 64, layers: layers), assets: assets, device: device)
            return try renderer.render(resources, clearAlpha: 0).0
        }
        let fogOnly = try render([fog])
        let bottom = (60 * 64 + 32) * 4
        let top = (5 * 64 + 32) * 4
        XCTAssertEqual(Array(fogOnly[top..<(top + 4)]), [0, 0, 0, 0])
        let alpha = fogOnly[bottom + 3]
        XCTAssertGreaterThan(alpha, 0)
        XCTAssertLessThan(alpha, 128)
        XCTAssertEqual(Array(fogOnly[bottom..<(bottom + 4)]), [alpha, 0, 0, alpha])
        let covered = try render([fog, foreground])
        let front = try render([foreground, fog])
        XCTAssertEqual(Array(covered[bottom..<(bottom + 4)]), [0, 0, 255, 255])
        XCTAssertEqual(Array(front[top..<(top + 4)]), [0, 0, 255, 255])
        XCTAssertEqual(Array(front[bottom..<(bottom + 4)]), [alpha, 0, 255 - alpha, 255])
    }

    func testLegacyCloudsSceneRetainsParametersAndRenderingWithoutFogResources() throws {
        let root = WSSCloudsFixtureTests().fixture
        let doc = try WSSSceneDocumentV1.load(
            entry: root.appendingPathComponent("scene.wss.json"), root: root)
        let old = try doc.scene()
        let reopened = try WSSSceneDocumentV1.decode(data: doc.encoded())
        XCTAssertEqual(reopened, doc)
        XCTAssertEqual(try reopened.scene().imageLayers[0].effects, old.imageLayers[0].effects)
        let assets = try doc.assetSource(root: root)
        let device = try WSSStaticTests().device()
        let original = try WSSStaticResources(scene: old, assets: assets, device: device)
        let roundTrip = try WSSStaticResources(
            scene: reopened.scene(), assets: assets, device: device)
        XCTAssertNil(original.fog)
        XCTAssertNil(roundTrip.fog)
        let renderer = WSSCloudsTests()
        XCTAssertEqual(
            try renderer.render(original, time: 2).0, try renderer.render(roundTrip, time: 2).0)
    }

    @MainActor func testEditorAddReorderLiveColorUndoAndSave() async throws {
        let helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
        addTeardownBlock { @MainActor in try await helper.tearDown() }
        let project = try XCTUnwrap(helper.project)
        let item = try XCTUnwrap(helper.item)
        let storage = helper.helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([item]).write(to: storage)
        let store = ManagedWallpaperStore(storage: storage)
        let doc = WSSEditorDocument(
            project: project,
            save: { snapshot in
                let candidate = try await WSSManifestSaveValidator().prepare(
                    snapshot, handle: project.handle)
                return try await store.commitWSSManifest(candidate)
            })
        do {
            defer { doc.close() }
            let canvas = doc.canvasModel
            try doc.addFog(.ground)
            let layer = try XCTUnwrap(doc.selection?.layer)
            XCTAssertEqual(doc.fogLayer(layer)?.fog, WSSFogPreset.ground.configuration)
            try doc.moveLayer(layer, to: 1)
            await doc.waitForPreview()
            let preview = doc.previewResources
            try doc.changeFog(layer, name: "Drift") {
                $0.driftX = 3
                $0.driftY = 4
            }
            try doc.selectFogDriftDirection(.up, layer: layer)
            XCTAssertEqual(doc.fogLayer(layer)?.fog.driftX, 0)
            XCTAssertEqual(doc.fogLayer(layer)?.fog.driftY, -5)
            let color = WSSFogConfiguration.Color(red: 0.17, green: 0.71, blue: 0.32)
            try doc.changeFog(layer, name: "Color") { $0.color = color }
            await doc.waitForPreview()
            XCTAssertTrue(doc.previewIsCurrent)
            XCTAssertTrue(doc.previewResources.sharesPreparedResources(with: preview))
            guard case .fog(let rendered) = doc.previewResources.scene.layers[1] else {
                return XCTFail("Expected fog in the preview between images")
            }
            XCTAssertEqual(rendered.fog.color, color)
            XCTAssertEqual(doc.canvasModel, canvas)
            doc.undoManager.undo()
            XCTAssertEqual(doc.fogLayer(layer)?.fog.color, WSSFogPreset.ground.configuration.color)
            doc.undoManager.redo()
            let saved = await doc.save()
            guard saved else { return XCTFail("Could not save edited fog layer") }
            let reopened = try WSSSceneDocumentV1.load(
                entry: item.url, root: project.handle.root)
            XCTAssertEqual(reopened, doc.state.workingModel)
            XCTAssertEqual(reopened.layers[1].content, .fog(rendered))
        }
    }

    @MainActor func testRepeatedVisibilityChangesRedrawHostedPreview() async throws {
        let helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
        addTeardownBlock { @MainActor in try await helper.tearDown() }
        let doc = helper.document()
        defer { doc.close() }
        for layer in doc.identity.layers { try doc.setVisibility(false, layer: layer.id) }
        try doc.addFog(.atmosphere)
        let id = try XCTUnwrap(doc.selection?.layer)
        let settings = try XCTUnwrap(doc.fogLayer(id)?.fog)
        await doc.waitForPreview()
        let prepared = try XCTUnwrap(doc.previewResources.fog)
        let renderer = WSSCloudsTests()
        let visiblePixels = try renderer.render(doc.previewResources, time: 2).0
        let hosting = NSHostingView(rootView: WSSPreviewView(document: doc))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
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

        func requireFrames(_ player: WSSStaticPlayer, target: Int) async throws {
            for _ in 0..<150 where player.metrics.snapshot().frames < target {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThanOrEqual(player.metrics.snapshot().frames, target)
        }

        for playing in [true, false, true] {
            doc.playing = playing
            for _ in 0..<100 where host.surface.player?.view.isPaused == playing {
                try await Task.sleep(for: .milliseconds(10))
            }
            for visible in [false, true, false, true] {
                let previous = try XCTUnwrap(host.surface.player)
                let frames = previous.metrics.snapshot().frames
                let time = previous.elapsed
                try doc.toggleVisibility(id)
                await doc.waitForPreview()
                for _ in 0..<100 where host.surface.player?.resources !== doc.previewResources {
                    try await Task.sleep(for: .milliseconds(10))
                }
                let player = try XCTUnwrap(host.surface.player)
                XCTAssertEqual(doc.fogLayer(id), .init(visible: visible, fog: settings))
                XCTAssertTrue(player.resources === doc.previewResources)
                XCTAssertTrue(player.resources.fog === prepared)
                if visible {
                    XCTAssertFalse(player === previous)
                    XCTAssertNil(previous.view.delegate)
                    XCTAssertGreaterThanOrEqual(player.elapsed, time)
                } else {
                    XCTAssertTrue(player === previous)
                }
                XCTAssertEqual(player.view.isPaused, !(visible && playing))
                if !playing { XCTAssertEqual(player.elapsed, time) }
                let pixels = try renderer.render(player.resources, time: 2).0
                XCTAssertEqual(pixels == visiblePixels, visible)
                let target =
                    visible && playing
                    ? player.metrics.snapshot().frames + 3
                    : (player === previous ? frames + 1 : 1)
                try await requireFrames(player, target: target)
            }
        }
    }

    func testDriftDirectionPreservesMagnitudeAndHonorsAxisLimits() {
        let expected: [WSSShootingStarDirection: SIMD2<Float>] = [
            .right: SIMD2(1, 0), .upRight: SIMD2(1, -1), .up: SIMD2(0, -1),
            .upLeft: SIMD2(-1, -1), .left: SIMD2(-1, 0), .downLeft: SIMD2(-1, 1),
            .down: SIMD2(0, 1), .downRight: SIMD2(1, 1),
        ]
        for (direction, axes) in expected {
            var fog = WSSFogPreset.atmosphere.configuration
            fog.driftX = 3
            fog.driftY = 4
            fog.setDriftDirection(direction)
            let factor = 5 / hypot(axes.x, axes.y)
            XCTAssertEqual(fog.driftX, axes.x * factor, accuracy: 1e-6)
            XCTAssertEqual(fog.driftY, axes.y * factor, accuracy: 1e-6)
            XCTAssertEqual(hypot(fog.driftX, fog.driftY), 5, accuracy: 1e-6)
            XCTAssertEqual(fog.driftAngle ?? -1, direction.rawValue, accuracy: 1e-6)
        }
        var fog = WSSFogPreset.ground.configuration
        fog.driftX = 128
        fog.driftY = -128
        fog.setDriftDirection(.downLeft)
        XCTAssertEqual(fog.driftX, -128)
        XCTAssertEqual(fog.driftY, 128)
        fog.setDriftDirection(.up)
        XCTAssertEqual(fog.driftX, 0)
        XCTAssertEqual(fog.driftY, -128)
        fog.driftY = 0
        XCTAssertNil(fog.driftAngle)
        fog.setDriftDirection(.left)
        XCTAssertEqual(fog.driftX, -WSSFogPreset.ground.configuration.driftX)
        XCTAssertEqual(fog.driftY, 0)
    }

    func testSpeedScalesCurrentDirectionAndStopsAnimation() throws {
        for direction in [SIMD2<Double>(1, 0), SIMD2(0, -1), SIMD2(-0.6, 0.8)] {
            var fog = WSSFogPreset.atmosphere.configuration
            for speed in [0.002, 2.5, 96] {
                fog.setDriftSpeed(speed, in: direction)
                XCTAssertEqual(fog.driftSpeed, speed, accuracy: 1e-5)
                let actual = try XCTUnwrap(fog.driftUnitDirection)
                XCTAssertEqual(actual.x, direction.x, accuracy: 1e-6)
                XCTAssertEqual(actual.y, direction.y, accuracy: 1e-6)
                try fog.validate()
            }
            fog.setDriftSpeed(500, in: direction)
            XCTAssertEqual(
                fog.driftSpeed, WSSFogConfiguration.driftSpeedLimit(in: direction), accuracy: 1e-5)
            let capped = try XCTUnwrap(fog.driftUnitDirection)
            XCTAssertEqual(capped.x, direction.x, accuracy: 1e-6)
            XCTAssertEqual(capped.y, direction.y, accuracy: 1e-6)
            try fog.validate()

            fog.setDriftSpeed(0, in: direction)
            XCTAssertEqual(fog.driftSpeed, 0)
            XCTAssertFalse(fog.isAnimated)
            XCTAssertNil(fog.driftUnitDirection)
        }
    }

    @MainActor func testEditorSpeedFollowsManualAxesRestoresDirectionAndGroupsUndo() async throws {
        let helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
        addTeardownBlock { @MainActor in try await helper.tearDown() }
        let doc = helper.document()
        defer { doc.close() }
        try doc.addFog(.ground)
        let id = try XCTUnwrap(doc.selection?.layer)
        func configuration() throws -> WSSFogConfiguration {
            try XCTUnwrap(doc.fogLayer(id)?.fog)
        }
        try doc.changeFog(id, name: "Horizontal") { $0.driftX = -3 }
        XCTAssertEqual(try configuration().driftSpeed, 3)
        try doc.changeFog(id, name: "Vertical") { $0.driftY = 4 }
        XCTAssertEqual(try configuration().driftSpeed, 5)
        doc.beginFogSpeedSlider(id)
        try doc.setFogSpeed(10, layer: id)
        try doc.setFogSpeed(0, layer: id)
        XCTAssertEqual(try configuration().driftSpeed, 5)
        XCTAssertEqual(doc.fogSpeedDrag?.draft.isAnimated, false)
        doc.endFogSpeedSlider()
        XCTAssertFalse(try configuration().isAnimated)
        doc.undoManager.undo()
        XCTAssertEqual(try configuration().driftSpeed, 5)
        doc.undoManager.redo()
        XCTAssertEqual(try configuration().driftSpeed, 0)

        doc.select(.layer(doc.identity.layers[0].id))
        doc.select(.layer(id))
        try doc.setFogSpeed(2.5, layer: id)
        let resumed = try configuration()
        XCTAssertEqual(resumed.driftX, -1.5)
        XCTAssertEqual(resumed.driftY, 2)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        guard case .fog(let preview) = doc.previewResources.scene.layers.last else {
            return XCTFail("Expected fog in live preview")
        }
        XCTAssertEqual(preview.fog, resumed)

        try doc.changeFog(id, name: "Horizontal") { $0.driftX = 0 }
        try doc.changeFog(id, name: "Vertical") { $0.driftY = 0 }
        try doc.setFogSpeed(0.125, layer: id)
        XCTAssertEqual(try configuration().driftX, 0)
        XCTAssertEqual(try configuration().driftY, 0.125)
    }

    @MainActor func testNumericSpeedKeepsDirectionAndRoundTripsDrift() async throws {
        let helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
        addTeardownBlock { @MainActor in try await helper.tearDown() }
        let doc = helper.document()
        defer { doc.close() }
        try doc.addFog(.ground)
        let id = try XCTUnwrap(doc.selection?.layer)
        try doc.changeFog(id, name: "Drift") {
            $0.driftX = -3
            $0.driftY = 4
        }
        let before = doc.state.workingModel
        doc.undoManager.removeAllActions()

        try doc.setFogNumericSpeed(2.5, layer: id)
        XCTAssertEqual(doc.fogLayer(id)?.fog.driftX, -1.5)
        XCTAssertEqual(doc.fogLayer(id)?.fog.driftY, 2)
        XCTAssertEqual(doc.fogLayer(id)?.fog.driftSpeed, 2.5)
        XCTAssertThrowsError(try doc.setFogNumericSpeed(161, layer: id))
        let edited = doc.state.workingModel
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: edited.encoded()), edited)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertFalse(doc.undoManager.canUndo)
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, edited)

        try doc.setFogNumericSpeed(0, layer: id)
        try doc.setFogNumericSpeed(5, layer: id)
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertTrue(doc.beginFogSpeedSlider(id))
        try doc.setFogSpeed(10, layer: id)
        XCTAssertEqual(doc.fogLayer(id)?.fog.driftSpeed, 5)
        doc.endFogSpeedSlider()
        XCTAssertEqual(doc.fogLayer(id)?.fog.driftSpeed, 10)
        XCTAssertEqual(doc.fogLayer(id)?.fog.driftX, -6)
        XCTAssertEqual(doc.fogLayer(id)?.fog.driftY, 8)
    }

    @MainActor func testSpeedFromLoadedStillFogDefaultsToRight() async throws {
        let helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
        addTeardownBlock { @MainActor in try await helper.tearDown() }
        let doc = helper.document()
        defer { doc.close() }
        var model = doc.state.workingModel
        var fog = WSSFogPreset.ground.configuration
        fog.driftX = 0
        fog.driftY = 0
        model.layers.append(.init(content: .fog(.init(fog: fog))))
        let reopened = try WSSSceneDocumentV1.decode(data: model.encoded())
        try doc.mutate(reopened, name: "Load stationary fog", ids: WSSEditorIdentity(reopened))
        let layer = try XCTUnwrap(doc.identity.layers.last?.id)
        try doc.setFogSpeed(3, layer: layer)
        XCTAssertEqual(doc.fogLayer(layer)?.fog.driftX, 3)
        XCTAssertEqual(doc.fogLayer(layer)?.fog.driftY, 0)
    }

    @MainActor func testRapidSpeedChangesKeepLatestPreviewAndOneUndo() async throws {
        let helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
        addTeardownBlock { @MainActor in try await helper.tearDown() }
        for withRain in [false, true] {
            let doc = helper.document()
            defer { doc.close() }
            _ = doc.maskCanvas
            _ = doc.directionCanvas
            if withRain {
                // Exercise drag isolation with another prepared layer that stays hidden.
                var model = doc.state.workingModel
                model.layers.append(
                    .init(
                        content: .rain(
                            .init(
                                region: .init(x: 0, y: 0, width: 1920, height: 1920),
                                rain: .init(effect: .init(density: 1900)), visible: false,
                                composition: "sourceOver"))))
                try doc.mutate(model, name: "Rain", ids: WSSEditorIdentity(model))
            }
            try doc.addFog(.ground)
            await doc.waitForPreview()
            let id = try XCTUnwrap(doc.selection?.layer)
            let original = doc.previewResources
            let host = WSSPreviewHost(document: doc)
            let player = try XCTUnwrap(host.surface.player)
            let revision = doc.state.workingRevision
            let canvas = doc.canvasModel
            doc.undoManager.removeAllActions()
            doc.beginFogSpeedSlider(id)
            for value in 1...120 {
                try doc.setFogSpeed(Double(value) / 4, layer: id)
            }
            XCTAssertEqual(doc.state.workingRevision, revision)
            XCTAssertTrue(doc.previewResources === original)
            XCTAssertEqual(doc.fogLayer(id)?.fog.driftSpeed, 9)
            XCTAssertTrue(doc.undoManager.canUndo)
            let draft = try XCTUnwrap(player.fogDragPreview)
            guard case .fog(let transient) = draft.scene.layers.last else {
                return XCTFail("Expected transient fog in live preview")
            }
            XCTAssertEqual(transient.fog.driftSpeed, 30)
            XCTAssertTrue(draft.fog === original.fog)
            doc.endFogSpeedSlider()
            await doc.waitForPreview()
            XCTAssertEqual(doc.state.workingRevision, revision + 1)
            XCTAssertTrue(doc.previewIsCurrent)
            host.update(doc)
            XCTAssertTrue(host.surface.player === player)
            XCTAssertTrue(player.resources === doc.previewResources)
            XCTAssertNil(player.fogDragPreview)
            XCTAssertEqual(doc.fogLayer(id)?.fog.driftSpeed, 30)
            guard case .fog(let preview) = doc.previewResources.scene.layers.last else {
                return XCTFail("Expected fog in live preview")
            }
            XCTAssertEqual(preview.fog.driftSpeed, 30)
            XCTAssertTrue(doc.previewResources.sharesPreparedResources(with: original))
            XCTAssertTrue(doc.previewResources.fog === original.fog)
            XCTAssertEqual(doc.canvasModel, canvas)
            doc.undoManager.undo()
            XCTAssertEqual(doc.fogLayer(id)?.fog.driftSpeed, 9)
            XCTAssertFalse(doc.undoManager.canUndo)
            doc.undoManager.redo()
            XCTAssertEqual(doc.fogLayer(id)?.fog.driftSpeed, 30)
            await doc.waitForPreview()
            XCTAssertTrue(doc.previewIsCurrent)

            // An unrelated edit may still be pending when the next drag starts.
            // Reconcile both edits, including the final slider value.
            try doc.setImage(.opacity, value: 0.6, layer: doc.identity.layers[0].id)
            XCTAssertFalse(doc.previewIsCurrent)
            doc.beginFogSpeedSlider(id)
            try doc.setFogSpeed(31, layer: id)
            try doc.setFogSpeed(32, layer: id)
            doc.endFogSpeedSlider()
            await doc.waitForPreview()
            XCTAssertTrue(doc.previewIsCurrent)
            XCTAssertEqual(doc.previewResources.scene.imageLayers.first?.opacity, 0.6)
            guard case .fog(let final) = doc.previewResources.scene.layers.last else {
                return XCTFail("Expected reconciled fog in live preview")
            }
            XCTAssertEqual(final.fog.driftSpeed, 32)

            doc.beginFogSpeedSlider(id)
            try doc.setFogSpeed(39, layer: id)
            doc.undoManager.undo()
            XCTAssertNil(doc.fogSpeedDrag)
            XCTAssertEqual(doc.fogLayer(id)?.fog.driftSpeed, 32)
            doc.undoManager.redo()
            XCTAssertEqual(doc.fogLayer(id)?.fog.driftSpeed, 39)
        }
    }
}
