import Foundation
import Metal
import QuartzCore
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
    let targetFPS: Int
    let frameWindow: SceneMetrics.FrameWindow?
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

    struct FrameWindow {
        let seconds: Double
        let gpu: Totals
        let cpuSamples: Int
        let submissions: Int
        let cpuSeconds: Double
        let confirmedPresentations: Int
        let presentationWasIdle: Bool

        var gpuCompletionsPerSecond: Double { Double(gpu.frames) / seconds }
        var presentedFPS: Double? {
            guard confirmedPresentations > 0 || presentationWasIdle else { return nil }
            return Double(confirmedPresentations) / seconds
        }
        var averageCPUMilliseconds: Double? {
            cpuSamples > 0 ? cpuSeconds * 1000 / Double(cpuSamples) : nil
        }
        var averageGPUMilliseconds: Double? { gpu.averageGPUMilliseconds(since: Totals()) }
    }

    struct Encoding: Sendable {
        fileprivate let generation: UUID
        fileprivate let startedAt: Double
    }

    private struct Window {
        let startedAt: Double
        var gpu = Totals()
        var presentations = 0
        var startedWithPendingPresentation = false
    }

    private struct State {
        var active = true
        var totals = Totals()
        var generation: UUID
        var presentationCallbacks = 0
        var window: Window
    }

    // Encoding is entirely main-actor owned. Only asynchronous callbacks and window
    // boundaries use the lock. Neither encoding nor submission takes that lock.
    private struct CPUWindow {
        var submissions = 0
        var samples = 0
        var seconds = 0.0
    }

    private let now: @Sendable () -> Double
    private let state: OSAllocatedUnfairLock<State>
    @MainActor private var generation: UUID?
    @MainActor private var generationSubmissions = 0
    @MainActor private var cpu = CPUWindow()
    @MainActor private(set) var submittedDrawableSize: SceneRenderExtent?

    @MainActor init(now: @escaping @Sendable () -> Double = { CACurrentMediaTime() }) {
        self.now = now
        let generation = UUID()
        self.generation = generation
        state = OSAllocatedUnfairLock(
            initialState: State(generation: generation, window: Window(startedAt: now())))
    }

    @MainActor func submitted(width: Int, height: Int) {
        submittedDrawableSize = SceneRenderExtent(width: width, height: height)
    }

    @MainActor func beginEncoding() -> Encoding? {
        guard let generation else { return nil }
        return Encoding(generation: generation, startedAt: now())
    }

    // Only successful encodes reach submission. Register before Metal can invoke a callback.
    @MainActor func encoded(_ encoding: Encoding) {
        let duration = now() - encoding.startedAt
        guard generation == encoding.generation else { return }
        generationSubmissions += 1
        cpu.submissions += 1
        guard duration.isFinite, duration >= 0 else { return }
        cpu.samples += 1
        cpu.seconds += duration
    }

    func presented(_ encoding: Encoding, at time: Double) {
        state.withLock {
            guard $0.active, $0.generation == encoding.generation else { return }
            $0.presentationCallbacks += 1
            guard time.isFinite, time > 0, time >= encoding.startedAt,
                time >= $0.window.startedAt, time <= now()
            else { return }
            $0.window.presentations += 1
        }
    }

    func completed(_ command: MTLCommandBuffer, encoding: Encoding?) {
        recordCompletion(success: command.status == .completed, encoding: encoding) {
            (command.gpuStartTime, command.gpuEndTime)
        }
    }

    func recordCompletion(
        success: Bool, encoding: Encoding? = nil, timestamps: () -> (start: Double, end: Double)
    ) {
        guard success else { return }
        state.withLock {
            guard $0.active else { return }
            let inGeneration = encoding?.generation == $0.generation
            $0.totals.frames += 1
            if inGeneration { $0.window.gpu.frames += 1 }
            let (start, end) = timestamps()
            guard start.isFinite, end.isFinite, start > 0, end > start else { return }
            let duration = end - start
            $0.totals.gpuSamples += 1
            $0.totals.gpuSeconds += duration
            if inGeneration {
                $0.window.gpu.gpuSamples += 1
                $0.window.gpu.gpuSeconds += duration
            }
        }
    }

    @MainActor func takeFrameWindow() -> FrameWindow? {
        guard generation != nil else { return nil }
        let cpu = cpu
        let submissions = generationSubmissions
        let result = state.withLock { state -> FrameWindow? in
            let end = now()
            let window = state.window
            let seconds = end - window.startedAt
            guard seconds.isFinite, seconds > 0 else { return nil }
            state.window = Window(
                startedAt: end,
                startedWithPendingPresentation: submissions > state.presentationCallbacks)
            return FrameWindow(
                seconds: seconds, gpu: window.gpu, cpuSamples: cpu.samples,
                submissions: cpu.submissions,
                cpuSeconds: cpu.seconds, confirmedPresentations: window.presentations,
                presentationWasIdle: cpu.submissions == 0 && !window.startedWithPendingPresentation)
        }
        if result != nil { self.cpu = CPUWindow() }
        return result
    }

    @MainActor func resetFrameWindow() {
        guard generation != nil else { return }
        let generation = UUID()
        self.generation = generation
        generationSubmissions = 0
        cpu = CPUWindow()
        submittedDrawableSize = nil
        state.withLock {
            $0.generation = generation
            $0.presentationCallbacks = 0
            $0.window = Window(startedAt: now())
        }
    }

    @MainActor func deactivate() {
        generation = nil
        state.withLock { $0.active = false }
    }

    func snapshot() -> Totals {
        state.withLock { $0.totals }
    }
}
