import MetalKit

final class WSSMusicNotesRenderer {
    private static let atlasWidth = 192
    private static let atlasHeight = 64
    private let atlas: MTLTexture
    private let pipeline: MTLRenderPipelineState
    private let instances: [UInt32: MTLBuffer]

    var textureBytes: Int { atlas.allocatedSize }
    var bufferBytes: Int { instances.values.reduce(0) { $0 + $1.length } }

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
        _ layer: WSSMusicNotesLayer, canvas: SIMD2<Float>, crop: SIMD2<Float>, time: Double,
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
        let hoverAxis = notes.hover ? layer.hoverAxis : .zero
        var uniforms = Uniforms(
            projection: .init(canvas.x, canvas.y, crop.x, crop.y),
            region: .init(region.x, region.y, region.width, region.height),
            phase: layer.phases(at: time),
            color: .init(notes.color.red, notes.color.green, notes.color.blue, notes.opacity),
            shape: .init(size, hoverAxis.x, notes.rotation ? 1 : 0, hoverAxis.y),
            symbols: symbols)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setVertexBuffer(buffer, offset: 0, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(atlas, index: 0)
        encoder.drawPrimitives(
            type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: notes.count * 4)
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
        """
}
