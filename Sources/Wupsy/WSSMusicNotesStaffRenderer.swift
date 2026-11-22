import MetalKit
import simd

final class WSSMusicNotesStaffRenderer {
    struct Mask {
        let texture: MTLTexture
        let origin: SIMD2<Int>
    }

    struct Projection: Equatable {
        let size: SIMD2<Int>
        let scale: SIMD2<Double>
        let origin: SIMD2<Double>

        init(
            outputSize: SIMD2<Int>, canvas: SIMD2<Float>, crop: SIMD2<Float>, origin: SIMD2<Double>
        ) {
            size = outputSize
            let extent = SIMD2<Double>(outputSize)
            scale = extent / (SIMD2<Double>(canvas) * SIMD2<Double>(crop)) * SIMD2(1, -1)
            self.origin = extent / 2 + (origin - SIMD2<Double>(canvas) / 2) * scale
        }
    }

    final class Prepared {
        let key: WSSMusicNotesStaff.GeometryKey
        let buffer: MTLBuffer
        let progressBuffer: MTLBuffer?
        var bufferBytes: Int { buffer.length + (progressBuffer?.length ?? 0) }
        let vertexCount: Int
        let origin: SIMD2<Double>
        let lower: SIMD2<Double>
        let upper: SIMD2<Double>

        private let lock = NSLock()
        private var cached: (projection: Projection, depth: WSSMusicNotesDepth?, mask: Mask)?

        init(
            _ geometry: WSSMusicNotesStaff.Geometry, key: WSSMusicNotesStaff.GeometryKey,
            device: MTLDevice, tracksDepth: Bool
        ) throws {
            guard
                let buffer = geometry.vertices.withUnsafeBytes({ bytes in
                    bytes.baseAddress.flatMap {
                        device.makeBuffer(
                            bytes: $0, length: bytes.count, options: .storageModeShared)
                    }
                })
            else { throw WSSSceneError.invalid("musicNotes staff buffer allocation") }
            self.key = key
            self.buffer = buffer
            if tracksDepth, !geometry.progress.isEmpty {
                guard
                    let progressBuffer = geometry.progress.withUnsafeBytes({ bytes in
                        device.makeBuffer(
                            bytes: bytes.baseAddress!, length: bytes.count,
                            options: .storageModeShared)
                    })
                else { throw WSSSceneError.invalid("musicNotes staff progress allocation") }
                self.progressBuffer = progressBuffer
            } else {
                progressBuffer = nil
            }
            vertexCount = geometry.vertices.count
            origin = geometry.origin
            var lower = SIMD2<Float>(repeating: .infinity)
            var upper = -lower
            for point in geometry.vertices {
                lower = simd_min(lower, point)
                upper = simd_max(upper, point)
            }
            self.lower = SIMD2<Double>(lower)
            self.upper = SIMD2<Double>(upper)
        }

        func mask(for projection: Projection, depth: WSSMusicNotesDepth? = nil) -> Mask? {
            lock.lock()
            defer { lock.unlock() }
            guard cached?.projection == projection, cached?.depth == depth else { return nil }
            return cached?.mask
        }

        func store(_ mask: Mask, for projection: Projection, depth: WSSMusicNotesDepth?) {
            lock.lock()
            defer { lock.unlock() }
            cached = (projection, depth, mask)
        }
    }

    private let coveragePipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let sampleCount: Int

