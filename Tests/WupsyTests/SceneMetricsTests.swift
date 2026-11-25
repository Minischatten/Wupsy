import Darwin
import Foundation
import Metal
import XCTest
import os

@testable import Wupsy

final class SceneMetricsTests: XCTestCase {
    @MainActor func testCompletionCountsAreIndependentOfValidGPUTimestamps() {
        let metrics = SceneMetrics()
        let start = metrics.snapshot()
        for timestamps in [(0.0, 0.0), (0, 1), (2, 1), (2, 2), (.nan, 3), (2, .infinity)] {
            metrics.recordCompletion(success: true) { timestamps }
        }
        metrics.recordCompletion(success: false) {
            XCTFail("Failed buffers must not read GPU timestamps")
            return (1, 2)
        }
        XCTAssertEqual(metrics.snapshot().frames, 6)
        XCTAssertNil(metrics.snapshot().averageGPUMilliseconds(since: start))

        metrics.recordCompletion(success: true) { (1, 1.125) }
        metrics.recordCompletion(success: true) { (2, 2.25) }
        let end = metrics.snapshot()
        XCTAssertEqual(end.frames, 8)
        XCTAssertEqual(end.gpuSamples, 2)
        XCTAssertEqual(end.averageGPUMilliseconds(since: start), 187.5)

        metrics.deactivate()
        metrics.recordCompletion(success: true) {
            XCTFail("Retired collectors must not read GPU timestamps")
            return (1, 2)
        }
        XCTAssertEqual(metrics.snapshot(), end)
    }

    @MainActor func testFrameWindowRatesUseElapsedTimeAndIndependentSamples() throws {
        let clock = OSAllocatedUnfairLock(initialState: 100.0)
        let metrics = SceneMetrics(now: { clock.withLock { $0 } })
        XCTAssertNil(metrics.takeFrameWindow())

        let first = try XCTUnwrap(metrics.beginEncoding())
        clock.withLock { $0 += 0.125 }
        metrics.encoded(first)
        metrics.recordCompletion(success: true, encoding: first) { (100, 100.25) }

        let aborted = try XCTUnwrap(metrics.beginEncoding())
        // No encoded call for an aborted frame.
        metrics.recordCompletion(success: false, encoding: aborted) {
            XCTFail("Failed buffers must not read GPU timestamps")
            return (0, 0)
        }

        let second = try XCTUnwrap(metrics.beginEncoding())
        clock.withLock { $0 += 0.25 }
        metrics.encoded(second)
        metrics.recordCompletion(success: true, encoding: second) { (0, 0) }
        metrics.presented(first, at: 100.25)
        metrics.presented(second, at: 0)

        clock.withLock { $0 = 102 }
        let window = try XCTUnwrap(metrics.takeFrameWindow())
        XCTAssertEqual(window.seconds, 2)
        XCTAssertEqual(window.cpuSamples, 2)
        XCTAssertEqual(window.averageCPUMilliseconds, 187.5)
        XCTAssertEqual(window.gpuCompletionsPerSecond, 1)
        XCTAssertEqual(window.gpu.gpuSamples, 1)
        XCTAssertEqual(window.averageGPUMilliseconds, 250)
        XCTAssertEqual(window.confirmedPresentations, 1)
        XCTAssertEqual(window.presentedFPS, 0.5)

        clock.withLock { $0 = 102.5 }
        let idle = try XCTUnwrap(metrics.takeFrameWindow())
        XCTAssertEqual(idle.seconds, 0.5)
        XCTAssertEqual(idle.presentedFPS, 0)
        XCTAssertEqual(idle.gpuCompletionsPerSecond, 0)
        XCTAssertNil(idle.averageCPUMilliseconds)
        XCTAssertNil(idle.averageGPUMilliseconds)
    }

