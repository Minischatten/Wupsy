import Metal
import simd

// Texture-free native renderer; no Compatibility pipeline or wallpaper-specific constants.
final class WSSTrailRenderer {
    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    init(device: MTLDevice) throws {
        self.device = device
        let lib = try device.makeLibrary(source: Self.shader, options: nil)
        let p = MTLRenderPipelineDescriptor()
        p.vertexFunction = lib.makeFunction(name: "trailVertex")
        p.fragmentFunction = lib.makeFunction(name: "trailFragment")
        let a = p.colorAttachments[0]!
        a.pixelFormat = .bgra8Unorm
        a.isBlendingEnabled = true
        a.sourceRGBBlendFactor = .sourceAlpha
        a.destinationRGBBlendFactor = .one
        a.writeMask = [.red, .green, .blue]
        pipeline = try device.makeRenderPipelineState(descriptor: p)
    }
    func encode(
        encoder: MTLRenderCommandEncoder, simulation: WSSTrailSimulation,
        time: Double, canvas: SIMD2<Float>, crop: SIMD2<Float> = SIMD2(repeating: 1)
    ) throws {
        guard canvas.x.isFinite, canvas.y.isFinite, canvas.x > 0, canvas.y > 0,
            crop.x.isFinite, crop.y.isFinite, crop.x > 0, crop.y > 0
        else {
            throw WSSSceneError.invalid("trail canvas")
        }
        let vertices = simulation.vertices(time: time)
        guard !vertices.isEmpty else { return }
        let buffer = vertices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        guard let buffer else { throw WSSSceneError.invalid("trail vertex buffer") }
        let uniforms = [
            SIMD4(canvas.x, canvas.y, simulation.configuration.edgeSoftness, 0),
            SIMD4(crop.x, crop.y, 0, 0),
        ]
        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        uniforms.withUnsafeBytes { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
    }
    static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float2 position; float side; float padding; float4 color; };
        struct Out { float4 position [[position]]; float side; float4 color; };
        vertex Out trailVertex(uint id [[vertex_id]], const device Vertex *v [[buffer(0)]],
                               constant float4 *u [[buffer(1)]]) {
            Out o; o.position=float4((v[id].position*2/u[0].xy-1)/u[1].xy,0,1);
            o.side=v[id].side; o.color=v[id].color; return o;
        }
        fragment float4 trailFragment(Out in [[stage_in]], constant float4 *u [[buffer(0)]]) {
            float edge=max(u[0].z, max(fwidth(in.side), 0.0001));
            float coverage=1-smoothstep(1-edge,1.0,abs(in.side));
            return float4(in.color.rgb,in.color.a*coverage);
        }
        """
}
