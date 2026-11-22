import MetalKit

final class WSSMusicNotesRenderer {
    private static let atlasWidth = 256
    private static let atlasHeight = 256
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
            } else if layer.usesActivePath {
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
        var motion: SIMD4<Float>
        var perspective: SIMD4<Float>
    }

    func encode(
        _ layer: WSSMusicNotesLayer, path prepared: PreparedPath?, canvas: SIMD2<Float>,
        crop: SIMD2<Float>, time: Double,
        encoder: MTLRenderCommandEncoder, depthSide: WSSMusicNotesDepth.Side? = nil
    ) {
        let notes = layer.notes
        let single = layer.singleSymbol
        guard let buffer = instances[notes.seed],
            single.map({ $0.opacity > 0 }) ?? (notes.count > 0 && notes.opacity > 0)
        else { return }
        let region = layer.region
        let size =
            single != nil
            ? layer.drawnSingleSize : min(notes.size, min(region.width, region.height) * 0.48)
        var symbols = SIMD4<UInt32>.zero
        if let single {
            symbols.x = single.symbol.atlasIndex
        } else {
            for (index, symbol) in notes.symbols.enumerated() {
                symbols[index] = symbol.atlasIndex
            }
        }
        let path = layer.usesActivePath ? layer.path : nil
        let hoverAxis = path == nil && notes.hoverAmount > 0 ? layer.hoverAxis : .zero
        var uniforms = Uniforms(
            projection: .init(canvas.x, canvas.y, crop.x, crop.y),
            region: .init(region.x, region.y, region.width, region.height),
            phase: path == nil ? layer.phases(at: time) : .zero,
            color: .init(notes.color.red, notes.color.green, notes.color.blue, notes.opacity),
            shape: .init(size, hoverAxis.x, notes.rotationAmount, hoverAxis.y),
            symbols: symbols, motion: .init(notes.hoverAmount, Float(notes.symbols.count), 0, 0),
            perspective: .zero)
        var instanceCount = notes.count * 4
        if let single {
            let rocking = layer.rockingAmount(for: single)
            let mode = single.effectiveRotationMode(legacyRocking: notes.rotation)
            let oscillation = layer.oscillationPhases(at: time, rockingAmount: rocking)
            uniforms.shape.y = mode == .continuous ? single.spinPhase(at: time) : 0
            uniforms.shape.z = rocking
            uniforms.shape.w = mode == .continuous && single.spinAxis == .vertical ? 1 : 0
            uniforms.phase = .init(
                (layer.anchorPosition ?? 50) / 100, 0, oscillation.x, oscillation.y)
            uniforms.color = .init(
                single.color.red, single.color.green, single.color.blue, single.opacity)
            uniforms.motion.y = 1
            uniforms.motion.z = 1  // Fixed position and no edge fade.
            uniforms.motion.w = layer.alignToPath == true ? 1 : 0
            let table = path == nil ? nil : prepared
            if let table {
                uniforms.region.z = table.origin.x
                uniforms.region.w = table.origin.y
            } else {
                let center =
                    layer.placementMode == .freeSingle ? layer.singleCenter : layer.regionCenter
                uniforms.region = .init(center.x, center.y, 0, 0)
            }
            var counts = SIMD2(UInt32(1), UInt32(table.map { $0.sampleCount - 1 } ?? 0))
            encoder.setRenderPipelineState(pathPipeline)
            // With zero table intervals the shader never reads this binding.
            encoder.setVertexBuffer(table?.buffer ?? buffer, offset: 0, index: 2)
            encoder.setVertexBytes(&counts, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 3)
            instanceCount = 1
        } else if let path, let prepared {
            if let perspective = layer.activePerspective {
                let factors = perspective.factors
                let limit = min(
                    WSSMusicNotesLayer.sizeRange.upperBound, min(region.width, region.height) * 0.48
                )
                uniforms.perspective = .init(factors.x, factors.y, limit, 1)
            }
            let timing = PreparedPath.timing(
                length: prepared.length, speed: notes.speed, time: time, closed: path.closed)
            let oscillation = layer.oscillationPhases(at: time)
            uniforms.phase = .init(timing.x, timing.y, oscillation.x, oscillation.y)
            uniforms.region.z = prepared.origin.x
            uniforms.region.w = prepared.origin.y
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
        if single != nil || prepared != nil && path != nil {
            var depth = WSSMusicNotesDepth.Uniforms(
                layer.depth, side: depthSide, closed: path?.closed == true)
            encoder.setVertexBytes(
                &depth, length: MemoryLayout<WSSMusicNotesDepth.Uniforms>.stride, index: 4)
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
            float4 motion, perspective;
        };

        uint musicSymbol(float selection, constant NotesUniforms &u) {
            uint count = uint(u.motion.y);
            return u.symbols[min(uint(selection * float(count)), count - 1)];
        }

        // Original 64-square tiles stay in the top row. The clef uses a
        // padded 96-by-192 tile with its long axis matching the logical size.
        float2 musicSymbolUV(uint symbol, float2 corner) {
            float2 uv = float2(corner.x, 1.0 - corner.y);
            if (symbol == 3) {
                return (float2(0, 64) + uv * float2(96, 192)) / 256.0;
            }
            return (float2(symbol * 64, 0) + uv * 64.0) / 256.0;
        }

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
            position += u.shape.yw * size * u.motion.x
                * sin(turn * (note.w + u.phase.z)) / span;
            float2 center = fract(position) * span;
            float2 alternate = select(span, -span, center >= span * 0.5);
            center += alternate * float2(tile & 1, tile >> 1);
            float extent = size * 0.708;
            if (any(center + extent <= 0.0) || any(center - extent >= span)) {
                return {float4(2, 2, 0, 1), float2(0), float2(0)};
            }

            float2 corner = float2(vertexID & 1, vertexID >> 1);
            uint symbol = musicSymbol(note.z, u);
            float2 offset = (corner - 0.5) * size;
            if (symbol == 3) offset.x *= 0.5;
            float angle = u.shape.z * 0.32 * sin(turn * (note.w + u.phase.w));
            float c = cos(angle), s = sin(angle);
            float2 local = center + float2(c * offset.x - s * offset.y, s * offset.x + c * offset.y);
            float2 clip = ((local + u.region.xy) / u.projection.xy * 2.0 - 1.0) / u.projection.zw;
            float2 uv = musicSymbolUV(symbol, corner);
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

        struct NoteDepth {
            float4 first, second;
            uint4 section;
        };

        vertex PathVertex musicNotePathQuad(
            uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
            constant NotesUniforms &u [[buffer(0)]],
            device const float4 *instances [[buffer(1)]],
            device const float4 *samples [[buffer(2)]],
            constant uint2 &counts [[buffer(3)]],
            constant NoteDepth &depth [[buffer(4)]]
        ) {
            constexpr float turn = 6.28318530718;
            float4 note = instances[instanceID];
            bool fixedPosition = u.motion.z > 0;
            float travel = fixedPosition ? u.phase.x
                : fract(u.phase.x + (float(instanceID) + 0.5) / float(counts.x));
            float2 center = float2(0);
            float size = u.shape.x;
            float2 tangent = float2(1, 0);
            float squared = 1.0;
            if (counts.y > 0) {
                float progress = !fixedPosition && u.shape.w > 0 ? 1.0 - travel : travel;
                if (depth.section.z > 0) {
                    float depthProgress = depth.section.w > 0 && progress == 1.0 ? 0.0 : progress;
                    uint section = 0;
                    for (uint j = 0; j < depth.section.x; ++j) {
                        float boundary = j < 4 ? depth.first[j] : depth.second[j - 4];
                        section += uint(depthProgress >= boundary);
                    }
                    uint side = 1 + ((depth.section.y >> section) & 1);
                    if (side != depth.section.z) {
                        return {float4(2, 2, 0, 1), float2(0), 0.0};
                    }
                }
                if (u.perspective.w > 0) {
                    float scale = u.perspective.x + (u.perspective.y - u.perspective.x) * progress;
                    size = min(size * scale, u.perspective.z);
                }
                float index = progress * float(counts.y);
                uint lower = min(uint(index), counts.y - 1);
                float fraction = index - float(lower);
                float4 a = samples[lower], b = samples[lower + 1];
                center = mix(a.xy, b.xy, fraction);

                if (u.motion.x > 0 || (fixedPosition && u.motion.w > 0)) {
                    // Authored orientation is independent of playback direction.
                    float2 blended = mix(a.zw, b.zw, fraction);
                    squared = dot(blended, blended);
                    tangent = squared > 1e-6 ? blended * rsqrt(max(squared, 1e-6))
                        : (fraction < 0.5 ? a.zw : b.zw);
                }
            }

            if (u.motion.x > 0) {
                float2 normal = float2(-tangent.y, tangent.x);
                center += normal * (size * u.motion.x * smoothstep(1e-6, 0.04, squared)
                    * sin(turn * (note.w + u.phase.z)));
            }

            float2 corner = float2(vertexID & 1, vertexID >> 1);
            uint symbol = musicSymbol(note.z, u);
            float2 offset = (corner - 0.5) * size;
            if (symbol == 3) offset.x *= 0.5;
            float angle = u.shape.z * 0.32 * sin(turn * (note.w + u.phase.w));
            if (fixedPosition && u.shape.y != 0.0) {
                float spin = turn * u.shape.y;
                if (u.shape.w > 0) {
                    // A signed width projects both faces with unchanged UVs.
                    // The composition encoder disables back-face culling.
                    float phase = abs(u.shape.y);
                    offset.x *= phase == 0.25 || phase == 0.75 ? 0.0 : cos(spin);
                } else {
                    angle += spin;
                }
            }
            if (fixedPosition && u.motion.w > 0 && counts.y > 0) {
                angle += atan2(tangent.y, tangent.x);
            }
            float c = cos(angle), s = sin(angle);
            float2 local = center + float2(c * offset.x - s * offset.y, s * offset.x + c * offset.y);
            float2 clip = ((local + u.region.zw + u.region.xy) / u.projection.xy * 2.0 - 1.0)
                / u.projection.zw;
            float2 uv = musicSymbolUV(symbol, corner);
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
