import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import Wupsy

@MainActor final class LibraryReorderTests: XCTestCase {
    func testAdaptiveCardTargetsBothHalvesAtEveryWidth() {
        let id = UUID()
        for width: CGFloat in [178, 220, 270] {
            XCTAssertEqual(LibraryInsertion.card(id, x: 0, width: width).placement, .before)
            XCTAssertEqual(
                LibraryInsertion.card(id, x: width / 2 - 1, width: width).placement, .before)
            XCTAssertEqual(LibraryInsertion.card(id, x: width / 2, width: width).placement, .after)
            XCTAssertEqual(LibraryInsertion.card(id, x: width, width: width).placement, .after)
        }
    }

    func testPayloadRoundtripAndTypeSeparation() throws {
        let item = LibraryReorderItem(contextID: UUID(), wallpaperID: UUID())
        let decoded = try JSONDecoder().decode(
            LibraryReorderItem.self,
            from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded.contextID, item.contextID)
        XCTAssertEqual(decoded.wallpaperID, item.wallpaperID)
        XCTAssertFalse(UTType.wupsyLibraryEntry.conforms(to: .fileURL))
        XCTAssertNotEqual(
            UTType.wupsyLibraryEntry.identifier,
            "com.wirdschonsoftware.wupsy.playlist-entry")
    }

    func testFilteredDropMovesOnlySourceInGlobalOrder() async throws {
        let global = (0..<5).map {
            Wallpaper(
                title: "\($0)", path: "/synthetic/\($0).png", root: "/synthetic", kind: .image)
        }
        let internalOrder = Array(global.reversed())
        let controller = LibraryReorderController()
        let item = LibraryReorderItem(contextID: controller.contextID, wallpaperID: global[4].id)
        var result = internalOrder
        let accepted = try await controller.submit(
            item,
            at: .init(targetID: global[2].id, placement: .before),
            visibleIDs: [global[0].id, global[2].id, global[4].id]
        ) { source, target, placement in
            result = try LibraryMove.reordered(
                result, wallpaperID: source,
                relativeTo: target, placement: placement)
        }
        XCTAssertTrue(accepted)
        XCTAssertEqual(
            LibraryOrder.visible(result).map(\.id),
            [global[0], global[1], global[4], global[2], global[3]].map(\.id))
        // After the last filtered result means after that UUID, not at the global end.
        let next = LibraryReorderItem(contextID: controller.contextID, wallpaperID: global[0].id)
        _ = try await controller.submit(
            next,
            at: .init(targetID: global[2].id, placement: .after),
            visibleIDs: [global[0].id, global[2].id]
        ) { source, target, placement in
            result = try LibraryMove.reordered(
                result, wallpaperID: source,
                relativeTo: target, placement: placement)
        }
        XCTAssertEqual(
            LibraryOrder.visible(result).map(\.id),
            [global[1], global[4], global[2], global[0], global[3]].map(\.id))
    }

    func testInvalidatedSourceTargetAndEmptyResultsNeverCallMove() async throws {
        let controller = LibraryReorderController()
        let a = UUID()
        let b = UUID()
        let item = LibraryReorderItem(contextID: controller.contextID, wallpaperID: a)
        let target = LibraryInsertion(targetID: b, placement: .before)
        for ids in [[], [a], [b], [a, b, b]] as [[UUID]] {
            let accepted = try await controller.submit(item, at: target, visibleIDs: ids) {
                _, _, _ in
                XCTFail("Invalid membership accepted")
            }
            XCTAssertFalse(accepted)
        }
        XCTAssertFalse(
            controller.accepts(
                item, at: .init(targetID: a, placement: .after),
                visibleIDs: [a, b]))
        controller.insertion = target
        controller.invalidate()  // search/filter/page/maintenance change or cancellation
        XCTAssertNil(controller.insertion)
        let accepted = try await controller.submit(item, at: target, visibleIDs: [a, b]) {
            _, _, _ in
            XCTFail("Stale payload accepted")
        }
        XCTAssertFalse(accepted)
    }

