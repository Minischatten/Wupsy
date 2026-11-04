import XCTest

@testable import Wupsy

final class PresentationIdentityTests: XCTestCase {
    private func wallpaper(_ title: String, kind: WallpaperKind = .image, ext: String = "png")
        -> Wallpaper
    {
        Wallpaper(title: title, path: "/synthetic/\(title).\(ext)", root: "/synthetic", kind: kind)
    }

    func testSidebarWidthContractAndContentInsets() {
        XCTAssertEqual(LibrarySidebarLayout.minimumWidth, 240)
        XCTAssertEqual(LibrarySidebarLayout.idealWidth, 255)
        XCTAssertEqual(LibrarySidebarLayout.maximumWidth, 300)
        XCTAssertLessThan(LibrarySidebarLayout.minimumWidth, LibrarySidebarLayout.idealWidth)
        XCTAssertLessThan(LibrarySidebarLayout.idealWidth, LibrarySidebarLayout.maximumWidth)
        for width: CGFloat in [240, 255, 270, 300] {
            XCTAssertEqual(LibrarySidebarLayout.contentWidth(for: width), width - 40)
            XCTAssertLessThan(LibrarySidebarLayout.contentWidth(for: width), width)
        }
        XCTAssertEqual(LibrarySidebarLayout.contentWidth(for: 0), 0)
        XCTAssertEqual(LibrarySidebarLayout.contentWidth(for: 20), 0)
    }

    func testPlaybackAppearanceUsesStateRatherThanTitle() {
        XCTAssertTrue(LibraryPlaybackStatus.playing(displayCount: 2).isPlaying)
        for state: LibraryPlaybackStatus in [
            .ready, .stopped, .preparing(.balanced), .paused(.manual), .paused(.memory),
        ] {
            XCTAssertFalse(state.isPlaying)
        }
        XCTAssertEqual(
            LibraryPlaybackStatus.playing(displayCount: 1).localizedTitle(language: "en"),
            "Playing · 1 display")
        XCTAssertEqual(
            LibraryPlaybackStatus.playing(displayCount: 2).localizedTitle(language: "en"),
            "Playing · 2 displays")
    }

    func testPagesAndSortUseTechnicalSelectionValues() {
        var page: LibraryPage = .overview
        page = .playlist
        XCTAssertEqual(page, .playlist)
        XCTAssertEqual(Set(LibraryPage.allCases).count, 4)
        let z = wallpaper("Zulu")
        let a = wallpaper("Alpha")
        let b = wallpaper("Beta")
        XCTAssertEqual(
            LibrarySort.newest.ordered([z, a, b], favorites: []).map(\.id), [b.id, a.id, z.id])
        XCTAssertEqual(
            LibrarySort.name.ordered([z, a, b], favorites: []).map(\.id), [a.id, b.id, z.id])
        XCTAssertEqual(
            LibrarySort.favorites.ordered([z, a, b], favorites: [z.id]).map(\.id),
            [z.id, a.id, b.id])
    }

    func testMediaSymbolAndFilterDoNotDependOnDisplayName() {
        let gif = wallpaper("beliebiger Name", kind: .web, ext: "GIF")
        XCTAssertTrue(gif.isGIF)
        XCTAssertEqual(gif.symbol, "square.stack.3d.up")
        XCTAssertTrue(WallpaperFilter.gif.accepts(gif))
        XCTAssertFalse(WallpaperFilter.web.accepts(gif))
        XCTAssertEqual(wallpaper("Bild", kind: .image).symbol, "photo")
        XCTAssertEqual(wallpaper("Szene", kind: .scene, ext: "gif").symbol, "cube.transparent")
        XCTAssertEqual(wallpaper("Video", kind: .video, ext: "mov").symbol, "play.rectangle")
        XCTAssertEqual(WallpaperFilter.image.rawValue, "Images")
        XCTAssertEqual(WallpaperFilter.image.title, ProductText.filterImages.text)
        XCTAssertEqual(ProductText.filterImages.localized(language: "en"), "Images")
        XCTAssertTrue(WallpaperFilter.image.accepts(wallpaper("Images")))
        XCTAssertFalse(WallpaperFilter.video.accepts(wallpaper("Video")))
    }

