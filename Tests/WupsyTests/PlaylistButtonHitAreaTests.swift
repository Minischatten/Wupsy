import AppKit
import SwiftUI
import XCTest

@testable import Wupsy

@MainActor final class PlaylistButtonHitAreaTests: XCTestCase {
    private func value(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
    private func nodes(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            let children =
                (value(node, "accessibilityChildren") as? [NSObject] ?? [])
                + (value(node, "accessibilityChildrenInNavigationOrder") as? [NSObject] ?? [])
                + (value(node, "accessibilityContents") as? [NSObject] ?? [])
                + ((node as? NSView)?.subviews ?? [])
            return [node] + children.flatMap(walk)
        }
        return walk(root)
    }
    private func bool(_ object: NSObject, _ name: String) throws -> Bool {
        let selector = NSSelectorFromString(name)
        let implementation = try XCTUnwrap(
            object.responds(to: selector) ? object.method(for: selector) : nil)
        typealias Method = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(implementation, to: Method.self)(object, selector)
    }
    private func frame(_ object: NSObject) throws -> NSRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        let implementation = try XCTUnwrap(
            object.responds(to: selector) ? object.method(for: selector) : nil)
        typealias Method = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(implementation, to: Method.self)(object, selector)
    }
    func testHostedPlaylistButtonsHaveSeparate36PointTargetsAndAccessibleActions() async throws {
        _ = NSApplication.shared
        var adds = 0
        var checks = 0
        var removes = 0
        let appeared = expectation(description: "Playlist buttons appeared")
        let host = NSHostingView(
            rootView: HStack(spacing: 9) {
                Text("Outside button targets")
                Spacer()
                Button {
                    adds += 1
                } label: {
                    PlaylistEntryButtonLabel(systemName: "plus")
                }
                .accessibilityIdentifier("add").accessibilityLabel(
                    ProductText.playlistAddTitle.format("Example"))
                Button {
                    checks += 1
                } label: {
                    PlaylistEntryButtonLabel(systemName: "checkmark")
                }
                .accessibilityIdentifier("check").accessibilityLabel(
                    ProductText.playlistRemoveTitle.format("Example"))
                Button {
                    removes += 1
                } label: {
                    PlaylistEntryButtonLabel(systemName: "xmark.circle")
                }
                .accessibilityIdentifier("remove").accessibilityLabel(
                    ProductText.playlistRemoveTitle.format("Example"))
            }.buttonStyle(.borderless).frame(width: 420, height: 60)
                .environment(\.accessibilityEnabled, true).onAppear { appeared.fulfill() })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 60), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        await fulfillment(of: [appeared], timeout: 3)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        func button(_ identifier: String) throws -> NSObject {
            try XCTUnwrap(
                nodes(host).first { value($0, "accessibilityIdentifier") as? String == identifier },
                identifier + " host=\(host.frame) nodes="
                    + nodes(host).map {
                        "\(value($0, "accessibilityRole") ?? "")|\(value($0, "accessibilityIdentifier") ?? "")|\(value($0, "accessibilityLabel") ?? "")"
                    }.joined(separator: "\n"))
        }
        let add = try button("add")
        let check = try button("check")
        let remove = try button("remove")
        for (node, label) in [
            (add, ProductText.playlistAddTitle.format("Example")),
            (check, ProductText.playlistRemoveTitle.format("Example")),
            (remove, ProductText.playlistRemoveTitle.format("Example")),
        ] {
            XCTAssertEqual(
                value(node, "accessibilityRole") as? String, NSAccessibility.Role.button.rawValue)
            XCTAssertEqual(value(node, "accessibilityLabel") as? String, label)
            XCTAssertTrue(try bool(node, "isAccessibilityEnabled"))
            let rect = try frame(node)
            XCTAssertEqual(rect.width, 36, accuracy: 1)
            XCTAssertEqual(rect.height, 36, accuracy: 1)
            for point in [
                NSPoint(x: rect.minX + 2, y: rect.minY + 2),
                NSPoint(x: rect.maxX - 2, y: rect.maxY - 2),
            ] {
                let hit = try XCTUnwrap(host.accessibilityHitTest(point) as? NSObject)
                XCTAssertEqual(
                    value(hit, "accessibilityIdentifier") as? String,
                    value(node, "accessibilityIdentifier") as? String)
            }
        }
        XCTAssertFalse(try frame(add).intersects(frame(check)))
        XCTAssertFalse(try frame(remove).intersects(frame(check)))
        let addRect = try frame(add)
        let textHit =
            host.accessibilityHitTest(NSPoint(x: addRect.minX - 70, y: addRect.midY)) as? NSObject
        XCTAssertNotEqual(
            textHit.flatMap { value($0, "accessibilityRole") as? String },
            NSAccessibility.Role.button.rawValue)
        XCTAssertEqual(adds + checks + removes, 0)
        XCTAssertTrue(try bool(add, "accessibilityPerformPress"))
        XCTAssertEqual(adds, 1)
        XCTAssertTrue(try bool(check, "accessibilityPerformPress"))
        XCTAssertEqual(checks, 1)
        XCTAssertTrue(try bool(remove, "accessibilityPerformPress"))
        XCTAssertEqual(removes, 1)
    }
    func testHostedPlaylistButtonReceivesFocusWhenKeyboardNavigationIsEnabled() async throws {
        _ = NSApplication.shared
        // This API reports System Settings > Keyboard > Keyboard navigation, not
        // the separate Full Keyboard Access option under Accessibility > Keyboard.
        try XCTSkipUnless(
            NSApp.isFullKeyboardAccessEnabled,
            "Requires keyboard navigation in System Settings > Keyboard.")
        let ready = expectation(description: "Focusable playlist button appeared")
        let host = NSHostingView(
            rootView: Button {
            } label: {
                PlaylistEntryButtonLabel(systemName: "plus")
            }.buttonStyle(.borderless).accessibilityIdentifier("focusPlaylistButton")
                .accessibilityLabel(ProductText.playlistAddTitle.format("Example"))
                .environment(\.accessibilityEnabled, true).onAppear { ready.fulfill() })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 80), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        await fulfillment(of: [ready], timeout: 3)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let add = try XCTUnwrap(
            nodes(host).first {
                value($0, "accessibilityIdentifier") as? String == "focusPlaylistButton"
            })
        let selector = NSSelectorFromString("setAccessibilityFocused:")
        let implementation = try XCTUnwrap(
            add.responds(to: selector) ? add.method(for: selector) : nil)
        let allowedSelector = NSSelectorFromString("isAccessibilitySelectorAllowed:")
        let allowedImplementation = try XCTUnwrap(
            add.responds(to: allowedSelector) ? add.method(for: allowedSelector) : nil)
        typealias Allowed = @convention(c) (AnyObject, Selector, Selector) -> Bool
        XCTAssertTrue(
            unsafeBitCast(allowedImplementation, to: Allowed.self)(add, allowedSelector, selector))
        typealias Focus = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(implementation, to: Focus.self)(add, selector, true)
        XCTAssertTrue(try bool(add, "isAccessibilityFocused"))
    }
    func testDisabledButtonRetainsTargetAndCannotPerformAction() async throws {
        _ = NSApplication.shared
        var presses = 0
        let ready = expectation(description: "Disabled button appeared")
        let host = NSHostingView(
            rootView: Button {
                presses += 1
            } label: {
                PlaylistEntryButtonLabel(systemName: "plus")
            }.buttonStyle(.borderless).accessibilityIdentifier("disabledPlaylistButton")
                .accessibilityLabel("Add wallpaper").environment(\.accessibilityEnabled, true)
                .disabled(true).onAppear { ready.fulfill() })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 80), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        await fulfillment(of: [ready], timeout: 3)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let node = try XCTUnwrap(
            nodes(host).first {
                value($0, "accessibilityIdentifier") as? String == "disabledPlaylistButton"
            })
        XCTAssertFalse(try bool(node, "isAccessibilityEnabled"))
        _ = try bool(node, "accessibilityPerformPress")
        XCTAssertEqual(presses, 0)
    }
}
