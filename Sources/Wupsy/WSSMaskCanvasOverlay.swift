import AppKit
import MetalKit

// Editor-only pass. CPU bytes reach a private texture through ordered GPU blits;
// no texture sampled by an in-flight frame is overwritten by the CPU.
@MainActor final class WSSMaskCanvasOverlay {
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var texture: MTLTexture?
    private var queueID: ObjectIdentifier?
    private var pending: CGRect?
    private var fullUpload = true
    init(device: MTLDevice) throws {
        let library = try device.makeLibrary(
            source: WSSStaticResources.shader + """
                fragment float4 maskOverlay(ImageVertex v [[stage_in]],
                    constant ImageTransform &t [[buffer(0)]], constant float4 &color [[buffer(1)]],
                    texture2d<float> mask [[texture(0)]], sampler filtering [[sampler(0)]]) {
                    float amount = mask.sample(filtering, v.uv * t.sampling.xy).r * color.a;
                    return float4(color.rgb * amount, amount);
                }
                """, options: nil)
        let p = MTLRenderPipelineDescriptor()
        p.vertexFunction = library.makeFunction(name: "imageQuad")
        p.fragmentFunction = library.makeFunction(name: "maskOverlay")
        let c = p.colorAttachments[0]!
        c.pixelFormat = .bgra8Unorm
        c.isBlendingEnabled = true
        c.sourceRGBBlendFactor = .one
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.sourceAlphaBlendFactor = .one
        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: p)
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: s) else {
            throw WSSMaskError.invalid
        }
        self.sampler = sampler
    }
    func invalidate(region: CGRect?) {
        if let region {
            pending = pending.map { $0.union(region) } ?? region
        } else {
            fullUpload = true
        }
    }
    func encode(
        session: WSSMaskCanvasSession, scene: CGSize, command: MTLCommandBuffer,
        descriptor: MTLRenderPassDescriptor
    ) throws {
        guard let loaded = session.loaded, let geometry = session.geometry,
            let pixels = session.pixels
        else {
            texture = nil
            fullUpload = true
            return
        }
        let bitmap = loaded.bitmap
        let queue = ObjectIdentifier(command.commandQueue)
        if texture?.width != bitmap.width || texture?.height != bitmap.height || queueID != queue {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm, width: bitmap.width, height: bitmap.height, mipmapped: false)
            d.storageMode = .private
            d.usage = .shaderRead
            texture = command.device.makeTexture(descriptor: d)
            queueID = queue
            fullUpload = true
        }
        guard let texture else { throw WSSMaskError.invalid }
        let bounds = CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height)
        if let region = (fullUpload ? bounds : pending)?.intersection(bounds), !region.isEmpty {
            let x = Int(region.minX)
            let y = Int(region.minY)
            let w = Int(region.width)
            let h = Int(region.height)
            let stride = (w + 255) / 256 * 256
            guard
                let buffer = command.device.makeBuffer(
                    length: stride * h, options: .storageModeShared),
                let blit = command.makeBlitCommandEncoder()
            else { throw WSSMaskError.invalid }
            pixels.withUnsafeBytes { raw in
                for row in 0..<h {
                    memcpy(
                        buffer.contents().advanced(by: row * stride),
                        raw.baseAddress!.advanced(by: (y + row) * bitmap.width + x), w)
                }
            }
            blit.copy(
                from: buffer, sourceOffset: 0, sourceBytesPerRow: stride,
                sourceBytesPerImage: stride * h,
                sourceSize: MTLSize(width: w, height: h, depth: 1), to: texture,
                destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: x, y: y, z: 0))
            blit.endEncoding()
            pending = nil
            fullUpload = false
        }
        descriptor.colorAttachments[0].loadAction = .load
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WSSMaskError.invalid
        }
        defer { encoder.endEncoding() }
        let t = geometry.transform
        var u = WSSStaticResources.Uniforms(
            horizontal: SIMD4(
                t.axisX.x, t.axisY.x, t.center.x - Float(scene.width) / 2, Float(scene.width)),
            vertical: SIMD4(
                t.axisX.y, t.axisY.y, t.center.y - Float(scene.height) / 2, Float(scene.height)),
            sampling: SIMD4(bitmap.uvScale.x, bitmap.uvScale.y, 1, 0))
        var tint = WSSEditorOverlayAccent.selected.rgba
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&u, length: MemoryLayout.size(ofValue: u), index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout.size(ofValue: u), index: 0)
        encoder.setFragmentBytes(&tint, length: MemoryLayout.size(ofValue: tint), index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}

@MainActor final class WSSMaskCanvasOutline: NSView {
    weak var session: WSSMaskCanvasSession?
    var sceneSize = CGSize.zero
    var imageOrigin = CGPoint.zero
    var zoom: CGFloat = 1
    var cursor: SIMD2<Float>?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let session, let geometry = session.geometry else { return }
        func path(_ points: [SIMD2<Float>]) -> NSBezierPath {
            let result = NSBezierPath()
            for (index, scene) in points.enumerated() {
                let point = WSSCanvasGeometry.viewportPoint(
                    scene, origin: imageOrigin, zoom: zoom, height: sceneSize.height)
                if index == 0 { result.move(to: point) } else { result.line(to: point) }
            }
            if !points.isEmpty { result.close() }
            return result
        }
        let t = geometry.transform
        let contour = path(
            [SIMD2(-0.5, -0.5), SIMD2(0.5, -0.5), SIMD2(0.5, 0.5), SIMD2(-0.5, 0.5)].map(t.point))
        NSColor.black.withAlphaComponent(0.75).setStroke()
        contour.lineWidth = 3
        contour.stroke()
        NSColor.white.withAlphaComponent(0.85).setStroke()
        contour.lineWidth = 1
        contour.stroke()
        if session.brushEnabled, let cursor {
            let ring = path(session.brushFootprint(at: cursor))
            NSColor.black.setStroke()
            ring.lineWidth = 3
            ring.stroke()
            NSColor.white.setStroke()
            ring.lineWidth = 1
            ring.stroke()
        }
    }
}
