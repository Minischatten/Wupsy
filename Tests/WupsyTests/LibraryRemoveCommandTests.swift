import XCTest

@testable import Wupsy

@MainActor final class LibraryRemoveCommandTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var maintenance: MaintenanceCoordinator!
    private var library: Library!
    private var item: Wallpaper!

    override func setUpWithError() throws {
        suite = "LibraryRemoveCommandTests-" + UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        maintenance = MaintenanceCoordinator()
        item = Wallpaper(
            title: "Synthetic", path: root.appendingPathComponent("image.png").path,
            root: root.path, kind: .image)
        let storage = root.appendingPathComponent("library.json")
        try JSONEncoder().encode([item!]).write(to: storage)
        library = Library(
            maintenance: maintenance, storage: storage, defaults: defaults,
            restoreOnLaunch: false, targetScreens: { [] })
    }
    override func tearDownWithError() throws {
        library = nil
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }
    func testExistingSelectionIsRemovableButNoOrStaleSelectionIsNot() {
        XCTAssertTrue(library.canRemove(item))
        XCTAssertFalse(library.canRemove(nil))
        var stale = item!
        stale.id = UUID()
        XCTAssertFalse(library.canRemove(stale))
    }
    func testBusyAndUnreadableLibraryDisableRemove() throws {
        library.importing = true
        XCTAssertFalse(library.canRemove(item))
        library.importing = false
        XCTAssertTrue(library.canRemove(item))
        let storage = root.appendingPathComponent("invalid.json")
        try Data("invalid".utf8).write(to: storage)
        let unreadable = Library(
            maintenance: maintenance, storage: storage, defaults: defaults,
            restoreOnLaunch: false, targetScreens: { [] })
        unreadable.items = [item]
        XCTAssertFalse(unreadable.canRemove(item))
    }
    func testFreezeAndRestartDisableRemove() throws {
        let job = try maintenance.reserve(.restore)
        XCTAssertTrue(library.canRemove(item))
        try maintenance.freeze()
        XCTAssertFalse(library.canRemove(item))
        try maintenance.requireRestart()
        XCTAssertFalse(library.canRemove(item))
        job.finish()
        XCTAssertFalse(library.canRemove(item))
    }
}
