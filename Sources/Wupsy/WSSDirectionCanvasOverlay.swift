import AppKit

struct WSSDirectionArrow {
    let center: CGPoint
    let tip: CGPoint
    let opacity: CGFloat
    let magnitude: Double
}
enum WSSDirectionOverlayGeometry {
    static let minimumDirectionalMagnitude = 0.001

    // Flow uses WSSFlowGlyphSelection. This helper preserves the transport presentation.
    // Use the same relevance rule as the blue area: an explicit region is
    // authoritative; without one, only meaningful vector magnitude marks an area.
    // Raw samples remain intact for painting/queries. Coverage only affects opacity.
    static func glyphSamples(_ samples: [WSSDirectionSample], hasRegion: Bool)
        -> [WSSDirectionSample]
    {
        guard !hasRegion else { return samples }  // Sampling already applies the region gate.
        return samples.filter {
            hypot(Double($0.vector.x), Double($0.vector.y)) >= minimumDirectionalMagnitude
        }
    }

    static func arrow(
        _ sample: WSSDirectionSample, geometry: WSSDirectionCanvasGeometry,
        origin: CGPoint, zoom: CGFloat, height: CGFloat, minimumLength: CGFloat = 0
    ) -> WSSDirectionArrow {
        let scene = geometry.scene(sample.uv)
        let center = WSSCanvasGeometry.viewportPoint(
            scene, origin: origin, zoom: zoom, height: height)
        let vector = geometry.sceneVector(sample.vector)
        let visible = SIMD2(Double(vector.x), -Double(vector.y))
        let length = hypot(visible.x, visible.y)
        let magnitude = hypot(Double(sample.vector.x), Double(sample.vector.y))
        // sqrt(2) remains visibly longer than a unit vector.
        let distance = max(Double(minimumLength), 18 * magnitude)
        let delta = length > 0 ? visible * (distance / length) : .zero
        return WSSDirectionArrow(
            center: center,
            tip: CGPoint(x: center.x + delta.x, y: center.y + delta.y),
            opacity: CGFloat(0.25 + 0.7 * Double(sample.coverage)), magnitude: magnitude)
    }
    static func queries(
        visible: CGRect, origin: CGPoint, zoom: CGFloat,
        height: CGFloat, geometry: WSSDirectionCanvasGeometry
    ) -> [SIMD2<Double>] {
        guard zoom > 0, visible.width > 0, visible.height > 0 else { return [] }
        let spacing = max(50, max(visible.width, visible.height) / 62)
        var result: [SIMD2<Double>] = []
        for y in stride(
            from: floor(visible.minY / spacing) * spacing, through: visible.maxY, by: spacing)
        {
            for x in stride(
                from: floor(visible.minX / spacing) * spacing, through: visible.maxX, by: spacing)
            {
                let scene = WSSCanvasGeometry.scenePoint(
                    CGPoint(x: x, y: y), origin: origin, zoom: zoom, height: height)
                if let uv = geometry.uv(scene) { result.append(uv) }
                if result.count == WSSDirectionSampling.maximumSamples { return result }
            }
        }
        return result
    }
}

