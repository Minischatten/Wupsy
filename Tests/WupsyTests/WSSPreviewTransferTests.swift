import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSPreviewTransferTests: XCTestCase {
    func testSlimeTransferPreservesPlayheadPauseAndPresentation() async throws {
        try await exerciseTransfer(effect: .slime)
    }

    func testStarfieldTransferStillRenewsPlayer() async throws {
        try await exerciseTransfer(effect: .starfield)
    }

    func testMusicNotesTransferStillRenewsPlayer() async throws {
        try await exerciseTransfer(effect: .musicNotes)
    }

    private enum TransferEffect {
        case slime, starfield, musicNotes
    }

    private func exerciseTransfer(effect: TransferEffect) async throws {
        let fixture = WSSMaskEditingTests()
        try await fixture.setUp()
        do {
            try await exerciseTransfer(fixture.doc, effect: effect)
        } catch {
            try await fixture.tearDown()
            throw error
        }
        try await fixture.tearDown()
    }

    private func exerciseTransfer(_ doc: WSSEditorDocument, effect: TransferEffect) async throws {
        switch effect {
        case .slime: try doc.addSlime()
        case .starfield:
            try doc.addStarfield()
            let id = try XCTUnwrap(doc.selection?.layer)
            try doc.changeStarfield(id, name: "Twinkle") { $0.starfield.twinkleEnabled = true }
        case .musicNotes: try doc.addMusicNotes()
        }
        await doc.waitForPreview()
        XCTAssertTrue(doc.previewIsCurrent)
        let host = WSSPreviewHost(document: doc)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 330),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.center()
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        defer {
            host.shutdown()
            window.close()
        }
        for _ in 0..<100 where host.surface.player?.view.isPaused != false {
            try await Task.sleep(for: .milliseconds(10))
        }

        let original = try XCTUnwrap(host.surface.player)
        XCTAssertFalse(original.view.isPaused)
        if effect == .slime {
            let layer = try XCTUnwrap(doc.selection?.layer)
            try doc.changeSlime(layer, name: "Gloss") { $0.configuration.gloss = 0.6 }
            await doc.waitForPreview()
            host.update(doc)
            XCTAssertTrue(host.surface.player === original)
            XCTAssertTrue(doc.previewIsCurrent)
        }
        let resources = original.resources

        func transfer(from previous: WSSStaticPlayer, _ action: () -> Void) throws
            -> WSSStaticPlayer
        {
            let time = previous.elapsed
            let started = ProcessInfo.processInfo.systemUptime
            action()
            let next = try XCTUnwrap(host.surface.player)
            XCTAssertFalse(next === previous)
            XCTAssertFalse(next.view === previous.view)
            XCTAssertTrue(next.resources === resources)
            XCTAssertNil(previous.view.delegate)
            XCTAssertFalse(next.view.isPaused)
            XCTAssertGreaterThanOrEqual(next.elapsed, time)
            XCTAssertLessThanOrEqual(
                next.elapsed - time, ProcessInfo.processInfo.systemUptime - started + 0.02)
            return next
        }

        let expanded = try transfer(from: original) { host.expand() }
        XCTAssertTrue(expanded.view.window === host.expandedWindow)
        if effect == .slime {
            try await requirePresentation(of: expanded)
        }
        let restored = try transfer(from: expanded) { host.restore() }
        XCTAssertTrue(restored.view.window === window)
        XCTAssertNil(host.expandedWindow)
        if effect == .slime {
            try await requirePresentation(of: restored)

            doc.playing = false
            host.update(doc)
            let frozen = restored.elapsed
            host.expand()
            XCTAssertTrue(restored.view.window === host.expandedWindow)
            XCTAssertTrue(host.surface.player === restored)
            XCTAssertTrue(restored.view.isPaused)
            host.restore()
            XCTAssertTrue(restored.view.window === window)
            XCTAssertTrue(host.surface.player === restored)
            XCTAssertTrue(restored.view.isPaused)
            XCTAssertEqual(restored.elapsed, frozen)
            XCTAssertFalse(doc.playing)
        }

    }

    private func requirePresentation(of player: WSSStaticPlayer) async throws {
        guard ProcessInfo.processInfo.environment["WUPSY_REQUIRE_METAL_PRESENTATION"] == "1"
        else { return }
        XCTAssertNotNil(player.startMeasuring())
        defer { player.stopMeasuring() }
        for _ in 0..<18 {
            try await Task.sleep(for: .milliseconds(250))
            if let window = player.performanceSnapshot()?.frameWindow,
                window.confirmedPresentations > 0
            {
                return
            }
        }
        XCTFail("No confirmed Metal presentation after transfer")
    }
}
