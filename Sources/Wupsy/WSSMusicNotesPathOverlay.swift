import AppKit
import simd

@MainActor final class WSSMusicNotesPathOverlay: NSView {
    var path: WSSMusicNotesPath?
    var region: WSSSceneDocumentV1.Region?
    var selected: Int?
    var isEditing = false
    var metrics = WupsyMetrics()
    private var hitRadiusSquared: Double {
        let radius = Double(metrics.target(8))
        return radius * radius
    }
    var imageOrigin = CGPoint.zero
    var imageBounds = CGRect.zero
    var sceneHeight: CGFloat = 0
    var zoom: CGFloat = 1

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var staffKey: WSSMusicNotesStaff.GeometryKey?
    private var staffOrigin: SIMD2<Double>?
    private var staffPath: CGPath?
    private var staffColor: NSColor?

    var showsStaff: Bool { staffPath != nil && staffColor != nil }

    func viewport(_ point: SIMD2<Double>) -> SIMD2<Double> {
        guard let region else { return .zero }
        return viewport(regionPoint: point * SIMD2(Double(region.width), Double(region.height)))
    }

    func viewport(regionPoint: SIMD2<Double>) -> SIMD2<Double> {
        guard let region else { return .zero }
        return SIMD2(
            Double(imageOrigin.x) + Double(zoom) * (Double(region.x) + regionPoint.x),
            Double(imageOrigin.y)
                + Double(zoom) * (Double(sceneHeight) - Double(region.y) - regionPoint.y))
    }

    func updateStaff(_ layer: WSSMusicNotesLayer?, draft: WSSMusicNotesPath?) {
        guard var layer, layer.drawsStaff, let staff = layer.staff, staff.enabled, staff.opacity > 0
        else {
            staffKey = nil
            staffOrigin = nil
            staffPath = nil
            staffColor = nil
            return
        }
        staffColor = NSColor(
            srgbRed: CGFloat(staff.color.red), green: CGFloat(staff.color.green),
            blue: CGFloat(staff.color.blue), alpha: CGFloat(staff.opacity))
        let committed = layer
        if let draft { layer.path = draft }
        let key = WSSMusicNotesStaff.GeometryKey(layer: layer, staff: staff)
        guard staffKey != key else { return }
        guard let geometry = try? layer.preparedStaff() else {
            // The curve overlay can show a transient invalid draft. Hold the
            // committed staff until the draft has usable geometry again.
            updateStaff(draft == nil ? nil : committed, draft: nil)
            return
        }
        let triangles = CGMutablePath()
        for index in stride(from: 0, to: geometry.vertices.count, by: 3) {
            let a = geometry.vertices[index]
            let b = geometry.vertices[index + 1]
            let c = geometry.vertices[index + 2]
            triangles.move(to: CGPoint(x: CGFloat(a.x), y: CGFloat(a.y)))
            triangles.addLine(to: CGPoint(x: CGFloat(b.x), y: CGFloat(b.y)))
            triangles.addLine(to: CGPoint(x: CGFloat(c.x), y: CGFloat(c.y)))
            triangles.closeSubpath()
        }
        staffPath = triangles
        staffOrigin = geometry.origin
        staffKey = key
    }

    var staffViewportOrigin: CGPoint? {
        staffOrigin.map {
            let origin = viewport(regionPoint: $0)
            return CGPoint(x: origin.x, y: origin.y)
        }
    }

