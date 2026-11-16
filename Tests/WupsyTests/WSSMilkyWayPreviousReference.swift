// Frozen original Wupsy stage-3 shader for reproducible visual/performance comparisons.
// Test-only reference; never compiled or selected by the shipping application.
enum WSSMilkyWayPreviousReference {
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
        fragment float4 galaxyFragment(GalaxyOut v [[stage_in]],constant float4 *u [[buffer(0)]],constant uint &seed [[buffer(1)]]) {
            float2 uv=fract(v.uv-u[5].xy);
            float minor=min(u[1].z,u[1].w);
            int2 base=max(int2(round(u[1].zw/minor*6)),int2(1));
            float coarse=galaxyNoise(uv,base,seed);
            float middle=galaxyNoise(uv,base*2,seed^0xa341316cu);
            float fine=galaxyNoise(uv,base*8,seed^0xc8013ea4u);
            float micro=galaxyNoise(uv,base*32,seed^0xad90777du);
            float clouds=0.5*coarse+0.28*middle+0.15*fine+0.07*micro;
            float2 q=fract(uv-u[2].xy);
            float band=0,dark=0;
            float width=u[3].x*minor;
            // Four weighted periodic images form a continuous partition of unity.
            // The band rotates in metric scene coordinates, not stretched UV space.
            for(int y=0;y<2;y++) for(int x=0;x<2;x++) {
                float2 d=(q-float2(x,y))*u[1].zw;
                float along=dot(d,u[2].zw);
                float cross=dot(d,float2(-u[2].w,u[2].z));
                float w=(x==0?1-q.x:q.x)*(y==0?1-q.y:q.y);
                float warped=cross+(coarse-0.5)*width*0.5;
                float profile=exp(-3*pow(warped/width,2.0));
                float lane=warped+sin(along/minor*8+middle*5)*width*0.16;
                float dust=exp(-pow(lane/(width*(0.05+0.12*fine)),2.0))*(0.45+0.55*middle);
                band+=w*profile; dark+=w*profile*dust;
            }
            float luminosity=mix(0.55,0.1+1.8*pow(clouds,1.7),u[3].z);
            float detail=mix(1.0,0.65+0.7*fine+0.35*micro,u[3].z);
            // Dense unresolved stellar granularity, with a separate deterministic hash domain.
            int2 grid=base*32; float2 p=uv*float2(grid),f=fract(p);
            uint2 cell=galaxyWrap(int2(floor(p)),grid);
            float2 center=0.2+0.6*float2(galaxyUnit(cell,seed^0x13u),galaxyUnit(cell,seed^0x71u));
            float2 cellPixels=(u[5].zw*u[1].zw/u[0].zw)/float2(grid);
            float radius=max(0.055,0.45/max(min(cellPixels.x,cellPixels.y),0.01));
            float stars=exp(-dot(f-center,f-center)/(radius*radius))
                *pow(galaxyUnit(cell,seed^0x51u),5.0)*1.7;
            float energy=max(0.0,band-u[3].w*0.95*dark)*luminosity*detail;
            float3 tint=clamp(u[4].rgb*(1+0.10*float3(coarse-0.5,0.0,0.5-coarse)),0.0,1.0);
            return float4(tint*u[3].y*(energy+band*stars*(0.25+0.75*u[3].z)),0);
        }
        """
}