    @MainActor func testOldPresentationTimesAndUnconfirmedFramesStayUnavailable() throws {
        let clock = OSAllocatedUnfairLock(initialState: 10.0)
        let metrics = SceneMetrics(now: { clock.withLock { $0 } })
        let pending = try XCTUnwrap(metrics.beginEncoding())
        metrics.encoded(pending)
        clock.withLock { $0 = 11 }
        XCTAssertNil(try XCTUnwrap(metrics.takeFrameWindow()).presentedFPS)
        metrics.presented(pending, at: 10.75)

        for time in [Double.nan, .infinity, -1, 0, 10.99, 12] {
            let frame = try XCTUnwrap(metrics.beginEncoding())
            metrics.encoded(frame)
            metrics.presented(frame, at: time)
        }
        let current = try XCTUnwrap(metrics.beginEncoding())
        metrics.encoded(current)
        clock.withLock { $0 = 11.5 }
        let missing = try XCTUnwrap(metrics.takeFrameWindow())
        XCTAssertNil(missing.presentedFPS)
        XCTAssertEqual(missing.confirmedPresentations, 0)

        // This frame was submitted in the previous window but presented in this one.
        clock.withLock { $0 = 11.75 }
        metrics.presented(current, at: 11.625)
        clock.withLock { $0 = 12 }
        XCTAssertEqual(try XCTUnwrap(metrics.takeFrameWindow()).presentedFPS, 2)
    }

    @MainActor func testLifecycleResetAndReplacementRejectLateFrameCallbacks() throws {
        let clock = OSAllocatedUnfairLock(initialState: 10.0)
        let old = SceneMetrics(now: { clock.withLock { $0 } })
        let stale = try XCTUnwrap(old.beginEncoding())
        old.encoded(stale)
        clock.withLock { $0 = 11 }
        old.resetFrameWindow()
        let live = try XCTUnwrap(old.beginEncoding())
        old.encoded(live)
        clock.withLock { $0 = 12 }
        old.presented(stale, at: 11.5)
        old.recordCompletion(success: true, encoding: stale) { (11, 12) }
        old.presented(live, at: 11.75)
        let window = try XCTUnwrap(old.takeFrameWindow())
        XCTAssertEqual(window.cpuSamples, 1)
        XCTAssertEqual(window.presentedFPS, 1)
        XCTAssertEqual(window.gpu.frames, 0)
        XCTAssertEqual(old.snapshot().frames, 1)

        old.deactivate()
        let replacement = SceneMetrics(now: { clock.withLock { $0 } })
        let new = try XCTUnwrap(replacement.beginEncoding())
        replacement.encoded(new)
        clock.withLock { $0 = 13 }
        old.presented(live, at: 12.5)
        replacement.presented(stale, at: 12.5)
        XCTAssertNil(old.beginEncoding())
        XCTAssertNil(old.takeFrameWindow())
        XCTAssertNil(try XCTUnwrap(replacement.takeFrameWindow()).presentedFPS)
    }

    func testMemoryScopesAndUnavailableValues() throws {
        let footprint = PerformanceMemory.processFootprintBytes { info, _ in
            info.phys_footprint = 8_388_608
            return KERN_SUCCESS
        }
        XCTAssertEqual(footprint, 8_388_608)
        XCTAssertNil(PerformanceMemory.processFootprintBytes { _, _ in KERN_FAILURE })
        XCTAssertNil(
            PerformanceMemory.processFootprintBytes { info, count in
                info.phys_footprint = 8_388_608
                count = 0
                return KERN_SUCCESS
            })
        XCTAssertNil(PerformanceMemory.metalAllocation(for: nil))
        XCTAssertNil(PerformanceMemory.metalAllocation(registryID: 11, bytes: -1))
        XCTAssertEqual(
            PerformanceMemory.metalAllocation(registryID: 11, bytes: 0),
            .init(registryID: 11, bytes: 0))
        XCTAssertEqual(
            PerformanceMemory.metalAllocation(registryID: 22, bytes: 1_048_576),
            .init(registryID: 22, bytes: 1_048_576))
        XCTAssertGreaterThan(try XCTUnwrap(PerformanceMemory.processFootprintBytes()), 0)
    }

    @MainActor func testBenchmarkJSONDistinguishesZeroCompletionsAndUnavailableTiming() throws {
        let start = SceneMetrics.Totals(frames: 5, gpuSamples: 2, gpuSeconds: 0.5)
        let end = SceneMetrics.Totals(frames: 9, gpuSamples: 3, gpuSeconds: 0.625)
        func json(_ fields: [String: Any]) throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: fields)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        let measured = try json(Benchmark.sceneMeasurement(start: start, end: end, seconds: 2))
        XCTAssertEqual(measured["sceneFrames"] as? Int, 4)
        XCTAssertEqual(measured["sceneMeasuredFPS"] as? Double, 2)
        XCTAssertEqual(measured["sceneGPUAverageMilliseconds"] as? Double, 125)
        XCTAssertEqual(measured["sceneGPUValidSamples"] as? Int, 1)

