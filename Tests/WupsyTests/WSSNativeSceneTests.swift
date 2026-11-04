import ImageIO
import MetalKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import Wupsy

final class WSSNativeSceneTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WSSNative-" + UUID().uuidString
        ).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func png(
        _ pixels: [UInt8] = [40, 80, 120, 255, 40, 80, 120, 255], width: Int = 2, height: Int = 1
    ) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(
            CGImage(
                width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let output = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        return data as Data
    }
    func document(clouds: Bool = false, mask: Bool = false) -> [String: Any] {
        var layer: [String: Any] = [
            "image": "assets/base.png", "transform": ["center": [32, 32], "size": [64, 64]],
            "composition": "replace",
        ]
        if clouds {
            var effect: [String: Any] = [
                "type": "clouds", "velocity": [12, -3], "scale": 32,
                "intensity": 0.7, "density": 0.5, "seed": 7,
            ]
            if mask { effect["mask"] = "assets/mask.png" }
            layer["effects"] = [effect]
        }
        return [
            "format": "wss-scene", "version": 1, "title": "Native test",
            "canvas": ["width": 64, "height": 64], "layers": [layer],
        ]
    }
    func fixture(_ doc: [String: Any]? = nil, name: String = "Source") throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try png().write(to: folder.appendingPathComponent("assets/base.png"))
        try png([0, 0, 0, 255, 255, 0, 0, 255]).write(
            to: folder.appendingPathComponent("assets/mask.png"))
        try JSONSerialization.data(withJSONObject: doc ?? document()).write(
            to: folder.appendingPathComponent("scene.wss.json"))
        return folder
    }
    func load(_ doc: [String: Any]) throws -> WSSScene {
        let folder = try fixture(doc)
        return try WSSSceneDocumentV1.load(
            entry: folder.appendingPathComponent("scene.wss.json"), root: folder
        ).scene()
    }
    func testStaticCloudsMaskLayersAndTransform() throws {
        let staticScene = try load(document())
        let maskFolder = root.appendingPathComponent("Source")
        let maskPixels = try WSSNativeAssets(root: maskFolder).mask(
            for: WSSAssetID(value: "assets/mask.png"))
        XCTAssertEqual(maskPixels.pixels, Data([0, 255]))
        XCTAssertFalse(staticScene.isAnimated)
        var doc = document(clouds: true, mask: true)
        var layers = doc["layers"] as! [[String: Any]]
        var second = layers[0]
        second["effects"] = [] as [Any]
        second["opacity"] = 0.4
        second["visible"] = false
        second["composition"] = "sourceOver"
        second["transform"] =
            ["center": [13, 17], "size": [8, 12], "scale": [2, 3], "rotation": Float.pi / 2]
            as [String: Any]
        layers.append(second)
        doc["layers"] = layers
        let scene = try load(doc)
        XCTAssertEqual(scene.testImages.count, 2)
        XCTAssertTrue(scene.isAnimated)
        XCTAssertEqual(scene.testImages[0].composition, .replace)
        XCTAssertEqual(scene.testImages[1].composition, .sourceOver)
        XCTAssertEqual(scene.testImages[1].transform.center, SIMD2(13, 17))
        XCTAssertEqual(scene.testImages[1].transform.axisX.y, 16, accuracy: 0.0001)
        XCTAssertEqual(scene.testImages[1].transform.axisY.x, -36, accuracy: 0.0001)
        XCTAssertEqual(scene.testImages[1].opacity, 0.4)
        XCTAssertFalse(scene.testImages[1].visible)
        guard case .clouds(let e) = scene.testImages[0].effects.first else {
            return XCTFail("native clouds")
        }
        XCTAssertEqual(e.velocity, SIMD2(12, -3))
        XCTAssertEqual(e.seed, 7)
        XCTAssertEqual(e.mask?.asset.value, "assets/mask.png")
    }
    func testStrictDocumentRejections() throws {
        for change: (inout [String: Any]) -> Void in [
            { $0["background"] = NSNull() }, { $0["version"] = 2 }, { $0["format"] = "other" },
            { $0["newFeature"] = true },
            { $0["canvas"] = ["width": 0, "height": 10] },
            { $0["canvas"] = ["width": 1.5, "height": 10] },
            { $0["canvas"] = ["width": 100_000_000, "height": 100_000_000] },
            { $0["background"] = [0, -1, 0] }, { $0["title"] = " " },
            { $0["layers"] = [] as [Any] },
            {
                var a = $0["layers"] as! [[String: Any]]
                a[0]["composition"] = "add"
                $0["layers"] = a
            },
            {
                var a = $0["layers"] as! [[String: Any]]
                a[0]["opacity"] = 1.1
                $0["layers"] = a
            },
            {
                var a = $0["layers"] as! [[String: Any]]
                a[0]["transform"] = ["center": [0], "size": [2, 2]]
                $0["layers"] = a
            },
            {
                var a = $0["layers"] as! [[String: Any]]
                a[0]["effects"] = [["type": "rain"]]
                $0["layers"] = a
            },
            {
                var a = $0["layers"] as! [[String: Any]]
                var e = (a[0]["effects"] as! [[String: Any]])[0]
                e["scale"] = 0
                a[0]["effects"] = [e]
                $0["layers"] = a
            },
            {
                var a = $0["layers"] as! [[String: Any]]
                var e = (a[0]["effects"] as! [[String: Any]])[0]
                e["unknown"] = 1
                a[0]["effects"] = [e]
                $0["layers"] = a
            },
        ] {
            var doc = document(clouds: true)
            change(&doc)
            XCTAssertThrowsError(try load(doc))
        }
        for path in [
            "../outside.png", "/tmp/outside.png", "assets/../base.png", "assets//base.png",
            "assets\\base.png", "https://example.org/a.png", "~/.png",
        ] {
            var doc = document()
            var layers = doc["layers"] as! [[String: Any]]
            layers[0]["image"] = path
            doc["layers"] = layers
            XCTAssertThrowsError(try load(doc))
        }
    }
    func testMissingAssetsUnsafeSymlinksAndUnknownVersionErrors() async throws {
        let folder = try fixture(document(clouds: true, mask: true))
        let item = try WallpaperImporter.resolve(folder)
        XCTAssertEqual(item.sceneSource, .nativeWSS)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("assets/mask.png"))
        do {
            _ = try await ScenePlayback.prepare(for: item)
            XCTFail("missing mask")
        } catch { XCTAssertEqual(error as? WSSDocumentError, .missingAsset("assets/mask.png")) }
        let outside = root.appendingPathComponent("outside.png")
        try png().write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("assets/mask.png"), withDestinationURL: outside)
        do {
            _ = try await ScenePlayback.prepare(for: item)
            XCTFail("symlink")
        } catch { XCTAssertEqual(error as? WSSDocumentError, .unsafePath("assets/mask.png")) }
        let store = ManagedWallpaperStore(
            storage: root.appendingPathComponent("Support/library.json"))
        do {
            _ = try await store.importWallpaper(folder, existing: [])
            XCTFail("managed symlink")
        } catch {}
        var doc = document()
        doc["version"] = 99
        let invalid = try fixture(doc, name: "Future")
        XCTAssertThrowsError(try WallpaperImporter.resolve(invalid)) { error in
            XCTAssertEqual(error as? WSSDocumentError, .version(99))
        }
        XCTAssertNil(item.scenePlaybackMode)
    }
    func testPersistenceAndLegacyBackendRules() throws {
        let folder = try fixture()
        let item = try WallpaperImporter.resolve(folder)
        XCTAssertEqual(
            try WallpaperImporter.resolve(folder.appendingPathComponent("scene.wss.json"))
                .sceneSource, .nativeWSS)
        XCTAssertEqual(item.playbackMode, .wss)
        let data = try JSONEncoder().encode(item)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["sceneSource"] as? String, "nativeWSS")
        XCTAssertNil(object["scenePlaybackMode"])
        XCTAssertEqual(try JSONDecoder().decode(Wallpaper.self, from: data), item)
        for mode in ["compatibility", "wss"] {
            object["scenePlaybackMode"] = mode
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    Wallpaper.self, from: JSONSerialization.data(withJSONObject: object)))
        }
        object.removeValue(forKey: "sceneSource")
        object.removeValue(forKey: "scenePlaybackMode")
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                Wallpaper.self, from: JSONSerialization.data(withJSONObject: object)))

    }
    @MainActor func running(_ lib: Library) async throws -> WSSStaticPlayer {
        for _ in 0..<250 {
            if let p = lib.renderers.first?.scene as? WSSStaticPlayer,
                p.metrics.snapshot().frames > 0
            {
                return p
            }
            if let error = lib.message { throw WSSDocumentError.invalid(error) }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WSSDocumentError.invalid("no native frame")
    }
    @MainActor func testManagedLibraryProductionPlaybackWithoutSourceOrEngineFiles() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("Display required") }
        for (i, flags) in [(false, false), (true, false), (true, true)].enumerated() {
            let source = try fixture(document(clouds: flags.0, mask: flags.1), name: "Source\(i)")
            let suite = "WSSNative-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(false, forKey: "conserve")
            defaults.set(false, forKey: "pauseOnBattery")
            defaults.set(false, forKey: "allDisplays")
            let storage = root.appendingPathComponent("Support\(i)/library.json")
            let lib = Library(storage: storage, defaults: defaults)
            defer { lib.stop() }
            lib.importURLs([source])
            for _ in 0..<300 {
                if !lib.importing { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(lib.message)
            let item = try XCTUnwrap(lib.items.first)
            XCTAssertEqual(item.sceneSource, .nativeWSS)
            XCTAssertEqual(item.ownership, .managed)
            XCTAssertTrue(item.managed!.directory.hasPrefix("WSS/"))
            XCTAssertNil(item.scenePlaybackMode)
            XCTAssertEqual(item.title, "Native test")
            XCTAssertNotEqual(item.root, source.path)
            lib.toggleFavorite(item)
            let store = ManagedWallpaperStore(storage: storage)
            let duplicate = try await store.importWallpaper(source, existing: lib.items)
            XCTAssertNotEqual(duplicate.id, item.id)
            XCTAssertNotEqual(duplicate.root, item.root)
            try FileManager.default.removeItem(at: source)
            let loaded = try XCTUnwrap(store.load().first)
            XCTAssertEqual(loaded.id, item.id)
            let reloaded = Library(storage: storage, defaults: defaults)
            defer { reloaded.stop() }
            XCTAssertTrue(reloaded.favorites.contains(item.id))
            let support = await ScenePlayback.wssSupport(for: loaded)
            XCTAssertEqual(support, .supported)
            lib.apply(loaded)
            let p = try await running(lib)
            XCTAssertEqual(p.view.isPaused, !flags.0)
            XCTAssertEqual(p.resources.scene.testImages[0].effects.isEmpty, !flags.0)
            let before = p.elapsed
            lib.sceneRenderResolution = .standard
            lib.sceneRenderResolution = .hiDPI
            XCTAssertGreaterThanOrEqual(p.elapsed, before)
            lib.manuallyPaused = true
            XCTAssertTrue(lib.renderers.allSatisfy { !$0.hasLiveResources })
            let paused = p.elapsed
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(p.elapsed, paused)
            lib.manuallyPaused = false
            let resumed = try await running(lib)
            XCTAssertGreaterThanOrEqual(resumed.elapsed, paused - 0.02)
            XCTAssertLessThan(resumed.elapsed, paused + 1)
            let rendered = try WSSCloudsTests().render(resumed.resources).0
            let later = try WSSCloudsTests().render(resumed.resources, time: 4).0
            if flags.0 {
                XCTAssertNotEqual(rendered, later)
            } else {
                XCTAssertEqual(rendered, later)
            }
            let details = await MediaDetails.read(item)
            XCTAssertEqual(details.format, "WSS")
            XCTAssertTrue(details.dimensions.contains("64 × 64"))

            XCTAssertEqual(lib.active?.sceneSource, .nativeWSS)
            XCTAssertEqual(lib.active?.playbackMode, .wss)
        }
    }
}
