import AppKit
import XCTest

@testable import Wupsy

@MainActor final class LibraryRestoreRestartTests: XCTestCase {
    func testOnlyCommittedRestoreCanLaunchAndTerminationFollowsReadiness() throws {
        var events: [String] = []
        for outcome: LibraryRestoreCoordinator.Outcome? in [nil, .restoredA, .unresolved] {
            XCTAssertThrowsError(
                try LibraryRestoreRestart.initiate(
                    outcome: outcome, launch: { events.append("ready") },
                    terminate: { events.append("terminate") }))
        }
        XCTAssertTrue(events.isEmpty)
        try LibraryRestoreRestart.initiate(
            outcome: .committed, launch: { events.append("ready") },
            terminate: { events.append("terminate") })
        XCTAssertEqual(events, ["ready", "terminate"])
    }

    func testFailedLaunchDoesNotTerminateOrReleaseRestoreProtection() throws {
        let maintenance = MaintenanceCoordinator()
        let lease = try maintenance.reserve(.restore)
        try maintenance.freeze()
        try maintenance.requireRestart()
        var terminated = false
        XCTAssertThrowsError(
            try LibraryRestoreRestart.initiate(
                outcome: .committed, launch: { throw CocoaError(.fileReadNoPermission) },
                terminate: { terminated = true }))
        XCTAssertFalse(terminated)
        XCTAssertEqual(maintenance.state, .restartRequired)
        XCTAssertFalse(maintenance.allowsMutation)
        withExtendedLifetime(lease) {}
    }

    func testLaunchConfigurationUsesExactBundleAndFreshInstance() {
        let configuration = LibraryRestoreRestart.configuration()
        XCTAssertFalse(configuration.allowsRunningApplicationSubstitution)
        XCTAssertTrue(configuration.createsNewApplicationInstance)
        XCTAssertTrue(configuration.activates)
        XCTAssertTrue(configuration.arguments.isEmpty)
    }

    func testCommittedLibrarySurvivesFailedRestartAndFreshRuntimeReadsB() async throws {
        let fixture = LibraryRestoreTransactionTests()
        try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        try fixture.a()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: fixture.domain))
        let maintenance = MaintenanceCoordinator()
        let library = Library(
            maintenance: maintenance, storage: fixture.root.appendingPathComponent("library.json"),
            defaults: defaults, restoreOnLaunch: false, targetScreens: { [] })
        XCTAssertTrue(library.items.isEmpty)
        let prepared = try await fixture.b()
        let lease = try maintenance.reserve(.restore)
        try maintenance.freeze()
        await library.stopAndDrainForMaintenance()
        try await LibraryRestorePublication.publish(
            prepared, context: .init(supportRoot: fixture.root, preferenceDomain: fixture.domain))
        try maintenance.requireRestart()
        let before = try fixture.bytes()
        XCTAssertThrowsError(
            try LibraryRestoreRestart.initiate(
                outcome: .committed, launch: { throw CocoaError(.fileReadNoPermission) },
                terminate: { XCTFail("Must remain open on failure") }))
        library.selected = UUID()
        library.profile = .original
        XCTAssertEqual(try fixture.bytes(), before)
        try fixture.assertB(prepared.plan)
        var fresh: Library?
        try WupsyStartup.run(
            context: .init(supportRoot: fixture.root, preferenceDomain: fixture.domain)
        ) {
            fresh = Library(
                maintenance: MaintenanceCoordinator(),
                storage: fixture.root.appendingPathComponent("library.json"), defaults: defaults,
                restoreOnLaunch: false, targetScreens: { [] })
        }
        XCTAssertEqual(fresh?.items.map(\.id), prepared.plan.library.map(\.id))
        withExtendedLifetime(lease) {}
    }

    func testHelperExitDuringHandoffThrowsInsteadOfSignallingParent() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        XCTAssertThrowsError(try LibraryRestoreRestart.authorize(pipe.fileHandleForWriting))
    }

    func testReadinessRequiresExpectedByteAndRejectsEOFAndTimeout() throws {
        for byte: UInt8 in [82, 0] {
            let pipe = Pipe()
            try pipe.fileHandleForWriting.write(contentsOf: Data([byte]))
            if byte == 82 {
                XCTAssertNoThrow(
                    try LibraryRestoreRestart.awaitReadiness(
                        fd: pipe.fileHandleForReading.fileDescriptor, timeoutMilliseconds: 10))
            } else {
                XCTAssertThrowsError(
                    try LibraryRestoreRestart.awaitReadiness(
                        fd: pipe.fileHandleForReading.fileDescriptor, timeoutMilliseconds: 10))
            }
        }
        let pipe = Pipe()
        XCTAssertThrowsError(
            try LibraryRestoreRestart.awaitReadiness(
                fd: pipe.fileHandleForReading.fileDescriptor, timeoutMilliseconds: 1))
        try pipe.fileHandleForWriting.close()
        XCTAssertThrowsError(
            try LibraryRestoreRestart.awaitReadiness(
                fd: pipe.fileHandleForReading.fileDescriptor, timeoutMilliseconds: 10))
    }

    func testUnbundledExecutableIsRejected() {
        XCTAssertThrowsError(try LibraryRestoreRestart.bundleURL(Bundle(for: Self.self)))
    }

    func testCompletionIconIsCenteredWithoutMovingTextOrResizing() {
        _ = NSApplication.shared
        let alert = LibraryRestoreUI.completionAlert(.committed, language: "de")
        let baseline = NSAlert()
        baseline.messageText = alert.messageText
        baseline.informativeText = alert.informativeText
        baseline.addButton(withTitle: alert.buttons[0].title)
        baseline.layout()
        alert.layout()
        XCTAssertEqual(alert.window.frame.size, baseline.window.frame.size)
        func textFrames(_ view: NSView, in content: NSView) -> [String: NSRect] {
            var result: [String: NSRect] = [:]
            for child in view.subviews {
                if let text = child as? NSTextField, !text.stringValue.isEmpty {
                    XCTAssertTrue(text.alignment == .left || text.alignment == .natural)
                    result[text.stringValue] = text.convert(text.bounds, to: content)
                }
                result.merge(textFrames(child, in: content)) { first, _ in first }
            }
            return result
        }
        if let actual = alert.window.contentView, let original = baseline.window.contentView {
            XCTAssertEqual(textFrames(actual, in: actual), textFrames(original, in: original))
        }
        let before = alert.window.frame.size
        alert.layout()
        XCTAssertEqual(alert.window.frame.size, before)
        guard let content = alert.window.contentView else {
            return XCTFail("Missing alert content")
        }
        func images(_ view: NSView) -> [NSImageView] {
            view.subviews.flatMap { child in
                if let image = child as? NSImageView, image.image == alert.icon { return [image] }
                return images(child)
            }
        }
        let icons = images(content)
        XCTAssertEqual(icons.count, 1)
        for icon in icons {
            XCTAssertEqual(
                icon.convert(icon.bounds, to: content).midX, content.bounds.midX, accuracy: 1)
        }
    }
}
