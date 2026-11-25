import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSImageReplacementTests: XCTestCase {
    private var helper: WSSDraftTests!
    private var store: ManagedWallpaperStore!
    private var suite: String!
    private var defaults: UserDefaults!
    override func setUp() async throws {
        helper = WSSDraftTests()
        try await helper.setUp()
        store = helper.store()
        suite = "WSSImageReplacement-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await helper.tearDown()
    }
    private func image() async throws -> Wallpaper {
        try await store.importWallpaper(helper.image(), existing: [])
    }
    private func draft(_ item: Wallpaper) async throws -> (
        WSSLoadedEditorProject, WSSImageReplacementTarget
    ) {
        try await WSSDraftPreparation().create(libraryImage: item)
    }
    private func snapshot(
        _ project: WSSLoadedEditorProject, _ target: WSSImageReplacementTarget?,
        name: String = "Scene"
    ) throws -> WSSSaveAsSnapshot {
        try WSSSaveAsSnapshot(
            document: project.document,
            state: WSSEditorDocumentState(model: project.document, diskBasis: project.diskBasis),
            source: project.handle, name: name, destinationID: project.handle.id,
            publication: target.map { .replacing($0) } ?? .additional)
    }
    func testNativeSheetDefaultsToAdditionalAndBothChoicesAreLocalized() {
        for language in ["de", "en"] {
            let (sheet, field, options) = WSSWallpaperNameRequest.imageAlert(
                proposedName: "Original", language: language)
            XCTAssertEqual(field.stringValue, "Original")
            XCTAssertEqual(options.indexOfSelectedItem, 0)
            XCTAssertEqual(options.numberOfItems, 2)
            XCTAssertEqual(
                options.itemTitle(at: 0),
                EditorText.imageSaveAdditional.localized(language: language))
            XCTAssertEqual(
                options.itemTitle(at: 1), EditorText.imageSaveReplace.localized(language: language))
            XCTAssertEqual(sheet.buttons[0].keyEquivalent, "\r")
            XCTAssertEqual(sheet.buttons[1].keyEquivalent, "\u{1b}")
            XCTAssertTrue(sheet.window.initialFirstResponder === field)
        }
    }
    func testReplaceRetainsIdentityLatestOrderAndBothOriginalFiles() async throws {
        let first = try await image()
        let other = try await image()
        let (project, target) = try await draft(first)
        defer { try? project.handle.draftOwner?.discard() }
        let original = try Data(contentsOf: first.url)
        _ = try await store.move(wallpaperID: first.id, relativeTo: other.id, placement: .before)
        let order = try store.load().map(\.id)
        let receipt = try await store.publishWSSDraft(snapshot(project, target, name: first.title))
        let items = try store.load()
        XCTAssertEqual(items.map(\.id), order)
        XCTAssertEqual(items.count, 2)
        let scene = try XCTUnwrap(items.first { $0.id == first.id })
        XCTAssertEqual(scene.kind, .scene)
        XCTAssertNotEqual(scene.root, first.root)
        XCTAssertEqual(scene, receipt.project.handle.wallpaper)
        XCTAssertEqual(try Data(contentsOf: first.url), original)
        XCTAssertEqual(try Data(contentsOf: helper.image()), original)
        try FileManager.default.removeItem(at: first.url)
        _ = try WSSEditorProjectLoader.read(scene)  // no dependency on old internal image
    }
    func testAdditionalPreservesAllExistingValuesAndOrderAndAllowsDuplicateNames() async throws {
        let first = try await image()
        _ = try await image()
        let originalItems = try store.load()
        let (project, _) = try await draft(first)
        defer { try? project.handle.draftOwner?.discard() }
        let receipt = try await store.publishWSSDraft(snapshot(project, nil, name: first.title))
        XCTAssertEqual(Array(try store.load().dropLast()), originalItems)
        XCTAssertEqual(receipt.project.handle.id, project.handle.id)
        XCTAssertNotEqual(receipt.project.handle.id, first.id)
        XCTAssertEqual(receipt.project.document.title, first.title)
        for invalid in ["", "line\nbreak", String(repeating: "a", count: 257)] {
            XCTAssertThrowsError(try snapshot(project, nil, name: invalid))
        }
        XCTAssertEqual(try store.load().count, originalItems.count + 1)
    }

    func testConflictsAndAdditionalFallback() async throws {
        for change in ["rename", "delete", "bytes", "replace"] {
            let item = try await image()
            let (project, target) = try await draft(item)
            defer { try? project.handle.draftOwner?.discard() }
            switch change {
            case "rename": _ = try await store.rename(wallpaperID: item.id, newTitle: "Renamed")
            case "delete": _ = try await store.remove(item, existing: store.load())
            case "bytes": try Data("changed".utf8).write(to: item.url)
            default: _ = try await store.publishWSSDraft(snapshot(project, target))
            }
            let before = try Data(contentsOf: store.storage)
            do {
                _ = try await store.publishWSSDraft(snapshot(project, target))
                XCTFail("Accepted stale source")
            } catch { XCTAssertTrue(error is WSSImagePublicationError) }
            XCTAssertEqual(try Data(contentsOf: store.storage), before)
            // A committed replacement is no longer a draft publication to retry under its old directory.
            if change != "replace" {
                let added = try await store.publishWSSDraft(snapshot(project, nil))
                XCTAssertNotEqual(added.project.handle.id, item.id)
            }
        }
    }
    func testFailuresBeforeCommitPreserveOriginalAndRetryAndAfterCommitWarns() async throws {
        for stage in [
            WSSSaveAsStage.write, .preparation, .projectPublish, .finalValidation,
            .libraryPersistence, .libraryCommit,
        ] {
            let item = try await image()
            let (project, target) = try await draft(item)
            defer { try? project.handle.draftOwner?.discard() }
            let before = try Data(contentsOf: store.storage)
            let snap = try snapshot(project, target)
            do {
                _ = try await store.publishWSSDraft(
                    snap, checkpoint: { if $0 == stage { throw WSSSaveAsError.storage } })
                XCTFail("Committed injected failure")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: store.storage), before)
            let receipt = try await store.publishWSSDraft(
                snap, checkpoint: { if $0 == .afterCommit { throw WSSSaveAsError.storage } })
            XCTAssertFalse(receipt.warnings.isEmpty)
            XCTAssertEqual(try store.load().first { $0.id == item.id }?.kind, .scene)
        }
    }
    func testSourceFingerprintRecheckedAtFinalCommitAndUnknownDirectorySurvives() async throws {
        let item = try await image()
        let (project, target) = try await draft(item)
        defer { try? project.handle.draftOwner?.discard() }
        let before = try Data(contentsOf: store.storage)
        do {
            _ = try await store.publishWSSDraft(
                snapshot(project, target),
                checkpoint: {
                    if $0 == .libraryCommit { try Data("external change".utf8).write(to: item.url) }
                })
            XCTFail("Committed stale source bytes")
        } catch { XCTAssertTrue(error is WSSImagePublicationError) }
        XCTAssertEqual(try Data(contentsOf: store.storage), before)
        let item2 = try await image()
        let (project2, target2) = try await draft(item2)
        defer { try? project2.handle.draftOwner?.discard() }
        let collision = store.wallpaperRoot.appendingPathComponent(
            "WSS/" + project2.handle.id.uuidString)
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
        let marker = collision.appendingPathComponent("unknown")
        try Data("keep".utf8).write(to: marker)
        do {
            _ = try await store.publishWSSDraft(snapshot(project2, target2))
            XCTFail("Replaced unknown directory")
        } catch {}
        XCTAssertEqual(try String(contentsOf: marker), "keep")
        XCTAssertEqual(try store.load().first { $0.id == item2.id }, item2)
    }
    func testLibraryPreservesFavoritesSelectionPlaylistBytesAndCanonicalizesStaleApply()
        async throws
    {
        let item = try await image()
        let (project, target) = try await draft(item)
        defer { try? project.handle.draftOwner?.discard() }
        let library = Library(storage: store.storage, defaults: defaults, restoreOnLaunch: false)
        defer { library.stop() }
        library.toggleFavorite(item)
        library.selected = item.id
        let playlistURL = helper.root.appendingPathComponent("test-playlists.json")
        let playlist = WallpaperPlaylist(
            library: library, storage: playlistURL, defaults: defaults, restoreOnLaunch: false)
        defer { playlist.shutdown() }
        let id = try playlist.createPlaylist(name: "Retain")
        try playlist.add(item.id, to: id)
        let bytes = try Data(contentsOf: playlistURL)
        let state = playlist.state
        let result = try await library.publishWSSDraft(snapshot(project, target))
        XCTAssertEqual(result.project.handle.id, item.id)
        XCTAssertTrue(library.favorites.contains(item.id))
        XCTAssertEqual(library.selected, item.id)
        XCTAssertEqual(playlist.state, state)
        XCTAssertEqual(try Data(contentsOf: playlistURL), bytes)
        XCTAssertNil(library.active)
        library.manuallyPaused = true
        _ = library.apply(item, source: .automatic)
        XCTAssertEqual(library.active?.kind, .scene)
        XCTAssertEqual(playlist.state, state)
    }

    func testPausedPendingImageCanBeReplacedWithoutLosingTheRequest() async throws {
        let item = try await image()
        let (project, target) = try await draft(item)
        defer { try? project.handle.draftOwner?.discard() }
        let library = Library(storage: store.storage, defaults: defaults, restoreOnLaunch: false)
        defer { library.stop() }
        library.manuallyPaused = true
        let request = library.apply(item, source: .automatic)
        _ = try await library.publishWSSDraft(snapshot(project, target))
        XCTAssertEqual(library.active?.kind, .scene)
        XCTAssertEqual(library.items.count, 1)
        XCTAssertEqual(library.pauseReason, .manual)
        library.stop()
        if case .superseded = await request.outcome {
        } else {
            XCTFail("Request resolved before resume")
        }
    }
    func testAcceptedPreferenceDoesNotPreventReplacingInactiveImage() async throws {
        let item = try await image()
        let (project, target) = try await draft(item)
        defer { try? project.handle.draftOwner?.discard() }
        defaults.set(item.id.uuidString, forKey: "activeWallpaper")
        let library = Library(storage: store.storage, defaults: defaults, restoreOnLaunch: false)
        defer { library.stop() }
        _ = try await library.publishWSSDraft(snapshot(project, target))
        XCTAssertNil(library.active)
        XCTAssertEqual(library.items.first?.kind, .scene)
    }

    func testCoordinatorCancelReplacementTakeoverNormalSaveReopenAndClose() async throws {
        let item = try await image()
        var docs: [WSSEditorDocument] = []
        var windows: [ImageReplacementWindow] = []
        let coordinator = WSSEditorCoordinator(
            lookup: { id in try XCTUnwrap(self.store.load().first { $0.id == id }) },
            save: { snap in
                let saved = try XCTUnwrap(
                    self.store.load().first { $0.id == snap.diskBasis.identity.wallpaperID })
                let prepared = try await WSSManifestSaveValidator().prepare(
                    snap, handle: WSSExistingProjectResolver.resolve(saved))
                return try await self.store.commitWSSManifest(prepared)
            }, saveAs: { try await self.store.saveWSSAs($0) },
            publishDraft: {
                try await self.store.publishWSSDraft(
                    $0, checkpoint: { if $0 == .afterCommit { throw WSSSaveAsError.storage } })
            },
            makeWindow: { doc, close in
                docs.append(doc)
                let window = ImageReplacementWindow(close)
                windows.append(window)
                return window
            })
        defer { coordinator.shutdown() }
        try await coordinator.open(wallpaperID: item.id)
        let doc = try XCTUnwrap(docs.first)
        let draftID = doc.project.handle.id
        let bytes = try Data(contentsOf: store.storage)
        doc.chooseImageFirstSave = { _ in nil }
        let cancelled = await doc.save()
        XCTAssertFalse(cancelled)
        XCTAssertEqual(try Data(contentsOf: store.storage), bytes)
        var choices = 0
        var warnings = 0
        doc.presentMessage = { _, _ in warnings += 1 }
        doc.chooseImageFirstSave = { name in
            choices += 1
            return .init(name: name, replace: true)
        }
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(coordinator.openIDs, [item.id])
        XCTAssertFalse(coordinator.openIDs.contains(draftID))
        XCTAssertNil(doc.libraryImageSource)
        try doc.addEffect(.ripple)
        let again = await doc.save()
        XCTAssertTrue(again)
        XCTAssertEqual(choices, 1)
        XCTAssertEqual(warnings, 1)
        XCTAssertEqual(try store.load().count, 1)
        try await coordinator.open(wallpaperID: item.id)
        XCTAssertEqual(docs.count, 1)
        coordinator.close(wallpaperID: item.id)
        await doc.waitForDraftCleanup()
        XCTAssertTrue(coordinator.openIDs.isEmpty)
        try await coordinator.open(wallpaperID: item.id)
        XCTAssertEqual(docs.count, 2)
        XCTAssertEqual(docs[1].project.handle.id, item.id)
        coordinator.close(wallpaperID: item.id)
    }
}

@MainActor private final class ImageReplacementWindow: WSSEditorWindow {
    let onClose: () -> Void
    init(_ onClose: @escaping () -> Void) { self.onClose = onClose }
    func focus() {}
    func close() { onClose() }
}
