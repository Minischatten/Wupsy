import Foundation
import simd

enum WSSCanvasGeometry {
    static func fit(scene: CGSize, viewport: CGSize) -> CGFloat {
        guard scene.width > 0, scene.height > 0 else { return 1 }
        return max(
            0.001,
            min(
                max(1, viewport.width - 24) / scene.width,
                max(1, viewport.height - 24) / scene.height))
    }
    static func scenePoint(_ point: CGPoint, origin: CGPoint, zoom: CGFloat, height: CGFloat)
        -> SIMD2<Float>
    {
        SIMD2(Float((point.x - origin.x) / zoom), Float(height - (point.y - origin.y) / zoom))
    }
    static func viewportPoint(
        _ point: SIMD2<Float>, origin: CGPoint, zoom: CGFloat, height: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: origin.x + CGFloat(point.x) * zoom, y: origin.y + (height - CGFloat(point.y)) * zoom)
    }
    static func uv(_ point: SIMD2<Float>, transform: WSSImageTransform) -> SIMD2<Float>? {
        let matrix = simd_float2x2(columns: (transform.axisX, transform.axisY))
        guard abs(simd_determinant(matrix)) > Float.leastNormalMagnitude else { return nil }
        let local = matrix.inverse * (point - transform.center)
        return SIMD2(local.x + 0.5, 0.5 - local.y)
    }
    static func texel(uv: SIMD2<Float>, scale: SIMD2<Float>, dimensions: SIMD2<Float>) -> SIMD2<
        Float
    > {
        uv * scale * dimensions - SIMD2(repeating: 0.5)
    }
    static func scenePoint(
        texel: SIMD2<Float>, scale: SIMD2<Float>, dimensions: SIMD2<Float>,
        transform: WSSImageTransform
    ) -> SIMD2<Float> {
        let uv = (texel + SIMD2(repeating: 0.5)) / (scale * dimensions)
        return transform.point(SIMD2(uv.x - 0.5, 0.5 - uv.y))
    }
}
