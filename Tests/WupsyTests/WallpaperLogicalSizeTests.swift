import Darwin
import XCTest

@testable import Wupsy

final class WallpaperLogicalSizeTests: XCTestCase {
    var fixture: WSSNativeSceneTests!
    var root: URL { fixture.root }
    override func setUpWithError() throws {
        fixture = WSSNativeSceneTests()
        try fixture.setUpWithError()
    }
    override func tearDownWithError() throws { try fixture.tearDownWithError() }
    func write(_ name: String, _ bytes: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }
    func managed(_ category: String, entry: String, kind: WallpaperKind) throws -> Wallpaper {
        let project = root.appendingPathComponent("Wallpapers/" + category + "/Owned")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return Wallpaper(
            title: "Owned", path: project.appendingPathComponent(entry).path,
            root: project.path, kind: kind,
            managed: .init(directory: category + "/Owned", entry: entry))
    }
    func testSingleFilesUseStoredBytesAndIgnoreNeighbors() throws {
        for (ext, kind) in [
            ("png", WallpaperKind.image), ("mp4", .video), ("gif", .web),
        ] {
            let url = try write("single." + ext, Data(repeating: 7, count: 1234))
            _ = try write("cache/large-" + ext, Data(repeating: 0, count: 10000))
            let item = Wallpaper(title: ext, path: url.path, root: root.path, kind: kind)
            XCTAssertEqual(try WallpaperLogicalSize.measure(item), 1234)
        }
    }
    func native() throws -> (Wallpaper, Int64) {
        var doc = fixture.document(clouds: true, mask: true)
        var layers = doc["layers"] as! [[String: Any]]
        var vector = layers[0]
        vector["effects"] = [
            [
                "type": "flow",
                "flowMap": [
                    "format": WSSVectorFieldAsset.fileFormat, "version": 1,
                    "asset": "assets/a.wssvf",
                ],
                "speed": 30, "strength": 6,
            ]
        ]
        var flow = layers[0]
        flow["effects"] = [
            [
                "type": "flow",
                "flowMap": [
                    "format": "wss-flow-rgba8", "version": 1, "asset": "assets/flow.png",
                ],
                "speed": 1, "strength": 1,
            ]
        ]
        layers += [vector, flow]
        doc["layers"] = layers
        let folder = try fixture.fixture(doc)
        let vectorBytes = try WSSFlowTestSupport().field(.zero).encodedNative()
        try vectorBytes.write(to: folder.appendingPathComponent("assets/a.wssvf"))
        let flowBytes = try fixture.png()
        try flowBytes.write(to: folder.appendingPathComponent("assets/flow.png"))
        let entry = folder.appendingPathComponent("scene.wss.json")
        let item = Wallpaper(
            title: "WSS", path: entry.path, root: folder.path, kind: .scene, sceneSource: .nativeWSS
        )
        let expected = try [
            "scene.wss.json", "assets/base.png", "assets/mask.png", "assets/a.wssvf",
            "assets/flow.png",
        ].reduce(Int64(0)) {
            $0 + Int64(try Data(contentsOf: folder.appendingPathComponent($1)).count)
        }
        return (item, expected)
    }
    func testWSSUsesUniqueSavedReferencesOnly() throws {
        let (item, expected) = try native()
        let folder = URL(fileURLWithPath: item.root)
        for name in ["old-cow.png", "cache", ".save-temp", "draft", "VisualTests"] {
            try Data(repeating: 9, count: 999).write(to: folder.appendingPathComponent(name))
        }
        XCTAssertEqual(try WallpaperLogicalSize.measure(item), expected)
        let manifest = try WSSSceneDocumentV1.load(entry: item.url, root: folder)
        XCTAssertEqual(manifest.referencedPaths.count, 4)  // base used by all three layers
    }
    func testWSSMissingUnsafeAndSymlinkedResourcesAreUnavailable() async throws {
        let (item, _) = try native()
        let asset = URL(fileURLWithPath: item.root).appendingPathComponent("assets/base.png")
        try FileManager.default.removeItem(at: asset)
        XCTAssertThrowsError(try WallpaperLogicalSize.measure(item))
        let missing = await WallpaperLogicalSize.read(item)
        XCTAssertNil(missing)
        let outside = try write("original.png", Data(repeating: 1, count: 999))
        try FileManager.default.createSymbolicLink(at: asset, withDestinationURL: outside)
        XCTAssertThrowsError(try WallpaperLogicalSize.measure(item))
        try FileManager.default.removeItem(at: asset)
        let bytes = try Data(contentsOf: item.url)
        let unsafe = String(decoding: bytes, as: UTF8.self).replacingOccurrences(
            of: "assets/base.png", with: "../original.png")
        try Data(unsafe.utf8).write(to: item.url)
        XCTAssertThrowsError(try WallpaperLogicalSize.measure(item))
        let details = await MediaDetails.read(item)
        XCTAssertTrue(details.size.isEmpty)
        try bytes.write(to: item.url)
        XCTAssertEqual(mkfifo(asset.path, 0o600), 0)
        XCTAssertThrowsError(try WallpaperLogicalSize.measure(item))
        try FileManager.default.removeItem(at: asset)
        let assets = asset.deletingLastPathComponent()
        try FileManager.default.removeItem(at: assets)
        try FileManager.default.createSymbolicLink(at: assets, withDestinationURL: root)
        XCTAssertThrowsError(try WallpaperLogicalSize.measure(item))
        try FileManager.default.removeItem(at: item.url)
        try FileManager.default.createSymbolicLink(at: item.url, withDestinationURL: outside)
        XCTAssertThrowsError(try WallpaperLogicalSize.measure(item))
    }
    func testManagedWebCountsCompleteExclusiveCopies() throws {
        for (category, kind, entry) in [
            ("Web", WallpaperKind.web, "index.html")
        ] {
            let item = try managed(category, entry: entry, kind: kind)
            let base = URL(fileURLWithPath: item.root)
            var total: Int64 = 0
            for (name, content) in [
                (entry, "<link href='https://example.invalid/remote.css'>"),
                ("local.css", "body{}"), ("scripts/main.js", "local()"), ("images/a.png", "image"),
                ("fonts/a.woff", "font"),
            ] {
                let bytes = Data(content.utf8)
                _ = try write(
                    base.appendingPathComponent(name).path.replacingOccurrences(
                        of: root.path + "/", with: ""), bytes)
                total += Int64(bytes.count)
            }
            _ = try write(
                "Wallpapers/" + category + "/Other/foreign", Data(repeating: 9, count: 999))
            _ = try write("Caches/foreign", Data(repeating: 9, count: 999))
            XCTAssertEqual(try WallpaperLogicalSize.measure(item), total)
        }
    }
    func testManagedTreesRejectLinksSpecialFilesAndBadBoundaries() throws {
        for category in ["Web"] {
            let kind: WallpaperKind = .web
            let item = try managed(category, entry: "entry.html", kind: kind)
            try Data("entry".utf8).write(to: item.url)
            let child = URL(fileURLWithPath: item.root).appendingPathComponent("unexpected")
            try FileManager.default.createSymbolicLink(at: child, withDestinationURL: root)
            XCTAssertThrowsError(try WallpaperLogicalSize.measure(item))
            try FileManager.default.removeItem(at: child)
            XCTAssertEqual(mkfifo(child.path, 0o600), 0)
            XCTAssertThrowsError(try WallpaperLogicalSize.measure(item))
            try FileManager.default.removeItem(at: child)
            var escape = item
            escape.managed?.entry = "../outside"
            XCTAssertThrowsError(try WallpaperLogicalSize.measure(escape))
            var boundary = item
            boundary.root = root.path
            XCTAssertThrowsError(try WallpaperLogicalSize.measure(boundary))
            try FileManager.default.removeItem(at: item.url)
            XCTAssertThrowsError(try WallpaperLogicalSize.measure(item))
        }
    }
    func testExternalMediaAndWebUseEntryFallbackOnly() throws {
        _ = try write("neighbor/big", Data(repeating: 8, count: 10000))
        for kind in [WallpaperKind.image, .web] {
            let url = try write("entry-\(kind.rawValue).html", Data("entry".utf8))
            let item = Wallpaper(title: "historical", path: url.path, root: root.path, kind: kind)
            XCTAssertEqual(try WallpaperLogicalSize.measure(item), 5)
        }
    }
    func testCheckedAdditionRejectsOverflowAndNegativeMetadata() throws {
        XCTAssertEqual(try WallpaperLogicalSize.adding(Int64.max - 1, 1), Int64.max)
        XCTAssertThrowsError(try WallpaperLogicalSize.adding(Int64.max, 1))
        XCTAssertThrowsError(try WallpaperLogicalSize.adding(0, -1))
    }
}
