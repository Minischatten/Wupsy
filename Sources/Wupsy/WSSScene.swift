import Foundation
import simd

struct WSSAssetID: Hashable, Sendable {
    let value: String
}
struct WSSImageTransform {
    let localSize: SIMD2<Float>
    var center: SIMD2<Float>
    var axisX: SIMD2<Float>
    var axisY: SIMD2<Float>

    init(
        center: SIMD2<Float>, size: SIMD2<Float>, scale: SIMD2<Float> = SIMD2(repeating: 1),
        rotation: Float = 0
    ) {
        localSize = size
        self.center = center
        axisX = SIMD2(cos(rotation), sin(rotation)) * size.x * scale.x
        axisY = SIMD2(-sin(rotation), cos(rotation)) * size.y * scale.y
    }
    func point(_ local: SIMD2<Float>) -> SIMD2<Float> { center + axisX * local.x + axisY * local.y }
}
struct WSSImageLayer {
    enum Composition { case replace, sourceOver }
    var asset: WSSAssetID
    var transform: WSSImageTransform
    var opacity: Float = 1
    var visible = true
    var composition: Composition = .sourceOver
    var effects: [WSSImageEffect] = []
}
enum WSSSceneLayer {
    case image(WSSImageLayer)
    case rain(WSSRainLayer)
    case trail(WSSTrailLayer)
    var visible: Bool {
        switch self {
        case .image(let l): return l.visible
        case .rain(let l): return l.visible
        case .trail(let l): return l.visible
        }
    }
}
struct WSSScene {
    var width: Int
    var height: Int
    var background: SIMD3<Float> = .zero
    var layers: [WSSSceneLayer]
    var imageLayers: [WSSImageLayer] {
        layers.compactMap {
            if case .image(let l) = $0 { return l }
            return nil
        }
    }
    init(width: Int, height: Int, background: SIMD3<Float> = .zero, layers: [WSSSceneLayer]) {
        self.width = width
        self.height = height
        self.background = background
        self.layers = layers
    }
    init(width: Int, height: Int, background: SIMD3<Float> = .zero, layers: [WSSImageLayer]) {
        self.init(
            width: width, height: height, background: background,
            layers: layers.map(WSSSceneLayer.image))
    }

    var isAnimated: Bool {
        layers.contains {
            switch $0 {
            case .image(let l):
                return l.visible
                    && l.effects.contains {
                        switch $0 {
                        case .clouds: return true
                        case .flow(let e): return e.speed > 0 && e.strength > 0
                        case .ripple(let e):
                            return e.amplitude > 0 && (e.travelSpeed > 0 || e.evolutionRate > 0)
                        }
                    }
            case .trail(let l): return l.visible
            case .rain(let l):
                return l.visible && l.rain.speed > 0 && l.rain.density > 0 && l.rain.opacity.max > 0
            }
        }
    }

    func validate(allowEmpty: Bool = false) throws {
        guard (1...8192).contains(width), (1...8192).contains(height),
            width * height <= 32 * 1024 * 1024,
            ((allowEmpty ? 0 : 1)...128).contains(layers.count), (0...1).contains(background.x),
            (0...1).contains(background.y), (0...1).contains(background.z)
        else { throw WSSSceneError.invalid("canvas, background or layer count") }
        var effectPasses = 0
        for layer in imageLayers {
            effectPasses += try WSSImageEffectPlan.validateBudget(layer.effects)
            guard effectPasses <= WSSImageEffectPlan.maximumPassesPerScene else {
                throw WSSSceneError.invalid("scene effect pass budget exceeded (256)")
            }
        }
        var trailBudget = 0.0
        var rainCount = 0
        for node in layers {
            if case .trail(let trail) = node {
                try trail.configuration.validate()
                trailBudget += trail.configuration.lifetime * trail.configuration.emissionRate
                guard trailBudget <= 4096 else { throw WSSSceneError.invalid("total trail budget") }
                continue
            }
            if case .rain(let rain) = node {
                rainCount += try WSSRainPopulation(rain).instances.count
                guard rainCount <= WSSRainPopulation.budget else {
                    throw WSSSceneError.invalid("total rain instance budget exceeded (8192)")
                }
                continue
            }
            guard case .image(let layer) = node else { continue }
            for effect in layer.effects {
                switch effect {
                case .clouds(let clouds): try clouds.validate()
                case .flow(let flow): try flow.validate()
                case .ripple(let ripple): try ripple.validate()
                }
            }
            let t = layer.transform
            guard t.localSize.x.isFinite, t.localSize.y.isFinite, t.localSize.x > 0,
                t.localSize.y > 0,
                t.localSize.x <= 8192, t.localSize.y <= 8192, !layer.asset.value.isEmpty,
                (0...1).contains(layer.opacity),
                [t.center.x, t.center.y, t.axisX.x, t.axisX.y, t.axisY.x, t.axisY.y].allSatisfy({
                    $0.isFinite && abs($0) <= 1_000_000
                }),
                simd_length(t.axisX) > 0, simd_length(t.axisY) > 0
            else { throw WSSSceneError.invalid("image layer") }
        }
    }
}

