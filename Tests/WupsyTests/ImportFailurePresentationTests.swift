import AppKit
import SwiftUI
import XCTest

@testable import Wupsy

final class ImportFailurePresentationTests: XCTestCase {
    var missingResource: WallpaperImportDiagnostic {
        .init(.invalidResource, file: "assets/missing.png")
    }
    let source = URL(fileURLWithPath: "/Volumes/Private/Wallpapers/Ocean/scene.wss.json")
    func testInternalInformationIsOnlyInRequestedTechnicalDetails() {
        let detail = "unverified W2 active scene\nadditional internal evidence"
        let value = ImportFailurePresentation(
            source: source,
            error: WallpaperImportDiagnostic(.invalidResource, detail: detail))
        XCTAssertTrue(value.technicalDetails.contains(detail))
        for forbidden in [
            "W1", "W2", "W3", "W6", "W7", "unverified", "external user-owned resources",
            "Supported scenes",
        ] {
            XCTAssertFalse(value.title.contains(forbidden))
            XCTAssertFalse(value.explanation.contains(forbidden))
        }
    }
    func testEveryCategoryHasAPublicMessageWithoutInterpolatingInternals() {
        let categories: [WallpaperImportDiagnostic.Category] = [
            .invalidProject, .invalidResource, .unsafePath, .resourceLimit, .storage, .publish,
            .rollback, .cleanup,
        ]
        for category in categories {
            let value = ImportFailurePresentation(
                source: source,
                error: WallpaperImportDiagnostic(
                    category, detail: "W7 external user-owned resources"))
            XCTAssertFalse(value.explanation.isEmpty)
            XCTAssertFalse((value.title + value.explanation).contains("W7"))
            XCTAssertFalse((value.title + value.explanation).contains("external user-owned"))
        }
    }
    func testRelativePathsAndMultilineEvidenceArePreserved() {
        let diagnostic = WallpaperImportDiagnostic(
            .invalidResource, file: "materials/tmp/mask.tex",
            detail: "TEX layout mismatch\nExpected bytes: 64\nActual bytes: 16")
        let value = ImportFailurePresentation(source: source, error: diagnostic, language: "de")
        XCTAssertEqual(
            value.technicalDetails,
            "Kategorie: invalidResource\nEinstufung: unsupported\nDatei: materials/tmp/mask.tex\nDetail: TEX layout mismatch\nExpected bytes: 64\nActual bytes: 16"
        )
    }
    func testProjectPathsBecomeRelativeAndUnrelatedPrivatePrefixesAreRedacted() {
        let diagnostic = WallpaperImportDiagnostic(
            .invalidResource,
            file: "/Volumes/Private/Wallpapers/Ocean/assets/mask.png",
            detail:
                "Read /Users/Another Person/Private Folder/mask.png; code=13\nNSFilePath=/private/var/folders/cache/file.json, reason=denied\nURL=file:///Volumes/Other%20Disk/Secret/image.png"
        )
        let value = ImportFailurePresentation(source: source, error: diagnostic, language: "de")
        XCTAssertTrue(value.technicalDetails.contains("Datei: assets/mask.png"))
        for path in [
            "/Users/", "/Volumes/", "/private/var/", "Another Person", "Private Folder",
            "Other%20Disk",
        ] {
            XCTAssertFalse(value.technicalDetails.contains(path))
            XCTAssertFalse(value.copyText.contains(path))
        }
        for evidence in ["mask.png", "file.json", "image.png", "code=13", "reason=denied"] {
            XCTAssertTrue(value.copyText.contains(evidence))
        }
    }
    func testRedactionKeepsInlineEvidenceAndMultipleResourceNames() {
        let diagnostic = WallpaperImportDiagnostic(
            .invalidResource,
            detail:
                "Read /Users/A/One Folder/first.png and /Volumes/Other/second.png failed with code 13"
        )
        let value = ImportFailurePresentation(source: source, error: diagnostic, language: "de")
        XCTAssertTrue(value.copyText.contains("first.png and"))
        XCTAssertTrue(value.copyText.contains("second.png failed with code 13"))
        XCTAssertFalse(value.copyText.contains("/Users/"))
        XCTAssertFalse(value.copyText.contains("/Volumes/"))
    }
    func testFallbackErrorIsPrivateAndDoesNotClaimInvalidWallpaper() {
        let value = ImportFailurePresentation(
            source: source,
            error: NSError(
                domain: "Synthetic", code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Cannot read /Users/Test/Private/file.json"]))
        XCTAssertFalse(value.title.contains("ungültig"))
        XCTAssertFalse(value.explanation.contains("/Users/"))
        XCTAssertFalse(value.copyText.contains("/Users/"))
        XCTAssertTrue(value.copyText.contains("file.json"))
    }
    @MainActor func testCopyWritesExactlyTheDisplayedDiagnosticToAnIsolatedPasteboard() {
        let value = ImportFailurePresentation(
            source: source, error: missingResource, language: "de")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        ImportFailureView.copy(value, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), value.copyText)
        XCTAssertTrue(pasteboard.types?.contains(.string) == true)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertFalse(pasteboard.types?.contains(.fileURL) == true)
    }

    @MainActor func testNativeDetailsButtonUnifiesLabelAndArrowWithoutAFocusRing() async throws {
        var expanded = false
        let failure = ImportFailurePresentation(
            source: source, error: missingResource, language: "de")
        let before = failure.copyText
        let appeared = expectation(description: "Details control appeared")
        let control = ImportDetailsButton(
            sourceName: failure.sourceName,
            isExpanded: Binding(get: { expanded }, set: { expanded = $0 }), language: "de")
        let host = NSHostingView(
            rootView: AnyView(control.fixedSize().onAppear { appeared.fulfill() }))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 70),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        await fulfillment(of: [appeared], timeout: 3)
        host.layoutSubtreeIfNeeded()
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let targets = buttons(host).filter { $0.title == "Details" }
        XCTAssertEqual(targets.count, 1)
        let button = try XCTUnwrap(targets.first)
        XCTAssertFalse(expanded)
        XCTAssertEqual(button.state, .off)
        XCTAssertFalse(button.isBordered)
        XCTAssertEqual(button.focusRingType, .none)
        XCTAssertTrue(window.makeFirstResponder(button))
        XCTAssertTrue(window.firstResponder === button)
        XCTAssertEqual(button.accessibilityLabel(), "Technische Details zu Ocean/scene.wss.json")
        XCTAssertEqual(button.accessibilityValueDescription(), "Eingeklappt")
        let cell = try XCTUnwrap(button.cell as? NSButtonCell)
        XCTAssertEqual(cell.highlightsBy, [])
        XCTAssertEqual(cell.showsStateBy, [])
        // Native cell geometry, no hard-coded screen/pixel coordinates. Both
        // title and arrow hit the same control and therefore the same action.
        for rect in [
            cell.imageRect(forBounds: button.bounds), cell.titleRect(forBounds: button.bounds),
        ] {
            XCTAssertFalse(rect.isEmpty)
            let point = button.convert(NSPoint(x: rect.midX, y: rect.midY), to: button.superview)
            XCTAssertTrue(button.hitTest(point) === button)
        }
        button.performClick(nil)
        XCTAssertTrue(expanded)
        host.rootView = AnyView(control.fixedSize())
        host.layoutSubtreeIfNeeded()
        let current = try XCTUnwrap(buttons(host).first { $0.title == "Details" })
        XCTAssertEqual(current.state, .on)
        _ = current.accessibilityPerformPress()
        XCTAssertFalse(expanded)
        XCTAssertEqual(failure.copyText, before)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        ImportFailureView.copy(failure, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), before)
    }

    @MainActor func testUnreadableFutureLibraryAndPlaylistAreNotOverwrittenByImportPresentation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryURL = root.appendingPathComponent("library.json")
        let playlistURL = root.appendingPathComponent("playlists.json")
        let id = UUID()
        let bytes = try JSONSerialization.data(withJSONObject: [
            [
                "id": id.uuidString, "title": "Future data", "kind": "scene",
                "sceneSource": "future-version", "ownership": "managed",
                "managed": ["directory": "WSS/" + id.uuidString, "entry": "scene.wss.json"],
            ]
        ])
        try bytes.write(to: libraryURL)
        var state = PlaylistCollectionState()
        state.definitions = [PlaylistDefinition(name: "Preserve IDs", wallpaperIDs: [id])]
        try WallpaperPlaylistStore(url: playlistURL).save(state)
        let playlistBytes = try Data(contentsOf: playlistURL)
        let suite = "UnreadableLibraryPreservation-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = Library(storage: libraryURL, defaults: defaults, restoreOnLaunch: false)
        defer { library.stop() }
        let playlists = WallpaperPlaylist(
            library: library, storage: playlistURL,
            defaults: defaults, restoreOnLaunch: false)
        defer { playlists.shutdown() }
        XCTAssertFalse(library.isLibraryReadable)
        XCTAssertNotNil(library.message)
        XCTAssertNotNil(playlists.error)
        library.importURLs([root.appendingPathComponent("not-present.pkg")])
        XCTAssertFalse(library.importing)
        XCTAssertNil(library.importFailureReport)
        XCTAssertEqual(try Data(contentsOf: libraryURL), bytes)
        XCTAssertEqual(try Data(contentsOf: playlistURL), playlistBytes)
    }

}
