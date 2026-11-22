import AppKit
import ServiceManagement
import SwiftUI
import XCTest

@testable import Wupsy

@MainActor final class WupsySettingsTests: XCTestCase {
    func testMenuPauseLabelsFollowManualPauseOnly() {
        var conditions = PlaybackConditions()
        conditions.onBattery = true
        XCTAssertEqual(conditions.reason(conserve: true, pauseOnBattery: true), .battery)
        let pause = WupsyMenu.playbackAction(manuallyPaused: conditions.manual)
        XCTAssertEqual(pause.localized(language: "de"), "Hintergrundbilder pausieren")
        conditions.manual = true
        let resume = WupsyMenu.playbackAction(manuallyPaused: conditions.manual)
        XCTAssertEqual(resume.localized(language: "de"), "Hintergrundbilder fortsetzen")
        XCTAssertEqual(resume.localized(language: "en"), "Resume Wallpapers")
    }

    func testLoginToggleIncludesPendingSystemApproval() {
        XCTAssertTrue(WupsySettings.loginEnabled(.enabled))
        XCTAssertTrue(WupsySettings.loginEnabled(.requiresApproval))
        XCTAssertFalse(WupsySettings.loginEnabled(.notRegistered))
        XCTAssertFalse(WupsySettings.loginEnabled(.notFound))
    }

    func testSettingsWindowFitsAtAllInterfaceScales() throws {
        _ = NSApplication.shared
        let suite = "WupsySettingsLayout." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let appearance = WupsyAppearance(defaults: defaults)
        let maintenance = MaintenanceCoordinator()
        let library = Library(
            maintenance: maintenance, storage: storage.appendingPathComponent("library.json"),
            defaults: defaults, restoreOnLaunch: false, targetScreens: { [] })
        let widgets = DesktopWidgets(defaults: defaults, maintenance: maintenance)
        defer { widgets.shutdownForMaintenance() }
        let playlist = WallpaperPlaylist(
            library: library, storage: storage.appendingPathComponent("playlists.json"),
            defaults: defaults, restoreOnLaunch: false)
        let previousEditor = WupsyDelegate.editorCoordinator
        let previousRestore = WupsyDelegate.restoreCoordinator
        defer {
            WupsyDelegate.editorCoordinator = previousEditor
            WupsyDelegate.restoreCoordinator = previousRestore
        }
        let editors = WSSEditorCoordinator(
            maintenance: maintenance, lookup: { try library.wallpaperForEditor(id: $0) })
        let backup = LibraryBackupCoordinator(maintenance: maintenance)
        let restore = LibraryRestoreUI()
        let updates = UpdateCheckCoordinator.live(defaults: defaults)
        defer { updates.shutdown() }

        var sizes: [CGSize] = []
        for scale in WupsyInterfaceScale.allCases {
            appearance.scale = scale
            let host = NSHostingController(
                rootView: WupsyAppearanceScope(appearance) {
                    WupsySettings(
                        appearance: appearance, library: library, widgets: widgets,
                        playlist: playlist, editors: editors, backup: backup, restore: restore,
                        updates: updates, maintenance: maintenance)
                })
            let size = host.sizeThatFits(
                in: CGSize(width: 440 * scale.factor, height: 240 * scale.factor))
            XCTAssertGreaterThanOrEqual(size.width, 420 * scale.factor)
            XCTAssertGreaterThanOrEqual(size.height, 220 * scale.factor)
            XCTAssertLessThan(size.width, 750)
            XCTAssertLessThan(size.height, 550)
            sizes.append(size)
        }
        XCTAssertGreaterThan(try XCTUnwrap(sizes.last).width, try XCTUnwrap(sizes.first).width)
    }

    func testPlaybackSettingsLoadAndSaveExistingKeysAndRespectRestoreFreeze() throws {
        let suite = "WupsySettingsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let maintenance = MaintenanceCoordinator()
        defaults.set(false, forKey: "allDisplays")
        defaults.set(true, forKey: "pauseOnBattery")
        defaults.set(false, forKey: "conserve")
        func load() -> Library {
            Library(
                maintenance: maintenance, storage: storage, defaults: defaults,
                restoreOnLaunch: false, targetScreens: { [] })
        }

        let library = load()
        XCTAssertFalse(library.allDisplays)
        XCTAssertTrue(library.pauseOnBattery)
        XCTAssertFalse(library.conserve)
        library.allDisplays = true
        library.pauseOnBattery = false
        library.conserve = true

        let reloaded = load()
        XCTAssertTrue(reloaded.allDisplays)
        XCTAssertFalse(reloaded.pauseOnBattery)
        XCTAssertTrue(reloaded.conserve)
        let lease = try maintenance.reserve(.restore)
        defer { lease.finish() }
        try maintenance.freeze()
        reloaded.allDisplays = false
        reloaded.pauseOnBattery = true
        reloaded.conserve = false
        XCTAssertTrue(reloaded.allDisplays)
        XCTAssertFalse(reloaded.pauseOnBattery)
        XCTAssertTrue(reloaded.conserve)
        XCTAssertTrue(defaults.bool(forKey: "allDisplays"))
        XCTAssertFalse(defaults.bool(forKey: "pauseOnBattery"))
        XCTAssertTrue(defaults.bool(forKey: "conserve"))
    }
}
