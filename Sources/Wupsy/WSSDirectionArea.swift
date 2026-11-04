import CoreGraphics
import Foundation

// Editor visualization only. Coverage is deliberately not used as paint history.
struct WSSDirectionArea {
    let width: Int
    let height: Int
    let image: CGImage
    let glyphSupport: WSSFlowGlyphSupport?
    static let reservedBytes = 8 * 1024 * 1024
    static func dimensions(_ field: WSSVectorFieldAsset) -> (Int, Int) {
        let scale = min(1, 512 / Double(max(field.width, field.height)))
        return (max(1, Int(Double(field.width) * scale)), max(1, Int(Double(field.height) * scale)))
    }
    static func make(
        _ field: WSSVectorFieldAsset, region: WSSFlowRegion? = nil, touches: [UInt8]? = nil,
        accent: WSSEditorOverlayAccent = .selected, flowGlyphs: Bool = false
    ) throws -> Self {
        let (width, height) = dimensions(field)
        var strengths = [Float](repeating: 0, count: width * height)
        var representatives = flowGlyphs ? [Int32](repeating: -1, count: width * height) : []
        if let region {
            try region.validate()
            region.pixels.withUnsafeBytes { (pixels: UnsafeRawBufferPointer) in
                for index in pixels.indices where pixels[index] == 255 {
                    let target =
                        (index / region.width * height / region.height) * width
                        + (index % region.width * width / region.width)
                    strengths[target] = 1
                    if flowGlyphs, representatives[target] < 0 {
                        representatives[target] = Int32(index)
                    }
                }
            }
        } else {
            field.vectors.withUnsafeBytes { raw in
                for index in 0..<(field.width * field.height) {
                    let x = Float(
                        Float16(
                            bitPattern: UInt16(
                                littleEndian: raw.loadUnaligned(
                                    fromByteOffset: index * 4, as: UInt16.self))))
                    let y = Float(
                        Float16(
                            bitPattern: UInt16(
                                littleEndian: raw.loadUnaligned(
                                    fromByteOffset: index * 4 + 2, as: UInt16.self))))
                    let target =
                        (index / field.width * height / field.height) * width
                        + (index % field.width * width / field.width)
                    let strength = min(1, hypot(x, y))
                    if flowGlyphs,
                        strength >= Float(WSSDirectionOverlayGeometry.minimumDirectionalMagnitude),
                        representatives[target] < 0 || strength > strengths[target]
                    {
                        representatives[target] = Int32(index)
                    }
                    strengths[target] = max(strengths[target], strength)
                }
            }
        }
        var rgba = Data(count: width * height * 4)
        rgba.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for index in strengths.indices {
                let persistent = strengths[index] * 0.35
                let transient = Float(touches?[index] ?? 0) / 255 * 0.25
                let alpha = 1 - (1 - persistent) * (1 - transient)
                raw[index * 4] = UInt8((alpha * accent.red * 255).rounded())
                raw[index * 4 + 1] = UInt8((alpha * accent.green * 255).rounded())
                raw[index * 4 + 2] = UInt8((alpha * accent.blue * 255).rounded())
                raw[index * 4 + 3] = UInt8((alpha * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: rgba as CFData) else {
            throw WSSVectorPaintError.budget
        }
        guard
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw WSSVectorPaintError.budget }
        let support =
            flowGlyphs
            ? WSSFlowGlyphSupport(
                width: width, height: height,
                rasterWidth: region?.width ?? field.width,
                rasterHeight: region?.height ?? field.height,
                indices: representatives) : nil
        return Self(width: width, height: height, image: image, glyphSupport: support)
    }
}