    init(device: MTLDevice) throws {
        sampleCount = device.supportsTextureSampleCount(8) ? 8 : 4
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "staffMesh")
        descriptor.fragmentFunction = library.makeFunction(name: "staffCoverage")
        descriptor.colorAttachments[0].pixelFormat = .r8Unorm
        descriptor.rasterSampleCount = sampleCount
        coveragePipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        descriptor.vertexFunction = library.makeFunction(name: "staffQuad")
        descriptor.fragmentFunction = library.makeFunction(name: "staffComposite")
        descriptor.rasterSampleCount = 1
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        compositePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    static func prepare(
        scene: WSSScene, device: MTLDevice, previous: WSSStaticResources? = nil
    ) throws -> [Int: Prepared] {
        var result: [Int: Prepared] = [:]
        for (index, node) in scene.layers.enumerated() {
            guard case .musicNotes(let layer) = node, let staff = layer.staff else { continue }
            let key = WSSMusicNotesStaff.GeometryKey(layer: layer, staff: staff)
            let tracksDepth = layer.usesActivePath && layer.depth?.includesStaff == true
            if let existing = previous?.musicNotesStaffs[index], existing.key == key,
                !tracksDepth || existing.progressBuffer != nil
            {
                result[index] = existing
            } else if layer.drawsStaff, staff.opacity > 0, let geometry = try layer.preparedStaff()
            {
                result[index] = try Prepared(
                    geometry, key: key, device: device, tracksDepth: tracksDepth)
            }
        }
        return result
    }

    func prepareMask(
        _ mesh: Prepared, projection: Projection, command: MTLCommandBuffer,
        depth: WSSMusicNotesDepth? = nil
    ) throws -> Mask? {
        if let mask = mesh.mask(for: projection, depth: depth) { return mask }

        let a = mesh.lower * projection.scale + projection.origin
        let b = mesh.upper * projection.scale + projection.origin
        let extent = SIMD2<Double>(projection.size)
        let lower = simd_min(a, b)
        let minimum = simd_clamp(SIMD2(floor(lower.x), floor(lower.y)), .zero, extent)
        let upper = simd_max(a, b)
        let maximum = simd_clamp(SIMD2(ceil(upper.x), ceil(upper.y)), .zero, extent)
        let size = SIMD2<Int>(maximum - minimum)
        guard size.x > 0, size.y > 0 else { return nil }

        let device = command.commandQueue.device
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: size.x, height: size.y, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let resolved = device.makeTexture(descriptor: descriptor) else {
            throw WSSSceneError.invalid("musicNotes staff coverage allocation")
        }
        descriptor.textureType = .type2DMultisample
        descriptor.sampleCount = sampleCount
        descriptor.storageMode = .memoryless
        descriptor.usage = .renderTarget
        guard let samples = device.makeTexture(descriptor: descriptor) else {
            throw WSSSceneError.invalid("musicNotes staff multisample allocation")
        }

        let pass = MTLRenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = samples
        attachment.resolveTexture = resolved
        attachment.loadAction = .clear
        attachment.clearColor = MTLClearColorMake(0, 0, 0, 0)
        attachment.storeAction = .multisampleResolve
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw WSSSceneError.invalid("musicNotes staff coverage encoder")
        }

        encoder.setRenderPipelineState(coveragePipeline)
        encoder.setVertexBuffer(mesh.buffer, offset: 0, index: 0)
        let dimensions = SIMD2<Double>(size)
        let scale = projection.scale / dimensions * SIMD2(2, -2)
        let offset = (projection.origin - minimum) / dimensions * SIMD2(2, -2) + SIMD2(-1, 1)
        var transform = SIMD4<Float>(
            Float(scale.x), Float(scale.y), Float(offset.x), Float(offset.y))
        encoder.setVertexBytes(&transform, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.setVertexBuffer(mesh.progressBuffer ?? mesh.buffer, offset: 0, index: 2)
        func drawCoverage(_ side: WSSMusicNotesDepth.Side?) {
            var routing = WSSMusicNotesDepth.Uniforms(
                depth, side: side, closed: mesh.key.path?.closed == true)
            let stride = MemoryLayout<WSSMusicNotesDepth.Uniforms>.stride
            encoder.setVertexBytes(&routing, length: stride, index: 3)
            encoder.setFragmentBytes(&routing, length: stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.vertexCount)
        }
        if depth != nil {
            drawCoverage(.behind)
            drawCoverage(.inFront)
        } else {
            drawCoverage(nil)
        }
        encoder.endEncoding()

        let mask = Mask(texture: resolved, origin: SIMD2<Int>(minimum))
        // Publish only completed masks. Other queues and in-flight frames can
        // read these immutable textures without sharing a writable attachment.
        command.addCompletedHandler { [weak mesh] command in
            if command.status == .completed { mesh?.store(mask, for: projection, depth: depth) }
        }
        return mask
    }

