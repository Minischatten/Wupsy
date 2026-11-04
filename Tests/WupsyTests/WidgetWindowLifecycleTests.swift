import AppKit
import XCTest

@testable import Wupsy

@MainActor private final class WidgetLifecycleTestWindow: NSWindow {
    var frontRequests = 0
    override func makeKeyAndOrderFront(_ sender: Any?) {
        frontRequests += 1
        super.makeKeyAndOrderFront(sender)
    }
}

@MainActor final class WidgetWindowLifecycleTests: XCTestCase {
    private func window() -> WidgetLifecycleTestWindow {
        let window = WidgetLifecycleTestWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier(
            "widget-lifecycle.tests." + UUID().uuidString)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        return window
    }
    private func withWidgets(_ body: (DesktopWidgets) async throws -> Void) async throws {
        _ = NSApplication.shared
        let domain = "widget-window.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let widgets = DesktopWidgets(defaults: defaults, maintenance: MaintenanceCoordinator())
        defer {
            widgets.shutdownForMaintenance()
            defaults.removePersistentDomain(forName: domain)
        }
        try await body(widgets)
    }
    private func transition(_ window: NSWindow, notification: Notification.Name, action: () -> Void)
        async
    {
        let completed = expectation(forNotification: notification, object: window)
        action()
        await fulfillment(of: [completed], timeout: 3)
    }

    func testVisibleWindowReturnsAfterEditingAndRepeatedEntryDoesNotLoseOwnership() async throws {
        try await withWidgets { widgets in
            let window = window()
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            XCTAssertTrue(window.isVisible)
            let identifier = window.identifier
            for _ in 0..<2 {
                await transition(window, notification: NSWindow.didMiniaturizeNotification) {
                    widgets.setEditing(true)
                }
                XCTAssertTrue(window.isMiniaturized)
                widgets.setEditing(true)
                await transition(window, notification: NSWindow.didDeminiaturizeNotification) {
                    widgets.setEditing(false)
                }
                XCTAssertTrue(window.isVisible)
                XCTAssertFalse(window.isMiniaturized)
                XCTAssertEqual(window.identifier, identifier)
                XCTAssertTrue(NSApp.windows.contains { $0 === window })
            }
        }
    }

    func testPreviouslyHiddenAndAlreadyMinimizedWindowsStayUnchanged() async throws {
        try await withWidgets { widgets in
            let hidden = window()
            let minimized = window()
            defer {
                hidden.close()
                minimized.close()
            }
            minimized.orderFront(nil)
            await transition(minimized, notification: NSWindow.didMiniaturizeNotification) {
                minimized.miniaturize(nil)
            }
            XCTAssertFalse(hidden.isVisible)
            widgets.setEditing(true)
            widgets.setEditing(false)
            XCTAssertFalse(hidden.isVisible)
            XCTAssertFalse(hidden.isMiniaturized)
            XCTAssertTrue(minimized.isMiniaturized)
        }
    }

    func testUserRestoringThenMinimizingWindowAgainOverridesEditingSession() async throws {
        try await withWidgets { widgets in
            let window = window()
            defer { window.close() }
            window.orderFront(nil)
            await transition(window, notification: NSWindow.didMiniaturizeNotification) {
                widgets.setEditing(true)
            }
            await transition(window, notification: NSWindow.didDeminiaturizeNotification) {
                window.deminiaturize(nil)
            }
            await transition(window, notification: NSWindow.didMiniaturizeNotification) {
                window.miniaturize(nil)
            }
            widgets.setEditing(false)
            XCTAssertTrue(window.isMiniaturized)
        }
    }

    func testClosedWindowIsNotReopenedAtEndOfEditing() async throws {
        try await withWidgets { widgets in
            let window = window()
            defer { window.close() }
            window.orderFront(nil)
            await transition(window, notification: NSWindow.didMiniaturizeNotification) {
                widgets.setEditing(true)
            }
            window.close()
            widgets.setEditing(false)
            XCTAssertFalse(window.isVisible)
        }
    }

    func testWindowOpenedDuringEditingPreventsForcingOriginalToFront() async throws {
        try await withWidgets { widgets in
            let original = window()
            let opened = window()
            defer {
                original.close()
                opened.close()
            }
            original.makeKeyAndOrderFront(nil)
            await transition(original, notification: NSWindow.didMiniaturizeNotification) {
                widgets.setEditing(true)
            }
            opened.makeKeyAndOrderFront(nil)
            XCTAssertTrue(opened.isVisible)
            let previousRequests = original.frontRequests
            await transition(original, notification: NSWindow.didDeminiaturizeNotification) {
                widgets.setEditing(false)
            }
            XCTAssertTrue(original.isVisible)
            XCTAssertTrue(opened.isVisible)
            XCTAssertEqual(original.frontRequests, previousRequests)
        }
    }

    func testApplicationHideDiscardsPendingRestoration() async throws {
        try await withWidgets { widgets in
            let window = window()
            defer { window.close() }
            window.orderFront(nil)
            await transition(window, notification: NSWindow.didMiniaturizeNotification) {
                widgets.setEditing(true)
            }
            NotificationCenter.default.post(name: NSApplication.didHideNotification, object: NSApp)
            widgets.setEditing(false)
            XCTAssertTrue(window.isMiniaturized)
        }
    }

    func testSessionResignDiscardsRestorationAndMaintenanceShutdownStaysWriteFree() async throws {
        try await withWidgets { widgets in
            let window = window()
            defer { window.close() }
            window.orderFront(nil)
            await transition(window, notification: NSWindow.didMiniaturizeNotification) {
                widgets.setEditing(true)
            }
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            XCTAssertFalse(widgets.editing)
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
            widgets.setEditing(false)
            XCTAssertTrue(window.isMiniaturized)
            await transition(window, notification: NSWindow.didDeminiaturizeNotification) {
                window.deminiaturize(nil)
            }
            await transition(window, notification: NSWindow.didMiniaturizeNotification) {
                widgets.setEditing(true)
            }
            widgets.shutdownForMaintenance()
            widgets.setEditing(false)
            XCTAssertTrue(window.isMiniaturized)
        }
    }
}
