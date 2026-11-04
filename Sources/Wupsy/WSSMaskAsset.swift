import Foundation
import ImageIO

extension WSSMaskAsset {
    // Read decoded channel bytes directly. No CGContext, color-space conversion,
    // premultiplication or RGB image upload. Ambiguous pixel layouts fail closed.
    static func decode(
        _ data: Data, width: Int, height: Int,
        uvScale: SIMD2<Float>
    ) throws -> WSSMaskAsset {
        guard (1...8192).contains(width), (1...8192).contains(height),
            width * height <= 32 * 1024 * 1024, data.count <= 128 * 1024 * 1024,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            properties[kCGImagePropertyPixelWidth] as? Int == width,
            properties[kCGImagePropertyPixelHeight] as? Int == height,
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            image.width == width, image.height == height, image.bitsPerComponent == 8,
            let provider = image.dataProvider, let raw = provider.data
        else { throw WSSSceneError.invalid("encoded scalar mask") }
        let bytes = raw as Data
        let channels = image.bitsPerPixel / 8
        guard
            (channels == 1 && image.colorSpace?.model == .monochrome)
                || ([3, 4].contains(channels) && image.colorSpace?.model == .rgb),
            image.bytesPerRow >= width * channels
        else { throw WSSSceneError.unsupported("mask color model or stride") }
        let alpha = image.alphaInfo
        let little = image.bitmapInfo.contains(.byteOrder32Little)
        let red: Int
        let alphaIndex: Int?
        switch (channels, alpha) {
        case (1, .none):
            red = 0
            alphaIndex = nil
        case (3, .none):
            red = 0
            alphaIndex = nil
        case (4, .noneSkipLast):
            red = little ? 3 : 0
            alphaIndex = nil
        case (4, .noneSkipFirst):
            red = little ? 2 : 1
            alphaIndex = nil
        case (4, .last), (4, .premultipliedLast):
            red = little ? 3 : 0
            alphaIndex = little ? 0 : 3
        case (4, .first), (4, .premultipliedFirst):
            red = little ? 2 : 1
            alphaIndex = little ? 3 : 0
        default: throw WSSSceneError.unsupported("mask pixel layout")
        }
        guard bytes.count >= image.bytesPerRow * height else {
            throw WSSSceneError.invalid("mask row data")
        }
        var scalar = Data(count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * image.bytesPerRow + x * channels
                if let alphaIndex,
                    alpha == .premultipliedFirst || alpha == .premultipliedLast,
                    bytes[p + alphaIndex] != 255
                {
                    throw WSSSceneError.unsupported("premultiplied non-opaque scalar mask")
                }
                scalar[y * width + x] = bytes[p + red]
            }
        }
        return WSSMaskAsset(width: width, height: height, pixels: scalar, uvScale: uvScale)
    }
}
