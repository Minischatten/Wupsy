import Metal
import simd

// Local color-space boundary only: legacy composition/pipelines are untouched.
final class WSSStormLightingRenderer {
    let pipeline: MTLRenderPipelineState
    init(device: MTLDevice) throws {
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "stormLightVertex")
        d.fragmentFunction = library.makeFunction(name: "stormLightFragment")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: d)
    }
    func encode(
        command: MTLCommandBuffer, descriptor: MTLRenderPassDescriptor,
        input: MTLTexture, frame: WSSStormLightingFrame
    ) -> Bool {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            return false
        }
        let uniforms = [SIMD4(frame.exposure, 0), SIMD4(frame.shadowLift, 0)]
        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(.none)
        encoder.setFragmentTexture(input, index: 0)
        uniforms.withUnsafeBytes {
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }
    static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 stormLightVertex(uint id [[vertex_id]]) {
            const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};
            return float4(p[id],0,1);
        }
        float3 lightLinear(float3 c) {
            return select(pow((c+0.055)/1.055,float3(2.4)),c/12.92,c<=0.04045);
        }
        float3 lightEncoded(float3 c) {
            return select(1.055*pow(c,float3(1.0/2.4))-0.055,12.92*c,c<=0.0031308);
        }
        fragment float4 stormLightFragment(float4 position [[position]],
            texture2d<float,access::read> source [[texture(0)]], constant float4 *u [[buffer(0)]]) {
            // Exact pixel read, no resampling and no change to composed alpha.
            float4 sample=source.read(uint2(position.xy));
            float3 c=lightLinear(clamp(sample.rgb,0.0,1.0));
            float3 gain=exp2(u[0].rgb);
            float shadows=pow(1-clamp(dot(c,float3(0.2126,0.7152,0.0722)),0.0,1.0),2.0);
            float3 lift=u[1].rgb*shadows;
            // Anchored shoulder: identity at gain=1/lift=0, white stays white.
            float3 result=(c*gain+lift)/(1+c*(gain-1)+lift);
            return float4(lightEncoded(clamp(result,0.0,1.0)),sample.a);
        }
        """
}
