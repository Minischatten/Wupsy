import Foundation
import Metal
import os

enum SceneRendererStatus: Equatable {
    case paused, onDemand, running, stopped, failed
}

struct SceneRenderExtent: Equatable {
    let width: Int
    let height: Int
}

struct ScenePerformanceSnapshot {
    let sessionID: UUID
    let status: SceneRendererStatus
    let targetDrawableSize: CGSize
    let submittedDrawableSize: SceneRenderExtent?
    let completions: SceneMetrics.Totals
}

final class SceneMetrics: Sendable {
    struct Totals: Equatable {
        var frames = 0
        var gpuSamples = 0
        var gpuSeconds = 0.0

        func averageGPUMilliseconds(since start: Self) -> Double? {
            let samples = gpuSamples - start.gpuSamples
            guard samples > 0 else { return nil }
            return (gpuSeconds - start.gpuSeconds) * 1000 / Double(samples)
        }
    }

    private struct State {
        var active = true
        var totals = Totals()
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    @MainActor fileprivate(set) var submittedDrawableSize: SceneRenderExtent?

    @MainActor func submitted(width: Int, height: Int) {
        submittedDrawableSize = SceneRenderExtent(width: width, height: height)
    }

    func completed(_ command: MTLCommandBuffer) {
        recordCompletion(success: command.status == .completed) {
            (command.gpuStartTime, command.gpuEndTime)
        }
    }

    func recordCompletion(success: Bool, timestamps: () -> (start: Double, end: Double)) {
        guard success else { return }
        state.withLock {
            guard $0.active else { return }
            $0.totals.frames += 1
            let (start, end) = timestamps()
            guard start.isFinite, end.isFinite, start > 0, end > start else { return }
            $0.totals.gpuSamples += 1
            $0.totals.gpuSeconds += end - start
        }
    }

    func deactivate() {
        state.withLock { $0.active = false }
    }

    func snapshot() -> Totals {
        state.withLock { $0.totals }
    }
}
