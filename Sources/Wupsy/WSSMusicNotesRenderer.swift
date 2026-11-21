import MetalKit

final class WSSMusicNotesRenderer {
    private static let atlasWidth = 192
    private static let atlasHeight = 64
    private let atlas: MTLTexture
    private let pipeline: MTLRenderPipelineState
    private let pathPipeline: MTLRenderPipelineState
    private let instances: [UInt32: MTLBuffer]

    var textureBytes: Int { atlas.allocatedSize }
    var bufferBytes: Int { instances.values.reduce(0) { $0 + $1.length } }

    struct PreparedPath {
        let buffer: MTLBuffer
        let length: Double
        let origin: SIMD2<Float>
        let sampleCount: Int

        init(_ table: WSSMusicNotesPath.Table, device: MTLDevice) throws {
            guard
                let buffer = table.samples.withUnsafeBytes({ bytes in
                    device.makeBuffer(
                        bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
                })
            else { throw WSSSceneError.invalid("musicNotes path buffer allocation") }
            self.buffer = buffer
            length = table.length
            origin = SIMD2<Float>(table.origin)
            sampleCount = table.samples.count
        }

        static func timing(length: Double, speed: Float, time: Double, closed: Bool) -> SIMD2<Float>
        {
            guard speed > 0 else { return .zero }
            let period = length / Double(speed)
            let phase = time.isFinite ? time.truncatingRemainder(dividingBy: period) / period : 0
            let fade = closed ? 0 : max(Double(Float.leastNormalMagnitude), min(0.2, 0.25 / period))
            return SIMD2(Float(phase), Float(fade))
        }
    }

    static func preparePaths(
        scene: WSSScene, device: MTLDevice, previous: WSSStaticResources? = nil
    ) throws -> [Int: PreparedPath] {
        var result: [Int: PreparedPath] = [:]
        for (index, node) in scene.layers.enumerated() {
            guard case .musicNotes(let layer) = node, let path = layer.path else { continue }
            if let previous, let prepared = previous.musicNotesPaths[index],
                case .musicNotes(let old) = previous.scene.layers[index],
                let oldPath = old.path, path.sameCurve(as: oldPath),
                layer.region.width == old.region.width, layer.region.height == old.region.height
            {
                result[index] = prepared
            } else if path.enabled {
                result[index] = try PreparedPath(path.prepare(in: layer.region), device: device)
            }
        }
        return result
    }

    init(scene: WSSScene, device: MTLDevice) throws {
        let width = Self.atlasWidth
        let height = Self.atlasHeight
        guard let url = Bundle.module.url(forResource: "MusicNotesAtlas", withExtension: "r8")
        else { throw WSSSceneError.invalid("missing music notes atlas") }
        let pixels = try Data(contentsOf: url)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard pixels.count == width * height, let atlas = device.makeTexture(descriptor: descriptor)
        else { throw WSSSceneError.invalid("music notes atlas") }
        pixels.withUnsafeBytes {
            atlas.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width)
        }
        self.atlas = atlas

        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let render = MTLRenderPipelineDescriptor()
        render.vertexFunction = library.makeFunction(name: "musicNoteQuad")
        render.fragmentFunction = library.makeFunction(name: "musicNoteColor")
        let attachment = render.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: render)
        render.vertexFunction = library.makeFunction(name: "musicNotePathQuad")
        render.fragmentFunction = library.makeFunction(name: "musicNotePathColor")
        pathPipeline = try device.makeRenderPipelineState(descriptor: render)

        var buffers: [UInt32: MTLBuffer] = [:]
        for case .musicNotes(let layer) in scene.layers where buffers[layer.notes.seed] == nil {
            let buffer = WSSMusicNotesLayer.instances(seed: layer.notes.seed).withUnsafeBytes {
                device.makeBuffer(
                    bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            }
            guard let buffer else { throw WSSSceneError.invalid("music notes instance allocation") }
            buffers[layer.notes.seed] = buffer
        }
        instances = buffers
    }

    private struct Uniforms {
        var projection, region, phase, color, shape: SIMD4<Float>
        var symbols: SIMD4<UInt32>
    }

