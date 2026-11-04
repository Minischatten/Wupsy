import AppKit
import MetalKit
import XCTest

@testable import Wupsy

// All filesystem and preference fixtures are isolated; no user project is opened.
final class WSSEditorProjectTests: XCTestCase {
    var fixtures: WSSNativeSceneTests!
    var root: URL { fixtures.root }
    override func setUpWithError() throws {
        fixtures = WSSNativeSceneTests()
        try fixtures.setUpWithError()
    }
    override func tearDownWithError() throws { try fixtures.tearDownWithError() }
    func native() throws -> Wallpaper {
        let folder = try fixtures.fixture(name: "Wallpapers/WSS/Native")
        return Wallpaper(
            title: "Library title", path: folder.appendingPathComponent("scene.wss.json").path,
            root: folder.path, kind: .scene,
            managed: .init(directory: "WSS/Native", entry: "scene.wss.json"),
            sceneSource: .nativeWSS)
    }
    func missing() -> Wallpaper {
        let folder = root.appendingPathComponent("Wallpapers/WSS/MissingProject")
        return Wallpaper(
            title: "Missing", path: folder.appendingPathComponent("scene.wss.json").path,
            root: folder.path, kind: .scene,
            managed: .init(directory: "WSS/MissingProject", entry: "scene.wss.json"))
    }
    func snapshot() throws -> [String: Data] { try ManagedLibraryTests().snapshot(root) }

