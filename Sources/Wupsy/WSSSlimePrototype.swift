import Metal
import simd

/// Internal acceptance geometry in logical canvas units, with Y pointing down.
struct WSSSlimePrototype {
    static let canvas = SIMD2<Float>(480, 360)
    static let duration = 7.0
    static let release = 3.8
    static let fallLimit: Float = 147
    static let anchor = SIMD2<Float>(240, 83)
    static let segments = 12

    struct Material {
        var tintAndOpacity: SIMD4<Float>

        static let dark = Self(tintAndOpacity: SIMD4(0.13, 0.26, 0.15, 0.87))
        static let clear = Self(tintAndOpacity: SIMD4(0.71, 0.82, 0.79, 0.30))
    }

    struct Frame: Equatable {
        // XY center, Z radius.
        var stem: [SIMD4<Float>]
        var neck: SIMD4<Float>
        // XY center, Z horizontal radius, W vertical radius.
        var drop: SIMD4<Float>
        var visibility: Float
    }

    static func ramp(_ value: Float) -> Float {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    static func frame(at time: Double) -> Frame {
        let phase = time.isFinite && time >= 0 ? time.truncatingRemainder(dividingBy: duration) : 0
        let age = Float(phase)
        let fall = max(0, Float(phase - release))
        let growth = ramp((age - 0.30) / 3.1)
        let stretch = ramp((age - 2.45) / 1.35)
        let settling = ramp(fall / 0.92)
        // The tip draws in faster than the lateral bend relaxes, then slows into the pad.
        let retract = settling + 0.60 * settling * (1 - settling)
        let reach = (5 + 77 * growth + 15 * stretch) * (1 - retract) + 5 * retract
        let relaxedBend = 1 - settling
        let bend = (6 * growth + 1.2 * sin(age * 2) * growth * (1 - stretch)) * relaxedBend
        let gathering = 4 * settling * (1 - settling)
        let bulgeCenter = 1 - 0.36 * settling
        let stem = (0...segments).map { index -> SIMD4<Float> in
            let u = Float(index) / Float(segments)
            let x = anchor.x + bend * u * u + 2.5 * growth * relaxedBend * sin(u * .pi)
            let taper = 9 * (1 - u) * (1 - 0.38 * stretch * u * (1 - retract))
            // The existing round-ended tube gathers material near its tip, then into the stem.
            let bulge = 3.8 * gathering * u * (1 - ramp(abs(u - bulgeCenter) / 0.48))
            let longitudinal = u + 0.24 * gathering * u * (1 - u)
            return SIMD4(x, anchor.y + reach * longitudinal, taper + bulge, 0)
        }

        let releaseX = anchor.x + 6
        let releaseY = anchor.y + 97 + 13.5
        let distance = min(fallLimit, 96 * fall * fall)
        let drop = SIMD4(
            fall > 0 ? releaseX + distance * 0.026 : stem[segments].x,
            fall > 0 ? releaseY + distance : stem[segments].y + 13.5 * stretch,
            1.2 + 8.3 * growth - 1.4 * ramp(distance / 90),
            1.2 + 8.3 * growth + 4 * stretch + 2 * ramp(distance / 90))
        let neck = SIMD4(
            stem[segments].x, stem[segments].y + 5 * stretch,
            4.5 * growth * (1 - stretch), 0)
        return Frame(
            stem: stem, neck: neck, drop: drop,
            visibility: ramp((age - 0.4) / 0.6) * (1 - ramp((distance - 105) / 42)))
    }
}

struct WSSSlimePrototypeRenderer {
    private let pipeline: MTLRenderPipelineState

