import Foundation
import simd

// All geometry uses scene units or view points, never backing pixels.
enum WSSCanvasHit: Equatable {
    case image(WSSLayerID)
    case corner(WSSLayerID, Int)
    case rotation(WSSLayerID)
    var layer: WSSLayerID {
        switch self {
        case .image(let id), .corner(let id, _), .rotation(let id): return id
        }
    }
}
enum WSSCanvasInteractionGeometry {
    static let corners: [SIMD2<Float>] = [
        SIMD2(-0.5, -0.5), SIMD2(0.5, -0.5), SIMD2(0.5, 0.5), SIMD2(-0.5, 0.5),
    ]
    static func handles(
        transform: WSSImageTransform, origin: CGPoint, zoom: CGFloat, height: CGFloat
    )
        -> [CGPoint]
    {
        let points = corners.map {
            WSSCanvasGeometry.viewportPoint(
                transform.point($0), origin: origin, zoom: zoom, height: height)
        }
        let top = CGPoint(x: (points[2].x + points[3].x) / 2, y: (points[2].y + points[3].y) / 2)
        let center = WSSCanvasGeometry.viewportPoint(
            transform.center, origin: origin, zoom: zoom, height: height)
        let dx = top.x - center.x
        let dy = top.y - center.y
        let length = max(0.0001, hypot(dx, dy))
        return points + [CGPoint(x: top.x + dx / length * 28, y: top.y + dy / length * 28)]
    }
    static func hit(
        point: CGPoint, scene: WSSScene, identity: WSSEditorIdentity, selected: WSSLayerID?,
        origin: CGPoint, zoom: CGFloat
    ) -> WSSCanvasHit? {
        guard zoom > 0 else { return nil }
        if let selected, let index = identity.layers.firstIndex(where: { $0.id == selected }),
            scene.layers.indices.contains(index), case .image(let image) = scene.layers[index],
            image.visible
        {
            let points = handles(
                transform: image.transform, origin: origin, zoom: zoom,
                height: CGFloat(scene.height))
            // Nearest handle wins even when a very small quad makes hit zones overlap.
            if let index = points.indices.min(by: {
                hypot(points[$0].x - point.x, points[$0].y - point.y)
                    < hypot(points[$1].x - point.x, points[$1].y - point.y)
            }), hypot(points[index].x - point.x, points[index].y - point.y) <= 9 {
                return index == 4 ? .rotation(selected) : .corner(selected, index)
            }
        }
        let p = WSSCanvasGeometry.scenePoint(
            point, origin: origin, zoom: zoom, height: CGFloat(scene.height))
        for index in scene.layers.indices.reversed() {
            guard identity.layers.indices.contains(index),
                case .image(let image) = scene.layers[index], image.visible,
                let uv = WSSCanvasGeometry.uv(p, transform: image.transform),
                uv.x >= -0.00001, uv.x <= 1.00001, uv.y >= -0.00001, uv.y <= 1.00001
            else { continue }
            return .image(identity.layers[index].id)
        }
        return nil
    }
}

struct WSSCanvasGesture {
    enum Kind: Equatable {
        case move
        case scale(Int, independent: Bool)
        case rotate
    }
    let kind: Kind
    let original: WSSSceneDocumentV1.Transform
    let start: SIMD2<Float>
    private var lastAngle: Float
    private var angleDelta: Float = 0
    init(kind: Kind, transform: WSSSceneDocumentV1.Transform, start: SIMD2<Float>) {
        self.kind = kind
        original = transform
        self.start = start
        lastAngle = atan2(start.y - transform.center[1], start.x - transform.center[0])
    }
    mutating func transform(at point: SIMD2<Float>) throws -> WSSSceneDocumentV1.Transform {
        var result = original
        let native = try original.native()
        switch kind {
        case .move:
            let center = native.center + point - start
            result.center = [center.x, center.y]
        case .scale(let index, let independent):
            guard WSSCanvasInteractionGeometry.corners.indices.contains(index) else {
                return result
            }
            let corner = WSSCanvasInteractionGeometry.corners[index]
            let anchor = native.point(-corner)
            let diagonal = native.point(corner) - anchor
            let delta = native.point(corner) + point - start - anchor
            var factor: SIMD2<Float>
            if independent {
                let local = simd_float2x2(columns: (native.axisX, native.axisY)).inverse * delta
                factor = local / (corner * 2)
            } else {
                factor = SIMD2(repeating: simd_dot(delta, diagonal) / simd_dot(diagonal, diagonal))
            }
            guard factor.x.isFinite, factor.y.isFinite, factor.x > 0, factor.y > 0 else {
                throw WSSDocumentError.invalid("scale cannot cross zero")
            }
            let scale = SIMD2(original.scale[0], original.scale[1])
            // Positive scales only; both axes share one bound in proportional mode.
            if independent {
                factor = simd_clamp(
                    factor, SIMD2(repeating: Float.leastNormalMagnitude) / scale,
                    SIMD2(repeating: 100) / scale)
            } else {
                let f = max(
                    Float.leastNormalMagnitude / min(scale.x, scale.y),
                    min(factor.x, 100 / max(scale.x, scale.y)))
                factor = SIMD2(repeating: f)
            }
            let scaled = scale * factor
            result.scale = [scaled.x, scaled.y]
            let center =
                anchor + native.axisX * corner.x * factor.x + native.axisY * corner.y * factor.y
            result.center = [center.x, center.y]
        case .rotate:
            let vector = point - native.center
            guard simd_length_squared(vector) > 0.000001 else {
                result.rotation = original.rotation + angleDelta
                return result
            }
            let angle = atan2(vector.y, vector.x)
            var step = angle - lastAngle
            if step > .pi { step -= 2 * .pi }
            if step < -.pi { step += 2 * .pi }
            angleDelta += step
            lastAngle = angle
            result.rotation = original.rotation + angleDelta
        }
        _ = try result.native()
        return result
    }
}