    func testMissingProjectDoesNotMaterializeAndExternalIsRejected() async throws {
        let item = missing()
        let before = try snapshot()
        XCTAssertEqual(try WSSExistingProjectResolver.resolve(item).origin, .native)
        do {
            _ = try await WSSEditorProjectLoader().load(item)
            XCTFail("Missing native project accepted")
        } catch {}
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Wallpapers/NativeProjects").path))
        XCTAssertEqual(try snapshot(), before)
        var external = try native()
        external.managed = nil
        XCTAssertThrowsError(try WSSExistingProjectResolver.resolve(external))
        var unmanagedMissing = item
        unmanagedMissing.managed = nil
        XCTAssertThrowsError(try WSSExistingProjectResolver.resolve(unmanagedMissing))
        // Only the explicit native fixture creation above changed the directory.
        XCTAssertTrue(before.isEmpty)
    }
    func testDamagedManifestAndMissingAssetsNeverRegenerate() async throws {
        let item = try native()
        let entry = URL(fileURLWithPath: item.path)
        let valid = try Data(contentsOf: entry)
        let loader = WSSEditorProjectLoader()
        for damage in [Data("broken".utf8), Data("{}".utf8)] {
            try damage.write(to: entry)
            let before = try snapshot()
            do {
                _ = try await loader.load(item)
                XCTFail("damaged project accepted")
            } catch {}
            XCTAssertEqual(try snapshot(), before)
        }
        try valid.write(to: entry)
        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: item.root).appendingPathComponent("assets/base.png"))
        let before = try snapshot()
        do {
            _ = try await loader.load(item)
            XCTFail("missing asset accepted")
        } catch {}
        XCTAssertEqual(try snapshot(), before)
    }
    func testInvalidAssetAndUnsupportedVersionAreLocalOpenFailures() async throws {
        let item = try native()
        let image = URL(fileURLWithPath: item.root).appendingPathComponent("assets/base.png")
        try Data("invalid image".utf8).write(to: image)
        var before = try snapshot()
        let loader = WSSEditorProjectLoader()
        do {
            _ = try await loader.load(item)
            XCTFail("invalid asset accepted")
        } catch {}
        XCTAssertEqual(try snapshot(), before)
        var document = fixtures.document()
        document["version"] = 99
        try JSONSerialization.data(withJSONObject: document).write(
            to: URL(fileURLWithPath: item.path))
        before = try snapshot()
        do {
            _ = try await loader.load(item)
            XCTFail("unknown version accepted")
        } catch WSSDocumentError.version(99) {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(try snapshot(), before)
    }
    @MainActor func testNativeFixtureEffectInventoryAndOrder() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let names = [
            "WSS-Ripple-v1", "WSS-Ripple-Chain-v1", "WSS-Flow-v1", "WSS-Flow-Ripple-v1",
            "WSS-Clouds-v2",
            "WSS-Rain-v1",
        ]
        var titles: [String] = []
        for name in names {
            let source = repo.appendingPathComponent("Test-Wallpaper/" + name)
            let target = root.appendingPathComponent("Wallpapers/WSS/" + name)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: target)
            let item = Wallpaper(
                title: name, path: target.appendingPathComponent("scene.wss.json").path,
                root: target.path, kind: .scene,
                managed: .init(directory: "WSS/" + name, entry: "scene.wss.json"),
                sceneSource: .nativeWSS)
            let before = try snapshot()
            let document = WSSEditorDocument(project: try await WSSEditorProjectLoader().load(item))
            for index in document.project.scene.layers.indices {
                document.selectedLayer = index
                titles += document.inspection.map(\.title)
                if case .image(let layer) = document.project.scene.layers[index] {
                    for effectIndex in layer.effects.indices {
                        XCTAssertTrue(
                            document.inspection.contains {
                                $0.title.hasPrefix(
                                    EditorText.effectHeading(index: effectIndex, name: ""))
                            })
                    }
                }
            }
            document.close()
            XCTAssertEqual(try snapshot(), before)
        }
        for kind in [
            EditorText.effectRipple.text, EditorText.effectFlow.text,
            EditorText.effectClouds.text, EditorText.effectRain.text,
        ] {
            XCTAssertTrue(titles.contains { $0.contains(kind) }, "missing inspector: " + kind)
        }
    }
    @MainActor func testInspectorPreservesTransformsOrderDescriptorsAndAllLayerKinds() async throws
    {
        var doc = fixtures.document(clouds: true, mask: true)
        var layers = doc["layers"] as! [[String: Any]]
        let rotation: Float = 4 * .pi + 0.25
        layers[0]["transform"] = [
            "center": [13, 17], "size": [64, 64], "scale": [2, 3], "rotation": rotation,
        ]
        layers[0]["image"] = [
            "asset": "assets/base.png", "encoding": "image", "width": 2,
            "height": 1, "uvScale": [1, 1], "filter": "nearest", "edge": "repeat",
            "mipmapped": false,
        ]
        let rain: [String: Any] = [
            "type": "rain", "region": ["x": 0, "y": 0, "width": 64, "height": 64],
            "rain": [
                "direction": 25, "speed": 900, "density": 100, "length": 32, "width": 1.2,
                "opacity": ["min": 0.08, "max": 0.24], "seed": 7,
            ],
        ]
        let trail = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(WSSTrailTests().configuration()))
        layers += [rain, ["type": "cursorTrail", "trail": trail, "visible": false]]
        doc["layers"] = layers
        let folder = try fixtures.fixture(doc, name: "Wallpapers/WSS/Inspection")
        let item = Wallpaper(
            title: "Display name", path: folder.appendingPathComponent("scene.wss.json").path,
            root: folder.path, kind: .scene,
            managed: .init(directory: "WSS/Inspection", entry: "scene.wss.json"),
            sceneSource: .nativeWSS)
        let before = try snapshot()
        let project = try await WSSEditorProjectLoader().load(item)
        let editor = WSSEditorDocument(project: project)
        XCTAssertEqual(project.document.layers[0].imageTransform?.rotation, rotation)
        XCTAssertEqual(project.document.layers[0].imageTransform?.scale, [2, 3])
        XCTAssertTrue(editor.layerNames[0].contains(EditorText.imageFilename.format("")))
        XCTAssertTrue(editor.layerNames[1].contains(EditorText.effectRain.text))
        XCTAssertTrue(editor.layerNames[2].contains(EditorText.effectTrail.text))
        var values = editor.inspection.flatMap(\.rows)
        XCTAssertTrue(values.contains { $0.0 == "Filter" && $0.1 == "nearest" })
        XCTAssertTrue(values.contains { $0.0 == "Scale" && $0.1 == "2.0, 3.0" })
        XCTAssertTrue(
            editor.inspection.contains {
                $0.title == EditorText.effectHeading(index: 0, name: EditorText.effectClouds.text)
            })
        editor.selectedLayer = 1
        values = editor.inspection.flatMap(\.rows)
        XCTAssertTrue(values.contains { $0.0 == "Seed" && $0.1 == "7" })
        editor.selectedLayer = 2
        XCTAssertTrue(editor.inspection.flatMap(\.rows).contains { $0.0 == "Color mode" })
        editor.close()
        XCTAssertEqual(try snapshot(), before)
    }
}

@MainActor private final class EditorTestWindow: WSSEditorWindow {
    var focuses = 0
    var closes = 0
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func focus() { focuses += 1 }
    func close() {
        closes += 1
        onClose()
    }
}