    init(device: MTLDevice) throws {
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "slimeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "slimeFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func encode(
        at time: Double, material: WSSSlimePrototype.Material, encoder: MTLRenderCommandEncoder
    ) {
        let frame = WSSSlimePrototype.frame(at: time)
        // The pad, stem, neck and drop share one fragment evaluation and blend operation.
        var bounds = SIMD4<Float>(221, 71, 268, 104)
        for sample in frame.stem + [frame.neck] {
            bounds.x = min(bounds.x, sample.x - sample.z - 2)
            bounds.y = min(bounds.y, sample.y - sample.z - 2)
            bounds.z = max(bounds.z, sample.x + sample.z + 2)
            bounds.w = max(bounds.w, sample.y + sample.z + 2)
        }
        if frame.visibility > 0 {
            bounds.x = min(bounds.x, frame.drop.x - frame.drop.z - 2)
            bounds.z = max(bounds.z, frame.drop.x + frame.drop.z + 2)
            bounds.w = max(bounds.w, frame.drop.y + frame.drop.w + 2)
        }
        let parameters = [
            frame.neck, frame.drop, material.tintAndOpacity,
            SIMD4(frame.visibility, 0, 0, 0),
        ]
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&bounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        frame.stem.withUnsafeBytes {
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
        }
        parameters.withUnsafeBytes {
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private static let shader = """
        #include <metal_stdlib>
        using namespace metal;

        struct Raster { float4 position [[position]]; float2 p; };

        vertex Raster slimeVertex(uint id [[vertex_id]], constant float4 &bounds [[buffer(0)]]) {
            float2 uv = float2(id & 1, id >> 1);
            float2 p = mix(bounds.xy, bounds.zw, uv);
            return { float4(p / float2(480, 360) * float2(2, -2) + float2(-1, 1), 0, 1), p };
        }

        struct Surface {
            float distance;
            float radius;
            float2 slope;
        };

        Surface ellipse(float2 p, float4 shape) {
            float2 q = (p - shape.xy) / shape.zw;
            return { (length(q) - 1) * min(shape.z, shape.w), shape.z,
                q * min(shape.z, shape.w) / shape.zw };
        }

        Surface tube(float2 p, float4 a, float4 b) {
            float2 axis = b.xy - a.xy;
            float lengthSquared = max(dot(axis, axis), 0.00001f);
            float t = clamp(dot(p - a.xy, axis) / lengthSquared, 0.0, 1.0);
            float2 delta = p - mix(a.xy, b.xy, t);
            float r = mix(a.z, b.z, t);
            float inverseLength = rsqrt(lengthSquared);
            float2 tangent = axis * inverseLength;
            float2 lateral = float2(tangent.y, -tangent.x);
            float taper = clamp((a.z - b.z) * inverseLength, -0.5f, 0.5f);
            float2 slope = delta / max(r, 0.1f) + tangent * taper;
            // Small longitudinal changes in apparent surface curvature break up the reflection.
            slope += lateral * (0.13f * sin((p.y - 83) * 0.16f)
                + 0.06f * sin((p.y - 83) * 0.37f));
            return { length(delta) - r, r, slope };
        }

        Surface nearest(Surface a, Surface b) { return a.distance <= b.distance ? a : b; }

        float4 shadeMaterial(Surface surface, float4 material, float coverage, float thickness) {
            float2 slope = surface.slope * rsqrt(max(1.0f, dot(surface.slope, surface.slope)));
            float3 normal = float3(slope, sqrt(max(0.0f, 1 - dot(slope, slope))));
            // Two broad reflections with different orientations over a tinted body.
            float diffuse = saturate(dot(normal, float3(-0.49, -0.39, 0.78)));
            float key = smoothstep(0.64f, 1.0f, dot(normal, float3(-0.42, -0.38, 0.824)));
            float fill = smoothstep(0.60f, 1.0f, dot(normal, float3(0.60, 0.35, 0.72)));
            float rim = 1 - normal.z;
            float gloss = (0.38f * key * key + 0.13f * fill) * mix(0.35f, 1.0f, thickness);
            float alpha = coverage * saturate(
                material.a * mix(0.45f, 1.0f, thickness) + 0.22f * gloss + 0.06f * rim);
            float3 body = material.rgb * mix(0.54f, 1.02f, diffuse);
            float3 color = mix(body, float3(0.87, 0.97, 0.93), gloss);
            return float4(color * alpha, alpha);
        }

        fragment float4 slimeFragment(
            Raster in [[stage_in]], constant float4 *stem [[buffer(0)]],
            constant float4 *params [[buffer(1)]]
        ) {
            float2 p = in.p;
            Surface surface = ellipse(p, float4(240, 83, 16, 8));
            for (uint i = 0; i < \(WSSSlimePrototype.segments); ++i) {
                surface = nearest(surface, tube(p, stem[i], stem[i + 1]));
            }
            float4 neck = params[0], drop = params[1], material = params[2];
            if (neck.z > 0.001) {
                surface = nearest(surface, tube(p, stem[\(WSSSlimePrototype.segments)], neck));
                surface = nearest(surface, tube(p, neck, float4(drop.xy, neck.z * 0.5, 0)));
            }
            float aa = max(length(dfdx(p)) + length(dfdy(p)), 0.001) * 0.5;
            Surface falling = ellipse(p, drop);
            float visibility = params[3].x;
            // Hide the free drop by fading its coverage, without layering alpha over the stem.
            float bodyCoverage = (1 - smoothstep(-aa, aa, surface.distance)) *
                smoothstep(0.0, aa, surface.radius);
            float dropCoverage = (1 - smoothstep(-aa, aa, falling.distance)) * visibility;
            if (dropCoverage > 0 && (falling.distance < surface.distance || bodyCoverage == 0)) {
                // Coverage remains the union; shading follows the nearest contour.
                float weight = bodyCoverage == 0 ? 1.0 : visibility;
                surface.radius = mix(surface.radius, falling.radius, weight);
                surface.slope = mix(surface.slope, falling.slope, weight);
            }
            float coverage = max(bodyCoverage, dropCoverage);
            float thickness = smoothstep(0.0, 9.0, surface.radius);
            return shadeMaterial(surface, material, coverage, thickness);
        }
        """
}
