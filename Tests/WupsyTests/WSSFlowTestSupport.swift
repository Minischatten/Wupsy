import MetalKit
import XCTest

@testable import Wupsy

struct WSSFlowTestSupport {
    let helper = WSSFlowTests()
    struct Assets: WSSImageAssetSource {
        var field: WSSVectorFieldAsset
        var mask: UInt8 = 255
        var base: Data = WSSFlowTests().pixels()
        func image(for id: WSSAssetID) throws -> WSSImageAsset {
            WSSImageAsset(width: 128, height: 128, payload: .rgba8(base))
        }
        func mask(for id: WSSAssetID) throws -> WSSMaskAsset {
            WSSMaskAsset(width: 1, height: 1, pixels: Data([mask]))
        }
        func vectorField(for id: WSSAssetID) throws -> WSSVectorFieldAsset {
            guard id.value == "map" else { throw WSSDocumentError.missingAsset(id.value) }
            return field
        }
    }
    func field(_ v: SIMD2<Float>, coverage: UInt8 = 255) -> WSSVectorFieldAsset {
        var bytes = Data()
        for component in [v.x, v.y] {
            var word = Float16(component).bitPattern.littleEndian
            withUnsafeBytes(of: &word) { bytes.append(contentsOf: $0) }
        }
        return WSSVectorFieldAsset(
            width: 1, height: 1, vectors: bytes, coverage: Data([coverage]),
            isNeutral: v == .zero || coverage == 0)
    }
    func resources(
        _ effects: [WSSImageEffect], vector: SIMD2<Float> = SIMD2(1, 0),
        coverage: UInt8 = 255, mask: UInt8 = 255, base: Data? = nil
    ) throws -> WSSStaticResources {
        var scene = try helper.resources([]).scene
        scene.testImages[0].effects = effects
        return try WSSStaticResources(
            scene: scene,
            assets: Assets(
                field: field(vector, coverage: coverage), mask: mask,
                base: base ?? helper.pixels()), device: WSSStaticTests().device())
    }
    func render(_ r: WSSStaticResources, _ time: Double = 0.13, size: Int = 128) throws -> Data {
        try helper.render(r, time: time, size: size)
    }
}
