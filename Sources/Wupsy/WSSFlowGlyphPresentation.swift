import AppKit

struct WSSFlowGlyphSupport {
    let width: Int
    let height: Int
    let rasterWidth: Int
    let rasterHeight: Int
    // Actual active region pixels (or meaningful field texels for legacy regionless Flow).
    // Built as part of the existing area pass, never by scanning the field in draw().
    let indices: [Int32]
    func uv(_ index: Int32) -> SIMD2<Double> {
        SIMD2(
            (Double(Int(index) % rasterWidth) + 0.5) / Double(rasterWidth),
            (Double(Int(index) / rasterWidth) + 0.5) / Double(rasterHeight))
    }
}
struct WSSFlowGlyphLayout: Equatable {
    let visible: CGRect
    let origin: CGPoint
    let zoom: CGFloat
    let sceneHeight: CGFloat
    let geometry: WSSDirectionCanvasGeometry
    var spacing: CGFloat { max(50, max(visible.width, visible.height) / 62) }
    static func == (a: Self, b: Self) -> Bool {
        a.visible == b.visible && a.origin == b.origin && a.zoom == b.zoom
            && a.sceneHeight == b.sceneHeight
            && a.geometry.transform.center == b.geometry.transform.center
            && a.geometry.transform.axisX == b.geometry.transform.axisX
            && a.geometry.transform.axisY == b.geometry.transform.axisY
            && a.geometry.transform.localSize == b.geometry.transform.localSize
    }
}
struct WSSFlowGlyphSelectionResult {
    let samples: [WSSDirectionSample]
    let inspectedSupportCells: Int
    let fieldProbes: Int
    static let empty = Self(samples: [], inspectedSupportCells: 0, fieldProbes: 0)
}
enum WSSFlowGlyphSelection {
    static let minimumLength: CGFloat = 14
    static let probesPerCell = 4
    private struct Candidate {
        let uv: SIMD2<Double>
        let distance: CGFloat
    }
    static func samples(
        _ field: WSSVectorFieldAsset, region: WSSFlowRegion?, area: WSSDirectionArea,
        layout: WSSFlowGlyphLayout?
    ) -> [WSSDirectionSample] {
        select(field, region: region, area: area, layout: layout).samples
    }
    static func select(
        _ field: WSSVectorFieldAsset, region: WSSFlowRegion?, area: WSSDirectionArea,
        layout: WSSFlowGlyphLayout?
    ) -> WSSFlowGlyphSelectionResult {
        guard let layout, let support = area.glyphSupport,
            layout.zoom.isFinite, layout.zoom > 0,
            layout.visible.width > 0, layout.visible.height > 0,
            !layout.visible.isInfinite, !layout.visible.isNull,
            [layout.visible.minX, layout.visible.minY, layout.visible.maxX, layout.visible.maxY]
                .allSatisfy({ $0.isFinite })
        else { return .empty }
        let visible = layout.visible
        let spacing = layout.spacing
        guard
            [
                visible.minX / spacing, visible.minY / spacing,
                visible.maxX / spacing, visible.maxY / spacing,
            ].allSatisfy({ abs($0) < CGFloat(Int.max / 4) })
        else { return .empty }
        let minX = Int(floor(visible.minX / spacing))
        let minY = Int(floor(visible.minY / spacing))
        let columns = Int(ceil(visible.maxX / spacing)) - minX
        let rows = Int(ceil(visible.maxY / spacing)) - minY
        guard columns > 0, rows > 0,
            columns * rows <= WSSDirectionSampling.maximumSamples
        else { return .empty }
        var candidates = [Candidate?](repeating: nil, count: columns * rows * probesPerCell)
        func viewPoint(_ uv: SIMD2<Double>) -> CGPoint {
            WSSCanvasGeometry.viewportPoint(
                layout.geometry.scene(uv), origin: layout.origin, zoom: layout.zoom,
                height: layout.sceneHeight)
        }
        // Cull the cached support index to the visible UV bounding box. Rotation is
        // checked again in view space below; no field/region-sized decoding is done here.
        let corners = [
            CGPoint(x: visible.minX, y: visible.minY),
            CGPoint(x: visible.maxX, y: visible.minY),
            CGPoint(x: visible.minX, y: visible.maxY),
            CGPoint(x: visible.maxX, y: visible.maxY),
        ].compactMap {
            layout.geometry.unboundedUV(
                WSSCanvasGeometry.scenePoint(
                    $0, origin: layout.origin, zoom: layout.zoom, height: layout.sceneHeight))
        }
        guard corners.count == 4 else { return .empty }
        let lowX = max(
            0, Int(floor(min(1, max(0, corners.map(\.x).min()!)) * Double(support.width))))
        let lowY = max(
            0, Int(floor(min(1, max(0, corners.map(\.y).min()!)) * Double(support.height))))
        let highX = min(
            support.width - 1,
            Int(floor(max(-1, min(1, corners.map(\.x).max()!)) * Double(support.width))))
        let highY = min(
            support.height - 1,
            Int(floor(max(-1, min(1, corners.map(\.y).max()!)) * Double(support.height))))
        guard lowX <= highX, lowY <= highY else { return .empty }
        for y in lowY...highY {
            for x in lowX...highX {
                let index = support.indices[y * support.width + x]
                guard index >= 0 else { continue }
                let uv = support.uv(index)
                let point = viewPoint(uv)
                guard visible.contains(point) else { continue }
                let gridX = Int(floor(point.x / spacing))
                let gridY = Int(floor(point.y / spacing))
                let column = gridX - minX
                let row = gridY - minY
                guard (0..<columns).contains(column), (0..<rows).contains(row) else { continue }
                let localX = point.x / spacing - CGFloat(gridX)
                let localY = point.y / spacing - CGFloat(gridY)
                let quadrant = (localY >= 0.5 ? 2 : 0) + (localX >= 0.5 ? 1 : 0)
                let center = CGPoint(
                    x: (CGFloat(gridX) + 0.5) * spacing,
                    y: (CGFloat(gridY) + 0.5) * spacing)
                let distance = pow(point.x - center.x, 2) + pow(point.y - center.y, 2)
                let slot = (row * columns + column) * probesPerCell + quadrant
                if candidates[slot] == nil || distance < candidates[slot]!.distance {
                    candidates[slot] = Candidate(uv: uv, distance: distance)
                }
            }
        }
        var fieldProbes = 0
        var selected = [CGPoint?](repeating: nil, count: columns * rows)
        var result: [WSSDirectionSample] = []
        for cell in 0..<(columns * rows) {
            // At most four local field probes/cell. No global directional average:
            // one actual meaningful local sample supplies direction and coverage.
            let local = candidates[(cell * probesPerCell)..<((cell + 1) * probesPerCell)]
                .compactMap { $0 }.sorted {
                    if $0.distance != $1.distance { return $0.distance < $1.distance }
                    if $0.uv.y != $1.uv.y { return $0.uv.y < $1.uv.y }
                    return $0.uv.x < $1.uv.x
                }
            fieldProbes += local.count
            let raw = WSSDirectionSampling.samples(field, at: local.map(\.uv), region: region)
            for sample in raw
            where hypot(Double(sample.vector.x), Double(sample.vector.y))
                >= WSSDirectionOverlayGeometry.minimumDirectionalMagnitude
            {
                let point = viewPoint(sample.uv)
                let row = cell / columns
                let column = cell % columns
                var crowded = false
                for y in max(0, row - 1)...min(rows - 1, row + 1) {
                    for x in max(0, column - 1)...min(columns - 1, column + 1) {
                        if let other = selected[y * columns + x],
                            hypot(point.x - other.x, point.y - other.y) < spacing * 0.65
                        {
                            crowded = true
                        }
                    }
                }
                if !crowded {
                    selected[cell] = point
                    result.append(sample)
                    break
                }
            }
        }
        return WSSFlowGlyphSelectionResult(
            samples: result, inspectedSupportCells: (highX - lowX + 1) * (highY - lowY + 1),
            fieldProbes: fieldProbes)
    }
}
