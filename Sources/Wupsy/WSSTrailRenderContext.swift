import Foundation
import Metal

// One state owner per native player/display. Prepared resources stay immutable.
final class WSSTrailRenderContext {
    private var states: [Int: WSSTrailSimulation] = [:]
    private let lock = NSLock()
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        states.removeAll()
    }
    func encode(
        index: Int, layer: WSSTrailLayer, renderer: WSSTrailRenderer,
        encoder: MTLRenderCommandEncoder, time: Double, pointer: SIMD2<Float>?,
        canvas: SIMD2<Float>, crop: SIMD2<Float>, advance: Bool = true
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        if states[index]?.configuration != layer.configuration {
            states[index] = try WSSTrailSimulation(configuration: layer.configuration)
        }
        if advance { states[index]!.update(time: time, pointer: pointer) }
        try renderer.encode(
            encoder: encoder, simulation: states[index]!, time: time,
            canvas: canvas, crop: crop)
    }
    func sampleCount(index: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return states[index]?.samples.count ?? 0
    }
}