    func testFailurePreservesVisibleModelAndReleasesAdmission() async throws {
        let fixture = LibraryBackupTests()
        try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        let items = (0..<3).map {
            Wallpaper(
                title: "\($0)", path: "/synthetic/\($0).png", root: "/synthetic", kind: .image)
        }
        try fixture.save(items)
        let library = Library(
            maintenance: MaintenanceCoordinator(),
            beforeMovePersistence: { throw CocoaError(.fileWriteOutOfSpace) },
            storage: fixture.storage, defaults: fixture.defaults, restoreOnLaunch: false)
        let before = try Data(contentsOf: fixture.storage)
        let controller = LibraryReorderController()
        do {
            _ = try await controller.submit(
                .init(contextID: controller.contextID, wallpaperID: items[0].id),
                at: .init(targetID: items[2].id, placement: .before), visibleIDs: items.map(\.id)
            ) {
                try await library.move(wallpaperID: $0, relativeTo: $1, placement: $2)
            }
            XCTFail("Expected write failure")
        } catch {}
        XCTAssertFalse(controller.isMoving)
        XCTAssertEqual(LibraryOrder.visible(library.items), LibraryOrder.visible(items))
        XCTAssertEqual(try Data(contentsOf: fixture.storage), before)
        controller.insertion = .init(targetID: items[1].id, placement: .before)
        controller.invalidate()  // cancelled drag, no submit
        XCTAssertEqual(try Data(contentsOf: fixture.storage), before)
    }

    func testBusyControllerRejectsSecondDrop() async throws {
        let controller = LibraryReorderController()
        let a = UUID()
        let b = UUID()
        var finish: CheckedContinuation<Void, Never>?
        let started = expectation(description: "Move in flight")
        let item = LibraryReorderItem(contextID: controller.contextID, wallpaperID: a)
        let target = LibraryInsertion(targetID: b, placement: .before)
        let first = Task {
            try await controller.submit(item, at: target, visibleIDs: [a, b]) { _, _, _ in
                await withCheckedContinuation {
                    finish = $0
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(controller.isMoving)
        let second = try await controller.submit(
            .init(contextID: controller.contextID, wallpaperID: b),
            at: .init(targetID: a, placement: .after), visibleIDs: [a, b]
        ) { _, _, _ in
            XCTFail("Concurrent drop admitted")
        }
        XCTAssertFalse(second)
        finish?.resume()
        let accepted = try await first.value
        XCTAssertTrue(accepted)
        XCTAssertFalse(controller.isMoving)
    }

    func testActualStartupSelectionDoesNotMigrateLibrary() throws {
        let fixture = LibraryBackupTests()
        try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        let items = (0..<3).map {
            Wallpaper(
                title: "Entry \($0)", path: "/synthetic/\($0).png",
                root: "/synthetic", kind: .image)
        }
        try fixture.save(items)
        let before = try Data(contentsOf: fixture.storage)
        for (saved, expected) in [
            (nil, items.last!.id), (UUID(), items.last!.id),
            (items[0].id, items[0].id),
        ] as [(UUID?, UUID)] {
            fixture.defaults.set(saved?.uuidString, forKey: "selectedWallpaper")
            let library = Library(
                maintenance: MaintenanceCoordinator(), storage: fixture.storage,
                defaults: fixture.defaults, restoreOnLaunch: false)
            XCTAssertEqual(library.selected, expected)
            XCTAssertEqual(library.items, items)
            XCTAssertEqual(try Data(contentsOf: fixture.storage), before)
        }
    }

    func testEdgeScrollAndNoninteractiveNativeBridge() {
        XCTAssertEqual(LibraryDragScrollView.edgeDelta(y: 1, height: 300), -12)
        XCTAssertEqual(LibraryDragScrollView.edgeDelta(y: 299, height: 300), 12)
        XCTAssertEqual(LibraryDragScrollView.edgeDelta(y: 150, height: 300), 0)
        XCTAssertEqual(LibraryDragScrollView.edgeDelta(y: -1, height: 300), 0)
        XCTAssertEqual(LibraryDragScrollView.edgeDelta(y: 0, height: 0), 0)
        XCTAssertNil(LibraryDragScrollView().hitTest(.zero))
    }
}
