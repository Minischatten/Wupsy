import Foundation
import XCTest

@testable import Wupsy

final class LibraryBackupCompletionSummaryTests: XCTestCase {
    func testSingularPluralAndZeroCountsPreserveByteFormatting() {
        let bytes: Int64 = 408_500_000
        let size = bytes.formatted(.byteCount(style: .file).locale(Locale(identifier: "en")))
        for (wallpapers, playlists, counts) in [
            (0, 0, "0 wallpapers · 0 playlists"),
            (1, 1, "1 wallpaper · 1 playlist"),
            (2, 2, "2 wallpapers · 2 playlists"),
            (10, 1, "10 wallpapers · 1 playlist"),
            (1, 3, "1 wallpaper · 3 playlists"),
            (10, 3, "10 wallpapers · 3 playlists"),
        ] {
            XCTAssertEqual(
                LibraryBackupCompletionSummary.string(
                    wallpapers: wallpapers, playlists: playlists, bytes: bytes, language: "en"),
                "\(counts) · \(size)")
        }
    }
    func testExistingRestoreSummaryRetainsEnglishAndOriginalByteFormatter() {
        let bytes: Int64 = 408_500_000
        XCTAssertEqual(
            LibraryBackupCompletionSummary.string(wallpapers: 0, playlists: 1, bytes: bytes),
            "0 wallpapers · 1 playlist · "
                + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
    }
    func testGermanCountsAndUnknownLanguageReuseCorePlurals() {
        for language in ["en", "de", "zz"] {
            let resolved = language == "de" ? "de" : "en"
            for count in [0, 1, 2, 10] {
                let size = Int64(408_500_000).formatted(
                    .byteCount(style: .file).locale(Locale(identifier: resolved)))
                let expected =
                    ProductText.wallpaperCount.format(Int64(count), language: resolved)
                    + " · " + ProductText.playlistCount.format(Int64(count), language: resolved)
                    + " · " + size
                XCTAssertEqual(
                    LibraryBackupCompletionSummary.string(
                        wallpapers: count,
                        playlists: count, bytes: 408_500_000, language: language), expected)
            }
        }
    }

}
