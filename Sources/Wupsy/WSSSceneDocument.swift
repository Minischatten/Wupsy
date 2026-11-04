import Foundation
import ImageIO

// Stable file DTOs, deliberately separate from the renderer's value types.
// V1 rejects unknown fields at every semantic level, including effect parameters.
enum WSSDocumentError: LocalizedError, Equatable {
    case version(Int)
    case invalid(String)
    case missingAsset(String)
    case unsafePath(String)
    case effect(String)
    var errorDescription: String? {
        switch self {
        case .version(let n):
            return "Unsupported WSS scene version: \(n). Only version 1 is supported."
        case .invalid(let s): return "Invalid WSS document: \(s)"
        case .missingAsset(let s): return "Missing or unreadable WSS asset: \(s)"
        case .unsafePath(let s): return "Unsafe WSS asset path: \(s)"
        case .effect(let s): return "Unsupported native WSS effect: \(s)"
        }
    }
}
private struct WSSDocumentKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
extension Decoder {
    func fields(_ allowed: [String]) throws {
        let c = try container(keyedBy: WSSDocumentKey.self)
        let extra = Set(c.allKeys.map(\.stringValue)).subtracting(allowed)
        for key in c.allKeys where key.stringValue != "mask" {
            if try c.decodeNil(forKey: key) {
                throw WSSDocumentError.invalid("null field: " + key.stringValue)
            }
        }
        guard extra.isEmpty else {
            throw WSSDocumentError.invalid(
                "unknown fields: " + extra.sorted().joined(separator: ", "))
        }
    }
}
// Optional explicit image contract for lossless native project materialization.
// String PNG references retain their original v1 defaults. This is data loading,
// not an imported texture container or a new rendering path.
struct WSSNativeImageDefinition: Codable, Equatable {
    let asset: String
    let encoding: String
    let width: Int
    let height: Int
    let uvScale: [Float]
    let filter: String
    let edge: String
    let mipmapped: Bool
    enum CodingKeys: String, CodingKey {
        case asset, encoding, width, height, uvScale, filter, edge, mipmapped
    }
    init(from decoder: Decoder) throws {
        try decoder.fields([
            "asset", "encoding", "width", "height", "uvScale", "filter", "edge", "mipmapped",
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asset = try c.decode(String.self, forKey: .asset)
        try WSSNativeAssets.validatePath(asset)
        encoding = try c.decode(String.self, forKey: .encoding)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        uvScale = try c.decode([Float].self, forKey: .uvScale)
        filter = try c.decode(String.self, forKey: .filter)
        edge = try c.decode(String.self, forKey: .edge)
        mipmapped = try c.decode(Bool.self, forKey: .mipmapped)
        guard ["rgba8", "image"].contains(encoding),
            (1...8192).contains(width), (1...8192).contains(height),
            width * height <= 32 * 1024 * 1024,
            uvScale.count == 2, uvScale.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1 }),
            ["linear", "nearest"].contains(filter), ["clamp", "repeat"].contains(edge)
        else { throw WSSDocumentError.invalid("native image contract") }
    }
    func load(_ assets: WSSNativeAssets) throws -> WSSImageAsset {
        let bytes = try assets.read(asset, limit: 128 * 1024 * 1024)
        let payload: WSSImageAsset.Payload
        if encoding == "rgba8" {
            guard bytes.count == width * height * 4 else {
                throw WSSDocumentError.invalid("RGBA8 image length")
            }
            payload = .rgba8(bytes)
        } else {
            guard
                bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
                    || bytes.starts(with: [255, 216, 255]),
                let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                CGImageSourceGetCount(source) == 1,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                properties[kCGImagePropertyPixelWidth] as? Int == width,
                properties[kCGImagePropertyPixelHeight] as? Int == height
            else { throw WSSDocumentError.invalid("native encoded image contract") }
            payload = .encoded(bytes)
        }
        return WSSImageAsset(
            width: width, height: height, payload: payload,
            uvScale: SIMD2(uvScale[0], uvScale[1]), filter: filter == "linear" ? .linear : .nearest,
            edge: edge == "clamp" ? .clamp : .repeatImage, mipmapped: mipmapped)
    }
}