    func testInspectorSelectionAndSummaryIgnoreAllPresentationTitles() {
        var sections = [
            WSSInspectionSection(
                kind: .image, title: "Image",
                entries: [.init(.visible, "true"), .init(.composition, "replace")]),
            WSSInspectionSection(
                kind: .imageAsset, title: "Image asset", entries: [.init(.asset, "image.png")]),
            WSSInspectionSection(
                kind: .effect, title: "Effect 1 · Ripple", entries: [.init(.amplitude, "4")],
                target: .effect(0)),
            WSSInspectionSection(
                kind: .mask, title: "Effect 1 · Mask", entries: [.init(.asset, "mask.png")],
                target: .effect(0)),
            WSSInspectionSection(
                kind: .effect, title: "Effect 11 · Flow",
                entries: [.init(.fieldAsset, "field.wssvf")], target: .effect(10)),
        ]
        for index in sections.indices {
            sections[index].title = "Ein beliebiger identischer Titel"
            for row in sections[index].entries.indices {
                sections[index].entries[row].title = "Ein beliebiges Zeilenlabel"
            }
        }
        let layer = WSSInspectionSection.selected(sections, effectIndex: nil)
        XCTAssertEqual(layer.count, 2)
        XCTAssertEqual(layer[0].entries.map(\.kind), [.composition])
        let effect = WSSInspectionSection.selected(sections, effectIndex: 0)
        XCTAssertEqual(effect.count, 2)
        XCTAssertEqual(effect.map(\.target), [.effect(0), .effect(0)])
        let summary = WSSInspectionSection.summaries(effect)
        XCTAssertEqual(summary.count, 1)
        XCTAssertEqual(summary[0].kind, .effect)
        XCTAssertTrue(summary[0].entries.isEmpty)
        XCTAssertEqual(WSSInspectionSection.selected(sections, effectIndex: 10).count, 1)
        XCTAssertEqual(sections[1].assetPaths, ["image.png"])
        XCTAssertEqual(sections[4].assetPaths, ["field.wssvf"])
        XCTAssertEqual(WSSEditorParameter.flowSpeed.inspectionRowKind, .speed)
        XCTAssertEqual(WSSEditorParameter.flowStrength.inspectionRowKind, .strength)
    }

    func testAdditionalActionTitlesPreserveTechnicalRawValues() {
        XCTAssertEqual(
            WSSMaskAction.allCases.map(\.rawValue),
            [
                "Create Mask", "Import Mask…", "Remove Mask", "Clear Mask", "Fill Mask",
            ])
        XCTAssertEqual(
            WSSMaskAction.allCases.map { $0.localizedTitle(language: "en") },
            WSSMaskAction.allCases.map(\.rawValue))
        XCTAssertEqual(WSSAddableEffect.allCases.map(\.rawValue), ["Ripple", "Clouds", "Flow"])
        XCTAssertEqual(
            WSSAddableEffect.allCases.map { $0.localizedTitle(language: "en") },
            ["Ripple", "Clouds", "Flow"])
        XCTAssertTrue(WSSAddableEffect.flow.requiresVectorField)
        XCTAssertFalse(WSSAddableEffect.ripple.requiresVectorField)
        XCTAssertEqual(PauseReason.manual.rawValue, "Paused by you")
        XCTAssertEqual(PauseReason.manual.displayName(language: "en"), "Paused by you")
        XCTAssertEqual(LibraryPlaybackStatus.paused(.manual).title, PauseReason.manual.title)
    }

    func testBackupFailurePhaseCannotBeReconstructedFromDisplayText() {
        let progress = LibraryBackupProgressState(phase: .archive, detail: "Done — beliebiger Text")
        XCTAssertEqual(progress.title, "Done — beliebiger Text")
        XCTAssertEqual(progress.phase, .archive)
        XCTAssertEqual(
            progress.phase.localizedFailureTitle(language: "en"),
            "Backup failed while writing the archive.")
        let tracker = LibraryBackupPhaseTracker()
        tracker.phase = progress.phase
        XCTAssertEqual(tracker.phase, .archive)
        XCTAssertNotEqual(tracker.phase, .done)
    }
}
