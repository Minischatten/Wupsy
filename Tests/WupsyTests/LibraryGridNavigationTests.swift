import XCTest

@testable import Wupsy

final class LibraryGridNavigationTests: XCTestCase {
    func testHorizontalNavigationFollowsVisibleOrderAcrossRows() {
        XCTAssertNil(LibraryGridDirection.left.destination(from: 0, count: 8, columns: 3))
        XCTAssertEqual(LibraryGridDirection.right.destination(from: 2, count: 8, columns: 3), 3)
        XCTAssertEqual(LibraryGridDirection.left.destination(from: 3, count: 8, columns: 3), 2)
        XCTAssertNil(LibraryGridDirection.right.destination(from: 7, count: 8, columns: 3))
    }

    func testVerticalNavigationUsesColumnAndClampsOnlyIntoAnExistingRow() {
        XCTAssertNil(LibraryGridDirection.up.destination(from: 2, count: 8, columns: 3))
        XCTAssertEqual(LibraryGridDirection.up.destination(from: 4, count: 8, columns: 3), 1)
        XCTAssertEqual(LibraryGridDirection.down.destination(from: 4, count: 8, columns: 3), 7)
        XCTAssertEqual(LibraryGridDirection.down.destination(from: 5, count: 8, columns: 3), 7)
        XCTAssertNil(LibraryGridDirection.down.destination(from: 6, count: 8, columns: 3))
        XCTAssertNil(LibraryGridDirection.down.destination(from: 7, count: 8, columns: 3))
    }

    func testWidthChangesColumnCountAndNavigation() {
        let minimum: CGFloat = 178
        for (width, columns) in [(160.0, 1), (363.0, 1), (364.0, 2), (550.0, 3)] {
            let actual = LibraryGridLayout.columnCount(width: width, minimum: minimum)
            XCTAssertEqual(actual, columns)
            XCTAssertEqual(
                LibraryGridDirection.down.destination(from: 0, count: 8, columns: actual), columns)
        }
    }

    func testMissingFilteredSelectionStartsAtFirstItemAndEmptyGridKeepsNoSelection() {
        for direction in LibraryGridDirection.allCases {
            XCTAssertEqual(direction.destination(from: nil, count: 2, columns: 3), 0)
            XCTAssertEqual(direction.destination(from: 5, count: 2, columns: 3), 0)
            XCTAssertNil(direction.destination(from: nil, count: 0, columns: 3))
        }
    }
}
