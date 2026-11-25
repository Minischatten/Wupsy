import XCTest

@testable import Wupsy

final class WSSDesktopFrameHistoryTests: XCTestCase {
    func testClockFreezesAtConfirmedTimeAndExcludesLongPause() {
        var clock = WSSPlaybackClock(offset: 2)
        clock.play(now: 10)
        XCTAssertEqual(clock.time(now: 13), 5)
        clock.freeze(at: 4.5)
        XCTAssertEqual(clock.time(now: 13.05), 4.5)
        XCTAssertEqual(clock.time(now: 3600), 4.5)
        clock.play(now: 3600)
        XCTAssertEqual(clock.time(now: 3600.25), 4.75)
    }

    func testHistoryRejectsInvalidEvictedAndLatePresentations() {
        var history = WSSDesktopFrameHistory()
        let old = history.submit(.init(time: 1, trail: nil))
        let newer = history.submit(.init(time: 2, trail: nil))
        XCTAssertTrue(history.presented(newer, at: 20))
        XCTAssertFalse(history.presented(old, at: 19))
        for hostTime in [0, Double.nan, Double.infinity] {
            let frame = history.submit(.init(time: 3, trail: nil))
            XCTAssertFalse(history.presented(frame, at: hostTime))
        }
        let evicted = history.submit(.init(time: 4, trail: nil))
        for _ in 0..<8 { _ = history.submit(.init(time: 5, trail: nil)) }
        XCTAssertFalse(history.presented(evicted, at: 21))
        let stale = history.submit(.init(time: 6, trail: nil))
        history.discardPending()
        XCTAssertFalse(history.presented(stale, at: 22))
        XCTAssertFalse(history.hasPending)
        XCTAssertEqual(history.confirmed?.time, 2)
    }

    func testConfirmedTrailRetainsSamplesAndResumeRebasesPointer() throws {
        var state = try WSSTrailSimulation(configuration: .init(colors: [.init(r: 1, g: 1, b: 1)]))
        state.update(time: 1, pointer: .init(10, 10))
        state.update(time: 1.1, pointer: .init(20, 20))
        var history = WSSDesktopFrameHistory()
        let frame = history.submit(.init(time: 1.1, trail: [0: state]))
        state.update(time: 1.2, pointer: .init(25, 25))
        XCTAssertTrue(history.presented(frame, at: 10))
        var restored = try XCTUnwrap(history.confirmed?.trail?[0])
        let oldSamples = restored.samples
        XCTAssertGreaterThan(oldSamples.count, 1)
        let point = SIMD2<Float>(100, 100)
        restored.rebase(time: 1.1, pointer: point)
        XCTAssertEqual(restored.samples, oldSamples)
        restored.update(time: 1.15, pointer: point)
        restored.update(time: 1.2, pointer: .init(110, 110))
        let newSamples = restored.samples.dropFirst(oldSamples.count)
        XCTAssertEqual(Array(restored.samples.prefix(oldSamples.count)), oldSamples)
        XCTAssertTrue(try XCTUnwrap(newSamples.first).startsSegment)
        let vertices = restored.vertices(time: 1.2)
        XCTAssertTrue(vertices.contains { $0.position.x < 30 })
        XCTAssertTrue(vertices.contains { $0.position.x > 90 })
        XCTAssertFalse(vertices.contains { (35...85).contains($0.position.x) })
    }
}
