import Metal
import simd

/// Internal acceptance geometry in logical canvas units, with Y pointing down.
struct WSSSlimePrototype {
    static let canvas = SIMD2<Float>(480, 360)
    static let duration = 7.0
    static let release = 3.8
    static let referenceWidth: Float = 18
    static let referenceDropSize: Float = 19
    static let fallCoefficient: Float = 96

    static func cycleDuration(distance: Float) -> Double {
        max(duration, release + sqrt(Double(distance) / Double(fallCoefficient)) + 0.05)
    }

    static func fallAxis(direction: Float) -> SIMD2<Float> {
        let angle = (direction - 180) * (.pi / 180)
        return SIMD2(-sin(angle), -cos(angle))
    }
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

    /// Gravity-aligned scene pixels. Only the pad follows the layer transform.
    struct Placement {
        let axisX: SIMD2<Float>
        let axisY: SIMD2<Float>
        let anchorTilt: Float
        let longitudinalScale: Float
        let padTransform: SIMD4<Float>
        let padExtent: SIMD2<Float>

        init(_ transform: WSSImageTransform, direction: Float) {
            let down = fallAxis(direction: direction)
            let right = SIMD2(-down.y, down.x)
            let scaleX = simd_length(transform.axisX) / WSSSlimeLayer.referenceSize
            let scaleY = simd_length(transform.axisY) / WSSSlimeLayer.referenceSize
            axisX = right
            axisY = down
            longitudinalScale = scaleY

            let padRight = simd_normalize(transform.axisX)
            let padDown = -simd_normalize(transform.axisY)
            let padNormal = SIMD2(
                simd_dot(padDown, right), simd_dot(padDown, down))
            let tilt = atan2(padNormal.x, padNormal.y)
            // The pad has two sides. For a nearly opposing normal, blend back to
            // gravity instead of folding the filament or jumping at the angle wrap.
            anchorTilt = tilt * (1 - ramp((abs(tilt) - 2) / (.pi - 2)))

            padTransform = SIMD4(
                simd_dot(axisX, padRight) / scaleX, simd_dot(axisY, padRight) / scaleX,
                simd_dot(axisX, padDown) / scaleY, simd_dot(axisY, padDown) / scaleY)
            let padX = SIMD2(simd_dot(padRight, right), simd_dot(padRight, down)) * (16 * scaleX)
            let padY = SIMD2(simd_dot(padDown, right), simd_dot(padDown, down)) * (8 * scaleY)
            padExtent = SIMD2(
                simd_length(SIMD2(padX.x, padY.x)),
                simd_length(SIMD2(padX.y, padY.y)))
        }
    }

    private struct Centerline {
        let reach: Float
        let tilt: Float
        let bend: Float
        let sway: Float
        private static let turnLength: Float = 22

        func point(at distance: Float) -> SIMD2<Float> {
            // Integrate a tangent that turns uniformly from the pad normal to gravity.
            // Mid-angle form avoids cancellation for an almost straight filament.
            let arc = min(distance, Self.turnLength)
            let halfTurn = tilt * arc / (2 * Self.turnLength)
            let meanAngle = tilt - halfTurn
            let arcFactor = abs(halfTurn) < 0.001 ? 1 : sin(halfTurn) / halfTurn
            let u = distance / reach
            let swayOffset = (bend * u * u + sway * sin(u * .pi)) * ramp(distance / Self.turnLength)
            return anchor
                + SIMD2(
                    arc * arcFactor * sin(meanAngle) + swayOffset,
                    arc * arcFactor * cos(meanAngle) + distance - arc)
        }

        var tip: SIMD2<Float> { point(at: reach) }
        var tipTangent: SIMD2<Float> { simd_normalize(tip - point(at: reach - 0.25)) }
    }