    private func drawStaff() {
        guard let staffPath, let staffColor, let origin = staffViewportOrigin,
            let context = NSGraphicsContext.current?.cgContext
        else { return }
        context.saveGState()
        context.clip(to: imageBounds)
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: zoom, y: -zoom)
        context.setFillColor(staffColor.cgColor)
        // Fill all consistently wound triangles together, including overlaps.
        context.addPath(staffPath)
        context.fillPath()
        context.restoreGState()
    }

    private func grips(at index: Int, path: WSSMusicNotesPath) -> [(
        WSSMusicNotesPath.Handle, SIMD2<Double>
    )] {
        let anchor = path.anchors[index]
        let center = viewport(anchor.position)
        let previous = viewport(
            path.anchors[(index + path.anchors.count - 1) % path.anchors.count].position)
        let next = viewport(path.anchors[(index + 1) % path.anchors.count].position)
        let hasIncoming = path.closed || index > 0
        let hasOutgoing = path.closed || index + 1 < path.anchors.count
        let forward =
            !hasIncoming ? next - center : !hasOutgoing ? center - previous : next - previous
        let norm = simd_length(forward)
        let axis = norm > 0.001 ? forward / norm : SIMD2(1, 0)
        func knob(_ grip: SIMD2<Double>, fallback: SIMD2<Double>) -> SIMD2<Double> {
            let delta = viewport(grip) - center
            let length = simd_length(delta)
            // Ease the collapsed handle outward without switching direction
            // abruptly when the authored grip crosses the anchor.
            return center + delta + fallback * max(0, 12 - length)
        }
        var result: [(WSSMusicNotesPath.Handle, SIMD2<Double>)] = []
        if hasIncoming { result.append((.incoming(index), knob(anchor.incoming, fallback: -axis))) }
        if hasOutgoing { result.append((.outgoing(index), knob(anchor.outgoing, fallback: axis))) }
        return result
    }

    func handle(at point: CGPoint) -> WSSMusicNotesPath.Handle? {
        guard isEditing, let path else { return nil }
        let query = SIMD2(Double(point.x), Double(point.y))
        var candidates = path.anchors.enumerated().map {
            (WSSMusicNotesPath.Handle.anchor($0.offset), viewport($0.element.position))
        }
        if let selected, path.anchors.indices.contains(selected) {
            candidates += grips(at: selected, path: path)
        }
        let nearest = candidates.min {
            simd_distance_squared($0.1, query) < simd_distance_squared($1.1, query)
        }
        guard let nearest, simd_distance_squared(nearest.1, query) <= hitRadiusSquared else {
            return nil
        }
        return nearest.0
    }

    func segment(at point: CGPoint) -> (index: Int, fraction: Double)? {
        guard let path else { return nil }
        let query = SIMD2(Double(point.x), Double(point.y))
        var closest = hitRadiusSquared
        var result: (Int, Double)?
        for index in 0..<path.segmentCount {
            let curve = path.editorSegment(index)
            // Measure in screen points so zoom and aspect ratio do not change
            // the pick radius. Project onto chords, then refine the best span.
            let steps = 48
            var best = Double.infinity
            var interval = 0
            var a = viewport(curve.start)
            for step in 0..<steps {
                let b = viewport(curve.point(at: Double(step + 1) / Double(steps)))
                let edge = b - a
                let squared = simd_length_squared(edge)
                let weight = squared > 0 ? min(1, max(0, simd_dot(query - a, edge) / squared)) : 0
                let distance = simd_distance_squared(a + edge * weight, query)
                if distance < best {
                    best = distance
                    interval = step
                }
                a = b
            }
            var lower = Double(max(0, interval - 1)) / Double(steps)
            var upper = Double(min(steps, interval + 2)) / Double(steps)
            func distance(_ t: Double) -> Double {
                simd_distance_squared(viewport(curve.point(at: t)), query)
            }
            for _ in 0..<20 {
                let third = (upper - lower) / 3
                if distance(lower + third) < distance(upper - third) {
                    upper -= third
                } else {
                    lower += third
                }
            }
            let t = (lower + upper) / 2
            let measured = distance(t)
            if measured < closest {
                closest = measured
                result = (index, t)
            }
        }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        drawStaff()
        guard let path, let first = path.anchors.first else { return }
        func point(_ value: SIMD2<Double>) -> CGPoint { CGPoint(x: value.x, y: value.y) }
        let curve = NSBezierPath()
        curve.move(to: point(viewport(first.position)))
        for index in 0..<path.segmentCount {
            let segment = path.editorSegment(index)
            curve.curve(
                to: point(viewport(segment.end)), controlPoint1: point(viewport(segment.outgoing)),
                controlPoint2: point(viewport(segment.incoming)))
        }
        if path.closed { curve.close() }
        NSColor.black.withAlphaComponent(isEditing ? 0.65 : 0.4).setStroke()
        curve.lineWidth = isEditing ? 5 : 3
        curve.stroke()
        NSColor.systemTeal.withAlphaComponent(isEditing ? 1 : 0.75).setStroke()
        curve.lineWidth = isEditing ? 2 : 1.25
        curve.stroke()
        guard isEditing else { return }

        let segment = path.editorSegment(path.direction == .forward ? 0 : path.segmentCount - 1)
        let tip = viewport(segment.point(at: 0.5))
        let delta = viewport(segment.point(at: 0.55)) - viewport(segment.point(at: 0.45))
        let length = simd_length(delta)
        if length > 0.001 {
            let heading = delta / length * (path.direction == .forward ? 1 : -1)
            let normal = SIMD2(-heading.y, heading.x)
            let arrow = NSBezierPath()
            arrow.move(to: point(tip - heading * 11 + normal * 5))
            arrow.line(to: point(tip + heading * 2))
            arrow.line(to: point(tip - heading * 11 - normal * 5))
            arrow.lineWidth = 3
            NSColor.systemTeal.setStroke()
            arrow.stroke()
        }

        if let selected, path.anchors.indices.contains(selected) {
            let center = point(viewport(path.anchors[selected].position))
            for (_, knob) in grips(at: selected, path: path) {
                let line = NSBezierPath()
                line.move(to: center)
                line.line(to: point(knob))
                NSColor.white.setStroke()
                line.stroke()
                let radius = Double(metrics.target(3))
                let rect = CGRect(
                    x: knob.x - radius, y: knob.y - radius, width: radius * 2, height: radius * 2)
                NSColor.white.setFill()
                NSBezierPath(ovalIn: rect).fill()
            }
        }
        for (index, anchor) in path.anchors.enumerated() {
            let center = viewport(anchor.position)
            let radius = Double(metrics.target(index == selected ? 6 : 4))
            let rect = CGRect(
                x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
            let start = path.direction == .forward ? 0 : path.anchors.count - 1
            let end = path.anchors.count - 1 - start
            let marker =
                !path.closed && index == start
                ? NSBezierPath(rect: rect) : NSBezierPath(ovalIn: rect)
            let color: NSColor =
                index == selected
                ? .white : !path.closed && index == end ? .systemOrange : .systemTeal
            color.setFill()
            marker.fill()
            NSColor.black.setStroke()
            marker.stroke()
        }
    }
}
