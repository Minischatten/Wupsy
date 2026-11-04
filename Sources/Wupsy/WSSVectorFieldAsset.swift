import Foundation
import ImageIO

// Shared native data: visible local +X right / +Y down; magnitude is retained.
// Signed zero carries no local direction. Coverage is independent, not confidence.
// The existing Flow-v1 PNG decoder below remains byte-for-byte arithmetic compatible.
struct WSSVectorFieldAsset {
    let width: Int
    let height: Int
    let vectors: Data  // interleaved signed Float16 X/Y, decoded BEFORE filtering
    let coverage: Data?  // nil = opaque; otherwise one unmodified byte per texel
    let isNeutral: Bool
    static let byteLimit = 32 * 1024 * 1024

    func validate() throws {
        guard try validatedNeutrality() == isNeutral else {
            throw WSSSceneError.invalid("flow neutral metadata")
        }
    }

    func validatedNeutrality() throws -> Bool {
        guard (1...8192).contains(width), (1...8192).contains(height),
            width * height <= Self.byteLimit / 5, vectors.count == width * height * 4,
            coverage == nil || coverage?.count == width * height
        else {
            throw WSSSceneError.invalid("flow asset dimensions/bytes")
        }
        var neutral = true
        try vectors.withUnsafeBytes { bytes in
            for i in 0..<(width * height) {
                let x = Float(
                    Float16(
                        bitPattern: UInt16(
                            littleEndian: bytes.loadUnaligned(
                                fromByteOffset: i * 4, as: UInt16.self))))
                let y = Float(
                    Float16(
                        bitPattern: UInt16(
                            littleEndian: bytes.loadUnaligned(
                                fromByteOffset: i * 4 + 2, as: UInt16.self))))
                guard x.isFinite, y.isFinite, abs(x) <= 1, abs(y) <= 1 else {
                    throw WSSSceneError.invalid("flow asset signed components")
                }
                neutral = neutral && (coverage?[i] == 0 || (x == 0 && y == 0))
            }
        }
        return neutral
    }
    static func component(_ byte: UInt8) -> Float {
        let d = Float(Int(byte) - 128)
        return d / (byte < 128 ? 128 : 127)
    }
    static func rgba(width: Int, height: Int, pixels: Data) throws -> Self {
        guard (1...8192).contains(width), (1...8192).contains(height),
            width * height <= byteLimit / 5, pixels.count == width * height * 4
        else { throw WSSSceneError.invalid("flow map dimensions/bytes") }
        var vectors = Data(count: width * height * 4)
        var coverage = Data(count: width * height)
        var opaque = true
        var neutral = true
        vectors.withUnsafeMutableBytes { output in
            let words = output.bindMemory(to: UInt16.self)
            for i in 0..<(width * height) {
                let p = i * 4
                words[i * 2] = Float16(component(pixels[p])).bitPattern.littleEndian
                words[i * 2 + 1] = Float16(component(pixels[p + 1])).bitPattern.littleEndian
                coverage[i] = pixels[p + 3]
                opaque = opaque && pixels[p + 3] == 255
                neutral =
                    neutral && (pixels[p + 3] == 0 || (pixels[p] == 128 && pixels[p + 1] == 128))
            }
        }
        guard stride(from: 2, to: pixels.count, by: 4).allSatisfy({ pixels[$0] == 0 }) else {
            throw WSSSceneError.invalid("flow map reserved blue must be zero")
        }
        return Self(
            width: width, height: height, vectors: vectors,
            coverage: opaque ? nil : coverage, isNeutral: neutral)
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= byteLimit, data.count >= 33,
            data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
            Array(data[12..<16]) == Array("IHDR".utf8), data[24] == 8,
            [2, 6].contains(data[25]), data[28] == 0,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) == 1,
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Int,
            let height = props[kCGImagePropertyPixelHeight] as? Int,
            (1...8192).contains(width), (1...8192).contains(height),
            width * height <= byteLimit / 5,
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            image.bitsPerComponent == 8,
            image.colorSpace?.model == .rgb, let raw = image.dataProvider?.data
        else {
            throw WSSSceneError.invalid("flow map requires bounded noninterlaced RGB8/RGBA8 PNG")
        }
        let bytes = raw as Data
        let channels = image.bitsPerPixel / 8
        let little = image.bitmapInfo.contains(.byteOrder32Little)
        let indices: [Int]
        let alpha: Int?
        switch (channels, image.alphaInfo) {
        case (3, .none):
            indices = [0, 1, 2]
            alpha = nil
        case (4, .last):
            indices = little ? [3, 2, 1] : [0, 1, 2]
            alpha = little ? 0 : 3
        case (4, .first):
            indices = little ? [2, 1, 0] : [1, 2, 3]
            alpha = little ? 3 : 0
        case (4, .noneSkipLast):
            indices = little ? [3, 2, 1] : [0, 1, 2]
            alpha = nil
        case (4, .noneSkipFirst):
            indices = little ? [2, 1, 0] : [1, 2, 3]
            alpha = nil
        default: throw WSSSceneError.unsupported("ambiguous/premultiplied flow data layout")
        }
        guard image.bytesPerRow >= width * channels, bytes.count >= image.bytesPerRow * height
        else {
            throw WSSSceneError.invalid("flow map stride")
        }
        var rgba = Data(count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * image.bytesPerRow + x * channels
                let q = (y * width + x) * 4
                for c in 0..<3 { rgba[q + c] = bytes[p + indices[c]] }
                rgba[q + 3] = alpha.map { bytes[p + $0] } ?? 255
            }
        }
        return try Self.rgba(width: width, height: height, pixels: rgba)
    }
}
