import Foundation
import Metal

final class SceneMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var gpuSeconds = 0.0
    func completed(_ command: MTLCommandBuffer) {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        if command.gpuEndTime > command.gpuStartTime {
            gpuSeconds += command.gpuEndTime - command.gpuStartTime
        }
    }
    func snapshot() -> (frames: Int, gpuSeconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (count, gpuSeconds)
    }
}