    func encode(
        _ mask: Mask, staff: WSSMusicNotesStaff, outputSize: SIMD2<Int>,
        encoder: MTLRenderCommandEncoder, depthSide: WSSMusicNotesDepth.Side? = nil
    ) {
        let origin = SIMD2<Float>(mask.origin)
        let extent = SIMD2<Float>(Float(mask.texture.width), Float(mask.texture.height))
        let scale = SIMD2<Float>(2, -2) / SIMD2<Float>(outputSize)
        let start = origin * scale + SIMD2(-1, 1)
        let span = extent * scale
        var rect = SIMD4(start.x, start.y, span.x, span.y)
        var color = SIMD4(staff.color.red, staff.color.green, staff.color.blue, staff.opacity)
        let side: UInt32 = depthSide.map { $0 == .inFront ? 2 : 1 } ?? 0
        var options = SIMD4<UInt32>(
            UInt32(mask.origin.x), UInt32(mask.origin.y), side, UInt32(sampleCount))
        encoder.setRenderPipelineState(compositePipeline)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&options, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 1)
        encoder.setFragmentTexture(mask.texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private static let shader = """
        #include <metal_stdlib>
        using namespace metal;

        struct Depth {
            float4 first, second;
            uint4 section;
        };

        struct StaffVertex {
            float4 position [[position]];
            float phase [[sample_no_perspective]];
        };

        vertex StaffVertex staffMesh(uint id [[vertex_id]], device const float2 *vertices [[buffer(0)]],
                                     constant float4 &transform [[buffer(1)]],
                                     device const float *progress [[buffer(2)]],
                                     constant Depth &depth [[buffer(3)]]) {
            return {float4(fma(vertices[id], transform.xy, transform.zw), 0.0, 1.0),
                    depth.section.z == 0 ? 0.0 : progress[id]};
        }

        fragment float4 staffCoverage(StaffVertex in [[stage_in]], constant Depth &depth [[buffer(0)]]) {
            if (depth.section.z == 0) return float4(1.0);
            float progress = clamp(in.phase, 0.0, 1.0);
            if (depth.section.w > 0 && progress == 1.0) progress = 0.0;
            uint section = 0;
            for (uint j = 0; j < depth.section.x; ++j) {
                section += uint(progress >= (j < 4 ? depth.first[j] : depth.second[j - 4]));
            }
            uint side = 1 + ((depth.section.y >> section) & 1);
            if (side != depth.section.z) discard_fragment();
            // The front draw overwrites coincident back samples. Both sample
            // counts survive the 4x or 8x R8 resolve as base-nine digits.
            return float4(side == 2 ? 216.0 / 255.0 : 24.0 / 255.0);
        }

        vertex float4 staffQuad(uint id [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
            return float4(rect.xy + float2(id & 1, id >> 1) * rect.zw, 0.0, 1.0);
        }

        fragment float4 staffComposite(float4 position [[position]],
                                       texture2d<float, access::read> mask [[texture(0)]],
                                       constant float4 &color [[buffer(0)]],
                                       constant uint4 &options [[buffer(1)]]) {
            uint2 pixel = uint2(position.xy) - options.xy;
            float coverage = mask.read(pixel).r;
            float alpha = coverage * color.a;
            if (options.z != 0) {
                uint packed = uint(round(coverage * 255.0 * float(options.w) / 24.0));
                float front = float(packed / 9) * color.a / float(options.w);
                float behind = float(packed % 9) * color.a / float(options.w);
                // The front source-over draw will attenuate the rear
                // contribution. Compensate for disjoint samples in one pixel.
                alpha = options.z == 2 ? front : behind / max(1.0 - front, 1e-6);
            }
            return float4(color.rgb * alpha, alpha);
        }
        """
}
