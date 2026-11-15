import Metal
import simd

final class WSSStormRenderContext {
    struct Key: Equatable {
        let event: UInt64
        let seed: UInt32
        let length: Double
        let spread: Double
        let depth: Int
    }
    struct Entry {
        let key: Key
        let buffer: MTLBuffer
        let count: Int
    }
    private(set) var entries: [Int: Entry] = [:]
    private(set) var generationCount = 0
    var bufferBytes: Int { entries.values.reduce(0) { $0 + $1.buffer.length } }
    func reset() { entries.removeAll() }
    func entry(index: Int, configuration c: WSSStormConfiguration, event: UInt64, device: MTLDevice)
        throws -> Entry
    {
        let key = Key(
            event: event, seed: c.seed, length: c.length, spread: c.spread, depth: c.branchDepth)
        if let old = entries[index], old.key == key,
            old.buffer.device.registryID == device.registryID
        {
            return old
        }
        guard (0..<128).contains(index),
            entries[index] != nil || entries.count < WSSStormGeometry.maximumLayers
        else {
            throw WSSSceneError.invalid("storm cache budget")
        }
        let segments = try WSSStormGeometry.segments(c, event: event)
        let packed = segments.map { segment in
            WSSStormRenderer.Segment(
                a: segment.a, b: segment.b,
                previous: segment.previous ?? segment.a, next: segment.next ?? segment.b,
                style: SIMD4(
                    segment.strength, segment.previous == nil ? 0 : 1, segment.next == nil ? 0 : 1,
                    0))
        }
        let buffer = packed.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        guard let buffer else { throw WSSSceneError.invalid("storm vertex allocation") }
        let entry = Entry(key: key, buffer: buffer, count: packed.count)
        entries[index] = entry
        generationCount += 1
        return entry
    }
}
final class WSSStormRenderer {
    struct Segment {
        var a: SIMD2<Float>
        var b: SIMD2<Float>
        var previous: SIMD2<Float>
        var next: SIMD2<Float>
        var style: SIMD4<Float>
    }
    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    init(device: MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let p = MTLRenderPipelineDescriptor()
        p.vertexFunction = library.makeFunction(name: "stormVertex")
        p.fragmentFunction = library.makeFunction(name: "stormFragment")
        let a = p.colorAttachments[0]!
        a.pixelFormat = .bgra8Unorm
        a.isBlendingEnabled = true
        a.sourceRGBBlendFactor = .one
        a.destinationRGBBlendFactor = .one
        a.writeMask = [.red, .green, .blue]
        pipeline = try device.makeRenderPipelineState(descriptor: p)
    }
    func encode(
        index: Int, layer: WSSStormLayer, encoder: MTLRenderCommandEncoder,
        command: MTLCommandBuffer, context: WSSStormRenderContext, time: Double,
        canvas: SIMD2<Float>, crop: SIMD2<Float>
    ) throws {
        let c = layer.storm
        guard c.boltEnabled, c.brightness > 0, let event = WSSStormEvents.event(c, at: time),
            event.intensity > 0
        else { return }
        let entry = try context.entry(
            index: index, configuration: c, event: event.identity, device: device)
        let angle = Float(c.direction * .pi / 180)
        let uniforms = [
            SIMD4(canvas.x, canvas.y, crop.x, crop.y),
            SIMD4(Float(c.x), Float(c.y), cos(angle), sin(angle)),
            SIMD4(
                Float(c.red), Float(c.green), Float(c.blue), Float(c.brightness) * event.intensity),
            SIMD4(Float(c.width), Float(c.glow), 0, 0),
        ]
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(entry.buffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(entry.buffer, offset: 0, index: 1)
        uniforms.withUnsafeBytes {
            encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
        }
        encoder.drawPrimitives(
            type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: entry.count)
        // Immutable event buffers may leave the cache while older commands are in flight.
        command.addCompletedHandler { [buffer = entry.buffer] _ in _ = buffer }
    }
    static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct Segment { float2 a; float2 b; float2 previous; float2 next; float4 style; };
        struct Out { float4 position [[position]]; float2 local; uint index [[flat]]; };
        vertex Out stormVertex(uint id [[vertex_id]], uint instance [[instance_id]], const device Segment *segments [[buffer(0)]], constant float4 *u [[buffer(1)]]) {
            const float2 corners[6] = {float2(-1,0),float2(1,0),float2(-1,1),float2(-1,1),float2(1,0),float2(1,1)};
            Segment s=segments[instance]; float2 delta=s.b-s.a;
            float2 tangent=delta/max(length(delta),0.001), normal=float2(-tangent.y,tangent.x);
            float radius=(u[3].x*0.5+u[3].y+1)*s.style.x;
            float2 corner=corners[id];
            float2 local=mix(s.a,s.b,corner.y)+normal*corner.x*radius+tangent*(corner.y*2-1)*radius;
            float2 p=float2(local.x*u[1].z-local.y*u[1].w,local.x*u[1].w+local.y*u[1].z)+u[1].xy;
            Out o; o.position=float4((p*2/u[0].xy-1)/u[0].zw,0,1);
            o.local=local; o.index=instance; return o;
        }
        float segmentDistance(float2 p,float2 a,float2 b) {
            float2 ab=b-a; float t=clamp(dot(p-a,ab)/max(dot(ab,ab),1e-12),0.0,1.0);
            return length(p-a-ab*t);
        }
        fragment float4 stormFragment(Out in [[stage_in]], constant float4 *u [[buffer(0)]], const device Segment *segments [[buffer(1)]]) {
            Segment s=segments[in.index]; float strength=s.style.x;
            float d=segmentDistance(in.local,s.a,s.b), edge=max(fwidth(d),0.001);
            // Voronoi ownership between connected capsules: nearest segment shades
            // a join once. Equal distances belong to the preceding segment.
            float tolerance=0.001*max(edge,1.0);
            if(s.style.y>0 && segmentDistance(in.local,s.previous,s.a)<=d+tolerance) discard_fragment();
            if(s.style.z>0 && segmentDistance(in.local,s.b,s.next)<d-tolerance) discard_fragment();
            float halfWidth=u[3].x*0.5*strength;
            float core=1-smoothstep(max(0.0,halfWidth-edge),halfWidth+edge,d);
            float radius=max(u[3].y*strength,0.001);
            float glow=u[3].y>0 ? exp(-4*pow(max(0.0,d-halfWidth)/radius,2.0))*(1-smoothstep(0.8,1.0,max(0.0,d-halfWidth)/radius))*0.22 : 0;
            float3 color=(mix(u[2].rgb,float3(1),0.65)*core+u[2].rgb*glow)*u[2].w*strength;
            return float4(color,0);
        }
        """
}