    func encode(
        _ layer: WSSMusicNotesLayer, path prepared: PreparedPath?, canvas: SIMD2<Float>,
        crop: SIMD2<Float>, time: Double,
        encoder: MTLRenderCommandEncoder
    ) {
        let notes = layer.notes
        guard notes.count > 0, notes.opacity > 0, let buffer = instances[notes.seed] else { return }
        let region = layer.region
        let size = min(notes.size, min(region.width, region.height) * 0.48)
        var symbols = SIMD4<UInt32>(0, 0, 0, UInt32(notes.symbols.count))
        for (index, symbol) in notes.symbols.enumerated() {
            symbols[index] = symbol.atlasIndex
        }
        let path = layer.path.flatMap { $0.enabled ? $0 : nil }
        let hoverAxis = path == nil && notes.hover ? layer.hoverAxis : .zero
        var uniforms = Uniforms(
            projection: .init(canvas.x, canvas.y, crop.x, crop.y),
            region: .init(region.x, region.y, region.width, region.height),
            phase: path == nil ? layer.phases(at: time) : .zero,
            color: .init(notes.color.red, notes.color.green, notes.color.blue, notes.opacity),
            shape: .init(size, hoverAxis.x, notes.rotation ? 1 : 0, hoverAxis.y),
            symbols: symbols)
        var instanceCount = notes.count * 4
        if let path, let prepared {
            let timing = PreparedPath.timing(
                length: prepared.length, speed: notes.speed, time: time, closed: path.closed)
            let oscillation = layer.oscillationPhases(at: time)
            uniforms.phase = .init(timing.x, timing.y, oscillation.x, oscillation.y)
            uniforms.region.z = prepared.origin.x
            uniforms.region.w = prepared.origin.y
            uniforms.shape.y = notes.hover ? 1 : 0
            uniforms.shape.w = path.direction == .reverse ? 1 : 0
            var counts = SIMD2(UInt32(notes.count), UInt32(prepared.sampleCount - 1))
            encoder.setRenderPipelineState(pathPipeline)
            encoder.setVertexBuffer(prepared.buffer, offset: 0, index: 2)
            encoder.setVertexBytes(&counts, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 3)
            instanceCount = notes.count
        } else {
            // All active paths are prepared before the snapshot is published.
            assert(path == nil)
            encoder.setRenderPipelineState(pipeline)
        }
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setVertexBuffer(buffer, offset: 0, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(atlas, index: 0)
        encoder.drawPrimitives(
            type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instanceCount)
    }

    // Periodic copies continue the same sprite across a seam. The three
    // extra quads degenerate unless they intersect the movement rectangle.
    private static let shader = """
        #include <metal_stdlib>
        using namespace metal;

        struct NotesUniforms {
            float4 projection, region, phase, color, shape;
            uint4 symbols;
        };

        struct NoteVertex {
            float4 position [[position]];
            float2 uv, local;
        };

        vertex NoteVertex musicNoteQuad(
            uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
            constant NotesUniforms &u [[buffer(0)]],
            device const float4 *instances [[buffer(1)]]
        ) {
            constexpr float turn = 6.28318530718;
            float4 note = instances[instanceID / 4];
            uint tile = instanceID % 4;
            float2 span = u.region.zw;
            float size = u.shape.x;
            float2 position = note.xy + u.phase.xy;
            position += u.shape.yw * size * 0.12
                * sin(turn * (note.w + u.phase.z)) / span;
            float2 center = fract(position) * span;
            float2 alternate = select(span, -span, center >= span * 0.5);
            center += alternate * float2(tile & 1, tile >> 1);
            float extent = size * 0.708;
            if (any(center + extent <= 0.0) || any(center - extent >= span)) {
                return {float4(2, 2, 0, 1), float2(0), float2(0)};
            }

            float2 corner = float2(vertexID & 1, vertexID >> 1);
            float2 offset = (corner - 0.5) * size;
            float angle = u.shape.z * 0.32 * sin(turn * (note.w + u.phase.w));
            float c = cos(angle), s = sin(angle);
            float2 local = center + float2(c * offset.x - s * offset.y, s * offset.x + c * offset.y);
            float2 clip = ((local + u.region.xy) / u.projection.xy * 2.0 - 1.0) / u.projection.zw;
            uint symbol = u.symbols[min(uint(note.z * float(u.symbols.w)), u.symbols.w - 1)];
            float2 uv = float2((float(symbol) + corner.x) / 3.0, 1.0 - corner.y);
            return {float4(clip, 0, 1), uv, local};
        }

        fragment float4 musicNoteColor(
            NoteVertex in [[stage_in]], constant NotesUniforms &u [[buffer(0)]],
            texture2d<float> atlas [[texture(0)]]
        ) {
            constexpr sampler sampleAtlas(coord::normalized, address::clamp_to_edge, filter::linear);
            float2 edge = min(in.local, u.region.zw - in.local);
            float fade = smoothstep(0.0, u.shape.x * 0.14, min(edge.x, edge.y));
            float alpha = atlas.sample(sampleAtlas, in.uv).r * fade * u.color.a;
            return float4(u.color.rgb * alpha, alpha);
        }

        struct PathVertex {
            float4 position [[position]];
            float2 uv;
            float fade [[flat]];
        };

        vertex PathVertex musicNotePathQuad(
            uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
            constant NotesUniforms &u [[buffer(0)]],
            device const float4 *instances [[buffer(1)]],
            device const float4 *samples [[buffer(2)]],
            constant uint2 &counts [[buffer(3)]]
        ) {
            constexpr float turn = 6.28318530718;
            float4 note = instances[instanceID];
            float travel = fract(u.phase.x + (float(instanceID) + 0.5) / float(counts.x));
            float progress = u.shape.w > 0 ? 1.0 - travel : travel;
            float index = progress * float(counts.y);
            uint lower = min(uint(index), counts.y - 1);
            float fraction = index - float(lower);
            float4 a = samples[lower], b = samples[lower + 1];
            float2 center = mix(a.xy, b.xy, fraction);

            if (u.shape.y > 0) {
                // Use the authored tangent regardless of the travel direction.
                // Taper hover through a cancellation at a sharp reversal.
                float2 tangent = mix(a.zw, b.zw, fraction);
                float squared = dot(tangent, tangent);
                float2 unit = squared > 1e-6 ? tangent * rsqrt(max(squared, 1e-6))
                    : (fraction < 0.5 ? a.zw : b.zw);
                float2 normal = float2(-unit.y, unit.x);
                center += normal * (u.shape.x * 0.12 * smoothstep(1e-6, 0.04, squared)
                    * sin(turn * (note.w + u.phase.z)));
            }

            float2 corner = float2(vertexID & 1, vertexID >> 1);
            float2 offset = (corner - 0.5) * u.shape.x;
            float angle = u.shape.z * 0.32 * sin(turn * (note.w + u.phase.w));
            float c = cos(angle), s = sin(angle);
            float2 local = center + float2(c * offset.x - s * offset.y, s * offset.x + c * offset.y);
            float2 clip = ((local + u.region.zw + u.region.xy) / u.projection.xy * 2.0 - 1.0)
                / u.projection.zw;
            uint symbol = u.symbols[min(uint(note.z * float(u.symbols.w)), u.symbols.w - 1)];
            float2 uv = float2((float(symbol) + corner.x) / 3.0, 1.0 - corner.y);
            float fade = u.phase.y > 0 ? smoothstep(0.0, max(u.phase.y, 1e-7), min(travel, 1.0 - travel)) : 1.0;
            return {float4(clip, 0, 1), uv, fade};
        }

        fragment float4 musicNotePathColor(
            PathVertex in [[stage_in]], constant NotesUniforms &u [[buffer(0)]],
            texture2d<float> atlas [[texture(0)]]
        ) {
            constexpr sampler sampleAtlas(coord::normalized, address::clamp_to_edge, filter::linear);
            float alpha = atlas.sample(sampleAtlas, in.uv).r * in.fade * u.color.a;
            return float4(u.color.rgb * alpha, alpha);
        }
        """
}