    static func ramp(_ value: Float) -> Float {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    static func frame(
        at time: Double, configuration: WSSSlimeConfiguration = .init(), anchorTilt: Float = 0,
        longitudinalScale: Float = 1
    ) -> Frame {
        let released = Centerline(
            reach: configuration.length, tilt: anchorTilt, bend: 6, sway: 2.5)
        let arcLength = (1...segments).reduce(Float.zero) { length, index in
            let step = released.reach / Float(segments)
            let previous = released.point(at: Float(index - 1) * step)
            let next = released.point(at: Float(index) * step)
            return length + simd_distance(previous, next)
        }
        let lengthScale = configuration.length / arcLength
        let dropSize = configuration.dropSize / referenceDropSize
        let dropOffset = 13.5 * dropSize
        let releaseVector =
            (released.tip - anchor) * lengthScale + released.tipTangent * dropOffset
        // Reserve room for a short visible fall even if the requested filament
        // would already reach the endpoint. Compress the attached geometry
        // from the beginning of the cycle so release remains continuous.
        let minimumTravel = min(12, configuration.distance * 0.25)
        let fit = min(1, (configuration.distance - minimumTravel) / max(1, releaseVector.y))
        let travel = configuration.distance - releaseVector.y * fit
        let widthFactor = configuration.width / referenceWidth
        let speed = Double(configuration.speed)
        let phase: Double
        if time.isFinite, time >= 0, speed > 0 {
            let duration = cycleDuration(distance: travel / longitudinalScale)
            let base = time.truncatingRemainder(dividingBy: duration / speed) * speed
            let shifted = base + Double(configuration.cycleOffset) * duration
            phase = shifted >= duration ? shifted - duration : shifted
        } else {
            phase = 0
        }
        let age = Float(phase)
        let fall = max(0, Float(phase - release))
        let growth = ramp((age - 0.30) / 3.1)
        let stretch = ramp((age - 2.45) / 1.35)
        let settling = ramp(fall / 0.92)
        // The tip draws in faster than the lateral bend relaxes, then slows into the pad.
        let retract = settling + 0.60 * settling * (1 - settling)
        let reach =
            (5 + (configuration.length - 20) * growth + 15 * stretch) * (1 - retract)
            + 5 * retract
        let relaxedBend = 1 - settling
        let bend = (6 * growth + 1.2 * sin(age * 2) * growth * (1 - stretch)) * relaxedBend
        let gathering = 4 * settling * (1 - settling)
        let bulgeCenter = 1 - 0.36 * settling
        let line = Centerline(
            reach: reach, tilt: anchorTilt, bend: bend, sway: 2.5 * growth * relaxedBend)
        let stem = (0...segments).map { index -> SIMD4<Float> in
            let u = Float(index) / Float(segments)
            let taper = 9 * (1 - u) * (1 - 0.38 * stretch * u * (1 - retract))
            // The existing round-ended tube gathers material near its tip, then into the stem.
            let bulge = 3.8 * gathering * u * (1 - ramp(abs(u - bulgeCenter) / 0.48))
            let longitudinal = u + 0.24 * gathering * u * (1 - u)
            let point =
                anchor + (line.point(at: reach * longitudinal) - anchor) * (lengthScale * fit)
            return SIMD4(point.x, point.y, (taper + bulge) * widthFactor, 0)
        }

        let distance = min(travel, fallCoefficient * longitudinalScale * fall * fall)
        let dropCenter: SIMD2<Float>
        if fall > 0 {
            dropCenter = anchor + releaseVector * fit + SIMD2(0, distance)
        } else {
            dropCenter =
                anchor
                + ((line.tip - anchor) * lengthScale + line.tipTangent * (stretch * dropOffset))
                * fit
        }
        let drop = SIMD4(
            dropCenter.x, dropCenter.y,
            (1.2 + 8.3 * growth - 1.4 * ramp(distance / 90)) * dropSize,
            (1.2 + 8.3 * growth + 4 * stretch + 2 * ramp(distance / 90)) * dropSize)
        let neckCenter =
            anchor
            + ((line.tip - anchor) * lengthScale + line.tipTangent * (5 * stretch)) * fit
        let neck = SIMD4(
            neckCenter.x, neckCenter.y, 4.5 * growth * (1 - stretch) * widthFactor, 0)
        let fadeDistance = min(42 * longitudinalScale, travel * (42.0 / 147.0))
        return Frame(
            stem: stem, neck: neck, drop: drop,
            visibility: ramp((age - 0.4) / 0.6)
                * (1 - ramp((distance - (travel - fadeDistance)) / fadeDistance)))
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
        at time: Double, material: WSSSlimePrototype.Material,
        configuration: WSSSlimeConfiguration = .init(),
        transform: WSSImageTransform? = nil, canvas: SIMD2<Float> = WSSSlimePrototype.canvas,
        crop: SIMD2<Float> = SIMD2(repeating: 1), encoder: MTLRenderCommandEncoder
    ) {
        let anchor = WSSSlimePrototype.anchor
        let placement =
            transform
            ?? WSSImageTransform(
                center: SIMD2(anchor.x, canvas.y - anchor.y),
                size: SIMD2(repeating: WSSSlimeLayer.referenceSize))
        let drawing = WSSSlimePrototype.Placement(placement, direction: configuration.direction)
        let frame = WSSSlimePrototype.frame(
            at: time, configuration: configuration, anchorTilt: drawing.anchorTilt,
            longitudinalScale: drawing.longitudinalScale)
        let reflection = configuration.reflectionColor
        let parameters = [
            frame.neck, frame.drop, material.tintAndOpacity,
            SIMD4(frame.visibility, configuration.gloss, configuration.opacity, 0),
            SIMD4(reflection.red, reflection.green, reflection.blue, 0),
            drawing.padTransform,
        ]
        encoder.setRenderPipelineState(pipeline)
        let projection = [
            SIMD4(placement.center.x, placement.center.y, anchor.x, anchor.y),
            SIMD4(drawing.axisX.x, drawing.axisX.y, drawing.axisY.x, drawing.axisY.y),
            SIMD4(canvas.x, canvas.y, crop.x, crop.y),
        ]
        projection.withUnsafeBytes {
            encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
        }
        frame.stem.withUnsafeBytes {
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
        }
        parameters.withUnsafeBytes {
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
        }
        for var bounds in Self.drawBounds(frame: frame, drawing: drawing) {
            encoder.setVertexBytes(&bounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    static func drawBounds(
        frame: WSSSlimePrototype.Frame, drawing: WSSSlimePrototype.Placement
    ) -> [SIMD4<Float>] {
        let anchor = WSSSlimePrototype.anchor
        let padExtent = drawing.padExtent + SIMD2<Float>(repeating: 2)
        var bounds = SIMD4(
            anchor.x - padExtent.x, anchor.y - padExtent.y,
            anchor.x + padExtent.x, anchor.y + padExtent.y)
        for sample in frame.stem + [frame.neck] {
            bounds.x = min(bounds.x, sample.x - sample.z - 2)
            bounds.y = min(bounds.y, sample.y - sample.z - 2)
            bounds.z = max(bounds.z, sample.x + sample.z + 2)
            bounds.w = max(bounds.w, sample.y + sample.z + 2)
        }
        guard frame.visibility > 0 else { return [bounds] }
        let drop = frame.drop
        let dropBounds = SIMD4(
            drop.x - drop.z - 2, drop.y - drop.w - 2,
            drop.x + drop.z + 2, drop.y + drop.w + 2)
        // Separated quads omit the empty path between the pad and a distant drop.
        // Overlapping quads and the connected neck keep a single coverage evaluation.
        if frame.neck.z <= 0.001,
            bounds.z <= dropBounds.x || dropBounds.z <= bounds.x
                || bounds.w <= dropBounds.y || dropBounds.w <= bounds.y
        {
            return [bounds, dropBounds]
        }
        return [
            SIMD4(
                min(bounds.x, dropBounds.x), min(bounds.y, dropBounds.y),
                max(bounds.z, dropBounds.z), max(bounds.w, dropBounds.w))
        ]
    }

    private static let shader = """
        #include <metal_stdlib>
        using namespace metal;

        struct Raster { float4 position [[position]]; float2 p; };

        vertex Raster slimeVertex(
            uint id [[vertex_id]], constant float4 &bounds [[buffer(0)]],
            constant float4 *projection [[buffer(1)]]
        ) {
            float2 uv = float2(id & 1, id >> 1);
            float2 p = mix(bounds.xy, bounds.zw, uv);
            float2 local = p - projection[0].zw;
            float2 scene = projection[0].xy + projection[1].xy * local.x + projection[1].zw * local.y;
            float2 clip = (scene / projection[2].xy * 2 - 1) / projection[2].zw;
            return { float4(clip, 0, 1), p };
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

        float4 shadeMaterial(
            Surface surface, float4 material, float coverage, float thickness, float intensity,
            float3 reflection
        ) {
            float2 slope = surface.slope * rsqrt(max(1.0f, dot(surface.slope, surface.slope)));
            float3 normal = float3(slope, sqrt(max(0.0f, 1 - dot(slope, slope))));
            // Two broad reflections with different orientations over a tinted body.
            float diffuse = saturate(dot(normal, float3(-0.49, -0.39, 0.78)));
            float key = smoothstep(0.64f, 1.0f, dot(normal, float3(-0.42, -0.38, 0.824)));
            float fill = smoothstep(0.60f, 1.0f, dot(normal, float3(0.60, 0.35, 0.72)));
            float rim = 1 - normal.z;
            float gloss = intensity * (0.38f * key * key + 0.13f * fill) * mix(0.35f, 1.0f, thickness);
            float alpha = coverage * saturate(
                material.a * mix(0.45f, 1.0f, thickness) + 0.22f * gloss + 0.06f * rim);
            float3 body = material.rgb * mix(0.54f, 1.02f, diffuse);
            float3 color = mix(body, reflection, gloss);
            return float4(color * alpha, alpha);
        }

        fragment float4 slimeFragment(
            Raster in [[stage_in]], constant float4 *stem [[buffer(0)]],
            constant float4 *params [[buffer(1)]]
        ) {
            float2 p = in.p;
            float2 anchor = float2(240, 83);
            float2 relative = p - anchor;
            float4 pad = params[5];
            float2 padPoint = float2(dot(pad.xy, relative), dot(pad.zw, relative));
            Surface surface = ellipse(padPoint, float4(0, 0, 16, 8));
            // Transform the pad normal and convert its signed distance into drawing space.
            float2 localSlope = surface.slope;
            surface.slope = pad.xy * localSlope.x + pad.zw * localSlope.y;
            float slopeLength = length(localSlope);
            if (slopeLength > 0.0001f) {
                surface.distance *= slopeLength / max(length(surface.slope), 0.0001f);
            }
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
            return shadeMaterial(surface, material, coverage, thickness, params[3].y, params[4].rgb)
                * params[3].z;
        }
        """
}
