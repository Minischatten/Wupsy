import Foundation
import Metal
import simd

// Lazy per prepared resource family: one region quad, no texture or geometry buffer.
final class WSSMilkyWayRenderer {
    let pipeline: MTLRenderPipelineState
    init(device: MTLDevice) throws {
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let p = MTLRenderPipelineDescriptor()
        p.vertexFunction = library.makeFunction(name: "galaxyVertex")
        p.fragmentFunction = library.makeFunction(name: "galaxyFragment")
        let a = p.colorAttachments[0]!
        a.pixelFormat = .bgra8Unorm
        a.isBlendingEnabled = true
        a.sourceRGBBlendFactor = .one
        a.destinationRGBBlendFactor = .one
        a.writeMask = [.red, .green, .blue]
        pipeline = try device.makeRenderPipelineState(descriptor: p)
    }
    func encode(
        _ c: WSSStarfieldConfiguration, encoder: MTLRenderCommandEncoder,
        canvas: SIMD2<Float>, crop: SIMD2<Float>, drawableSize: CGSize, time: Double
    ) {
        let m = c.milkyWay
        guard m.isEffective else { return }
        let angle = m.angle * .pi / 180
        let uniforms: [SIMD4<Float>] = [
            SIMD4(canvas.x, canvas.y, canvas.x * crop.x, canvas.y * crop.y),
            SIMD4(Float(c.x), Float(c.y), Float(c.width), Float(c.height)),
            SIMD4(Float(m.positionX), Float(m.positionY), Float(cos(angle)), Float(sin(angle))),
            SIMD4(Float(m.width), Float(m.intensity), Float(m.structure), Float(m.dust)),
            SIMD4(Float(m.red), Float(m.green), Float(m.blue), 0),
            SIMD4(
                WSSStarfieldConfiguration.phase(time: time, speed: c.driftX, period: c.width)
                    / Float(c.width),
                WSSStarfieldConfiguration.phase(time: time, speed: c.driftY, period: c.height)
                    / Float(c.height),
                Float(drawableSize.width), Float(drawableSize.height)),
        ]
        encoder.setRenderPipelineState(pipeline)
        uniforms.withUnsafeBytes {
            encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
        }
        var seed = m.seed
        encoder.setFragmentBytes(&seed, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
    static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct GalaxyOut { float4 position [[position]]; float2 uv; };
        vertex GalaxyOut galaxyVertex(uint id [[vertex_id]], constant float4 *u [[buffer(0)]]) {
            float2 uv=float2(id%2,id/2);
            float2 p=u[1].xy+uv*u[1].zw;
            return {float4((p-u[0].xy*0.5)*2/u[0].zw,0,1),uv};
        }
        uint galaxyHash(uint2 p,uint seed) {
            uint h=p.x*0x9e3779b9u ^ p.y*0x85ebca6bu ^ seed;
            h^=h>>16; h*=0x7feb352du; h^=h>>15; h*=0x846ca68bu; return h^(h>>16);
        }
        float galaxyUnit(uint2 p,uint seed) { return float(galaxyHash(p,seed)>>8)/16777216.0; }
        uint2 galaxyWrap(int2 p,int2 period) { return uint2((p%period+period)%period); }
        float galaxyNoise(float2 uv,int2 period,uint seed) {
            float2 p=uv*float2(period),f=fract(p); int2 cell=int2(floor(p));
            f=f*f*f*(f*(f*6-15)+10);
            float a=galaxyUnit(galaxyWrap(cell,period),seed);
            float b=galaxyUnit(galaxyWrap(cell+int2(1,0),period),seed);
            float c=galaxyUnit(galaxyWrap(cell+int2(0,1),period),seed);
            float d=galaxyUnit(galaxyWrap(cell+int2(1,1),period),seed);
            return mix(mix(a,b,f.x),mix(c,d,f.x),f.y);
        }
        // Two bounded fine-star fields; their local occupancy follows cloud density.
        // The finite cell kernel avoids an additional procedural instance population.
        float galaxyGrain(float2 uv,int2 grid,float2 outputPixels,uint seed,float density) {
            float2 p=uv*float2(grid),f=fract(p);
            uint2 cell=galaxyWrap(int2(floor(p)),grid);
            float2 center=0.18+0.64*float2(galaxyUnit(cell,seed^0x13u),galaxyUnit(cell,seed^0x71u));
            float luminosity=galaxyUnit(cell,seed^0x51u);
            float population=smoothstep(luminosity-0.06,luminosity+0.06,clamp(density,0.0,1.0));
            float2 cellPixels=outputPixels/float2(grid);
            float radius=clamp(0.38/max(min(cellPixels.x,cellPixels.y),0.01),0.045,0.24);
            float edge=min(min(f.x,f.y),min(1-f.x,1-f.y));
            float point=exp(-dot(f-center,f-center)/(radius*radius))*smoothstep(0.0,0.08,edge);
            return point*population*(0.25+2.5*pow(luminosity,4.0));
        }
        fragment float4 galaxyFragment(GalaxyOut v [[stage_in]],constant float4 *u [[buffer(0)]],constant uint &seed [[buffer(1)]]) {
            float2 uv=fract(v.uv-u[5].xy);
            float minor=min(u[1].z,u[1].w);
            int2 base=max(int2(round(u[1].zw/minor*3)),int2(1));
            float broad=galaxyNoise(uv,base,seed);
            float cloud=galaxyNoise(uv,base*2,seed^0xa341316cu);
            float fine=galaxyNoise(uv,base*9,seed^0xc8013ea4u);
            float micro=galaxyNoise(uv,base*35,seed^0xad90777du);
            // A broad separate domain produces patchy obscuration, not a drawn line.
            float dustCloud=galaxyNoise(uv,base*4,seed^0x9e12u);
            float dustDetail=galaxyNoise(uv,base*13,seed^0x35e1u);
            float structure=u[3].z;
            float occupancy=smoothstep(0.16,0.82,0.78*broad+0.22*cloud);
            float clouds=pow(occupancy,1.9)*(0.35+1.15*cloud);
            float knots=pow(smoothstep(0.50,0.90,cloud),3.0)*smoothstep(0.25,0.65,broad);
            float localDensity=clamp(0.025+1.15*clouds+1.7*knots,0.0,1.0);
            float density=mix(0.28,localDensity,structure);
            float2 q=fract(uv-u[2].xy);
            float obscured=0;
            float width=u[3].x*minor;
            // Keep the existing continuous periodic geometry, but vary the envelope.
            for(int y=0;y<2;y++) for(int x=0;x<2;x++) {
                float2 d=(q-float2(x,y))*u[1].zw;
                float cross=dot(d,float2(-u[2].w,u[2].z));
                float w=(x==0?1-q.x:q.x)*(y==0?1-q.y:q.y);
                float warp=(broad-0.5)*0.50+(cloud-0.5)*0.25;
                float warped=cross+warp*width;
                float localWidth=width*mix(1.0,0.65+0.9*cloud,structure);
                float profile=exp(-3*pow(warped/localWidth,2.0));
                float dustWidth=width*(0.12+0.34*dustCloud);
                float dustOffset=width*((cloud-0.5)*0.85+(fine-0.5)*0.25);
                float lane=exp(-1.4*pow((warped+dustOffset)/dustWidth,2.0));
                float patches=smoothstep(0.32,0.76,0.72*dustCloud+0.28*dustDetail);
                float opticalDepth=(0.35+1.8*patches)*lane+0.8*patches;
                obscured+=w*profile*exp(-u[3].w*opticalDepth*1.8);
            }
            // Diffuse emission is deliberately weak; local stellar texture carries the band.
            float diffuse=0.035+0.34*density;
            float mottling=mix(1.0,0.45+0.85*fine+0.55*micro,structure);
            float2 pixels=u[5].zw*u[1].zw/u[0].zw;
            float stars=galaxyGrain(uv,base*83,pixels,seed^0x713u,0.05+0.85*density)
                +0.75*galaxyGrain(uv,base*139,pixels,seed^0x925u,0.03+0.9*density);
            float stellarLight=stars*(0.55+1.4*density);
            float energy=3.2*obscured*(diffuse*mottling+stellarLight);
            float3 tint=clamp(u[4].rgb*(1+0.10*float3(cloud-0.5,0.0,0.5-cloud)),0.0,1.0);
            return float4(tint*u[3].y*energy,0);
        }
        """
}
