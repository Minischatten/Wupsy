import XCTest

@testable import Wupsy

@MainActor final class OverviewActionsTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }
    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path))
    }

    func testSharedActionsAndNavigationWiring() throws {
        let view = try source("Sources/Wupsy/LibraryView.swift")
        let overview = try source("Sources/Wupsy/StudioOverview.swift")
        let actions = try source("Sources/Wupsy/WallpaperActions.swift")
        XCTAssertTrue(view.contains("WallpaperActions(importWallpaper: library.importFiles)"))
        XCTAssertTrue(
            overview.contains(
                "importWallpaper: importWallpaper, onFirstSave: revealWallpaper"))
        XCTAssertTrue(actions.contains("await editors.newWallpaper(onFirstSave: onFirstSave)"))
        XCTAssertFalse(actions.contains("page ="))
        XCTAssertTrue(view.contains("library.importFiles(onSuccess: revealWallpaper)"))
        XCTAssertTrue(view.contains("library.selected = id\n        page = .wallpapers"))
        XCTAssertTrue(
            view.contains("search = \"\"\n        filter = .all\n        favoritesOnly = false"))
        XCTAssertLessThan(
            try XCTUnwrap(actions.range(of: "ProductText.createWallpaper")).lowerBound,
            try XCTUnwrap(actions.range(of: "ProductText.addWallpaper")).lowerBound)
        XCTAssertTrue(actions.contains("systemImage: \"plus\""))
    }

    func testImportCompletionOnlyReportsPublishedItems() async throws {
        let helper = ManagedLibraryTests()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let domain = "overview-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let library = Library(
            storage: helper.store.storage, defaults: defaults, restoreOnLaunch: false)
        defer { library.stop() }
        var completions: [UUID] = []
        library.importURLs([]) { completions.append($0) }
        while library.importing { await Task.yield() }
        XCTAssertTrue(completions.isEmpty)
        library.importURLs([helper.root.appendingPathComponent("missing.pkg")]) {
            completions.append($0)
        }
        while library.importing { await Task.yield() }
        XCTAssertTrue(completions.isEmpty)
        XCTAssertNotNil(library.importFailureReport)
        library.importURLs([try helper.nativeFolder()]) { completions.append($0) }
        while library.importing { await Task.yield() }
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(library.items.count, 1)
        XCTAssertEqual(library.selected, completions.first)
        XCTAssertEqual(library.items.first?.id, completions.first)
        let importer = try source("Sources/Wupsy/Library.swift")
        XCTAssertTrue(importer.contains("guard panel.runModal() == .OK else { return }"))
    }

    func testBuildMetadataDefaults() throws {
        XCTAssertEqual(
            try source("VERSION").trimmingCharacters(in: .whitespacesAndNewlines), "0.5.0")
        XCTAssertTrue(
            try source("scripts/config.sh").contains("BUILD_NUMBER=\"${BUILD_NUMBER:-1}\""))
        XCTAssertTrue(
            try source("scripts/build-app.sh").contains(
                "<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>"))
    }
}
