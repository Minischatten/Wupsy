import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSEditorLayerDuplicationTests: XCTestCase {
    private var fixture: WSSMaskEditingTests!
    private var doc: WSSEditorDocument { fixture.doc }

    override func setUp() async throws {
        fixture = WSSMaskEditingTests()
        try await fixture.setUp()
    }

    override func tearDown() async throws {
        try await fixture.tearDown()
    }

    private func index(_ id: WSSLayerID) throws -> Int {
        try XCTUnwrap(doc.identity.layers.firstIndex(where: { $0.id == id }))
    }

    @discardableResult
    private func duplicate(_ id: WSSLayerID) async throws -> WSSLayerID {
        let source = try index(id)
        let oldRows = doc.structureRows.map(\.id)
        let oldModel = doc.state.workingModel
        let oldIdentity = doc.identity
        let oldSelection = doc.selection
        try await doc.duplicateLayer(id)
        let copy = try XCTUnwrap(doc.selection?.layer)
        XCTAssertNotEqual(copy, id)
        XCTAssertEqual(try index(id), source)
        XCTAssertEqual(try index(copy), source + 1)
        let rows = doc.structureRows.map(\.id)
        let copyRow = try XCTUnwrap(rows.firstIndex(of: .layer(copy)))
        let sourceRow = try XCTUnwrap(oldRows.firstIndex(of: .layer(id)))
        XCTAssertEqual(copyRow, sourceRow + 1 + oldIdentity.layers[source].effects.count)
        XCTAssertEqual(rows.filter { $0.layer != copy }, oldRows)
        XCTAssertEqual(doc.state.workingModel.layers[source], oldModel.layers[source])
        XCTAssertNotNil(doc.state.workingModel.layers[source + 1].name)
        XCTAssertNotEqual(
            doc.state.workingModel.layers[source + 1].name, oldModel.layers[source].name)
        let newModel = doc.state.workingModel
        let newIdentity = doc.identity
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, oldModel)
        XCTAssertEqual(doc.identity, oldIdentity)
        XCTAssertEqual(doc.selection, oldSelection)
        doc.undoManager.redo()
        XCTAssertEqual(doc.state.workingModel, newModel)
        XCTAssertEqual(doc.identity, newIdentity)
        XCTAssertEqual(doc.selection, .layer(copy))
        return copy
    }

    func testEveryLayerTypePreservesSettingsAndUniqueEditorIdentity() async throws {
        let image = doc.identity.layers[0].id
        try doc.addRain()
        let rain = try XCTUnwrap(doc.selection?.layer)
        try doc.addTrail()
        let trail = try XCTUnwrap(doc.selection?.layer)
        try doc.addFog()
        let fog = try XCTUnwrap(doc.selection?.layer)
        try doc.addStorm()
        let storm = try XCTUnwrap(doc.selection?.layer)
        try doc.addStarfield()
        let starfield = try XCTUnwrap(doc.selection?.layer)
        try doc.addMusicNotes()
        let notes = try XCTUnwrap(doc.selection?.layer)
        try doc.setMusicNotesPathEnabled(true, layer: notes)
        var depthModel = doc.state.workingModel
        guard case .image(var targetImage) = depthModel.layers[0].content
        else { return XCTFail("Missing depth target image") }
        targetImage.composition = "sourceOver"
        depthModel.layers[0].content = .image(targetImage)
        try doc.mutate(depthModel, name: "Depth target composition")
        try doc.setMusicNotesDepthTarget(image, for: notes)
        try doc.addSlime()
        let slime = try XCTUnwrap(doc.selection?.layer)
        try doc.changeSlime(slime, name: "Test settings") {
            $0.transform.rotation = 0.45
            $0.transform.scale = [0.75, 1.4]
            $0.configuration.reflectionColor = .init(red: 0.2, green: 0.4, blue: 0.6)
            $0.configuration.opacity = 0.65
        }
        try doc.setVisibility(false, layer: slime)

        let assets = doc.state.workingModel.referencedPaths
        let staged = Set(doc.state.sessionAssets.keys)
        let resourcesOnDisk = try fixture.helper.helper.snapshot()
        for original in [image, rain, trail, fog, storm, starfield, notes, slime] {
            let copy = try await duplicate(original)
            let at = try index(copy)
            var copied = doc.state.workingModel.layers[at]
            let source = doc.state.workingModel.layers[at - 1]
            copied.name = source.name
            if case .image(var candidate) = copied.content,
                case .image(let original) = source.content
            {
                XCTAssertNotNil(candidate.depthID)
                XCTAssertNotEqual(candidate.depthID, original.depthID)
                XCTAssertEqual(doc.musicNotesLayer(notes)?.depth?.target, original.depthID)
                candidate.depthID = original.depthID
                copied.content = .image(candidate)
                let ids = doc.identity.layers
                XCTAssertFalse(ids[at].effects.isEmpty)
                XCTAssertTrue(Set(ids[at].effects).isDisjoint(with: ids[at - 1].effects))
            }
            XCTAssertEqual(copied, source)
            if original == notes {
                let sourcePath = try XCTUnwrap(doc.musicNotesLayer(notes)?.path)
                try doc.applyMusicNotesPathTemplate(.ellipsePath, layer: copy)
                XCTAssertEqual(doc.musicNotesLayer(notes)?.path, sourcePath)
                XCTAssertNotEqual(doc.musicNotesLayer(copy)?.path, sourcePath)
            }
        }
        XCTAssertEqual(doc.state.workingModel.referencedPaths, assets)
        XCTAssertEqual(Set(doc.state.sessionAssets.keys), staged)
        XCTAssertEqual(try fixture.helper.helper.snapshot(), resourcesOnDisk)
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
    }

    func testSharedMaskCopyOnWriteDeletionAndSaveReopen() async throws {
        let original = doc.identity.layers[0].id
        try doc.renameLayer(original, to: String(repeating: "ä", count: 256))
        let first = try await duplicate(original)
        let second = try await duplicate(original)
        XCTAssertNotEqual(
            doc.layerDisplayName(at: try index(first)), doc.layerDisplayName(at: try index(second)))
        for id in [first, second] {
            XCTAssertNoThrow(try WallpaperTitle.normalized(doc.layerDisplayName(at: index(id))))
        }
        let sourcePath = fixture.mask(doc.state.workingModel, layer: try index(original))
        XCTAssertEqual(fixture.mask(doc.state.workingModel, layer: try index(first)), sourcePath)
        XCTAssertEqual(fixture.mask(doc.state.workingModel, layer: try index(second)), sourcePath)

        let at = try index(second)
        let target = try fixture.target(layer: at)
        var stroke = try await doc.beginMaskStroke(
            target: target, settings: .init(diameter: 2, opacity: 0.5, mode: .paint), start: .zero)
        try await doc.applyMaskStroke(XCTUnwrap(stroke.finish()))
        let editedPath = fixture.mask(doc.state.workingModel, layer: at)
        XCTAssertNotEqual(editedPath, sourcePath)
        XCTAssertEqual(fixture.mask(doc.state.workingModel, layer: try index(original)), sourcePath)
        XCTAssertEqual(fixture.mask(doc.state.workingModel, layer: try index(first)), sourcePath)

        let originalImage = doc.state.workingModel.layers[try index(original)]
        let replacement = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: replacement) }
        try NativeImageTestWriter().save(
            Data([20, 40, 100, 255]), width: 1, height: 1, to: replacement)
        let generation = try await doc.imageImporter.load(replacement)
        try await doc.installImage(generation, replacing: second)
        XCTAssertEqual(doc.state.workingModel.layers[try index(original)], originalImage)
        XCTAssertEqual(
            doc.state.workingModel.layers[try index(second)].imageDefinition?.asset, generation.path
        )

        doc.select(.layer(first))
        try doc.deleteLayer(first)
        doc.select(.layer(original))
        try doc.deleteLayer(original)
        XCTAssertEqual(fixture.mask(doc.state.workingModel, layer: try index(second)), editedPath)
        let model = doc.state.workingModel
        let saved = await doc.save()
        XCTAssertTrue(saved)
        let loaded = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(loaded.document, model)
    }

    func testLimitsRejectDuplicationWithoutPartialChanges() async throws {
        for _ in 0..<WSSSlimeLayer.maximumLayers { try doc.addSlime() }
        let id = try XCTUnwrap(doc.selection?.layer)
        let model = doc.state.workingModel
        let ids = doc.identity
        let revision = doc.state.workingRevision
        doc.undoManager.removeAllActions()
        do {
            try await doc.duplicateLayer(id)
            XCTFail("Expected Slime budget rejection")
        } catch {
            XCTAssertTrue(String(describing: error).contains("slime scene budget"))
        }
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertEqual(doc.identity, ids)
        XCTAssertEqual(doc.state.workingRevision, revision)
        XCTAssertFalse(doc.undoManager.canUndo)

        var full = model
        guard case .image(var image) = model.layers[0].content else {
            return XCTFail("Missing image")
        }
        image.effects = []
        full.layers = Array(repeating: .init(content: .image(image)), count: 128)
        let identity = WSSEditorIdentity(full)
        try doc.mutate(
            full, name: "Fill scene", ids: identity, selected: .layer(identity.layers[0].id))
        XCTAssertNil(doc.duplicableLayer(nil))
        try await doc.duplicateLayer(identity.layers[0].id)
        XCTAssertEqual(doc.state.workingModel, full)
    }

    func testContextRowCommandAndNativeShortcutRespectSelectionAndTextEditing() async throws {
        let window = WSSEditorNativeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.editorDocument = doc
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        defer { window.close() }
        let commands = WSSEditorCommands(document: doc, window: window)
        let source = doc.identity.layers[0]
        doc.select(nil)
        XCTAssertFalse(commands.canPerform(.duplicateLayer(nil)))
        XCTAssertFalse(commands.canPerform(.duplicateLayer(.effect(source.id, source.effects[0]))))
        XCTAssertTrue(commands.canPerform(.duplicateLayer(.layer(source.id))))
        commands.perform(.duplicateLayer(.layer(source.id)))
        try await waitForLayerCount(3)
        XCTAssertEqual(try index(source.id), 0)
        XCTAssertEqual(doc.selection, .layer(doc.identity.layers[1].id))

        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2))
        let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        window.contentView?.addSubview(input)
        XCTAssertTrue(window.makeFirstResponder(input))
        XCTAssertFalse(commands.canPerform(.duplicateLayer(nil)))
        _ = window.performKeyEquivalent(with: event)
        XCTAssertEqual(doc.identity.layers.count, 3)
        input.removeFromSuperview()
        XCTAssertTrue(window.makeFirstResponder(window))
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        try await waitForLayerCount(4)
        XCTAssertEqual(doc.selection, .layer(doc.identity.layers[2].id))
    }

    func testDuplicateDrawsInFrontOfSourceAndRedoRestoresOrder() async throws {
        let source = doc.identity.layers[0].id
        doc.select(.layer(source))
        try await doc.duplicateLayer(source)
        let copy = try XCTUnwrap(doc.selection?.layer)
        let red = WSSAssetID(value: "red")
        let blue = WSSAssetID(value: "blue")
        let assets = WSSStaticTests.Assets(values: [
            red: .init(width: 1, height: 1, payload: .rgba8(Data([255, 0, 0, 255]))),
            blue: .init(width: 1, height: 1, payload: .rgba8(Data([0, 0, 255, 255]))),
        ])
        let device = try WSSStaticTests().device()

        func pixel() throws -> [UInt8] {
            let layers: [WSSSceneLayer] = doc.identity.layers.compactMap { identity in
                guard identity.id == source || identity.id == copy else { return nil }
                return .image(
                    .init(
                        asset: identity.id == source ? red : blue,
                        transform: .init(center: SIMD2(32, 32), size: SIMD2(64, 64))))
            }
            let resources = try WSSStaticResources(
                scene: .init(width: 64, height: 64, layers: layers), assets: assets, device: device)
            let bytes = try WSSCloudsTests().render(resources).0
            let center = (32 * 64 + 32) * 4
            return Array(bytes[center..<center + 4])
        }
        XCTAssertEqual(try pixel(), [255, 0, 0, 255])
        doc.undoManager.undo()
        XCTAssertEqual(doc.selection, .layer(source))
        XCTAssertEqual(try pixel(), [0, 0, 255, 255])
        doc.undoManager.redo()
        XCTAssertEqual(doc.selection, .layer(copy))
        XCTAssertEqual(try pixel(), [255, 0, 0, 255])
    }

    func testDuplicatedSlimeContinuesInHostedMetalPreview() async throws {
        try doc.addSlime()
        let original = try XCTUnwrap(doc.selection?.layer)
        await doc.waitForPreview()
        let host = WSSPreviewHost(document: doc)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 330),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.center()
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        defer {
            host.shutdown()
            window.close()
        }
        for _ in 0..<100 where host.surface.player?.view.isPaused != false {
            try await Task.sleep(for: .milliseconds(10))
        }
        let first = try XCTUnwrap(host.surface.player)
        XCTAssertFalse(first.view.isPaused)
        let playhead = first.elapsed
        let firstCopy = try await duplicate(original)
        let secondCopy = try await duplicate(original)
        try doc.changeSlime(firstCopy, name: "Position") { $0.transform.center[0] += 15 }
        try doc.changeSlime(secondCopy, name: "Position") { $0.transform.center[0] -= 15 }
        XCTAssertNotEqual(doc.slimeLayer(firstCopy)?.transform, doc.slimeLayer(original)?.transform)
        XCTAssertNotEqual(
            doc.slimeLayer(secondCopy)?.transform, doc.slimeLayer(original)?.transform)
        await doc.waitForPreview()
        host.update(doc)
        XCTAssertTrue(doc.previewIsCurrent)
        let player = try XCTUnwrap(host.surface.player)
        let layers = player.resources.scene.layers.compactMap { node -> WSSSlimeLayer? in
            if case .slime(let layer) = node { return layer }
            return nil
        }
        XCTAssertEqual(layers.count, 3)
        XCTAssertEqual(Set(layers.map { $0.transform.center[0] }).count, 3)
        XCTAssertGreaterThanOrEqual(player.elapsed, playhead)
        XCTAssertFalse(player.view.isPaused)

        guard ProcessInfo.processInfo.environment["WUPSY_REQUIRE_METAL_PRESENTATION"] == "1"
        else { return }
        XCTAssertNotNil(player.startMeasuring())
        defer { player.stopMeasuring() }
        for _ in 0..<18 {
            try await Task.sleep(for: .milliseconds(250))
            if let frame = player.performanceSnapshot()?.frameWindow,
                frame.confirmedPresentations > 0
            {
                return
            }
        }
        XCTFail("No confirmed Metal presentation for duplicated Slime layers")
    }

    private func waitForLayerCount(_ count: Int) async throws {
        for _ in 0..<100 where doc.identity.layers.count != count {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(doc.identity.layers.count, count)
    }
}