struct WSSSceneDocumentV1: Codable, Equatable {
    struct Canvas: Codable, Equatable {
        let width: Int
        let height: Int
        enum CodingKeys: String, CodingKey { case width, height }
        init(from decoder: Decoder) throws {
            try decoder.fields(["width", "height"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            width = try c.decode(Int.self, forKey: .width)
            height = try c.decode(Int.self, forKey: .height)
        }
    }
    struct Transform: Codable, Equatable {
        var center: [Float]
        var size: [Float]
        var scale: [Float]
        var rotation: Float
        enum CodingKeys: String, CodingKey { case center, size, scale, rotation }
        init(from decoder: Decoder) throws {
            try decoder.fields(["center", "size", "scale", "rotation"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            center = try c.decode([Float].self, forKey: .center)
            size = try c.decode([Float].self, forKey: .size)
            scale = try c.decodeIfPresent([Float].self, forKey: .scale) ?? [1, 1]
            rotation = try c.decodeIfPresent(Float.self, forKey: .rotation) ?? 0
        }
        func native() throws -> WSSImageTransform {
            guard
                [center, size, scale].allSatisfy({
                    $0.count == 2 && $0.allSatisfy { $0.isFinite && abs($0) <= 1_000_000 }
                }),
                size.allSatisfy({ $0 > 0 && $0 <= 8192 }),
                scale.allSatisfy({ $0 > 0 && $0 <= 100 }), rotation.isFinite,
                abs(rotation) <= 1_000_000
            else { throw WSSDocumentError.invalid("image transform") }
            return WSSImageTransform(
                center: SIMD2(center[0], center[1]), size: SIMD2(size[0], size[1]),
                scale: SIMD2(scale[0], scale[1]), rotation: rotation)
        }
    }
    struct CloudsField: Codable, Equatable {
        let field: WSSCloudsField
        init(field: WSSCloudsField) { self.field = field }
        enum CodingKeys: String, CodingKey { case velocity, scale }
        init(from decoder: Decoder) throws {
            try decoder.fields(["velocity", "scale"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let v = try c.decode([Float].self, forKey: .velocity)
            guard v.count == 2 else { throw WSSDocumentError.invalid("clouds field velocity") }
            field = WSSCloudsField(
                velocity: SIMD2(v[0], v[1]), scale: try c.decode(Float.self, forKey: .scale))
            try field.validate()
        }
    }
    struct Effect: Codable, Equatable {
        private(set) var native: WSSImageEffect
        private(set) var maskDefinition: WSSNativeImageDefinition?
        private(set) var fieldDefinition: FlowMap?
        // Shared native parameter values are the sole scalar source; file descriptors
        // remain separate and cannot be mutated independently through this API.
        init(parameters: WSSImageEffect, mask: WSSNativeImageDefinition?, field: FlowMap?) {
            native = parameters
            maskDefinition = mask
            fieldDefinition = field
        }
        mutating func updateParameters(_ update: (inout WSSImageEffect) -> Void) throws {
            var candidate = self
            update(&candidate.native)
            let bytes = try JSONEncoder().encode(candidate)
            let validated = try JSONDecoder().decode(Self.self, from: bytes)
            guard validated.maskPath == maskPath, validated.fieldDefinition == fieldDefinition,
                validated.flowRegionID == flowRegionID
            else {
                throw WSSDocumentError.invalid("parameter changes cannot replace resources")
            }
            self = validated
        }
        struct FlowMap: Codable, Equatable {
            let asset: WSSAssetID
            let format: String
            let version: Int
            enum CodingKeys: String, CodingKey { case format, version, asset }
            init(from decoder: Decoder) throws {
                try decoder.fields(["format", "version", "asset"])
                let c = try decoder.container(keyedBy: CodingKeys.self)
                format = try c.decode(String.self, forKey: .format)
                version = try c.decode(Int.self, forKey: .version)
                guard ["wss-flow-rgba8", WSSVectorFieldAsset.fileFormat].contains(format),
                    version == 1
                else {
                    throw WSSDocumentError.invalid("flow map format/version")
                }
                let path = try c.decode(String.self, forKey: .asset)
                try WSSNativeAssets.validatePath(path)
                guard path.hasSuffix(format == "wss-flow-rgba8" ? ".png" : ".wssvf") else {
                    throw WSSDocumentError.invalid("vector field format/extension mismatch")
                }
                asset = WSSAssetID(value: path)
            }
        }
        enum CodingKeys: String, CodingKey {
            case flowRegion, edgeProtectionMode
            case flowMap, speed, strength, edgeProtectionPixels
            case type, velocity, scale, intensity, density, seed, mask
            case amplitude, wavelength, stretch, direction, travelSpeed, evolutionRate,
                structureRotation, lateralDetail
            case primaryField, secondaryField, secondaryInfluence, softness, brightness,
                shadingAmount,
                shadingDirection
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            if type == "flow" {
                try decoder.fields([
                    "type", "flowMap", "speed", "strength", "edgeProtectionPixels",
                    "edgeProtectionMode", "flowRegion",
                ])
                let field = try c.decode(FlowMap.self, forKey: .flowMap)
                fieldDefinition = field
                let flow = WSSFlowEffect(
                    flowMap: field.asset,
                    speed: try c.decodeIfPresent(Float.self, forKey: .speed) ?? 40,
                    strength: try c.decodeIfPresent(Float.self, forKey: .strength) ?? 12,
                    edgeProtectionPixels: try c.decodeIfPresent(
                        Float.self, forKey: .edgeProtectionPixels) ?? 0,
                    edgeProtectionMode: try c.decodeIfPresent(
                        WSSFlowEffect.EdgeProtectionMode.self, forKey: .edgeProtectionMode)
                        ?? .imageBounds,
                    flowRegion: try c.decodeIfPresent(
                        WSSFlowRegionDefinition.self, forKey: .flowRegion)?.asset)
                try flow.validate()
                native = .flow(flow)
                return
            }
            if type == "ripple" {
                try decoder.fields([
                    "type", "amplitude", "wavelength", "stretch", "direction",
                    "travelSpeed", "evolutionRate", "seed", "mask", "structureRotation",
                    "lateralDetail",
                ])
                let mask: String?
                if c.contains(.mask), try !c.decodeNil(forKey: .mask),
                    (try? c.decode(String.self, forKey: .mask)) == nil
                {
                    maskDefinition = try c.decode(WSSNativeImageDefinition.self, forKey: .mask)
                    mask = maskDefinition?.asset
                } else {
                    mask = try c.decodeIfPresent(String.self, forKey: .mask)
                }
                if let definition = maskDefinition {
                    guard definition.filter == "linear", definition.edge == "clamp",
                        !definition.mipmapped
                    else {
                        throw WSSDocumentError.invalid("mask sampling contract")
                    }
                }
                if let mask { try WSSNativeAssets.validatePath(mask) }
                let ripple = WSSRippleEffect(
                    amplitude: try c.decode(Float.self, forKey: .amplitude),
                    wavelength: try c.decode(Float.self, forKey: .wavelength),
                    stretch: try c.decode(Float.self, forKey: .stretch),
                    direction: try c.decode(Float.self, forKey: .direction),
                    travelSpeed: try c.decode(Float.self, forKey: .travelSpeed),
                    evolutionRate: try c.decode(Float.self, forKey: .evolutionRate),
                    mask: mask.map { WSSImageMask(asset: WSSAssetID(value: $0)) },
                    seed: try c.decode(UInt32.self, forKey: .seed),
                    structureRotation: try c.decodeIfPresent(Float.self, forKey: .structureRotation)
                        ?? 0,
                    lateralDetail: c.contains(.lateralDetail)
                        ? try c.decode(Float.self, forKey: .lateralDetail) : 1)
                try ripple.validate()
                native = .ripple(ripple)
                return
            }
            guard type == "clouds" else { throw WSSDocumentError.effect(type) }
            try decoder.fields([
                "type", "velocity", "scale", "intensity", "density", "seed", "mask",
                "primaryField", "secondaryField", "secondaryInfluence", "softness", "brightness",
                "shadingAmount", "shadingDirection",
            ])
            let primary: WSSCloudsField
            if c.contains(.primaryField) {
                guard !c.contains(.velocity), !c.contains(.scale) else {
                    throw WSSDocumentError.invalid("ambiguous primary field")
                }
                primary = try c.decode(CloudsField.self, forKey: .primaryField).field
            } else {
                let velocity = try c.decode([Float].self, forKey: .velocity)
                guard velocity.count == 2 else { throw WSSDocumentError.invalid("clouds velocity") }
                primary = WSSCloudsField(
                    velocity: SIMD2(velocity[0], velocity[1]),
                    scale: try c.decode(Float.self, forKey: .scale))
            }
            let mask: String?
            if c.contains(.mask), try !c.decodeNil(forKey: .mask),
                (try? c.decode(String.self, forKey: .mask)) == nil
            {
                maskDefinition = try c.decode(WSSNativeImageDefinition.self, forKey: .mask)
                mask = maskDefinition?.asset
            } else {
                mask = try c.decodeIfPresent(String.self, forKey: .mask)
            }
            if let definition = maskDefinition {
                guard definition.filter == "linear", definition.edge == "clamp",
                    !definition.mipmapped
                else {
                    throw WSSDocumentError.invalid("mask sampling contract")
                }
            }
            if let mask { try WSSNativeAssets.validatePath(mask) }
            let clouds = WSSCloudsEffect(
                velocity: primary.velocity, scale: primary.scale,
                intensity: try c.decode(Float.self, forKey: .intensity),
                density: try c.decode(Float.self, forKey: .density),
                seed: try c.decode(UInt32.self, forKey: .seed),
                mask: mask.map { WSSImageMask(asset: WSSAssetID(value: $0)) },
                secondaryField: try c.decodeIfPresent(CloudsField.self, forKey: .secondaryField)?
                    .field,
                secondaryInfluence: try c.decodeIfPresent(Float.self, forKey: .secondaryInfluence)
                    ?? 0.35,
                softness: try c.decodeIfPresent(Float.self, forKey: .softness) ?? 0,
                brightness: try c.decodeIfPresent(Float.self, forKey: .brightness) ?? 1,
                shadingAmount: try c.decodeIfPresent(Float.self, forKey: .shadingAmount) ?? 0,
                shadingDirection: try c.decodeIfPresent(Float.self, forKey: .shadingDirection) ?? 0)
            try clouds.validate()
            native = .clouds(clouds)
        }
    }
    struct Region: Codable, Equatable {
        let x: Float, y: Float, width: Float, height: Float
        init(x: Float, y: Float, width: Float, height: Float) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
        enum CodingKeys: String, CodingKey { case x, y, width, height }
        init(from decoder: Decoder) throws {
            try decoder.fields(["x", "y", "width", "height"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            x = try c.decode(Float.self, forKey: .x)
            y = try c.decode(Float.self, forKey: .y)
            width = try c.decode(Float.self, forKey: .width)
            height = try c.decode(Float.self, forKey: .height)
        }
    }
    struct Rain: Codable, Equatable {
        struct Opacity: Codable, Equatable {
            let min: Float, max: Float
            init(min: Float, max: Float) {
                self.min = min
                self.max = max
            }
            enum CodingKeys: String, CodingKey { case min, max }
            init(from decoder: Decoder) throws {
                try decoder.fields(["min", "max"])
                let c = try decoder.container(keyedBy: CodingKeys.self)
                min = try c.decode(Float.self, forKey: .min)
                max = try c.decode(Float.self, forKey: .max)
            }
        }
        let effect: WSSRainEffect
        init(effect: WSSRainEffect) { self.effect = effect }
        enum CodingKeys: String, CodingKey {
            case direction, speed, density, length, width, opacity, seed, profiles
        }
        init(from decoder: Decoder) throws {
            try decoder.fields([
                "direction", "speed", "density", "length", "width", "opacity", "seed", "profiles",
            ])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let opacity = try c.decode(Opacity.self, forKey: .opacity)
            effect = WSSRainEffect(
                profiles: try c.decodeIfPresent([WSSRainEffect.Profile].self, forKey: .profiles),
                direction: try c.decode(Float.self, forKey: .direction),
                speed: try c.decode(Float.self, forKey: .speed),
                density: try c.decode(Float.self, forKey: .density),
                length: try c.decode(Float.self, forKey: .length),
                width: try c.decode(Float.self, forKey: .width),
                opacity: .init(min: opacity.min, max: opacity.max),
                seed: try c.decode(UInt32.self, forKey: .seed))
        }
    }
    struct Image: Equatable {
        var name: String? = nil
        var asset: String
        var definition: WSSNativeImageDefinition?
        var transform: Transform
        var opacity: Float
        var visible: Bool
        var composition: String
        var effects: [Effect]
    }
    struct RainLayer: Equatable {
        var region: Region
        var rain: Rain
        var visible: Bool
        var composition: String
        var mask: WSSNativeImageDefinition? = nil
    }
    struct Layer: Codable, Equatable {
        enum Content: Equatable {
            case image(Image)
            case rain(RainLayer)
            case trail(WSSTrailConfiguration, visible: Bool)
        }
        var content: Content
        init(content: Content) { self.content = content }
        var imageDefinition: WSSNativeImageDefinition? {
            if case .image(let image) = content { return image.definition }
            return nil
        }
        var imageTransform: Transform? {
            if case .image(let image) = content { return image.transform }
            return nil
        }
        var maskDefinitions: [WSSNativeImageDefinition] {
            if case .image(let image) = content {
                return image.effects.compactMap(\.maskDefinition)
            }
            if case .rain(let rain) = content { return rain.mask.map { [$0] } ?? [] }
            return []
        }
        enum CodingKeys: String, CodingKey {
            case type, name, image, transform, opacity, visible, composition, effects, region, rain,
                trail, mask
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decodeIfPresent(String.self, forKey: .type) ?? "image"
            if type == "cursorTrail" {
                try decoder.fields(["type", "trail", "visible"])
                content = .trail(
                    try c.decode(WSSTrailConfiguration.self, forKey: .trail),
                    visible: try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true)
            } else if type == "rain" {
                try decoder.fields(["type", "region", "rain", "visible", "composition", "mask"])
                let composition =
                    try c.decodeIfPresent(String.self, forKey: .composition) ?? "sourceOver"
                guard ["sourceOver", "additive"].contains(composition) else {
                    throw WSSDocumentError.invalid("rain composition " + composition)
                }
                content = .rain(
                    RainLayer(
                        region: try c.decode(Region.self, forKey: .region),
                        rain: try c.decode(Rain.self, forKey: .rain),
                        visible: try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true,
                        composition: composition,
                        mask: try c.decodeIfPresent(WSSNativeImageDefinition.self, forKey: .mask)))
            } else if type == "image" {
                try decoder.fields([
                    "type", "name", "image", "transform", "opacity", "visible", "composition",
                    "effects",
                ])
                let name = try c.decodeIfPresent(String.self, forKey: .name)
                if let name { _ = try WallpaperTitle.normalized(name) }
                let asset: String
                let definition: WSSNativeImageDefinition?
                if let path = try? c.decode(String.self, forKey: .image) {
                    asset = path
                    definition = nil
                } else {
                    let value = try c.decode(WSSNativeImageDefinition.self, forKey: .image)
                    asset = value.asset
                    definition = value
                }
                try WSSNativeAssets.validatePath(asset)
                let composition =
                    try c.decodeIfPresent(String.self, forKey: .composition) ?? "sourceOver"
                guard ["replace", "sourceOver"].contains(composition) else {
                    throw WSSDocumentError.invalid("composition " + composition)
                }
                content = .image(
                    Image(
                        name: name, asset: asset, definition: definition,
                        transform: try c.decode(Transform.self, forKey: .transform),
                        opacity: try c.decodeIfPresent(Float.self, forKey: .opacity) ?? 1,
                        visible: try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true,
                        composition: composition,
                        effects: try c.decodeIfPresent([Effect].self, forKey: .effects) ?? []))
                _ = try makeNative()
            } else {
                throw WSSDocumentError.invalid("unknown layer type " + type)
            }
        }
        func makeNative() throws -> WSSSceneLayer {
            switch content {
            case .image(let image):
                return .image(
                    WSSImageLayer(
                        asset: WSSAssetID(value: image.asset),
                        transform: try image.transform.native(), opacity: image.opacity,
                        visible: image.visible,
                        composition: image.composition == "replace" ? .replace : .sourceOver,
                        effects: image.effects.map(\.native)))
            case .rain(let layer):
                let r = layer.region
                return .rain(
                    WSSRainLayer(
                        region: WSSRainRegion(x: r.x, y: r.y, width: r.width, height: r.height),
                        rain: layer.rain.effect, visible: layer.visible,
                        composition: layer.composition == "additive" ? .additive : .sourceOver,
                        mask: layer.mask.map { WSSImageMask(asset: WSSAssetID(value: $0.asset)) }))
            case .trail(let configuration, let visible):
                return .trail(WSSTrailLayer(configuration: configuration, visible: visible))
            }
        }
    }
    var title: String
    var canvas: Canvas
    var background: [Float]
    var layers: [Layer]
    enum CodingKeys: String, CodingKey { case format, version, title, canvas, background, layers }
    init(from decoder: Decoder) throws {
        try decoder.fields(["format", "version", "title", "canvas", "background", "layers"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .format) == "wss-scene" else {
            throw WSSDocumentError.invalid("expected format wss-scene")
        }
        let version = try c.decode(Int.self, forKey: .version)
        guard version == 1 else { throw WSSDocumentError.version(version) }
        title = try c.decode(String.self, forKey: .title)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            title.utf8.count <= 1024
        else {
            throw WSSDocumentError.invalid("title")
        }
        canvas = try c.decode(Canvas.self, forKey: .canvas)
        background = try c.decodeIfPresent([Float].self, forKey: .background) ?? [0, 0, 0]
        layers = try c.decode([Layer].self, forKey: .layers)
    }
    func scene() throws -> WSSScene {
        guard background.count == 3 else { throw WSSDocumentError.invalid("background") }
        let mapped = try layers.map { try $0.makeNative() }
        let result = WSSScene(
            width: canvas.width, height: canvas.height,
            background: SIMD3(background[0], background[1], background[2]), layers: mapped)
        try result.validate()
        return result
    }
    func assetSource(root: URL) throws -> WSSNativeAssets {
        var definitions: [WSSAssetID: WSSNativeImageDefinition] = [:]
        var implicit = Set<WSSAssetID>()
        for layer in layers {
            for definition in layer.maskDefinitions {
                let id = WSSAssetID(value: definition.asset)
                guard !implicit.contains(id), definitions[id].map({ $0 == definition }) ?? true
                else {
                    throw WSSDocumentError.invalid("conflicting native mask contracts")
                }
                definitions[id] = definition
            }
            guard case .image(let image) = layer.content else { continue }
            let imageID = WSSAssetID(value: image.asset)
            if let definition = layer.imageDefinition {
                guard !implicit.contains(imageID),
                    definitions[imageID].map({ $0 == definition }) ?? true
                else { throw WSSDocumentError.invalid("conflicting native image contracts") }
                definitions[imageID] = definition
            } else {
                guard definitions[imageID] == nil else {
                    throw WSSDocumentError.invalid("conflicting native image contracts")
                }
                implicit.insert(imageID)
            }
        }
        return WSSNativeAssets(root: root, imageDefinitions: definitions)
    }
    static func load(entry: URL, root: URL) throws -> WSSSceneDocumentV1 {
        let assets = WSSNativeAssets(root: root)
        guard
            entry.standardizedFileURL.deletingLastPathComponent().path
                == root.standardizedFileURL.path,
            entry.lastPathComponent == "scene.wss.json"
        else { throw WSSDocumentError.invalid("native scene entry") }
        let data = try assets.read("scene.wss.json", limit: 2 * 1024 * 1024)
        return try decode(data: data)
    }
    static let byteLimit = 2 * 1024 * 1024
    static func decode(data: Data) throws -> Self {
        guard data.count <= byteLimit else { throw WSSDocumentError.invalid("manifest size") }
        do {
            let result = try JSONDecoder().decode(Self.self, from: data)
            _ = try result.scene()
            return result
        } catch let e as DecodingError {
            throw WSSDocumentError.invalid(String(describing: e))
        }
    }
}

struct WSSNativeAssets: WSSImageAssetSource {
    let root: URL
    var imageDefinitions: [WSSAssetID: WSSNativeImageDefinition] = [:]
    var fileBytes: [String: Data]?
    var didRead: ((String, Data) throws -> Void)?
    var sessionAssets: [String: WSSImageGeneration] = [:]
    static func validatePath(_ path: String) throws {
        do { _ = try ManagedWallpaperStore.components(path) } catch {
            throw WSSDocumentError.unsafePath(path)
        }
        guard !path.contains(":"), !path.hasPrefix("~") else {
            throw WSSDocumentError.unsafePath(path)
        }
    }
    func read(_ path: String, limit: Int) throws -> Data {
        try Self.validatePath(path)
        if let generation = sessionAssets[path] {
            let bytes = try generation.read()
            guard bytes.count <= limit else { throw WSSDocumentError.invalid("asset size") }
            try didRead?(path, bytes)
            return bytes
        }
        if let fileBytes {
            guard let bytes = fileBytes[path] else { throw WSSDocumentError.missingAsset(path) }
            guard bytes.count <= limit else {
                throw WSSDocumentError.invalid("asset size: " + path)
            }
            try didRead?(path, bytes)
            return bytes
        }
        let directory = root.standardizedFileURL
        let file = directory.appendingPathComponent(path)
        do {
            try ManagedWallpaperStore.checkPath(directory)
            try ManagedWallpaperStore.checkPath(file)
        } catch { throw WSSDocumentError.unsafePath(path) }
        guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            info.isRegularFile == true, let size = info.fileSize
        else { throw WSSDocumentError.missingAsset(path) }
        guard size <= limit else { throw WSSDocumentError.invalid("asset size: " + path) }
        do {
            let bytes = try WSSAssetIO.read(root: directory, path: path, limit: limit)
            guard bytes.count <= limit else {
                throw WSSDocumentError.invalid("asset size: " + path)
            }
            try didRead?(path, bytes)
            return bytes
        } catch let e as WSSDocumentError { throw e } catch let e as WSSSaveError { throw e } catch
        {
            throw WSSDocumentError.missingAsset(path)
        }
    }
    func flowRegion(for id: WSSAssetID) throws -> WSSFlowRegion {
        try WSSFlowRegion.decode(read(id.value, limit: WSSFlowRegion.byteLimit + 20))
    }
    func flowMap(for id: WSSAssetID) throws -> WSSFlowMapAsset {
        if id.value.hasSuffix(".wssvf") {
            return try WSSVectorFieldAsset.decodeNative(
                read(
                    id.value,
                    limit: WSSVectorFieldAsset.byteLimit + WSSVectorFieldAsset.fileHeaderBytes))
        }
        guard id.value.hasSuffix(".png") else {
            throw WSSDocumentError.invalid("flow map requires PNG or native .wssvf")
        }
        return try WSSFlowMapAsset.decode(read(id.value, limit: 32 * 1024 * 1024))
    }
    func image(for id: WSSAssetID) throws -> WSSImageAsset {
        if let definition = imageDefinitions[id] { return try definition.load(self) }
        guard id.value.hasSuffix(".png") else {
            throw WSSDocumentError.invalid("only PNG assets supported")
        }
        let bytes = try read(id.value, limit: 128 * 1024 * 1024)
        guard bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
            let source = CGImageSourceCreateWithData(bytes as CFData, nil),
            CGImageSourceGetCount(source) == 1,
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int,
            let h = props[kCGImagePropertyPixelHeight] as? Int,
            (1...8192).contains(w), (1...8192).contains(h), w * h <= 32 * 1024 * 1024
        else { throw WSSDocumentError.invalid("PNG asset: " + id.value) }
        return WSSImageAsset(width: w, height: h, payload: .encoded(bytes), mipmapped: true)
    }
}
