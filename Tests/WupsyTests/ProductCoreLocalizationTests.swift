import XCTest

@testable import Wupsy

final class ProductCoreLocalizationTests: XCTestCase {
    func testEveryCoreResourceHasEnglishAndGermanWithoutVisibleKeys() {
        for resource in ProductText.allCases {
            for language in ["en", "de"] {
                let path = Localization.bundle.path(forResource: language, ofType: "lproj")!
                let explicitBundle = Bundle(path: path)!
                XCTAssertNotEqual(
                    explicitBundle.localizedString(
                        forKey: resource.rawValue, value: "__missing__", table: nil), "__missing__",
                    resource.rawValue)
                let value = resource.localized(language: language)
                XCTAssertFalse(value.isEmpty, resource.rawValue)
                XCTAssertNotEqual(value, resource.rawValue)
                XCTAssertNotEqual(value, "Wupsy", resource.rawValue)
            }
        }
    }

    func testCentralMenuAndLibraryTerminology() {
        let expectations: [(ProductText, String, String)] = [
            (.createWallpaper, "Create wallpaper", "Hintergrundbild erstellen"),
            (.addWallpaper, "Add wallpaper", "Hintergrundbild hinzufügen"),
            (
                .removeManaged, "Remove Wallpaper from Library",
                "Wallpaper aus der Mediathek entfernen"
            ),
            (
                .managedRemoveHint,
                "Removes the wallpaper from the library and deletes its associated Wupsy-managed files. External original files are preserved.",
                "Entfernt das Wallpaper aus der Mediathek und löscht die zugehörigen von Wupsy verwalteten Dateien. Externe Originaldateien bleiben erhalten."
            ),
            (.quit, "Quit Wupsy", "Wupsy beenden"),
            (.launchLogin, "Launch at Login", "Bei der Anmeldung starten"),
            (.navAll, "All wallpapers", "Alle Hintergrundbilder"),
            (.favorites, "Favorites", "Favoriten"),
            (.searchWallpapers, "Search wallpapers", "Hintergrundbilder suchen"),
            (.playlistNewTitle, "New playlist", "Neue Playlist"),
            (.addFavorite, "Add to Favorites", "Zu Favoriten hinzufügen"),
            (.mediaScene, "Scene", "Szene"),
        ]
        for (resource, english, german) in expectations {
            XCTAssertEqual(resource.localized(language: "en"), english)
            XCTAssertEqual(resource.localized(language: "de"), german)
        }
    }

    func testQualityNamesAndPlaybackStatusInBothLanguages() {
        XCTAssertEqual(QualityProfile.balanced.displayName(language: "en"), "Balanced")
        XCTAssertEqual(QualityProfile.balanced.displayName(language: "de"), "Ausgewogen")
        XCTAssertEqual(QualityProfile.eco.displayName(language: "de"), "Effizient")
        XCTAssertEqual(
            LibraryPlaybackStatus.preparing(.balanced).localizedTitle(language: "de"),
            "Wiedergabe mit Qualität „Ausgewogen“ wird vorbereitet …")
        XCTAssertEqual(
            LibraryPlaybackStatus.paused(.battery).localizedTitle(language: "de"),
            "Batteriebetrieb")
        XCTAssertEqual(LibraryPlaybackStatus.ready.localizedTitle(language: "en"), "Ready")
        XCTAssertEqual(LibraryPlaybackStatus.ready.localizedTitle(language: "de"), "Bereit")
        XCTAssertEqual(LibraryPlaybackStatus.stopped.localizedTitle(language: "de"), "Gestoppt")
    }

    func testFollowUpQualityAndFormatContracts() {
        XCTAssertEqual(QualityProfile.eco.displayName(language: "en"), "Eco")
        XCTAssertEqual(QualityProfile.allCases.map(\.rawValue), ["eco", "balanced", "original"])
        XCTAssertEqual(QualityProfile.allCases.map(\.maxDimension), [1280, 2560, 8192])
        XCTAssertEqual(QualityProfile.allCases.map(\.fps), [24, 30, 60])
        let help = ProductText.qualityBalancedHelp.localized(language: "de")
        for value in ["Effizient", "1280", "24 FPS", "2560", "30 FPS", "Originaldatei"] {
            XCTAssertTrue(help.contains(value), value)
        }
        XCTAssertFalse(help.contains("Sparsam"))
        for language in ["en", "de"] {
            let formats = ProductText.formatsList.localized(language: language)
            XCTAssertFalse(formats.lowercased().contains("playback mode"))
            XCTAssertFalse(formats.lowercased().contains("wiedergabemodus"))
            XCTAssertTrue(formats.contains("scene.wss.json"))
            XCTAssertFalse(formats.contains("Wallpaper Engine"))
            XCTAssertNotEqual(formats, ProductText.formatsList.rawValue)
        }
    }

