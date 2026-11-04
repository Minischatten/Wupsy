import Foundation
import ImageIO
import UniformTypeIdentifiers

// Session-only identity: a resource path never identifies an editable effect instance.
enum WSSMaskSlot: Equatable {
    case ripple, clouds, rain
    var supportsDirectPaint: Bool {
        true
    }
}
struct WSSMaskTarget: Equatable {
    let sessionID: UUID
    let layerID: WSSLayerID
    enum Location: Equatable {
        case imageEffect(WSSEffectID)
        case layer
    }
    let location: Location
    let slot: WSSMaskSlot
    var effectID: WSSEffectID? {
        if case .imageEffect(let id) = location { return id }
        return nil
    }
    init(sessionID: UUID, layerID: WSSLayerID, effectID: WSSEffectID? = nil, slot: WSSMaskSlot) {
        self.sessionID = sessionID
        self.layerID = layerID
        location = effectID.map(Location.imageEffect) ?? .layer
        self.slot = slot
    }
}
struct WSSResolvedMaskTarget: Equatable {
    let target: WSSMaskTarget
    let path: String
    let fingerprint: WSSContentFingerprint
    let definition: WSSNativeImageDefinition?
}
enum WSSMaskError: LocalizedError {
    case stale, unsupported, invalid, budget, transaction
    var errorDescription: String? {
        switch self {
        case .stale: return "The mask target changed. No mask changes were applied."
        case .unsupported: return "Select an effect with an existing editable scalar mask."
        case .invalid: return "The scalar mask or brush data is invalid."
        case .budget: return "The mask change exceeds the available resource budget."
        case .transaction: return "This mask stroke is no longer active."
        }
    }
}
struct WSSMaskBitmap: Equatable {
    let width: Int
    let height: Int
    let uvScale: SIMD2<Float>
    let pixels: Data
    init(width: Int, height: Int, uvScale: SIMD2<Float>, pixels: Data) throws {
        guard (1...8192).contains(width), (1...8192).contains(height),
            width * height <= 32 * 1024 * 1024, pixels.count == width * height,
            uvScale.x.isFinite, uvScale.y.isFinite,
            uvScale.x > 0, uvScale.x <= 1, uvScale.y > 0, uvScale.y <= 1
        else { throw WSSMaskError.invalid }
        self.width = width
        self.height = height
        self.uvScale = uvScale
        self.pixels = pixels
    }
    init(_ asset: WSSMaskAsset) throws {
        try self.init(
            width: asset.width, height: asset.height, uvScale: asset.uvScale, pixels: asset.pixels)
    }
    func encoded() throws -> Data {
        guard let provider = CGDataProvider(data: pixels as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw WSSMaskError.invalid }
        let output = NSMutableData()
        guard
            let encoder = CGImageDestinationCreateWithData(
                output, UTType.png.identifier as CFString, 1, nil)
        else { throw WSSMaskError.invalid }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder), output.length <= 128 * 1024 * 1024 else {
            throw WSSMaskError.budget
        }
        let bytes = output as Data
        let decoded = try WSSMaskAsset.decode(bytes, width: width, height: height, uvScale: uvScale)
        guard decoded.pixels == pixels else { throw WSSMaskError.invalid }
        return bytes
    }
    func definition(path: String) -> WSSNativeImageDefinition {
        .init(
            asset: path, encoding: "image", width: width, height: height,
            uvScale: [uvScale.x, uvScale.y], filter: "linear", edge: "clamp", mipmapped: false)
    }
}

extension WSSSceneDocumentV1.Effect {
    var editableMaskSlot: WSSMaskSlot? {
        guard maskPath != nil else { return nil }
        return scalarMaskSlot
    }
    var scalarMaskSlot: WSSMaskSlot? {
        switch native {
        case .ripple: return .ripple
        case .clouds: return .clouds
        default: return nil
        }
    }
    // Separate from updateParameters: only one supported, already existing mask slot.
    func replacingMask(
        slot: WSSMaskSlot, expected: WSSResolvedMaskTarget, definition: WSSNativeImageDefinition
    ) throws -> Self {
        guard editableMaskSlot == slot, expected.target.slot == slot, maskPath == expected.path,
            maskDefinition == expected.definition
        else { throw WSSMaskError.stale }
        return try settingMask(slot: slot, definition: definition)
    }
    // Structural mask changes are separate from parameter-only updates.
    func settingMask(slot: WSSMaskSlot, definition: WSSNativeImageDefinition?) throws -> Self {
        guard scalarMaskSlot == slot else { throw WSSMaskError.unsupported }
        var value = native
        let mask = definition.map { WSSImageMask(asset: WSSAssetID(value: $0.asset)) }
        switch value {
        case .ripple(var effect):
            effect.mask = mask
            value = .ripple(effect)
        case .clouds(var effect):
            effect.mask = mask
            value = .clouds(effect)
        default: throw WSSMaskError.unsupported
        }
        let candidate = Self(parameters: value, mask: definition, field: fieldDefinition)
        return try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(candidate))
    }
}

actor WSSMaskPreparation {
    func read(
        _ resolved: WSSResolvedMaskTarget, model: WSSSceneDocumentV1, handle: WSSProjectHandle,
        generations: [String: WSSImageGeneration], basis: WSSProjectDiskBasis
    ) throws -> WSSMaskBitmap {
        try Task.checkCancellation()
        try basis.verify(handle)
        var assets = try model.assetSource(root: handle.root)
        assets.sessionAssets = generations
        let bytes = try assets.read(resolved.path, limit: resolved.fingerprint.byteCount)
        guard WSSContentFingerprint(bytes) == resolved.fingerprint else { throw WSSMaskError.stale }
        // Decode the exact captured bytes, not another mutable disk read.
        assets.fileBytes = [resolved.path: bytes]
        assets.sessionAssets = [:]
        let bitmap = try WSSMaskBitmap(assets.mask(for: WSSAssetID(value: resolved.path)))
        try basis.verify(handle)
        return bitmap
    }
    func generation(_ bitmap: WSSMaskBitmap, remainingBudget: Int) throws -> WSSImageGeneration {
        try Self.prepareGeneration(bitmap, remainingBudget: remainingBudget)
    }
    static func prepareGeneration(_ bitmap: WSSMaskBitmap, remainingBudget: Int) throws
        -> WSSImageGeneration
    {
        try Task.checkCancellation()
        let bytes = try bitmap.encoded()
        guard bytes.count <= remainingBudget else { throw WSSMaskError.budget }
        let generation = try WSSImageGeneration(
            bytes: bytes, width: bitmap.width, height: bitmap.height)
        let decoded = try WSSMaskAsset.decode(
            generation.read(), width: bitmap.width, height: bitmap.height, uvScale: bitmap.uvScale)
        guard decoded.pixels == bitmap.pixels else { throw WSSMaskError.invalid }
        try Task.checkCancellation()
        return generation
    }
}