@MainActor final class WSSDirectionCanvasOverlay: NSView {
    weak var session: WSSDirectionCanvasSession?
    var sceneSize = CGSize.zero
    var imageOrigin = CGPoint.zero
    var zoom: CGFloat = 1
    var cursor: SIMD2<Float>?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let session, session.overlayVisible, let geometry = session.geometry else { return }
        session.updateQueries(
            WSSDirectionOverlayGeometry.queries(
                visible: visibleRect,
                origin: imageOrigin, zoom: zoom, height: sceneSize.height, geometry: geometry))
        let flow = session.selectionIsFlow
        if flow {
            session.updateFlowGlyphLayout(
                WSSFlowGlyphLayout(
                    visible: visibleRect, origin: imageOrigin, zoom: zoom,
                    sceneHeight: sceneSize.height, geometry: geometry))
        }
        func path(_ points: [SIMD2<Float>]) -> NSBezierPath {
            let path = NSBezierPath()
            for (index, point) in points.enumerated() {
                let p = WSSCanvasGeometry.viewportPoint(
                    point, origin: imageOrigin, zoom: zoom, height: sceneSize.height)
                if index == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            path.close()
            return path
        }
        let border = path(
            [SIMD2<Double>(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)].map(geometry.scene))
        NSColor.black.withAlphaComponent(0.8).setStroke()
        border.lineWidth = 3
        border.stroke()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        border.lineWidth = 1
        border.stroke()
        NSGraphicsContext.saveGraphicsState()
        border.addClip()
        if let area = session.area {
            let p0 = WSSCanvasGeometry.viewportPoint(
                geometry.scene(SIMD2(0, 0)), origin: imageOrigin, zoom: zoom,
                height: sceneSize.height)
            let px = WSSCanvasGeometry.viewportPoint(
                geometry.scene(SIMD2(1, 0)), origin: imageOrigin, zoom: zoom,
                height: sceneSize.height)
            let py = WSSCanvasGeometry.viewportPoint(
                geometry.scene(SIMD2(0, 1)), origin: imageOrigin, zoom: zoom,
                height: sceneSize.height)
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.transformStruct = NSAffineTransformStruct(
                m11: px.x - p0.x, m12: px.y - p0.y, m21: py.x - p0.x, m22: py.y - p0.y, tX: p0.x,
                tY: p0.y)
            transform.concat()
            NSImage(cgImage: area.image, size: NSSize(width: area.width, height: area.height)).draw(
                in: NSRect(x: 0, y: 0, width: 1, height: 1), from: .zero, operation: .sourceOver,
                fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        let glyphs =
            flow
            ? session.flowGlyphs
            : WSSDirectionOverlayGeometry.glyphSamples(
                session.samples, hasRegion: session.loaded?.region != nil)
        for sample in glyphs {
            let arrow = WSSDirectionOverlayGeometry.arrow(
                sample, geometry: geometry,
                origin: imageOrigin, zoom: zoom, height: sceneSize.height,
                minimumLength: flow ? WSSFlowGlyphSelection.minimumLength : 0)
            if arrow.magnitude < WSSDirectionOverlayGeometry.minimumDirectionalMagnitude {
                let dot = NSBezierPath(
                    ovalIn: CGRect(
                        x: arrow.center.x - 1, y: arrow.center.y - 1, width: 2, height: 2))
                NSColor.black.withAlphaComponent(arrow.opacity).setStroke()
                dot.lineWidth = 2
                dot.stroke()
                NSColor.white.withAlphaComponent(arrow.opacity).setFill()
                dot.fill()
                continue
            }
            let p = NSBezierPath()
            p.move(to: arrow.center)
            p.line(to: arrow.tip)
            let angle = atan2(arrow.tip.y - arrow.center.y, arrow.tip.x - arrow.center.x)
            let displayLength = hypot(arrow.tip.x - arrow.center.x, arrow.tip.y - arrow.center.y)
            let head =
                flow
                ? min(5, max(3, displayLength * 0.35))
                : min(5, max(2, 18 * arrow.magnitude * 0.35))
            for turn in [-0.55, 0.55] {
                p.move(to: arrow.tip)
                p.line(
                    to: CGPoint(
                        x: arrow.tip.x - cos(angle + turn) * head,
                        y: arrow.tip.y - sin(angle + turn) * head))
            }
            NSColor.black.withAlphaComponent(arrow.opacity).setStroke()
            p.lineWidth = 3
            p.stroke()
            NSColor.white.withAlphaComponent(arrow.opacity).setStroke()
            p.lineWidth = 1.2
            p.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        if session.brushEnabled, let cursor, let uv = geometry.uv(cursor) {
            let ring = path(geometry.footprint(uv, diameter: session.diameter))
            NSColor.black.setStroke()
            ring.lineWidth = 3
            ring.stroke()
            NSColor.white.setStroke()
            ring.lineWidth = 1
            ring.stroke()
        }
    }
}