    func testSecondFollowUpFavoritesAndCachePresentation() {
        XCTAssertEqual(
            ProductText.emptyFavoritesHint.localized(language: "de"),
            "Markiere Hintergrundbilder mit dem Herz als Favoriten.")
        XCTAssertEqual(
            ProductText.emptyFavoritesHint.localized(language: "en"),
            "Tap a wallpaper’s heart to keep it here.")
        XCTAssertEqual(ProductText.clearOptimized.localized(language: "de"), "Video-Cache leeren")
        XCTAssertEqual(
            ProductText.clearOptimized.localized(language: "en"), "Clear optimized copies")
        XCTAssertEqual(
            ProductText.clearCacheHelp.localized(language: "de"),
            "Löscht nicht verwendete optimierte Videos im Cache. Aktuell zur Wiedergabe verwendete Dateien bleiben erhalten."
        )
        XCTAssertEqual(
            ProductText.clearCacheHelp.localized(language: "en"),
            "Deletes unused optimized videos from the cache. Files currently used for playback are kept."
        )
        XCTAssertEqual(
            ProductText.clearCacheHelp.localized(language: "zz"),
            ProductText.clearCacheHelp.localized(language: "en"))
        XCTAssertEqual(
            ProductText.clearOptimized.localized(language: "zz"), "Clear optimized copies")
        for language in ["de", "en", "zz"] {
            for resource: ProductText in [.emptyFavoritesHint, .clearOptimized, .clearCacheHelp] {
                XCTAssertNotEqual(resource.localized(language: language), resource.rawValue)
            }
        }
        XCTAssertEqual(QualityProfile.allCases.map(\.rawValue), ["eco", "balanced", "original"])
    }

    func testDisplayPluralsZeroOneTwoAndMany() {
        for count in [0, 1, 2, 37] {
            let state = LibraryPlaybackStatus.playing(displayCount: count)
            XCTAssertEqual(
                state.localizedTitle(language: "en"),
                "Playing · \(count) \(count == 1 ? "display" : "displays")")
            XCTAssertEqual(
                state.localizedTitle(language: "de"),
                "Wiedergabe · \(count) \(count == 1 ? "Display" : "Displays")")
            XCTAssertTrue(state.isPlaying)
        }
    }

    func testCoreCountAndDurationPluralFamilies() {
        let families: [(ProductText, String, String, String, String)] = [
            (.wallpaperCount, "wallpaper", "wallpapers", "Hintergrundbild", "Hintergrundbilder"),
            (.playlistCount, "playlist", "playlists", "Playlist", "Playlists"),
            (.widgetCount, "widget", "widgets", "Widget", "Widgets"),
            (.intervalSeconds, "second", "seconds", "Sekunde", "Sekunden"),
            (.intervalMinutes, "minute", "minutes", "Minute", "Minuten"),
            (.intervalHours, "hour", "hours", "Stunde", "Stunden"),
        ]
        for (resource, enOne, enOther, deOne, deOther) in families {
            for count in [0, 1, 2, 37] {
                XCTAssertEqual(
                    resource.format(Int64(count), language: "en"),
                    "\(count) \(count == 1 ? enOne : enOther)")
                XCTAssertEqual(
                    resource.format(Int64(count), language: "de"),
                    "\(count) \(count == 1 ? deOne : deOther)")
            }
        }
    }

    func testPlaylistIntervalsKeepNumericContracts() {
        XCTAssertEqual(
            PlaylistDefinition.intervals.map(\.seconds),
            [5, 10, 60, 300, 900, 1800, 3600, 7200, 21600, 86400])
        XCTAssertEqual(PlaylistDefinition.intervalTitle(5, language: "de"), "5 Sekunden · Test")
        XCTAssertEqual(PlaylistDefinition.intervalTitle(60, language: "de"), "1 Minute")
        XCTAssertEqual(PlaylistDefinition.intervalTitle(300, language: "de"), "5 Minuten")
        XCTAssertEqual(PlaylistDefinition.intervalTitle(3600, language: "de"), "1 Stunde")
        XCTAssertEqual(PlaylistDefinition.intervalTitle(7200, language: "en"), "2 hours")
    }

