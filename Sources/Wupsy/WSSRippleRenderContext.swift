import MetalKit

// Per player/display. Bounded layer-local ping-pong targets in separate GPU slots.
// The legacy encoder continues requesting only target zero.
final class WSSImageEffectRenderContext: @unchecked Sendable {
    struct Target: Hashable {
        let layer: Int
        let scratch: Int
    }
    struct Lease {
        let slot: Int
        let intermediateTargets: [Target: MTLTexture]
        let targets: [Int: MTLTexture]
        init(slot: Int, intermediateTargets: [Target: MTLTexture]) {
            self.slot = slot
            self.intermediateTargets = intermediateTargets
            targets = Dictionary(
                uniqueKeysWithValues: intermediateTargets.compactMap { key, value in
                    key.scratch == 0 ? (key.layer, value) : nil
                })
        }
    }
    private struct Slot {
        var busy = false
        var targets: [Target: MTLTexture] = [:]
    }
    let device: MTLDevice
    let byteLimit: Int
    private let allocate: (MTLTextureDescriptor) -> MTLTexture?
    private let lock = NSLock()
    private var slots: [Slot]
    init(
        device: MTLDevice, inFlightCount: Int = 2, byteLimit: Int = 256 * 1024 * 1024,
        allocate: ((MTLTextureDescriptor) -> MTLTexture?)? = nil
    ) {
        self.device = device
        self.byteLimit = byteLimit
        self.allocate = allocate ?? { device.makeTexture(descriptor: $0) }
        slots = Array(repeating: Slot(), count: max(1, min(2, inFlightCount)))
    }
    var textureBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return slots.reduce(0) { $0 + $1.targets.values.reduce(0) { $0 + $1.allocatedSize } }
    }
    var targets: [[Int: MTLTexture]] {
        lock.lock()
        defer { lock.unlock() }
        return slots.map { slot in
            Dictionary(
                uniqueKeysWithValues: slot.targets.compactMap { key, value in
                    key.scratch == 0 ? (key.layer, value) : nil
                })
        }
    }
    func acquire(sizes: [Int: SIMD2<Int>], output: MTLTexture) throws -> Lease {
        try acquire(
            requests: Dictionary(
                uniqueKeysWithValues: sizes.map { (Target(layer: $0.key, scratch: 0), $0.value) }),
            output: output)
    }
    func acquire(
        requests: [Target: SIMD2<Int>], output: MTLTexture, inputs: [MTLTexture] = []
    ) throws -> Lease {
        lock.lock()
        defer { lock.unlock() }
        guard requests.keys.allSatisfy({ $0.layer >= 0 && (0...1).contains($0.scratch) }) else {
            throw WSSSceneError.invalid("image effect target address")
        }
        guard output.device.registryID == device.registryID,
            let index = slots.firstIndex(where: { !$0.busy })
        else {
            throw WSSSceneError.invalid("ripple intermediate device or in-flight capacity")
        }
        var bytes = 0
        for size in requests.values {
            guard (1...8192).contains(size.x), (1...8192).contains(size.y) else {
                throw WSSSceneError.invalid("ripple intermediate dimensions")
            }
            bytes += size.x * size.y * 4
        }
        guard bytes <= byteLimit / slots.count else {
            throw WSSSceneError.invalid("ripple intermediate budget exceeded")
        }
        var targets: [Target: MTLTexture] = [:]
        for (layer, size) in requests {
            let texture: MTLTexture
            if let old = slots[index].targets[layer], old.width == size.x, old.height == size.y {
                texture = old
            } else {
                let d = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm,
                    width: size.x, height: size.y, mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]
                d.storageMode = .private
                guard let allocated = allocate(d) else {
                    throw WSSSceneError.invalid("ripple intermediate allocation failed")
                }
                texture = allocated
                texture.label = "WSS Ripple layer \(layer) slot \(index)"
            }
            guard texture !== output, !inputs.contains(where: { $0 === texture }),
                texture.device.registryID == device.registryID,
                texture.width == size.x, texture.height == size.y,
                texture.pixelFormat == .bgra8Unorm, texture.sampleCount == 1,
                texture.usage.contains([.renderTarget, .shaderRead]),
                !targets.values.contains(where: { $0 === texture }),
                !slots.enumerated().contains(where: { i, s in
                    i != index && s.targets.values.contains(where: { $0 === texture })
                })
            else { throw WSSSceneError.invalid("ripple intermediate alias or format") }
            targets[layer] = texture
        }
        let otherBytes = slots.enumerated().filter { $0.offset != index }.reduce(0) {
            $0 + $1.element.targets.values.reduce(0) { $0 + $1.allocatedSize }
        }
        guard otherBytes + targets.values.reduce(0, { $0 + $1.allocatedSize }) <= byteLimit else {
            throw WSSSceneError.invalid("ripple allocated intermediate budget exceeded")
        }
        slots[index].targets = targets
        slots[index].busy = true
        return Lease(slot: index, intermediateTargets: targets)
    }
    func release(_ lease: Lease) {
        lock.lock()
        defer { lock.unlock() }
        slots[lease.slot].busy = false
    }
}

// Source compatibility for existing players, encoders and regression helpers.
typealias WSSRippleRenderContext = WSSImageEffectRenderContext
