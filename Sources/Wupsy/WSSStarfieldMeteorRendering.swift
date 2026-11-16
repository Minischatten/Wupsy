import Foundation
import Metal
import simd

extension WSSStarfieldRenderer {
    // Two bounded event candidates, tiny inline uniforms, no GPU allocation or history target.
    func encodeMeteors(
        layer: WSSStarfieldLayer, encoder: MTLRenderCommandEncoder,
        canvas: SIMD2<Float>, crop: SIMD2<Float>, drawableSize: CGSize, time: Double
    ) {
        let c = layer.starfield
        guard max(c.red, max(c.green, c.blue)) > 0 else { return }
        let events = WSSShootingStarEvents.events(c, at: time)
        guard !events.isEmpty else { return }
        encoder.setRenderPipelineState(meteorPipeline)
        let density = min(
            Float(drawableSize.width) / (canvas.x * crop.x),
            Float(drawableSize.height) / (canvas.y * crop.y))
        for event in events {
            let head = event.head(c)
            let uniforms: [SIMD4<Float>] = [
                SIMD4(canvas.x, canvas.y, canvas.x * crop.x, canvas.y * crop.y),
                SIMD4(Float(c.x), Float(c.y), Float(c.width), Float(c.height)),
                SIMD4(Float(head.x), Float(head.y), Float(event.heading.x), Float(event.heading.y)),
                SIMD4(
                    Float(c.shootingStars.tailLength), Float(event.radius),
                    Float(event.envelope * event.brightness * c.shootingStars.brightness), density),
                SIMD4(Float(c.red), Float(c.green), Float(c.blue), 0),
            ]
            uniforms.withUnsafeBytes {
                encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
                encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }
    static let meteorShader = """
        struct MeteorOut { float4 position [[position]]; float2 local; float2 logical; };
        vertex MeteorOut meteorVertex(uint id [[vertex_id]], constant float4 *u [[buffer(0)]]) {
            float radius=max(u[3].y,0.6/max(u[3].w,0.001));
            float2 local=float2(mix(-u[3].x-3*radius,3*radius,float(id%2)),(float(id/2)*2-1)*3*radius);
            float2 direction=u[2].zw, normal=float2(-direction.y,direction.x);
            float2 logical=u[2].xy+direction*local.x+normal*local.y;
            float2 clip=(logical-u[0].xy*0.5)*2/u[0].zw;
            return {float4(clip,0,1),local,logical};
        }
        fragment float4 meteorFragment(MeteorOut v [[stage_in]], constant float4 *u [[buffer(0)]]) {
            if(any(v.logical<u[1].xy)||any(v.logical>u[1].xy+u[1].zw)) discard_fragment();
            float radius=u[3].y;
            // Pixel-aware core footprint, independent of quad derivative parity.
            float coreRadius=max(radius,0.6/max(u[3].w,0.001));
            float r=length(v.local)/coreRadius;
            float head=exp(-2*r*r)*(1-smoothstep(2.0,3.0,r));
            float tail=0;
            if(u[3].x>0) {
                float along=clamp(1+v.local.x/u[3].x,0.0,1.0);
                float cross=v.local.y/coreRadius;
                tail=0.45*pow(along,1.5)*exp(-3*cross*cross)
                    *(1-smoothstep(-radius,0.0,v.local.x));
            }
            return float4(u[4].rgb*u[3].z*(head+tail),0);
        }
        """
}
