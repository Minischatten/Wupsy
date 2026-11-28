import WebKit
import XCTest

@testable import Wupsy

// Loads imported pages through the desktop Renderer; no productive library is read.
@MainActor final class WebImportRenderingTests: XCTestCase {
    var root: URL!
    var store: ManagedWallpaperStore!
    let files = FileManager.default
    override func setUp() async throws {
        root = files.temporaryDirectory.appendingPathComponent(
            "WupsyWebRender-" + UUID().uuidString
        ).resolvingSymlinksInPath()
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        store = ManagedWallpaperStore(storage: root.appendingPathComponent("Support/library.json"))
    }
    override func tearDown() async throws { try files.removeItem(at: root) }
    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try files.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    let green =
        "<svg xmlns='http://www.w3.org/2000/svg' width='8' height='8'><rect width='8' height='8' fill='#0f0'/></svg>"

    func load(_ item: Wallpaper) async throws -> (Renderer, WKWebView) {
        let screen = try XCTUnwrap(NSScreen.main)
        let renderer = Renderer(
            maintenance: MaintenanceCoordinator(), wallpaper: item, screen: screen,
            onError: { XCTFail($0) })
        let view = try XCTUnwrap(renderer.web)
        for _ in 0..<500 {
            if !view.isLoading,
                try await view.evaluateJavaScript("document.readyState") as? String == "complete"
            {
                return (renderer, view)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Web wallpaper did not finish loading")
        return (renderer, view)
    }
    func value(_ view: WKWebView, _ script: String) async throws -> String {
        String(describing: try await view.evaluateJavaScript(script) ?? "nil")
    }

    func testStandaloneFileRendersAndCannotReadSiblingFolders() async throws {
        try write(
            "Source/alone.html",
            """
            <style>body{background:rgb(0, 0, 255)}</style><p id='p'>alone</p>
            <img id='sibling' src='sibling.svg'><img id='source' src='../../../../Source/sibling.svg'>
            <script>document.getElementById('p').textContent = 'script ran'</script>
            """)
        try write("Source/sibling.svg", green)
        let item = try await store.importWallpaper(
            root.appendingPathComponent("Source/alone.html"), existing: [])
        let (renderer, view) = try await load(item)
        defer { renderer.stop() }
        let text = try await value(view, "document.getElementById('p').textContent")
        XCTAssertEqual(text, "script ran")
        let color = try await value(view, "getComputedStyle(document.body).backgroundColor")
        XCTAssertEqual(color, "rgb(0, 0, 255)")
        for id in ["sibling", "source"] {
            let width = try await value(view, "document.getElementById('\(id)').naturalWidth")
            XCTAssertEqual(width, "0", id)
        }
    }
    func testProjectFolderRendersLocalResourcesFromManagedCopy() async throws {
        try write(
            "Project/index.html",
            """
            <link rel='stylesheet' href='css/style.css'><p id='p'>waiting</p>
            <img id='image' src='images/green.svg'><img id='outside' src='../../../../outside.svg'>
            <script src='js/app.js'></script>
            """)
        try write("Project/css/style.css", "body{background:rgb(255, 0, 0)}")
        try write("Project/js/app.js", "document.getElementById('p').textContent = 'script ran'")
        try write("Project/images/green.svg", green)
        try write("outside.svg", green)
        let item = try await store.importWallpaper(
            root.appendingPathComponent("Project"), existing: [])
        try files.removeItem(at: root.appendingPathComponent("Project"))
        let reloaded = try XCTUnwrap(ManagedWallpaperStore(storage: store.storage).load().first)
        XCTAssertEqual(reloaded, item)
        let (renderer, view) = try await load(reloaded)
        defer { renderer.stop() }
        let text = try await value(view, "document.getElementById('p').textContent")
        XCTAssertEqual(text, "script ran")
        let color = try await value(view, "getComputedStyle(document.body).backgroundColor")
        XCTAssertEqual(color, "rgb(255, 0, 0)")
        let width = try await value(view, "document.getElementById('image').naturalWidth")
        XCTAssertEqual(width, "8")
        let outside = try await value(view, "document.getElementById('outside').naturalWidth")
        XCTAssertEqual(outside, "0")
    }
}
