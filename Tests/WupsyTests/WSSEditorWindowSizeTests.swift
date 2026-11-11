import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSEditorWindowSizeTests: XCTestCase {
    var domain: String!
    var preferences: WSSEditorWindowSize!
    let minimum = NSSize(width: 1000, height: 650)
    let large = NSRect(x: -2000, y: 40, width: 2000, height: 1400)

    override func setUpWithError() throws {
        domain = "editor-window-size-tests." + UUID().uuidString
        preferences = WSSEditorWindowSize(defaults: try XCTUnwrap(UserDefaults(suiteName: domain)))
    }
    override func tearDownWithError() throws {
        preferences.defaults.removePersistentDomain(forName: domain)
    }
    func testDefaultUsesVisiblePointAreaAndLargerWorkspace() {
        let frame = preferences.initialFrame(in: large, minimum: minimum)
        XCTAssertEqual(frame.size, NSSize(width: 1800, height: 1200))
        XCTAssertEqual(frame.midX, large.midX)
        XCTAssertEqual(frame.midY, large.midY)
        let laptop = NSRect(x: 0, y: 70, width: 1440, height: 830)
        XCTAssertEqual(
            preferences.initialFrame(in: laptop, minimum: minimum).size,
            NSSize(width: 1368, height: 788.5))
        XCTAssertNil(preferences.saved)
        XCTAssertNil(preferences.defaults.object(forKey: WSSEditorWindowSize.key))
    }
    func testSizeIsAppWideAndSurvivesNewPreferencesInstance() throws {
        let size = NSSize(width: 1600, height: 1000)
        preferences.recordUserSize(size)
        let reopened = WSSEditorWindowSize(defaults: try XCTUnwrap(UserDefaults(suiteName: domain)))
        XCTAssertEqual(reopened.saved, size)
        XCTAssertEqual(reopened.initialFrame(in: large, minimum: minimum).size, size)
        XCTAssertEqual(preferences.defaults.array(forKey: WSSEditorWindowSize.key)?.count, 2)
    }
    func testSmallScreenClampPreservesPreferredSizeAndAdaptsMinimum() {
        let preferred = NSSize(width: 1700, height: 1100)
        preferences.recordUserSize(preferred)
        let small = NSRect(x: 500, y: -600, width: 800, height: 500)
        XCTAssertEqual(preferences.initialFrame(in: small, minimum: minimum), small)
        XCTAssertEqual(
            WSSEditorWindowSize.constrained(large, to: small, minimum: minimum), small)
        XCTAssertEqual(preferences.saved, preferred)
        XCTAssertEqual(preferences.initialFrame(in: large, minimum: minimum).size, preferred)
        let offscreen = NSRect(x: -5000, y: 6000, width: 1200, height: 900)
        let constrained = WSSEditorWindowSize.constrained(offscreen, to: large, minimum: minimum)
        XCTAssertTrue(large.contains(constrained))
        XCTAssertEqual(constrained.size, offscreen.size)
    }
    func testInvalidAndOldPreferencesAreIgnoredOrBoundedWithoutRewriting() {
        let values: [Any] = [
            "old-frame-string", [1500], [-1, 900], [0, 900], [50000, 900], ["a", "b"],
        ]
        for value in values {
            preferences.defaults.set(value, forKey: WSSEditorWindowSize.key)
            XCTAssertNil(preferences.saved)
            XCTAssertEqual(
                preferences.initialFrame(in: large, minimum: minimum).size,
                NSSize(width: 1800, height: 1200))
        }
        preferences.recordUserSize(NSSize(width: 100, height: 100))
        XCTAssertEqual(preferences.initialFrame(in: large, minimum: minimum).size, minimum)
        preferences.recordUserSize(NSSize(width: CGFloat.infinity, height: 900))
        preferences.recordUserSize(NSSize(width: 1500, height: CGFloat.nan))
        XCTAssertEqual(preferences.saved, NSSize(width: 100, height: 100))
    }
    func testNativeControllersShareSizeButNotLiveFramesOrDocumentState() async throws {
        let fixture = WSSDraftTests()
        try await fixture.setUp()
        defer { try? fixture.fixture.tearDownWithError() }
        let draft = try await fixture.draft()
        let first = WSSEditorDocument(project: draft)
        let firstController = WSSEditorWindowController(
            document: first, onClose: {}, sizePreferences: preferences)
        defer {
            first.close()
            firstController.close()
        }
        let window = try XCTUnwrap(firstController.window)
        XCTAssertFalse(window.isRestorable)
        XCTAssertEqual(window.frameAutosaveName, "")
        XCTAssertNil(preferences.saved)
        let note = Notification(name: NSWindow.didEndLiveResizeNotification, object: window)
        // Normal programmatic sizing and closing must not become user preferences.
        let originalModel = first.state.workingModel
        let chosen = NSSize(
            width: max(1000, window.frame.width - 30),
            height: max(700, window.frame.height - 30))
        window.setFrame(NSRect(origin: window.frame.origin, size: chosen), display: false)
        XCTAssertNil(preferences.saved)
        firstController.windowWillStartLiveResize(note)
        firstController.windowDidEndLiveResize(note)
        let saved = try XCTUnwrap(preferences.saved)
        XCTAssertEqual(saved, window.frame.size)
        let unchangedFirstFrame = window.frame
        let otherDraft = try await fixture.draft()
        defer { try? otherDraft.handle.draftOwner?.discard() }
        let receipt = try await fixture.store().publishWSSDraft(fixture.snapshot(otherDraft))
        let existing = WSSEditorDocument(project: receipt.project)
        let secondController = WSSEditorWindowController(
            document: existing, onClose: {}, sizePreferences: preferences)
        defer {
            existing.close()
            secondController.close()
        }
        let otherWindow = try XCTUnwrap(secondController.window)
        let restoredVisible = try XCTUnwrap(otherWindow.screen?.visibleFrame)
        let restoredMinimum = otherWindow.frameRect(
            forContentRect: NSRect(origin: .zero, size: WSSEditorWindowSize.minimumContent)
        ).size
        let expectedSize = preferences.initialFrame(
            in: restoredVisible, minimum: restoredMinimum
        ).size
        XCTAssertEqual(otherWindow.frame.size, expectedSize)
        XCTAssertEqual(preferences.saved, saved)
        XCTAssertEqual(window.frame, unchangedFirstFrame)
        let unchangedOtherFrame = otherWindow.frame
        let visible = try XCTUnwrap(window.screen?.visibleFrame)
        let smaller = NSRect(origin: visible.origin, size: NSSize(width: 800, height: 500))
        firstController.windowWillStartLiveResize(note)
        firstController.constrainWindow(to: smaller)
        firstController.windowDidEndLiveResize(note)
        XCTAssertEqual(preferences.saved, saved)
        XCTAssertEqual(otherWindow.frame, unchangedOtherFrame)
        XCTAssertTrue(smaller.contains(window.frame))
        XCTAssertLessThanOrEqual(window.contentMinSize.width, smaller.width)
        XCTAssertLessThanOrEqual(window.contentMinSize.height, smaller.height)
        firstController.windowWillEnterFullScreen(note)
        firstController.windowWillStartLiveResize(note)
        firstController.windowDidEndLiveResize(note)
        XCTAssertTrue(firstController.windowShouldZoom(window, toFrame: large))
        XCTAssertEqual(preferences.saved, saved)
        firstController.windowDidFailToEnterFullScreen(window)
        XCTAssertEqual(first.state.workingModel, originalModel)
        XCTAssertTrue(first.isUnpublished)
        XCTAssertFalse(existing.isDirty)
        first.close()
        firstController.close()
        XCTAssertEqual(preferences.saved, saved)
        XCTAssertTrue(secondController.windowShouldZoom(otherWindow, toFrame: visible))
        XCTAssertEqual(preferences.saved, visible.size)
        XCTAssertEqual(otherWindow.frame, unchangedOtherFrame)
    }
}
