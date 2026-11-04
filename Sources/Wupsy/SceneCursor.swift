import Foundation

// Shared pointer transform: inverse of the renderer's centered cover crop.
// AppKit and scene coordinates both have an upward Y axis. Object origin is
// subtracted at spawn and restored at draw; W3's origin is the canvas center.
enum SceneCursor {
    static func scenePoint(global: CGPoint, screen: CGRect, canvas: CGSize) -> SIMD2<Float>? {
        guard screen.width > 0, screen.height > 0, canvas.width > 0, canvas.height > 0,
            screen.contains(global)
        else { return nil }
        let aspect = screen.width / screen.height
        let scene = canvas.width / canvas.height
        let crop =
            aspect > scene
            ? CGSize(width: 1, height: scene / aspect) : CGSize(width: aspect / scene, height: 1)
        return SIMD2(
            Float(
                canvas.width * (0.5 + ((global.x - screen.minX) / screen.width - 0.5) * crop.width)),
            Float(
                canvas.height
                    * (0.5 + ((global.y - screen.minY) / screen.height - 0.5) * crop.height)))
    }
}
