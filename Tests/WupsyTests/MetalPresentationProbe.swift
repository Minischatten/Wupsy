import AppKit
import Metal
import QuartzCore
import os

@testable import Wupsy

@MainActor enum MetalPresentationProbe {
    enum Result {
        case confirmed
        case notConfirmed
        case failed(String)
    }

    private struct Callback: Sendable {
        let at: ContinuousClock.Instant
        let presentedTime: CFTimeInterval
    }

    private struct Observation: Sendable {
        var status: MTLCommandBufferStatus?
        var completedAt: ContinuousClock.Instant?
        var error: String?
        var callbacks: [Callback] = []
    }

    private typealias Attempt = OSAllocatedUnfairLock<Observation>

    private static func submit(
        _ number: Int, layer: CAMetalLayer, queue: MTLCommandQueue,
        deadline: ContinuousClock.Instant, resources: WSSStaticResources?, sceneTime: Double
    ) -> Attempt? {
        // Release local drawable and render-pass references before waiting for callbacks.
        autoreleasepool {
            guard let drawable = layer.nextDrawable() else {
                print("WUPSY_METAL_PROBE attempt=\(number) drawable=false")
                return nil
            }
            print("WUPSY_METAL_PROBE attempt=\(number) drawable=true")
            guard ContinuousClock.now < deadline, !Task.isCancelled else {
                print(
                    "WUPSY_METAL_PROBE attempt=\(number) deadlineExpiredOrCancelledBeforeCommit=true"
                )
                return nil
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.4, 0.8, 1)
            guard let command = queue.makeCommandBuffer() else {
                print("WUPSY_METAL_PROBE attempt=\(number) commandBuffer=unavailable")
                return nil
            }
            if let resources {
                do {
                    try resources.encode(
                        command: command, descriptor: pass, size: layer.drawableSize,
                        time: sceneTime + Double(number) / 8, projection: .fullCanvas)
                } catch {
                    print("WUPSY_METAL_PROBE scene encode failed: \(error)")
                    return nil
                }
            } else {
                guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                    print("WUPSY_METAL_PROBE attempt=\(number) encoder=unavailable")
                    return nil
                }
                encoder.endEncoding()
            }
            let observation = Attempt(initialState: Observation())
            command.addCompletedHandler { buffer in
                observation.withLock {
                    $0.completedAt = .now
                    $0.status = buffer.status
                    $0.error = buffer.error?.localizedDescription
                }
            }
            drawable.addPresentedHandler { drawable in
                let callback = Callback(at: .now, presentedTime: drawable.presentedTime)
                observation.withLock { $0.callbacks.append(callback) }

            }
            command.present(drawable)
            command.commit()
            return observation
        }
    }

    static func run(on screen: NSScreen, scene: WSSScene? = nil, sceneTime: Double = 3) async
        -> Result
    {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return .failed("No Metal device")
        }
        guard let queue = device.makeCommandQueue() else {
            return .failed("Could not create Metal command queue")
        }
        let resources: WSSStaticResources?
        do {
            resources = try scene.map {
                try WSSStaticResources(
                    scene: $0, assets: WSSStaticTests.Assets(values: [:]), device: device)
            }
        } catch { return .failed("Could not prepare presentation scene: \(error)") }
        let visible = screen.visibleFrame
        guard visible.width >= 160, visible.height >= 120 else {
            return .failed("Display has no usable window area: \(visible)")
        }

        let window = NSWindow(
            contentRect: NSRect(
                x: visible.midX - 80, y: visible.midY - 60, width: 160, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.title = "Metal presentation test"
        window.animationBehavior = .none
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.allowsNextDrawableTimeout = true
        view.wantsLayer = true
        view.layer = layer
        window.contentView = view
        let started = ContinuousClock.now
        var windowClosed = false
        defer {
            print("WUPSY_METAL_PROBE cleanupAt=\(started.duration(to: .now))")
            if !windowClosed {
                window.orderOut(nil)
                print("WUPSY_METAL_PROBE cleanup.orderedOutAt=\(started.duration(to: .now))")
                window.close()
                print("WUPSY_METAL_PROBE cleanup.closedAt=\(started.duration(to: .now))")
            }
            window.contentView = nil
            view.layer = nil
            print("WUPSY_METAL_PROBE cleanup.layerDetachedAt=\(started.duration(to: .now))")
        }
        window.orderFrontRegardless()
        layer.contentsScale = window.backingScaleFactor
        layer.drawableSize = view.convertToBacking(view.bounds).size
        print(
            "WUPSY_METAL_PROBE device=\(device.name) visible=\(window.isVisible) drawableSize=\(layer.drawableSize)"
        )
        guard window.isVisible, window.screen != nil,
            layer.drawableSize.width > 0, layer.drawableSize.height > 0
        else { return .failed("Control window did not attach to a usable display") }

        let deadline = started + .seconds(3)
        let completionDeadline = deadline + .seconds(2)
        var attempts: [Attempt] = []
        var finalSamples: [Observation]?
        var decidedAt: ContinuousClock.Instant?
        var observationCutoff = deadline
        print("WUPSY_METAL_PROBE submission.beginAt=\(started.duration(to: .now)) deadline=3s")

        func snapshot() -> [Observation] { attempts.map { $0.withLock { $0 } } }

        func finish(_ result: Result, samples: [Observation]) -> Result {
            finalSamples = samples
            decidedAt = .now
            return result
        }

        func decision(_ samples: [Observation], callbacksThrough cutoff: ContinuousClock.Instant)
            -> Result?
        {
            if Task.isCancelled { return finish(.failed("Probe cancelled"), samples: samples) }
            let callbacks = samples.map { $0.callbacks.filter { $0.at <= cutoff } }
            guard
                samples.allSatisfy({
                    $0.error == nil && ($0.status == nil || $0.status == .completed)
                }),
                callbacks.allSatisfy({
                    $0.count <= 1
                        && $0.allSatisfy { $0.presentedTime.isFinite && $0.presentedTime >= 0 }
                })
            else {
                return finish(
                    .failed("Invalid GPU status or contradictory presentation data"),
                    samples: samples)
            }

            guard !samples.isEmpty,
                samples.allSatisfy({
                    $0.status == .completed && ($0.completedAt.map { $0 <= deadline } ?? false)
                })
            else { return nil }

            if callbacks.joined().contains(where: { $0.presentedTime > 0 }) {
                return finish(.confirmed, samples: samples)
            }
            if samples.count == 3, callbacks.allSatisfy({ $0.count == 1 }) {
                return finish(
                    .failed("All callbacks were zero before the window lifecycle check"),
                    samples: samples)
            }
            return nil
        }

        func settle(until cutoff: ContinuousClock.Instant) async -> Result? {
            while ContinuousClock.now < cutoff {
                if let result = decision(snapshot(), callbacksThrough: cutoff) { return result }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return decision(snapshot(), callbacksThrough: cutoff)
        }
        defer {
            let samples = finalSamples ?? snapshot()
            let completed = samples.filter { $0.status == .completed }.count
            let callbacks = samples.map { $0.callbacks.filter { $0.at <= observationCutoff }.count }
            let pending = callbacks.filter { $0 == 0 }.count
            for (index, sample) in samples.enumerated() {
                let status = sample.status.map { String($0.rawValue) } ?? "pending"
                let gpuAt = sample.completedAt.map { String(describing: started.duration(to: $0)) }
                let callbackTimes = sample.callbacks.map { started.duration(to: $0.at) }
                print(
                    "WUPSY_METAL_PROBE attempt=\(index + 1) gpuStatus=\(status) gpuAt=\(gpuAt ?? "none") callbacks=\(sample.callbacks.count) callbackAt=\(callbackTimes) presentedTimes=\(sample.callbacks.map(\.presentedTime)) error=\(sample.error ?? "none")"
                )
            }
            print(
                "WUPSY_METAL_PROBE decisionAt=\(started.duration(to: decidedAt ?? .now)) submitted=\(samples.count) gpuCompleted=\(completed) acceptedCallbacks=\(callbacks.reduce(0, +)) pendingCallbacks=\(pending)"
            )
        }

        for number in 1...3 {
            let now = ContinuousClock.now
            guard now < deadline, !Task.isCancelled else { break }
            print(
                "WUPSY_METAL_PROBE attempt=\(number) startAt=\(started.duration(to: now)) remaining=\(now.duration(to: deadline))"
            )
            guard
                let attempt = submit(
                    number, layer: layer, queue: queue, deadline: deadline, resources: resources,
                    sceneTime: sceneTime)
            else {
                print("WUPSY_METAL_PROBE submission.endAt=\(started.duration(to: .now))")
                return .failed("Attempt \(number): drawable or command setup failed")
            }
            attempts.append(attempt)

            // Give each submission a chance to present. If its callback is still
            // pending, allow later frames to progress once GPU work has finished.
            let advanceAt = now + .milliseconds(500)
            while ContinuousClock.now < deadline, !Task.isCancelled {
                if let result = decision(snapshot(), callbacksThrough: deadline) {
                    print("WUPSY_METAL_PROBE submission.endAt=\(started.duration(to: .now))")
                    return result
                }
                let sample = attempt.withLock { $0 }
                if sample.status == .completed,
                    !sample.callbacks.isEmpty || ContinuousClock.now >= advanceAt
                {
                    break
                }
                if let status = sample.status, status != .completed {
                    print("WUPSY_METAL_PROBE submission.endAt=\(started.duration(to: .now))")
                    return .failed("Attempt \(number): GPU completion status \(status.rawValue)")
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            if attempts.contains(where: {
                $0.withLock { sample in
                    sample.callbacks.contains { $0.at <= deadline && $0.presentedTime > 0 }
                }
            }) {
                break
            }
        }

        print("WUPSY_METAL_PROBE submission.endAt=\(started.duration(to: .now))")

        // Preserve the original observation window even when all frames were
        // submitted early. The extra budget starts at its original deadline.
        if let result = await settle(until: deadline) { return result }
        let samples = snapshot()
        guard samples.count == 3,
            samples.allSatisfy({
                $0.status == .completed && ($0.completedAt.map { $0 <= deadline } ?? false)
            })
        else {
            return finish(
                .failed("Submission deadline expired with incomplete GPU work"), samples: samples)
        }

        observationCutoff = completionDeadline
        print("WUPSY_METAL_PROBE completion.beginAt=\(started.duration(to: .now)) deadline=5s")
        let result = await settle(until: completionDeadline)
        print("WUPSY_METAL_PROBE completion.endAt=\(started.duration(to: .now))")
        if let result { return result }

        let beforeClose = snapshot()
        let pending = beforeClose.indices.filter { beforeClose[$0].callbacks.isEmpty }
        guard pending.count == 1, let pendingIndex = pending.first,
            beforeClose.allSatisfy({ sample in
                sample.status == .completed && sample.error == nil && sample.callbacks.count <= 1
                    && sample.callbacks.allSatisfy {
                        $0.at <= completionDeadline && $0.presentedTime == 0
                    }
            })
        else {
            return finish(
                .failed("Expected exactly one pending callback and two valid zero timestamps"),
                samples: beforeClose)
        }

        // Closing the window can retire a drawable without displaying it.
        // Keep the layer attached until the outstanding callback has been observed.
        let closeStarted = ContinuousClock.now
        let closeDeadline = closeStarted + .milliseconds(1500)
        observationCutoff = closeDeadline
        print(
            "WUPSY_METAL_PROBE lifecycle.closeBeginAt=\(started.duration(to: closeStarted)) pendingAttempt=\(pendingIndex + 1)"
        )
        window.close()
        windowClosed = true
        print("WUPSY_METAL_PROBE lifecycle.closed visible=\(window.isVisible)")
        guard !window.isVisible else {
            return finish(
                .failed("Control window remained visible after close"), samples: snapshot())
        }
        while ContinuousClock.now < closeDeadline, !Task.isCancelled,
            attempts[pendingIndex].withLock({ $0.callbacks.isEmpty })
        {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let afterClose = snapshot()
        guard !Task.isCancelled,
            afterClose.allSatisfy({
                $0.callbacks.count == 1 && $0.callbacks[0].presentedTime == 0
            }), let callback = afterClose[pendingIndex].callbacks.first,
            callback.at >= closeStarted, callback.at <= closeDeadline
        else {
            return finish(
                .failed(
                    "Window close did not settle the pending callback with a valid zero timestamp"),
                samples: afterClose)
        }
        print(
            "WUPSY_METAL_PROBE lifecycle.settledAfterClose=\(closeStarted.duration(to: callback.at)) presentedTime=0.0"
        )
        return finish(.notConfirmed, samples: afterClose)
    }
}
