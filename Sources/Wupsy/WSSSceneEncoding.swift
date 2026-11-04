import Foundation

extension WSSSceneDocumentV1 {
    // Canonical semantics, not a source-spelling or whitespace roundtrip.
    func encoded() throws -> Data {
        _ = try scene()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(self)
        let decoded = try Self.decode(data: bytes)
        _ = try decoded.assetSource(root: URL(fileURLWithPath: "/"))
        return bytes
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("wss-scene", forKey: .format)
        try c.encode(1, forKey: .version)
        try c.encode(title, forKey: .title)
        try c.encode(canvas, forKey: .canvas)
        try c.encode(background, forKey: .background)
        try c.encode(layers, forKey: .layers)
    }
    var referencedPaths: Set<String> {
        var paths = Set<String>()
        for layer in layers {
            for mask in layer.maskDefinitions { paths.insert(mask.asset) }
            guard case .image(let image) = layer.content else { continue }
            paths.insert(image.asset)
            for effect in image.effects {
                if let mask = effect.maskPath { paths.insert(mask) }
                if let field = effect.fieldDefinition { paths.insert(field.asset.value) }
                if let region = effect.flowRegionID { paths.insert(region.value) }
            }
        }
        return paths
    }
}

extension WSSSceneDocumentV1.CloudsField {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode([field.velocity.x, field.velocity.y], forKey: .velocity)
        try c.encode(field.scale, forKey: .scale)
    }
}

extension WSSSceneDocumentV1.Rain {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(effect.direction, forKey: .direction)
        try c.encode(effect.speed, forKey: .speed)
        try c.encode(effect.density, forKey: .density)
        try c.encode(effect.length, forKey: .length)
        try c.encode(effect.width, forKey: .width)
        try c.encode(Opacity(min: effect.opacity.min, max: effect.opacity.max), forKey: .opacity)
        try c.encode(effect.seed, forKey: .seed)
        try c.encodeIfPresent(effect.profiles, forKey: .profiles)
    }
}

extension WSSSceneDocumentV1.Effect.FlowMap {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(version, forKey: .version)
        try c.encode(asset.value, forKey: .asset)
    }
}

extension WSSSceneDocumentV1.Effect {
    var flowRegionID: WSSAssetID? {
        if case .flow(let flow) = native { return flow.flowRegion }
        return nil
    }
    var maskPath: String? {
        switch native {
        case .ripple(let r): return r.mask?.asset.value
        case .clouds(let c): return c.mask?.asset.value
        default: return nil
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func field(_ id: WSSAssetID, key: CodingKeys) throws {
            guard let fieldDefinition, fieldDefinition.asset == id else {
                throw WSSDocumentError.invalid("missing or inconsistent field descriptor")
            }
            try c.encode(fieldDefinition, forKey: key)
        }
        func mask() throws {
            if let definition = maskDefinition {
                guard definition.asset == maskPath else {
                    throw WSSDocumentError.invalid("inconsistent mask descriptor")
                }
                try c.encode(definition, forKey: .mask)
            } else if let path = maskPath {
                try c.encode(path, forKey: .mask)
            }
        }
        switch native {
        case .flow(let f):
            try c.encode("flow", forKey: .type)
            try field(f.flowMap, key: .flowMap)
            try c.encode(f.speed, forKey: .speed)
            try c.encode(f.strength, forKey: .strength)
            if f.edgeProtectionMode == .region {
                try c.encode(f.edgeProtectionMode, forKey: .edgeProtectionMode)
                guard let region = f.flowRegion else { throw WSSVectorFieldEditError.invalid }
                try c.encode(WSSFlowRegionDefinition(asset: region), forKey: .flowRegion)
            }
            if f.edgeProtectionPixels != 0 {
                try c.encode(f.edgeProtectionPixels, forKey: .edgeProtectionPixels)
            }
        case .ripple(let r):
            try c.encode("ripple", forKey: .type)
            try c.encode(r.amplitude, forKey: .amplitude)
            try c.encode(r.wavelength, forKey: .wavelength)
            try c.encode(r.stretch, forKey: .stretch)
            try c.encode(r.direction, forKey: .direction)
            try c.encode(r.travelSpeed, forKey: .travelSpeed)
            try c.encode(r.evolutionRate, forKey: .evolutionRate)
            try c.encode(r.seed, forKey: .seed)
            try c.encode(r.structureRotation, forKey: .structureRotation)
            try c.encode(r.lateralDetail, forKey: .lateralDetail)
            try mask()
        case .clouds(let e):
            try c.encode("clouds", forKey: .type)
            try c.encode([e.velocity.x, e.velocity.y], forKey: .velocity)
            try c.encode(e.scale, forKey: .scale)
            try c.encode(e.intensity, forKey: .intensity)
            try c.encode(e.density, forKey: .density)
            try c.encode(e.seed, forKey: .seed)
            if let secondary = e.secondaryField {
                try c.encode(
                    WSSSceneDocumentV1.CloudsField(field: secondary), forKey: .secondaryField)
            }
            try c.encode(e.secondaryInfluence, forKey: .secondaryInfluence)
            try c.encode(e.softness, forKey: .softness)
            try c.encode(e.brightness, forKey: .brightness)
            try c.encode(e.shadingAmount, forKey: .shadingAmount)
            try c.encode(e.shadingDirection, forKey: .shadingDirection)
            try mask()
        }
    }
}

extension WSSSceneDocumentV1.Layer {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch content {
        case .image(let image):
            try c.encode("image", forKey: .type)
            if let name = image.name {
                _ = try WallpaperTitle.normalized(name)
                try c.encode(name, forKey: .name)
            }
            if let definition = image.definition {
                guard image.asset == definition.asset else {
                    throw WSSDocumentError.invalid("inconsistent image descriptor")
                }
                try c.encode(definition, forKey: .image)
            } else {
                try c.encode(image.asset, forKey: .image)
            }
            try c.encode(image.transform, forKey: .transform)
            try c.encode(image.opacity, forKey: .opacity)
            try c.encode(image.visible, forKey: .visible)
            try c.encode(image.composition, forKey: .composition)
            try c.encode(image.effects, forKey: .effects)
        case .rain(let layer):
            try c.encode("rain", forKey: .type)
            try c.encode(layer.region, forKey: .region)
            try c.encode(layer.rain, forKey: .rain)
            try c.encodeIfPresent(layer.mask, forKey: .mask)
            try c.encode(layer.visible, forKey: .visible)
            try c.encode(layer.composition, forKey: .composition)
        case .trail(let configuration, let visible):
            try c.encode("cursorTrail", forKey: .type)
            try c.encode(configuration, forKey: .trail)
            try c.encode(visible, forKey: .visible)
        }
    }
}
