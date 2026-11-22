import Foundation
import simd

// Session-only authoring proxy, not an image transform in the scene format.
// The fixed main-axis region includes a depth-dependent branch allowance.
enum WSSStormCanvas {
    static func heightFactor(_ c: WSSStormConfiguration) -> Double {
        1 + 0.25 * Double(c.branchDepth)
    }
    static func width(_ c: WSSStormConfiguration) -> Double {
        4 * (c.spread + 1) + 0.4 * Double(c.branchDepth) * c.length
    }
    static func transform(_ c: WSSStormConfiguration) -> WSSSceneDocumentV1.Transform {
        let h = c.length * heightFactor(c)
        let w = width(c)
        let angle = c.direction * .pi / 180
        let size = [min(w, 8192), min(h, 8192)]
        let center: [Float] = [Float(c.x + sin(angle) * h / 2), Float(c.y - cos(angle) * h / 2)]
        let dimensions: [Float] = size.map { Float($0) }
        let scale: [Float] = [Float(w / size[0]), Float(h / size[1])]
        var result = WSSSceneDocumentV1.Transform(center: center, size: dimensions)
        result.scale = scale
        result.rotation = Float(angle)
        return result
    }
    static func applying(
        _ t: WSSSceneDocumentV1.Transform, original c: WSSStormConfiguration,
        kind: WSSCanvasGesture.Kind
    ) throws -> WSSStormConfiguration {
        _ = try t.native()
        let baseline = transform(c)
        guard t != baseline else { return c }
        var result = c
        let oldH = c.length * heightFactor(c)
        switch kind {
        case .move: break
        case .rotate:
            let degrees = c.direction + Double(t.rotation - baseline.rotation) * 180 / .pi
            result.direction = (degrees.truncatingRemainder(dividingBy: 360) + 360)
                .truncatingRemainder(dividingBy: 360)
        case .scaleEdge:
            throw WSSDocumentError.invalid("Storm edge scaling")
        case .scale:
            let fx = Double(t.size[0] * t.scale[0]) / Double(baseline.size[0] * baseline.scale[0])
            let fy = Double(t.size[1] * t.scale[1]) / Double(baseline.size[1] * baseline.scale[1])
            result.length = c.length * fy
            result.spread = max(
                0, (width(c) * fx - 0.4 * Double(c.branchDepth) * result.length) / 4 - 1)
        }
        let oldAngle = c.direction * .pi / 180
        let newAngle = result.direction * .pi / 180
        let newH = result.length * heightFactor(c)
        result.x =
            c.x + Double(t.center[0] - baseline.center[0])
            + (sin(oldAngle) * oldH - sin(newAngle) * newH) / 2
        result.y =
            c.y + Double(t.center[1] - baseline.center[1])
            + (cos(newAngle) * newH - cos(oldAngle) * oldH) / 2
        try result.validate()
        return result
    }
}
extension WSSSceneDocumentV1.Layer {
    var canvasTransform: WSSSceneDocumentV1.Transform? {
        switch content {
        case .image(let image): return image.transform
        case .musicNotes(let layer): return layer.canvasTransform
        case .starfield(let layer): return layer.starfield.canvasTransform
        case .storm(let layer): return WSSStormCanvas.transform(layer.storm)
        default: return nil
        }
    }
}
extension WSSSceneLayer {
    var allowsCanvasRotation: Bool {
        switch self {
        case .starfield, .musicNotes: return false
        default: return true
        }
    }

    var canvasTransform: WSSImageTransform? {
        guard visible else { return nil }
        switch self {
        case .image(let image): return image.transform
        case .musicNotes(let layer): return try? layer.canvasTransform.native()
        case .starfield(let layer): return try? layer.starfield.canvasTransform.native()
        case .storm(let layer): return try? WSSStormCanvas.transform(layer.storm).native()
        default: return nil
        }
    }
}
