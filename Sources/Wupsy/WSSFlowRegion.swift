import Foundation

// Explicit binary geometry, independent of vector magnitude and legacy coverage.
struct WSSFlowRegion: Equatable, Sendable {
    let width: Int
    let height: Int
    var pixels: Data
    static let maximumAxis = 2048
    static let byteLimit = maximumAxis * maximumAxis
    func validate() throws {
        guard (1...Self.maximumAxis).contains(width), (1...Self.maximumAxis).contains(height),
            pixels.count == width * height,
            pixels.withUnsafeBytes({ raw in
                raw.allSatisfy { $0 == 0 || $0 == 255 }
            })
        else { throw WSSVectorFieldEditError.invalid }
    }
    static func empty(size: SIMD2<Float>) throws -> Self {
        guard size.x.isFinite, size.y.isFinite, size.x > 0, size.y > 0,
            size.x <= 8192, size.y <= 8192
        else { throw WSSVectorFieldEditError.invalid }
        // At most four local pixels/cell at the largest supported square image.
        // Small images retain approximately one cell per local pixel, without upscaling.
        let scale = min(1, Float(maximumAxis) / max(size.x, size.y))
        let width = max(1, min(Int(floor(size.x)), Int(ceil(size.x * scale))))
        let height = max(1, min(Int(floor(size.y)), Int(ceil(size.y * scale))))
        return Self(width: width, height: height, pixels: Data(count: width * height))
    }
    func encoded() throws -> Data {
        try validate()
        var bytes = Data("WSSREG1\0".utf8)
        for value in [1, width, height] {
            var word = UInt32(value).littleEndian
            withUnsafeBytes(of: &word) { bytes.append(contentsOf: $0) }
        }
        bytes.append(pixels)
        return bytes
    }
    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count >= 20, bytes.count <= byteLimit + 20,
            bytes.prefix(8) == Data("WSSREG1\0".utf8)
        else { throw WSSVectorFieldEditError.invalid }
        func word(_ offset: Int) -> Int {
            bytes.withUnsafeBytes {
                Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
        }
        guard word(8) == 1 else { throw WSSVectorFieldEditError.invalid }
        let value = Self(width: word(12), height: word(16), pixels: Data(bytes.dropFirst(20)))
        try value.validate()
        return value
    }
    func painted(
        imageSize: SIMD2<Double>, points: [SIMD2<Double>], subpaths: [Int], brush: WSSVectorBrush,
        retainedBytes: Int = 0
    ) throws -> Self {
        try validate()
        guard retainedBytes >= 0, retainedBytes <= WSSVectorFieldEditorBudget.workingDataLimit
        else { throw WSSVectorFieldEditError.budget }
        guard brush.operation != .neutralize else { return self }
        // Reuse exactly the vector painter's canonical path/stamp support on this raster.
        // Its buffers are bounded separately; vector and region passes run sequentially.
        let bytes =
            try WSSVectorFieldPaint.workingBytes(
                width: width, height: height,
                hasCoverage: false, pointCount: points.count) + pixels.count * 2 + retainedBytes
        try WSSVectorFieldEditorBudget.validateWorkingData(byteCount: bytes)
        var result = self
        try result.pixels.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            try WSSVectorFieldPaint.support(
                width: width, height: height, imageSize: imageSize, uvPoints: points,
                brush: WSSVectorBrush(
                    diameter: brush.diameter, magnitude: 0, operation: brush.operation),
                subpathStarts: subpaths
            ) { index, _, _ in
                output[index] = brush.operation == .erase ? 0 : 255
            }
        }
        return result
    }
}

struct WSSFlowRegionDefinition: Codable {
    let asset: WSSAssetID
    init(asset: WSSAssetID) { self.asset = asset }
    enum CodingKeys: String, CodingKey { case asset, format, version }
    init(from decoder: Decoder) throws {
        try decoder.fields(["asset", "format", "version"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .format) == "wss-flow-region-r8",
            try c.decode(Int.self, forKey: .version) == 1
        else { throw WSSVectorFieldEditError.invalid }
        let path = try c.decode(String.self, forKey: .asset)
        try WSSNativeAssets.validatePath(path)
        guard path.hasSuffix(".wssregion") else { throw WSSVectorFieldEditError.invalid }
        asset = WSSAssetID(value: path)
    }
    func encode(to encoder: Encoder) throws {
        try WSSNativeAssets.validatePath(asset.value)
        guard asset.value.hasSuffix(".wssregion") else { throw WSSVectorFieldEditError.invalid }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(asset.value, forKey: .asset)
        try c.encode("wss-flow-region-r8", forKey: .format)
        try c.encode(1, forKey: .version)
    }
}
