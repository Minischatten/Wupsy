import XCTest

@testable import Wupsy

// Synthetic folders and an injected library root only.
final class WebImportTests: XCTestCase {
    var root: URL!
    var store: ManagedWallpaperStore!
    let files = FileManager.default
    override func setUpWithError() throws {
        root = files.temporaryDirectory.appendingPathComponent(
            "WupsyWebImport-" + UUID().uuidString
        ).resolvingSymlinksInPath()
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        store = ManagedWallpaperStore(storage: root.appendingPathComponent("Support/library.json"))
    }
    override func tearDownWithError() throws { try files.removeItem(at: root) }

    @discardableResult
    func write(_ path: String, _ text: String = "x") throws -> URL {
        let url = root.appendingPathComponent(path)
        try files.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    func mixedFolder() throws -> URL {
        try write("Mixed/standalone.html", "<p>standalone</p>")
        try write(
            "Mixed/index.html",
            "<link rel='stylesheet' href='style.css'><img src='images/p.svg'><script src='app.js'></script>"
        )
        try write("Mixed/style.css")
        try write("Mixed/app.js")
        try write("Mixed/images/p.svg")
        try write("Mixed/private-notes.txt")
        try write("Mixed/Other/unrelated.bin")
        return root.appendingPathComponent("Mixed")
    }
    func contents(_ item: Wallpaper) throws -> [String] {
        try XCTUnwrap(files.subpathsOfDirectory(atPath: item.root) as [String]?).sorted()
    }

    func testSingleHTMLFileImportsOnlyThatFile() async throws {
        let folder = try mixedFolder()
        let item = try await store.importWallpaper(
            folder.appendingPathComponent("standalone.html"), existing: [])
        XCTAssertEqual(try contents(item), ["standalone.html"])
    }
    func testUnrelatedSymlinkBesideSelectedFileDoesNotBlockImport() async throws {
        let folder = try mixedFolder()
        let outside = try write("outside/secret.txt")
        try files.createSymbolicLink(
            at: folder.appendingPathComponent("Other/link"), withDestinationURL: outside)
        let item = try await store.importWallpaper(
            folder.appendingPathComponent("standalone.html"), existing: [])
        XCTAssertEqual(try contents(item), ["standalone.html"])
    }

    func testSingleHTMExtensionAndUppercaseImportOnlyThatFile() async throws {
        for name in ["page.htm", "UPPER.HTML"] {
            try write("Single/\(name)", "<p>\(name)</p>")
        }
        try write("Single/unrelated.txt")
        var existing: [Wallpaper] = []
        for name in ["page.htm", "UPPER.HTML"] {
            let source = root.appendingPathComponent("Single/\(name)")
            let item = try await store.importWallpaper(source, existing: existing)
            existing.append(item)
            XCTAssertEqual(item.kind, .web)
            XCTAssertTrue(item.managed!.directory.hasPrefix("Web/"))
            XCTAssertEqual(item.managed?.entry, name)
            XCTAssertEqual(try contents(item), [name])
            XCTAssertEqual(try Data(contentsOf: item.url), try Data(contentsOf: source))
        }
    }
    func testSingleFileFromCrowdedFolderImportsOnlyThatFile() async throws {
        for number in 0..<300 { try write("Crowded/file-\(number).bin") }
        let source = try write("Crowded/page.html")
        let item = try await store.importWallpaper(source, existing: [])
        XCTAssertEqual(try contents(item), ["page.html"])
        XCTAssertEqual(
            try files.contentsOfDirectory(atPath: root.appendingPathComponent("Crowded").path)
                .count, 301)
    }
    func testSelectedSymlinkStaysRejected() async throws {
        let target = try write("Links/real.html")
        let link = root.appendingPathComponent("Links/link.html")
        try files.createSymbolicLink(at: link, withDestinationURL: target)
        await fails { _ = try await self.store.importWallpaper(link, existing: []) }
        XCTAssertFalse(files.fileExists(atPath: store.storage.path))
    }
    func testProjectFolderKeepsResourcesAndSurvivesReload() async throws {
        let folder = try mixedFolder()
        let item = try await store.importWallpaper(folder, existing: [])
        XCTAssertEqual(item.managed?.entry, "index.html")
        XCTAssertEqual(
            try contents(item), try files.subpathsOfDirectory(atPath: folder.path).sorted())
        let reloaded = try XCTUnwrap(
            ManagedWallpaperStore(storage: store.storage).load().first)
        XCTAssertEqual(reloaded, item)
        for path in try files.subpathsOfDirectory(atPath: folder.path) {
            var isDirectory: ObjCBool = false
            _ = files.fileExists(
                atPath: folder.appendingPathComponent(path).path, isDirectory: &isDirectory)
            if !isDirectory.boolValue {
                XCTAssertEqual(
                    try Data(
                        contentsOf: URL(fileURLWithPath: reloaded.root).appendingPathComponent(path)
                    ),
                    try Data(contentsOf: folder.appendingPathComponent(path)), path)
            }
        }
    }
    func testProjectFolderRejectsInternalExternalAndSelectedSymlinks() async throws {
        let folder = try mixedFolder()
        let outside = try write("outside/secret.txt")
        for destination in [
            outside, folder.appendingPathComponent("style.css"),
            root.appendingPathComponent("outside"),
        ] {
            let link = folder.appendingPathComponent("images/link")
            try files.createSymbolicLink(at: link, withDestinationURL: destination)
            await fails { _ = try await self.store.importWallpaper(folder, existing: []) }
            try files.removeItem(at: link)
        }
        let alias = root.appendingPathComponent("alias")
        try files.createSymbolicLink(at: alias, withDestinationURL: folder)
        await fails { _ = try await self.store.importWallpaper(alias, existing: []) }
        // An index.html that links elsewhere is rejected too.
        try write("Linked/other.txt")
        try files.createSymbolicLink(
            at: root.appendingPathComponent("Linked/index.html"), withDestinationURL: outside)
        await fails {
            _ = try await self.store.importWallpaper(
                self.root.appendingPathComponent("Linked"), existing: [])
        }
        XCTAssertFalse(files.fileExists(atPath: store.storage.path))
    }
    func testStorageFailuresRollBackSingleFileAndFolderImports() async throws {
        let folder = try mixedFolder()
        for source in [folder.appendingPathComponent("standalone.html"), folder] {
            for stage in [ManagedWallpaperStore.ImportStage.sourcePublished, .libraryPersistence] {
                let failing = ManagedWallpaperStore(storage: store.storage) {
                    if $0 == stage { throw CocoaError(.fileWriteOutOfSpace) }
                }
                await fails { _ = try await failing.importWallpaper(source, existing: []) }
                XCTAssertFalse(files.fileExists(atPath: store.storage.path))
                XCTAssertEqual(
                    try files.contentsOfDirectory(atPath: store.wallpaperRoot.path), ["Web"])
                XCTAssertEqual(
                    try files.contentsOfDirectory(
                        atPath: store.wallpaperRoot.appendingPathComponent("Web").path), [])
            }
        }
        XCTAssertEqual(try files.subpathsOfDirectory(atPath: folder.path).count, 9)
    }
    func testExistingWebWallpaperIsLeftUntouchedByLaterImports() async throws {
        let folder = try mixedFolder()
        let old = try await store.importWallpaper(folder, existing: [])
        let before = try contents(old)
        let single = try await store.importWallpaper(
            folder.appendingPathComponent("index.html"), existing: [old])
        XCTAssertEqual(try contents(single), ["index.html"])
        XCTAssertNotEqual(single.root, old.root)
        XCTAssertEqual(try contents(old), before)
        XCTAssertEqual(try store.load(), [old, single])
    }
    private func explanations(_ source: URL) async -> [String] {
        do {
            _ = try await store.importWallpaper(source, existing: [])
            XCTFail("Expected rejection: \(source.lastPathComponent)")
            return []
        } catch {
            return ["en", "de"].flatMap { language -> [String] in
                let value = ImportFailurePresentation(
                    source: source, error: error, language: language)
                return [value.title, value.explanation]
            }
        }
    }
    private func expected(_ title: ImportText, _ reason: ImportText) -> [String] {
        ["en", "de"].flatMap {
            [title.localized(language: $0), reason.localized(language: $0)]
        }
    }
    func testWebFolderWithoutTopLevelIndexNamesTheRequirement() async throws {
        try write("TopPage/page.html")
        try write("TopHTM/index.htm")
        try write("Nested/dist/index.html")
        for name in ["TopPage", "TopHTM", "Nested"] {
            let shown = await explanations(root.appendingPathComponent(name))
            XCTAssertEqual(shown, expected(.failed, .webFolderMissingIndex), name)
        }
        XCTAssertFalse(files.fileExists(atPath: store.storage.path))
    }
    func testUnrelatedFolderIsNotCalledABrokenWebProject() async throws {
        try files.createDirectory(
            at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        try write("Photos/picture.png")
        try write("Photos/notes/.hidden.html")
        try write("Deep/a/b/page.html")
        for name in ["Empty", "Photos", "Deep"] {
            let shown = await explanations(root.appendingPathComponent(name))
            XCTAssertEqual(shown, expected(.failed, .folderWithoutProject), name)
        }
        let missing = await explanations(root.appendingPathComponent("gone.html"))
        for text: ImportText in [.webFolderMissingIndex, .folderWithoutProject] {
            XCTAssertFalse(missing.contains(text.localized(language: "en")))
        }
    }
    @MainActor func testImportPanelKeepsShortLocalizedMessageAndSelectionOptions() {
        for (language, message) in [
            ("en", "Select files or project folders to import."),
            ("de", "Wähle Dateien oder Projektordner zum Importieren aus."),
        ] {
            let panel = Library.importPanel(language: language)
            XCTAssertEqual(panel.message, message)
            XCTAssertTrue(panel.canChooseFiles)
            XCTAssertTrue(panel.canChooseDirectories)
            XCTAssertTrue(panel.allowsMultipleSelection)
        }
    }
    func testImportHintsAreLocalized() {
        for text: ImportText in [
            .panelHint, .singleHTMLNotice, .webFolderMissingIndex, .folderWithoutProject,
        ] {
            XCTAssertNotEqual(text.localized(language: "en"), text.localized(language: "de"))
        }
    }

    @MainActor func importThroughLibrary(_ urls: [URL]) async throws -> Library {
        let suite = "WupsyWebImportTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "manuallyPaused")
        let library = Library(storage: store.storage, defaults: defaults)
        library.importURLs(urls)
        for _ in 0..<1000 where library.importing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(library.importing)
        return library
    }
    @MainActor func testSingleHTMLImportShowsNoticeButFolderImportDoesNot() async throws {
        let folder = try mixedFolder()
        let single = try await importThroughLibrary([
            folder.appendingPathComponent("standalone.html")
        ])
        XCTAssertEqual(single.message, ImportText.singleHTMLNotice.text)
        XCTAssertNil(single.importFailureReport)
        single.stop()
        let project = try await importThroughLibrary([folder])
        XCTAssertNil(project.message)
        XCTAssertNil(project.importFailureReport)
        project.stop()
    }
    @MainActor func testSeveralIndependentItemsStaySeparateAndKeepNoticeInReport() async throws {
        let folder = try mixedFolder()
        try write("Second/page.htm")
        let broken = try write("broken.pkg")
        let library = try await importThroughLibrary([
            folder.appendingPathComponent("standalone.html"),
            root.appendingPathComponent("Second/page.htm"),
            folder.appendingPathComponent("index.html"), broken,
        ])
        XCTAssertEqual(
            try library.items.map { try contents($0) }.sorted { $0[0] < $1[0] },
            [["index.html"], ["page.htm"], ["standalone.html"]])
        XCTAssertNil(library.message)
        XCTAssertEqual(library.importFailureReport?.failures.count, 1)
        XCTAssertEqual(library.importFailureReport?.note, ImportText.singleHTMLNotice.text)
        library.stop()
    }

    @MainActor func testLibraryReportsFolderCasesWithoutNoticeOrAlert() async throws {
        try write("Web/page.html")
        try write("Plain/readme.txt")
        let library = try await importThroughLibrary([
            URL(fileURLWithPath: root.appendingPathComponent("Web").path, isDirectory: true),
            root.appendingPathComponent("Plain"),
        ])
        XCTAssertNil(library.message)
        XCTAssertNil(library.importFailureReport?.note)
        XCTAssertEqual(
            library.importFailureReport?.failures.map(\.explanation).sorted(),
            [ImportText.webFolderMissingIndex.text, ImportText.folderWithoutProject.text].sorted())
        library.stop()
    }

    private func fails(
        _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("Expected controlled failure", file: file, line: line)
        } catch {}
    }
}