        let idle = try json(Benchmark.sceneMeasurement(start: start, end: start, seconds: 2))
        XCTAssertEqual(idle["sceneMeasuredFPS"] as? Double, 0)
        XCTAssertTrue(idle["sceneGPUAverageMilliseconds"] is NSNull)
        let missing = try json(Benchmark.sceneMeasurement(start: start, end: nil, seconds: 2))
        XCTAssertTrue(missing["sceneFrames"] is NSNull)
        XCTAssertTrue(missing["sceneMeasuredFPS"] is NSNull)
    }

    @MainActor func testSessionLifecycleAndInFlightCompletionIsolation() async throws {
        let (root, item) = try ScenePlaybackTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try await ScenePlayback.prepare(for: item)
        func makePlayer() -> WSSStaticPlayer {
            WSSStaticPlayer(
                resources: prepared.resources, size: CGSize(width: 100, height: 50),
                scale: 2, maxDimension: 160, fps: 24, resolution: .standard, offset: 0,
                onError: { XCTFail($0) })
        }

        let player = makePlayer()
        let successor = makePlayer()
        defer {
            player.stop()
            successor.stop()
        }
        let id = player.sessionID
        XCTAssertNotEqual(id, successor.sessionID)
        XCTAssertEqual(player.rendererStatus, .paused)
        XCTAssertNil(player.metrics)
        XCTAssertNil(player.performanceSnapshot())
        XCTAssertNil(player.metalAllocation())

        let released = expectation(description: "Functional completions released")
        released.expectedFulfillmentCount = 3
        let disabledHandler = player.frameCompletionHandler(retryTransitionFrame: false) {
            released.fulfill()
        }
        let first = try XCTUnwrap(player.startMeasuring())
        XCTAssertTrue(player.startMeasuring() === first)
        let firstHandler = player.frameCompletionHandler(retryTransitionFrame: false) {
            released.fulfill()
        }
        player.stopMeasuring()
        XCTAssertNil(player.performanceSnapshot())
        XCTAssertNil(player.metalAllocation())

        let current = try XCTUnwrap(player.startMeasuring())
        XCTAssertFalse(current === first)
        let activeHandler = player.frameCompletionHandler(retryTransitionFrame: false) {
            released.fulfill()
        }
        for handler in [disabledHandler, firstHandler, activeHandler] {
            let command = try XCTUnwrap(prepared.resources.queue.makeCommandBuffer())
            command.addCompletedHandler(handler)
            command.commit()
        }
        await fulfillment(of: [released], timeout: 3)
        XCTAssertEqual(first.snapshot().frames, 0)
        XCTAssertEqual(current.snapshot().frames, 1)
        XCTAssertEqual(player.metalAllocation()?.registryID, prepared.resources.device.registryID)

        player.play()
        XCTAssertEqual(player.performanceSnapshot()?.status, .onDemand)
        player.setRenderResolution(.hiDPI)
        let snapshot = try XCTUnwrap(player.performanceSnapshot())
        XCTAssertEqual(snapshot.sessionID, id)
        XCTAssertEqual(snapshot.targetDrawableSize, CGSize(width: 160, height: 80))
        XCTAssertNil(snapshot.submittedDrawableSize)
        XCTAssertEqual(snapshot.targetFPS, 24)
        current.submitted(width: 160, height: 80)
        player.pause()
        XCTAssertEqual(player.performanceSnapshot()?.status, .paused)
        XCTAssertNil(current.submittedDrawableSize)
        current.submitted(width: 160, height: 80)
        player.play()
        XCTAssertEqual(player.performanceSnapshot()?.status, .onDemand)
        XCTAssertNil(current.submittedDrawableSize)
        player.stop()
        XCTAssertNil(player.performanceSnapshot())
        XCTAssertNil(player.startMeasuring())
        XCTAssertEqual(player.sessionID, id)
        XCTAssertEqual(player.rendererStatus, .stopped)
    }
}