enum WSSSceneError: LocalizedError, Equatable {
    case unsupported(String)
    case invalid(String)
    case decodedImageBudget
    var errorDescription: String? {
        switch self {
        case .unsupported(let detail):
            return "WSS scenes do not support: \(detail). No effects or layers were omitted."
        case .invalid(let detail): return "Invalid WSS scene: \(detail)"
        case .decodedImageBudget: return "Invalid WSS scene: decoded image budget"
        }
    }
}

// Asset IDs are independent of paths and formats. Native scenes can provide their own source.
protocol WSSImageAssetSource {
    func image(for id: WSSAssetID) throws -> WSSImageAsset
    func mask(for id: WSSAssetID) throws -> WSSMaskAsset
    func flowMap(for id: WSSAssetID) throws -> WSSFlowMapAsset
    func vectorField(for id: WSSAssetID) throws -> WSSVectorFieldAsset
    func flowRegion(for id: WSSAssetID) throws -> WSSFlowRegion
}
struct WSSImageAsset {
    enum Payload {
        case rgba8(Data)
        case encoded(Data)
    }
    enum Filter { case linear, nearest }
    enum Edge { case clamp, repeatImage }
    var width: Int
    var height: Int
    var payload: Payload  // RGBA8 input is straight alpha; encoded input is a single image.
    var uvScale = SIMD2<Float>(repeating: 1)
    var filter: Filter = .linear
    var edge: Edge = .clamp
    var mipmapped = false
}

struct WSSMaskAsset {
    var width: Int
    var height: Int
    var pixels: Data
    var uvScale = SIMD2<Float>(repeating: 1)
}
extension WSSImageAssetSource {
    func flowRegion(for id: WSSAssetID) throws -> WSSFlowRegion {
        throw WSSSceneError.unsupported("explicit flow region provider required")
    }
    // Existing providers keep their Flow-v1 entry point; future consumers share this one.
    func vectorField(for id: WSSAssetID) throws -> WSSVectorFieldAsset {
        try flowMap(for: id)
    }

    func flowMap(for id: WSSAssetID) throws -> WSSFlowMapAsset {
        throw WSSSceneError.unsupported("flow map requires an explicit data asset provider")
    }

    func mask(for id: WSSAssetID) throws -> WSSMaskAsset {
        let a = try image(for: id)
        if case .encoded(let bytes) = a.payload {
            return try WSSMaskAsset.decode(
                bytes, width: a.width, height: a.height, uvScale: a.uvScale)
        }
        guard case .rgba8(let bytes) = a.payload, a.width > 0, a.height > 0,
            a.width <= 8192, a.height <= 8192, bytes.count == a.width * a.height * 4
        else { throw WSSSceneError.unsupported("mask requires unmodified scalar/RGBA pixels") }
        return WSSMaskAsset(
            width: a.width, height: a.height,
            pixels: Data(stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] }),
            uvScale: a.uvScale)
    }
}
