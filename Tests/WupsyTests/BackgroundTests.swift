import AppKit
import XCTest

@testable import Wupsy

final class BackgroundTests: XCTestCase {
    @MainActor func testQuitPreservesWallpaperWhileStopClearsIt() async throws {
        let name = "WupsyBackgroundTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "manuallyPaused")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("wallpaper.png")
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        defaults.set(false, forKey: "pauseOnBattery")
        defaults.set(false, forKey: "conserve")
        let library = Library(
            storage: directory.appendingPathComponent("library.json"), defaults: defaults)
        XCTAssertTrue(library.manuallyPaused)
        let item = Wallpaper(
            title: "Paused test", path: file.path, root: directory.path, kind: .image)
        let request = library.apply(item)
        XCTAssertNil(defaults.string(forKey: "activeWallpaper"))
        library.manuallyPaused = false
        guard case .accepted = await request.outcome else {
            return XCTFail("Wallpaper was not accepted after resume")
        }
        XCTAssertEqual(defaults.string(forKey: "activeWallpaper"), item.id.uuidString)
        library.stop(preserveSelection: true)
        XCTAssertEqual(defaults.string(forKey: "activeWallpaper"), item.id.uuidString)
        library.stop()
        XCTAssertNil(defaults.string(forKey: "activeWallpaper"))
    }
}
