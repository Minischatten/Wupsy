import AppKit
import XCTest

@testable import Wupsy

@MainActor final class SlimeImportReproductionTests: XCTestCase {
    func testDirectDropImportMatrixWithIsolatedLibraries() async throws {
        let helper = ManagedLibraryTests()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let files = FileManager.default
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Test-Wallpaper/WSS-Slime-Direct-Drop-v1")
        let source = helper.root.appendingPathComponent("DirectDrop")
        try files.copyItem(at: fixture, to: source)
        let manifest = source.appendingPathComponent("scene.wss.json")
        let assets = source.appendingPathComponent("assets", isDirectory: true)
        let image = assets.appendingPathComponent("panels.png")
        let independentImage = assets.appendingPathComponent("Independent.png")
        try files.copyItem(at: image, to: independentImage)
        let broken = helper.root.appendingPathComponent("MissingAsset")
        try files.createDirectory(at: broken, withIntermediateDirectories: true)
        let brokenManifest = broken.appendingPathComponent("scene.wss.json")

        let secondAsset = assets.appendingPathComponent("second.png")
        try files.copyItem(at: image, to: secondAsset)
        var model = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        var layers = try XCTUnwrap(model["layers"] as? [[String: Any]])
        var secondLayer = layers[0]
        secondLayer["image"] = "assets/second.png"
        layers.insert(secondLayer, at: 1)
        model["layers"] = layers
        try JSONSerialization.data(withJSONObject: model).write(to: manifest)

        let otherProject = helper.root.appendingPathComponent("OtherProject")
        try files.copyItem(at: fixture, to: otherProject)
        let invalid = helper.root.appendingPathComponent("Invalid", isDirectory: true)
        try files.createDirectory(at: invalid, withIntermediateDirectories: true)
        let invalidManifest = invalid.appendingPathComponent("scene.wss.json")
        try Data("Invalid manifest".utf8).write(to: invalidManifest)
        let unsupported = helper.root.appendingPathComponent("Unsupported", isDirectory: true)
        try files.createDirectory(at: unsupported, withIntermediateDirectories: true)
        let brokenAssets = broken.appendingPathComponent("assets", isDirectory: true)
        try files.createDirectory(at: brokenAssets, withIntermediateDirectories: true)
        let survivingComponent = brokenAssets.appendingPathComponent("second.png")
        try files.copyItem(at: image, to: survivingComponent)
        try Data(contentsOf: manifest).write(to: brokenManifest)

        let sourceBefore = try helper.snapshot(source)
        let cases: [(name: String, inputs: [URL], kinds: [WallpaperKind], failed: [String])] = [
            ("Folder", [source], [.scene], []),
            ("Manifest", [manifest], [.scene], []),
            ("AssetsFolder", [manifest, assets], [.scene], []),
            ("ActualFiles", [manifest, image], [.scene], []),
            ("SeveralAssets", [image, secondAsset, manifest], [.scene], []),
            ("FolderAndParts", [image, manifest, source, assets], [.scene], []),
            ("ReverseFolderAndParts", [assets, source, manifest, image], [.scene], []),
            ("AssetOnly", [image], [.image], []),
            ("Independent", [manifest, independentImage], [.scene, .image], []),
            ("IndependentImages", [image, independentImage], [.image, .image], []),
            ("SeveralProjects", [otherProject, image, manifest], [.scene, .scene], []),
            ("Mixed", [unsupported, manifest], [.scene], ["Unsupported"]),
            (
                "Missing", [brokenManifest, brokenAssets, survivingComponent], [],
                [
                    "MissingAsset/scene.wss.json", "MissingAsset/assets",
                    "MissingAsset/assets/second.png",
                ]
            ),
            ("Invalid", [invalidManifest], [], ["Invalid/scene.wss.json"]),
        ]
        for variant in cases {
            let storage = helper.root.appendingPathComponent(variant.name + "/library.json")
            let suite = "SlimeImportMatrix." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let library = Library(storage: storage, defaults: defaults, restoreOnLaunch: false)
            defer { library.stop() }
            var success: UUID?
            library.importURLs(variant.inputs) { success = $0 }
            try await helper.wait(library)
            XCTAssertEqual(library.items.map(\.kind), variant.kinds, variant.name)
            XCTAssertEqual(
                library.importFailureReport?.failures.map(\.sourceName) ?? [], variant.failed,
                variant.name)
            XCTAssertEqual(success, library.items.last?.id, variant.name)
            let restarted = Library(storage: storage, defaults: defaults, restoreOnLaunch: false)
            defer { restarted.stop() }
            XCTAssertEqual(restarted.items.map(\.id), library.items.map(\.id), variant.name)

            if variant.name == "Mixed" {
                let report = try XCTUnwrap(library.importFailureReport)
                let failure = try XCTUnwrap(report.failures.first)
                XCTAssertTrue(failure.technicalDetails.contains("unsupportedSource"))
                XCTAssertTrue(failure.technicalDetails.contains("unsupported"))
                XCTAssertEqual(report.successes.count, 1)
                XCTAssertTrue(report.successes[0].contains("DirectDrop/scene.wss.json"))
                _ = try XCTUnwrap(NSScreen.main)
                let item = try XCTUnwrap(restarted.items.first)
                let outcome = await restarted.apply(item).outcome
                guard case .accepted = outcome else {
                    XCTFail("Reopened scene could not be applied: \(outcome)")
                    continue
                }
                XCTAssertEqual(restarted.active?.id, item.id)
                restarted.stop()
            }
            if variant.name == "Missing" || variant.name == "Invalid" {
                let report = try XCTUnwrap(library.importFailureReport)
                let failure = try XCTUnwrap(report.failures.first)
                XCTAssertTrue(report.successes.isEmpty)
                XCTAssertFalse(files.fileExists(atPath: storage.path))
                if variant.name == "Missing" {
                    XCTAssertTrue(failure.technicalDetails.contains("invalidResource"))
                    XCTAssertTrue(failure.technicalDetails.contains("panels.png"))
                    XCTAssertTrue(
                        report.failures.last?.technicalDetails.contains("projectComponent") == true)
                } else {
                    XCTAssertTrue(failure.technicalDetails.contains("invalidProject"))
                }
            }

            for item in restarted.items where item.kind == .scene {
                let asset = URL(fileURLWithPath: item.root).appendingPathComponent(
                    "assets/panels.png")
                XCTAssertEqual(try Data(contentsOf: asset), try Data(contentsOf: image))
                let project = try await WSSEditorProjectLoader().load(item)
                if project.document.referencedPaths.contains("assets/second.png") {
                    let second = URL(fileURLWithPath: item.root).appendingPathComponent(
                        "assets/second.png")
                    XCTAssertEqual(try Data(contentsOf: second), try Data(contentsOf: secondAsset))
                }
                let doc = WSSEditorDocument(project: project)
                defer { doc.close() }
                try doc.addSlime()
                XCTAssertTrue(doc.isDirty)
                let prepared = try await ScenePlayback.prepare(for: item)
                XCTAssertEqual(prepared.resources.scene.layers.count, project.scene.layers.count)
            }

            XCTAssertEqual(try helper.snapshot(source), sourceBefore, variant.name)
            let store = ManagedWallpaperStore(storage: storage)
            var published: Set<String> = []
            for root in ["WSS", "Media", "Web"] {
                let area = store.wallpaperRoot.appendingPathComponent(root)
                if files.fileExists(atPath: area.path) {
                    for directory in try files.contentsOfDirectory(atPath: area.path) {
                        published.insert(
                            area.appendingPathComponent(directory).standardizedFileURL.path)
                    }
                }
            }
            XCTAssertEqual(
                published,
                Set(restarted.items.map { URL(fileURLWithPath: $0.root).standardizedFileURL.path }))
            if files.fileExists(atPath: store.wallpaperRoot.path) {
                XCTAssertFalse(
                    try files.contentsOfDirectory(atPath: store.wallpaperRoot.path).contains {
                        $0.hasPrefix(".import-")
                    })
            }
        }
    }
    func testDropProvidersGroupProjectResources() async throws {
        let helper = ManagedLibraryTests()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let manifest = try helper.nativeSource()
        let asset = manifest.deletingLastPathComponent().appendingPathComponent("assets/base.png")
        let suite = "SlimeImportDrop." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = Library(
            storage: helper.store.storage, defaults: defaults, restoreOnLaunch: false)
        defer { library.stop() }

        XCTAssertTrue(
            library.importDroppedFiles(
                [asset, manifest].map { NSItemProvider(object: $0 as NSURL) }))
        for _ in 0..<200 where library.items.isEmpty && library.importFailureReport == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await helper.wait(library)
        XCTAssertEqual(library.items.map(\.kind), [.scene])
        XCTAssertNil(library.importFailureReport)
    }

}