    func testUserNamesUnicodeAndFormatTokensRemainVerbatim() {
        let name = "海 🌈 %@ core.quality %lld"
        XCTAssertEqual(
            ProductText.playlistWaiting.format(name, language: "de"),
            name + " · Wiedergabestart wird abgewartet …")
        XCTAssertEqual(
            ProductText.playlistShuffling.format(name, language: "en"), name + " · Shuffling")
        XCTAssertEqual(
            ProductText.playlistPaused.format(name, language: "de"), name + " · Pausiert")
        XCTAssertEqual(
            ProductText.playlistRemoveTitle.format(name, language: "de"),
            name + " aus Playlist entfernen")
        XCTAssertTrue(ProductText.deletePlaylistMessage.format(name, language: "de").contains(name))
    }

    func testFallbackAndAccessibilityResources() {
        XCTAssertEqual(ProductText.navAll.localized(language: "zz"), "All wallpapers")
        XCTAssertEqual(Localization.string(.fallbackProbe, language: "de"), "English fallback")
        XCTAssertEqual(ProductText.expanded.localized(language: "de"), "Ausgeklappt")
        XCTAssertEqual(ProductText.collapsed.localized(language: "de"), "Eingeklappt")
        XCTAssertEqual(ProductText.playlistDrag.localized(language: "de"), "Zum Umsortieren ziehen")
        XCTAssertEqual(
            ProductText.pauseBatteryHelp.localized(language: "de"),
            "Pausiert die Hintergrundbild-Wiedergabe, solange der Mac im Batteriebetrieb läuft.")
    }

    func testPresentationLookupsCannotMutatePersistedUserValuesOrIDs() throws {
        let name = "core.navAll 🌈"
        let playlist = PlaylistDefinition(name: name)
        let wallpaper = Wallpaper(
            title: name, path: "/synthetic/a.png", root: "/synthetic", kind: .image)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(playlist)
        let wallpaperBefore = try encoder.encode(wallpaper)
        for language in ["en", "de"] {
            _ = ProductText.playlistPlayingOrder.format(playlist.name, language: language)
            _ = QualityProfile.original.displayName(language: language)
            XCTAssertEqual(try WallpaperTitle.normalized(name), name)
        }
        XCTAssertEqual(try encoder.encode(playlist), before)
        XCTAssertEqual(try encoder.encode(wallpaper), wallpaperBefore)
        XCTAssertEqual(QualityProfile.allCases.map(\.rawValue), ["eco", "balanced", "original"])
        XCTAssertEqual(PlaylistPlaybackMode.allCases.map(\.rawValue), ["inOrder", "shuffle"])
        XCTAssertEqual(SceneRenderResolution.hiDPI.rawValue, "hiDPI")
        XCTAssertEqual(WallpaperFilter.image.rawValue, "Images")
        XCTAssertEqual(PauseReason.battery.rawValue, "On battery")
    }

    func testDeletionMessagesClearlyProtectExternalOriginals() {
        XCTAssertEqual(
            ProductText.removeExternal.localized(language: "de"), "Aus Mediathek entfernen")
        XCTAssertTrue(
            ProductText.externalRemoveHint.localized(language: "de").contains(
                "Originaldatei bleibt erhalten"))
        XCTAssertTrue(
            ProductText.managedRemoveHint.localized(language: "de").contains(
                "Externe Originaldateien bleiben erhalten"))
    }
    func testNameValidationKeepsParserDiagnosticsSeparateFromUI() {
        let cases: [(String, String, ProductText)] = [
            ("a\nb", "Use a single line without control characters.", .nameSingleLine),
            ("  ", "Enter a wallpaper name.", .nameRequired),
            (
                String(repeating: "a", count: 257), "Use a name with at most 256 characters.",
                .nameLength
            ),
        ]
        for (input, diagnostic, resource) in cases {
            XCTAssertThrowsError(try WallpaperTitle.normalized(input)) { error in
                XCTAssertTrue(error is ImportFailure)
                XCTAssertEqual(error.localizedDescription, diagnostic)
            }
            XCTAssertEqual(ProductCoreError.nameValidation(input), resource.text)
        }
        XCTAssertNil(ProductCoreError.nameValidation("海 🌈"))
    }

}
