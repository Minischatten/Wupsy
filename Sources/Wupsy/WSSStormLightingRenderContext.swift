import Foundation
import Metal

// Per player/display. Slots and retirement are synchronized with GPU completion.
final class WSSStormLightingRenderContext: @unchecked Sendable {
    struct Lease {
        let slot: Int
        let token: UInt64
        let texture: MTLTexture
    }
    private struct Slot {
        var texture: MTLTexture?
        var busy = false
        var retire = false
        var token: UInt64 = 0
    }
    let device: MTLDevice
    let byteLimit: Int
    private let allocate: (MTLTextureDescriptor) -> MTLTexture?
    private let now: () -> Double
    private let lock = NSLock()
    private var slots: [Slot]
    private var failedSize: SIMD2<Int>?
    private var retryAfter = 0.0
    init(
        device: MTLDevice, inFlightCount: Int = 2, byteLimit: Int = 256 * 1024 * 1024,
        allocate: ((MTLTextureDescriptor) -> MTLTexture?)? = nil,
        now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.device = device
        self.byteLimit = byteLimit
        self.allocate = allocate ?? { device.makeTexture(descriptor: $0) }
        self.now = now
        slots = Array(repeating: Slot(), count: max(1, min(2, inFlightCount)))
    }
    var textureBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return slots.reduce(0) { $0 + ($1.texture?.allocatedSize ?? 0) }
    }
    func discardResources() {
        lock.lock()
        defer { lock.unlock() }
        failedSize = nil
        for i in slots.indices {
            if slots[i].busy { slots[i].retire = true } else { slots[i].texture = nil }
        }
    }
    func acquire(output: MTLTexture, inputs: [MTLTexture]) -> Lease? {
        lock.lock()
        defer { lock.unlock() }
        let size = SIMD2(output.width, output.height)
        guard output.device.registryID == device.registryID, output.pixelFormat == .bgra8Unorm,
            output.sampleCount == 1, (1...8192).contains(size.x), (1...8192).contains(size.y),
            size.x * size.y <= 32 * 1024 * 1024,
            size.x * size.y * 4 <= byteLimit / slots.count
        else { return nil }
        let matches: (MTLTexture?) -> Bool = { $0?.width == size.x && $0?.height == size.y }
        // Free stale sizes without touching GPU-owned textures.
        for i in slots.indices where !slots[i].busy && !matches(slots[i].texture) {
            slots[i].texture = nil
        }
        guard
            let index = slots.indices.first(where: { !slots[$0].busy && matches(slots[$0].texture) }
            )
                ?? slots.indices.first(where: { !slots[$0].busy })
        else { return nil }
        let texture: MTLTexture
        if let cached = slots[index].texture {
            texture = cached
        } else {
            // Allocation failures must not cause a makeTexture attempt every frame.
            if failedSize == size, now() < retryAfter { return nil }
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: size.x, height: size.y, mipmapped: false)
            d.storageMode = .private
            d.usage = [.renderTarget, .shaderRead]
            guard let created = allocate(d) else {
                failedSize = size
                retryAfter = now() + 1
                return nil
            }
            texture = created
        }
        let otherBytes = slots.enumerated().filter { $0.offset != index }.reduce(0) {
            $0 + ($1.element.texture?.allocatedSize ?? 0)
        }
        guard texture !== output, !inputs.contains(where: { $0 === texture }),
            texture.device.registryID == device.registryID, texture.pixelFormat == .bgra8Unorm,
            texture.sampleCount == 1, texture.width == size.x, texture.height == size.y,
            texture.usage.contains([.renderTarget, .shaderRead]),
            !slots.enumerated().contains(where: {
                $0.offset != index && $0.element.texture === texture
            }),
            texture.allocatedSize <= byteLimit - otherBytes
        else {
            failedSize = size
            retryAfter = now() + 1
            return nil
        }
        slots[index].texture = texture
        slots[index].busy = true
        slots[index].retire = false
        slots[index].token &+= 1
        return Lease(slot: index, token: slots[index].token, texture: texture)
    }
    func release(_ lease: Lease) {
        lock.lock()
        defer { lock.unlock() }
        guard slots.indices.contains(lease.slot), slots[lease.slot].busy,
            slots[lease.slot].token == lease.token
        else { return }
        slots[lease.slot].busy = false
        if slots[lease.slot].retire {
            slots[lease.slot].texture = nil
            slots[lease.slot].retire = false
        }
    }
}
