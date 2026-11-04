import XCTest

@testable import Wupsy

final class WSSRemovedEffectTests: XCTestCase {
    let unsupported = ["surfaceAdvection", "waterSurface", "unknownFutureEffect"]

    func testRemovedAndUnknownEffectsFailExplicitlyEvenInHiddenLayersAndChains() throws {
        let helper = WSSNativeSceneTests()
        for type in unsupported {
            for hidden in [false, true] {
                var json = helper.document()
                var layers = json["layers"] as! [[String: Any]]
                layers[0]["visible"] = !hidden
                layers[0]["effects"] = [WSSSceneCodecTests().ripple(), ["type": type]]
                json["layers"] = layers
                XCTAssertThrowsError(
                    try JSONDecoder().decode(
                        WSSSceneDocumentV1.self, from: JSONSerialization.data(withJSONObject: json))
                ) {
                    XCTAssertEqual($0 as? WSSDocumentError, .effect(type))
                    XCTAssertTrue($0.localizedDescription.contains(type))
                }
            }
        }
    }

    func testSupportedEffectsEncodeAndDecodeWithoutRemovedTypes() throws {
        let helper = WSSSceneCodecTests()
        var json = WSSNativeSceneTests().document()
        var layers = json["layers"] as! [[String: Any]]
        layers[0]["effects"] = [
            helper.ripple(),
            ["type": "flow", "flowMap": helper.field(true)],
            [
                "type": "clouds", "velocity": [12, 0], "scale": 256,
                "intensity": 0.3, "density": 0.5, "seed": 1,
            ],
        ]
        json["layers"] = layers
        let decoded = try JSONDecoder().decode(
            WSSSceneDocumentV1.self,
            from: JSONSerialization.data(withJSONObject: json))
        let bytes = try decoded.encoded()
        XCTAssertEqual(try JSONDecoder().decode(WSSSceneDocumentV1.self, from: bytes), decoded)
        let text = String(decoding: bytes, as: UTF8.self)
        for type in unsupported { XCTAssertFalse(text.contains(type)) }
    }

    func testOpeningImportAndBackupRejectRemovedEffectsWithoutChangingSource() async throws {
        let helper = LibraryBackupTests()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let item = try helper.native("Wallpapers/WSS/Native")
        try helper.save([item])
        let original = try Data(contentsOf: item.url)
        for type in unsupported {
            var json = try JSONSerialization.jsonObject(with: original) as! [String: Any]
            var layers = json["layers"] as! [[String: Any]]
            layers[0]["effects"] = [["type": type]]
            json["layers"] = layers
            let bytes = try JSONSerialization.data(withJSONObject: json)
            try bytes.write(to: item.url)
            do {
                _ = try await WSSEditorProjectLoader().load(item)
                XCTFail("Unsupported effect opened: " + type)
            } catch {}
            let store = ManagedWallpaperStore(
                storage: helper.root.appendingPathComponent("Import/library.json"))
            do {
                _ = try await store.importWallpaper(URL(fileURLWithPath: item.root), existing: [])
                XCTFail("Unsupported effect imported: " + type)
            } catch {}
            XCTAssertThrowsError(try LibraryBackupPlan.analyze(storage: helper.storage))
            XCTAssertEqual(try Data(contentsOf: item.url), bytes)
        }
    }

    func testRestoreRejectsRemovedEffectsAfterValidArchiveHashChecks() async throws {
        let helper = LibraryRestoreTests()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let item = try helper.fixture.native("Wallpapers/WSS/Native")
        try helper.fixture.save([item])
        let path = "payloads/" + item.id.uuidString + "/source/scene.wss.json"
        for type in unsupported {
            let archive = try helper.mutated { files in
                try helper.json(&files, path) { json in
                    var layers = json["layers"] as! [[String: Any]]
                    layers[0]["effects"] = [["type": type]]
                    json["layers"] = layers
                }
            }
            await helper.rejected(archive)
        }
    }

    // Opt-in input must be an isolated temporary copy, never a live user library.
    @MainActor func testOptionalNativeProjectCopiesOpenImportPlayBackupAndRestore() async throws {
        guard let input = ProcessInfo.processInfo.environment["WUPSY_NATIVE_PROJECTS_QA"] else {
            throw XCTSkip("Set WUPSY_NATIVE_PROJECTS_QA to temporary native project copies")
        }
        let source = URL(fileURLWithPath: input).resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard source.path.hasPrefix(temporary.path + "/") else {
            throw WSSDocumentError.invalid("QA inputs must be temporary copies")
        }
        let helper = LibraryRestoreTests()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let folders = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("scene.wss.json").path)
        }
        XCTAssertEqual(folders.count, 5)
        let store = ManagedWallpaperStore(storage: helper.fixture.storage)
        var items: [Wallpaper] = []
        var documents: [UUID: WSSSceneDocumentV1] = [:]
        for folder in folders {
            let item = try await store.importWallpaper(folder, existing: items)
            items.append(item)
            let project = try await WSSEditorProjectLoader().load(item)
            documents[item.id] = project.document
            XCTAssertEqual(
                try JSONDecoder().decode(
                    WSSSceneDocumentV1.self,
                    from: project.document.encoded()), project.document)
            let document = WSSEditorDocument(project: project)
            await document.waitForPreview()
            XCTAssertNil(document.previewError)
            document.close()
        }
        try helper.fixture.save(items)
        helper.fixture.defaults.set(false, forKey: "conserve")
        helper.fixture.defaults.set(false, forKey: "pauseOnBattery")
        helper.fixture.defaults.set(false, forKey: "allDisplays")
        helper.fixture.defaults.set(
            SceneRenderResolution.standard.rawValue,
            forKey: SceneRenderResolution.preferenceKey)
        let library = Library(storage: helper.fixture.storage, defaults: helper.fixture.defaults)
        defer { library.stop() }
        for item in items {
            library.apply(item)
            _ = try await WSSNativeSceneTests().running(library)
            library.stop()
        }
        let archive = try helper.backup()
        let prepared = try await helper.prepare(archive)
        let receipt = try LibraryRestoreTransaction(
            root: helper.target,
            preferenceDomain: helper.fixture.suite
        ).publish(
            prepared,
            quiescence: RestoreRuntimeQuiescence(callerGuaranteesQuiescentRuntime: true))
        XCTAssertFalse(receipt.cleanupPending)
        let restored = try ManagedWallpaperStore(
            storage: helper.target.appendingPathComponent("library.json")
        ).load()
        XCTAssertEqual(Set(restored.map(\.id)), Set(items.map(\.id)))
        for item in restored {
            let project = try await WSSEditorProjectLoader().load(item)
            XCTAssertEqual(project.document, documents[item.id])
        }
    }
}
