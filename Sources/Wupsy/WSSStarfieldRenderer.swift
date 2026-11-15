import Foundation
import Metal
import simd

// Immutable seeded geometry, shared by compatible snapshots. Animation is analytic.
final class WSSStarfieldRenderer {
    struct Prepared {
        let count: Int
        let seed: UInt32
        let buffer: MTLBuffer?
    }
    let pipeline: MTLRenderPipelineState
    let layers: [Int: Prepared]
    var bufferBytes: Int { layers.values.reduce(0) { $0 + ($1.buffer?.length ?? 0) } }
    init(scene: WSSScene, device: MTLDevice) throws {
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let p = MTLRenderPipelineDescriptor()
        p.vertexFunction = library.makeFunction(name: "starVertex")
        p.fragmentFunction = library.makeFunction(name: "starFragment")
        let a = p.colorAttachments[0]!
        a.pixelFormat = .bgra8Unorm
        a.isBlendingEnabled = true
        a.sourceRGBBlendFactor = .one
        a.destinationRGBBlendFactor = .one
        a.writeMask = [.red, .green, .blue]
        pipeline = try device.makeRenderPipelineState(descriptor: p)
        var prepared: [Int: Prepared] = [:]
        for (index, node) in scene.layers.enumerated() {
            guard case .starfield(let layer) = node else { continue }
            let c = layer.starfield
            let population = try WSSStarfieldPopulation(count: c.count, seed: c.seed)
            let buffer: MTLBuffer?
            if population.instances.isEmpty {
                buffer = nil
            } else {
                buffer = population.instances.withUnsafeBytes {
                    device.makeBuffer(
                        bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
                }
                guard buffer != nil else {
                    throw WSSSceneError.invalid("starfield buffer allocation")
                }
            }
            prepared[index] = Prepared(count: c.count, seed: c.seed, buffer: buffer)
        }
        layers = prepared
    }
    func encode(
        index: Int, layer: WSSStarfieldLayer, encoder: MTLRenderCommandEncoder,
        canvas: SIMD2<Float>, crop: SIMD2<Float>, drawableSize: CGSize, time: Double
    ) throws {
        let c = layer.starfield
        guard c.isEffective else { return }
        guard let prepared = layers[index], prepared.count == c.count, prepared.seed == c.seed,
            let buffer = prepared.buffer
        else { throw WSSSceneError.invalid("missing starfield population") }
        let drift = c.driftX != 0 || c.driftY != 0
        let phases = (0..<8).map { group in
            WSSStarfieldConfiguration.phase(
                time: time,
                speed: c.twinkleSpeed * (0.65 + 0.1 * Double(group)) * 2 * .pi, period: 2 * .pi)
        }
        let uniforms: [SIMD4<Float>] = [
            SIMD4(canvas.x, canvas.y, canvas.x * crop.x, canvas.y * crop.y),
            SIMD4(Float(c.x), Float(c.y), Float(c.width), Float(c.height)),
            SIMD4(
                WSSStarfieldConfiguration.phase(time: time, speed: c.driftX, period: c.width),
                WSSStarfieldConfiguration.phase(time: time, speed: c.driftY, period: c.height),
                drift ? 1 : 0, 0),
            SIMD4(Float(c.red), Float(c.green), Float(c.blue), Float(c.colorVariation)),
            SIMD4(
                Float(c.size), Float(c.brightness),
                c.twinkleEnabled ? Float(c.twinkleIntensity) : 0,
                min(
                    Float(drawableSize.width) / (canvas.x * crop.x),
                    Float(drawableSize.height) / (canvas.y * crop.y))),
            SIMD4(phases[0], phases[1], phases[2], phases[3]),
            SIMD4(phases[4], phases[5], phases[6], phases[7]),
        ]
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 1)
        uniforms.withUnsafeBytes {
            encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
        }
        encoder.drawPrimitives(
            type: .triangleStrip, vertexStart: 0, vertexCount: 4,
            instanceCount: prepared.count * (drift ? 9 : 1))
    }
    static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct Star { float4 state, variation; };
        struct StarOut { float4 position [[position]]; float2 uv; float2 logical; float3 color; float light; float aa; };
        vertex StarOut starVertex(uint corner [[vertex_id]], uint id [[instance_id]],
            constant float4 *u [[buffer(0)]], const device Star *stars [[buffer(1)]]) {
            bool drift = u[2].z > 0;
            Star s = stars[drift ? id/9 : id];
            float2 uv=float2(corner%2,corner/2)*2-1;
            float2 extent=u[1].zw;
            float2 center=s.state.xy*extent;
            if(drift) center=fract((center+u[2].xy)/extent)*extent
                +float2(int(id%9)%3-1,int(id%9)/3-1)*extent;
            // A bounded halo fits the neighboring-tile contract even in tiny regions.
            float radius=min(u[4].x*s.state.z*3,min(extent.x,extent.y)*0.49);
            float2 logical=u[1].xy+center+uv*radius;
            float2 clip=(logical-u[0].xy*0.5)*2/u[0].zw;
            if(any(center+radius<0)||any(center-radius>extent)) clip=float2(3,3);
            uint group=uint(s.variation.y);
            float phase=group<4 ? u[5][group] : u[6][group-4];
            float twinkle=1-u[4].z*(0.5+0.5*sin(phase+s.variation.x));
            float3 color=clamp(u[3].rgb*(1+u[3].a*0.15*float3(s.variation.z,s.variation.w,-s.variation.z)),0.0,1.0);
            return {float4(clip,0,1),uv,logical,color,s.state.w*u[4].y*twinkle,0.5/max(radius*u[4].w,0.001)};
        }
        fragment float4 starFragment(StarOut v [[stage_in]], constant float4 *u [[buffer(0)]]) {
            if(any(v.logical<u[1].xy)||any(v.logical>u[1].xy+u[1].zw)) discard_fragment();
            float r=length(v.uv);
            // Analytic pixel footprint avoids derivative parity flicker on tiny moving cores.
            float aa=max(v.aa,0.001);
            float core=1-smoothstep(0.12-aa,0.24+aa,r);
            float halo=0.12*exp(-5*r*r)*(1-smoothstep(0.7,1.0,r));
            return float4(v.color*v.light*(core+halo),0);
        }
        """
}
