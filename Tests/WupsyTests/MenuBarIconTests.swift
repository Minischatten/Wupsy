import AppKit
import XCTest

@testable import Wupsy

final class MenuBarIconTests: XCTestCase {
    func testDesignSourceLoadsAsSeparateTemplateWithLogicalSize() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Brand/Wupsy-MenuBar-Icon-v1.png")
        let image = try XCTUnwrap(MenuBarIcon.load(from: url))
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size.width, 24)
        XCTAssertEqual(image.size.height, 16)
        XCTAssertEqual(image.accessibilityDescription, "Wupsy")
        let representation = try XCTUnwrap(image.representations.first)
        XCTAssertEqual(representation.pixelsWide, 1536)
        XCTAssertEqual(representation.pixelsHigh, 1024)
        XCTAssertNotEqual(MenuBarIcon.resourceName, "Wupsy")
    }

    func testMissingResourceDoesNotProduceAnInvalidImage() {
        XCTAssertNil(MenuBarIcon.load(from: URL(fileURLWithPath: "/nonexistent/wupsy-menu.png")))
    }
}