@MainActor final class WSSEditorCoordinatorTests: XCTestCase {
    func project() async throws -> WSSLoadedEditorProject {
        let helper = WSSEditorProjectTests()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        return try await WSSEditorProjectLoader().load(helper.native())
    }
    func testWindowIdentityCloseAndFreshOpen() async throws {
        let project = try await project()
        var entries = [project.handle.id: project.handle.wallpaper]
        var second = project.handle.wallpaper
        second.id = UUID()
        entries[second.id] = second
        var windows: [EditorTestWindow] = []
        var loads = 0
        let coordinator = WSSEditorCoordinator(
            lookup: { try XCTUnwrap(entries[$0]) },
            load: { item in
                loads += 1
                let handle = WSSProjectHandle(
                    wallpaper: item, root: project.handle.root,
                    entry: project.handle.entry, origin: .native)
                return WSSLoadedEditorProject(
                    handle: handle, document: project.document, scene: project.scene,
                    assets: project.assets, resources: project.resources,
                    diskBasis: project.diskBasis)
            },
            makeWindow: { _, close in
                let window = EditorTestWindow(onClose: close)
                windows.append(window)
                return window
            })
        try await coordinator.open(wallpaperID: project.handle.id)
        try await coordinator.open(wallpaperID: project.handle.id)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].focuses, 2)
        try await coordinator.open(wallpaperID: second.id)
        XCTAssertEqual(coordinator.openIDs.count, 2)
        coordinator.close(wallpaperID: project.handle.id)
        XCTAssertEqual(windows[0].closes, 1)
        try await coordinator.open(wallpaperID: project.handle.id)
        XCTAssertEqual(loads, 3)
        coordinator.shutdown()
        XCTAssertTrue(coordinator.openIDs.isEmpty)
    }
    func testPendingDeduplicationAndLateCloseOrShutdownCannotOpenWindow() async throws {
        let project = try await project()
        for shutdown in [false, true] {
            var continuation: CheckedContinuation<WSSLoadedEditorProject, Error>?
            var loads = 0
            var windowCount = 0
            let coordinator = WSSEditorCoordinator(
                lookup: { _ in project.handle.wallpaper },
                load: { _ in
                    loads += 1
                    return try await withCheckedThrowingContinuation { continuation = $0 }
                },
                makeWindow: { _, close in
                    windowCount += 1
                    return EditorTestWindow(onClose: close)
                })
            let first = Task { try await coordinator.open(wallpaperID: project.handle.id) }
            for _ in 0..<1000 where continuation == nil { await Task.yield() }
            XCTAssertNotNil(continuation)
            let second = Task { try await coordinator.open(wallpaperID: project.handle.id) }
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(loads, 1)
            if shutdown {
                coordinator.shutdown()
            } else {
                coordinator.close(wallpaperID: project.handle.id)
            }
            continuation?.resume(returning: project)
            do {
                try await first.value
                XCTFail("late open succeeded")
            } catch {}
            do {
                try await second.value
                XCTFail("late open succeeded")
            } catch {}
            XCTAssertEqual(windowCount, 0)
            XCTAssertTrue(coordinator.openIDs.isEmpty)
            coordinator.shutdown()
        }
    }
    func testPendingSuccessfulOpenIsSharedAndOpenFailureCreatesNoWindow() async throws {
        let project = try await project()
        var continuation: CheckedContinuation<WSSLoadedEditorProject, Error>?
        var loads = 0
        var windows = 0
        let coordinator = WSSEditorCoordinator(
            lookup: { _ in project.handle.wallpaper },
            load: { _ in
                loads += 1
                return try await withCheckedThrowingContinuation { continuation = $0 }
            },
            makeWindow: { _, close in
                windows += 1
                return EditorTestWindow(onClose: close)
            })
        let first = Task { try await coordinator.open(wallpaperID: project.handle.id) }
        for _ in 0..<1000 where continuation == nil { await Task.yield() }
        let second = Task { try await coordinator.open(wallpaperID: project.handle.id) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(loads, 1)
        continuation?.resume(returning: project)
        try await first.value
        try await second.value
        XCTAssertEqual(windows, 1)
        coordinator.shutdown()
        let failing = WSSEditorCoordinator(
            lookup: { _ in project.handle.wallpaper },
            load: { _ in throw WSSEditorOpenError.missingProject },
            makeWindow: { _, close in
                windows += 1
                return EditorTestWindow(onClose: close)
            })
        do {
            try await failing.open(wallpaperID: project.handle.id)
            XCTFail("opening should fail")
        } catch {}
        XCTAssertTrue(failing.openIDs.isEmpty)
        XCTAssertEqual(windows, 1)
        failing.shutdown()
    }
    func testEditorFocusUpdatesCommandGateAndRealWindowCloseStopsPreview() async throws {
        let project = try await project()
        let coordinator = WSSEditorCoordinator(lookup: { _ in project.handle.wallpaper })
        let document = WSSEditorDocument(project: project)
        let controller = WSSEditorWindowController(
            document: document, onClose: { document.close() })
        let window = try XCTUnwrap(controller.window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(coordinator.editorHasFocus)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(coordinator.editorHasFocus)
        controller.close()
        XCTAssertTrue(document.closed)
        XCTAssertNil(window.contentView)
        coordinator.shutdown()
    }
    func testRuntimeErrorStaysInDocumentAndLateErrorsAreIgnored() async throws {
        let project = try await project()
        let document = WSSEditorDocument(project: project)
        var stops = 0
        document.stopPreview = { stops += 1 }
        document.previewFailed("local GPU failure")
        XCTAssertEqual(document.previewError, EditorText.errorPreview.format("local GPU failure"))
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(document.playing)
        XCTAssertFalse(document.inspection.isEmpty)
        document.close()
        document.previewFailed("late failure")
        XCTAssertEqual(document.previewError, EditorText.errorPreview.format("local GPU failure"))
    }
}

@MainActor final class WSSEditorIntegrationTests: XCTestCase {
    func testEditorAAndBDoNotApplyPauseStopOrPersistLibraryOrPlaylist() async throws {
        let helper = WSSEditorProjectTests()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let a = try helper.native()
        let folder = try helper.fixtures.fixture(name: "Wallpapers/WSS/Other")
        let b = Wallpaper(
            title: "Other", path: folder.appendingPathComponent("scene.wss.json").path,
            root: folder.path, kind: .scene,
            managed: .init(directory: "WSS/Other", entry: "scene.wss.json"), sceneSource: .nativeWSS
        )
        let storage = helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([a, b]).write(to: storage)
        let suite = "WSSEditorIntegration-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "conserve")
        defaults.set(false, forKey: "pauseOnBattery")
        let library = Library(storage: storage, defaults: defaults, restoreOnLaunch: false)
        defer { library.stop() }
        let playlist = WallpaperPlaylist(
            library: library,
            storage: helper.root.appendingPathComponent("playlists.json"), defaults: defaults,
            restoreOnLaunch: false)
        defer { playlist.shutdown() }
        let outcome = await library.apply(a).outcome
        guard case .accepted = outcome else { return XCTFail("desktop fixture failed to apply") }
        let activeRenderers = library.renderers.map(ObjectIdentifier.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let playlistState = try encoder.encode(playlist.state)
        let before = try helper.snapshot()
        let preferences = defaults.dictionaryRepresentation()
        let events = library.playbackEvents
        let loader = WSSEditorProjectLoader()
        var commands = 0
        let originalCommand = library.onPlaybackCommand
        library.onPlaybackCommand = { command in
            commands += 1
            originalCommand?(command)
        }
        let coordinator = WSSEditorCoordinator(
            lookup: { try library.wallpaperForEditor(id: $0) },
            load: { try await loader.load($0) },
            makeWindow: { document, close in
                // Exercise the real local preview lifecycle, without foreground UI.
                let surface = WSSPreviewSurface(document: document)
                document.stopPreview = { surface.shutdown() }
                return EditorTestWindow(onClose: close)
            })
        for item in [a, b] {
            try await coordinator.open(wallpaperID: item.id)
            coordinator.close(wallpaperID: item.id)
            XCTAssertEqual(library.active?.id, a.id)
            XCTAssertFalse(library.manuallyPaused)
            XCTAssertEqual(library.renderers.map(ObjectIdentifier.init), activeRenderers)
            XCTAssertEqual(library.playbackEvents, events)
            XCTAssertEqual(try encoder.encode(playlist.state), playlistState)
            XCTAssertEqual(try helper.snapshot(), before)
            XCTAssertEqual(
                defaults.dictionaryRepresentation() as NSDictionary, preferences as NSDictionary)
        }
        coordinator.shutdown()
        XCTAssertEqual(commands, 0)
    }
}
