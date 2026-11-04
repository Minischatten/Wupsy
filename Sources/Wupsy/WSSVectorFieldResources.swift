import MetalKit

// Shared immutable upload for native vector-field consumers. One RG16F texture,
// optional separate R8 coverage, decode before filtering. No effect-specific math.
final class WSSVectorFieldResources {
    struct Field {
        let vectors: MTLTexture
        let coverage: MTLTexture?
        let isNeutral: Bool
    }
    let fields: [WSSAssetID: Field]
    let white: MTLTexture
    let sampler: MTLSamplerState
    var textureBytes: Int {
        fields.values.reduce(white.allocatedSize) {
            $0 + $1.vectors.allocatedSize + ($1.coverage?.allocatedSize ?? 0)
        }
    }
    init(
        ids: [WSSAssetID], device: MTLDevice,
        load: (WSSAssetID) throws -> WSSVectorFieldAsset
    ) throws {
        func upload(_ bytes: Data, width: Int, height: Int, format: MTLPixelFormat, stride: Int)
            throws -> MTLTexture
        {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            d.storageMode = .shared
            d.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: d) else {
                throw WSSSceneError.invalid("flow map allocation")
            }
            bytes.withUnsafeBytes {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: $0.baseAddress!, bytesPerRow: width * stride)
            }
            return texture
        }
        white = try upload(Data([255]), width: 1, height: 1, format: .r8Unorm, stride: 1)
        var loaded: [WSSAssetID: Field] = [:]
        var bytes = white.allocatedSize
        for id in ids where loaded[id] == nil {
            let asset = try load(id)
            try asset.validate()
            guard
                asset.vectors.count + (asset.coverage?.count ?? 0) <= WSSVectorFieldAsset.byteLimit
                    - bytes
            else {
                throw WSSSceneError.invalid("flow map aggregate budget")
            }
            let vectors = try upload(
                asset.vectors, width: asset.width, height: asset.height, format: .rg16Float,
                stride: 4)
            let coverage = try asset.coverage.map {
                try upload(
                    $0, width: asset.width, height: asset.height, format: .r8Unorm, stride: 1)
            }
            bytes += vectors.allocatedSize + (coverage?.allocatedSize ?? 0)
            guard bytes <= WSSVectorFieldAsset.byteLimit else {
                throw WSSSceneError.invalid("flow map allocated budget")
            }
            loaded[id] = Field(
                vectors: vectors, coverage: coverage, isNeutral: asset.isNeutral)
        }
        fields = loaded
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        guard let sampling = device.makeSamplerState(descriptor: s) else {
            throw WSSSceneError.invalid("flow sampler")
        }
        sampler = sampling
    }
}
