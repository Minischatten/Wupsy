import Foundation

struct WSSEffectAddress: Equatable, Hashable {
    let layerIndex: Int
    let effectIndex: Int
}

enum WSSEditorParameter: String, CaseIterable {
    case rippleAmplitude, rippleWavelength, rippleTravelSpeed
    case rippleStretch, rippleDirection, rippleStructureRotation, rippleEvolution,
        rippleLateralDetail
    case cloudsIntensity, cloudsDensity, cloudsScale
    case cloudsVelocityX, cloudsVelocityY, cloudsBrightness, cloudsSecondaryVelocityX,
        cloudsSecondaryVelocityY
    case flowSpeed, flowStrength, flowEdgeProtection

    var isAdvancedRipple: Bool {
        switch self {
        case .rippleStretch, .rippleDirection, .rippleStructureRotation,
            .rippleEvolution, .rippleLateralDetail:
            return true
        default: return false
        }
    }
    static func rippleSeed(in model: WSSSceneDocumentV1, at address: WSSEffectAddress) -> UInt32? {
        guard model.layers.indices.contains(address.layerIndex),
            case .image(let image) = model.layers[address.layerIndex].content,
            image.effects.indices.contains(address.effectIndex),
            case .ripple(let ripple) = image.effects[address.effectIndex].native
        else { return nil }
        return ripple.seed
    }
    static func applyingRippleSeed(
        _ value: Double, to model: WSSSceneDocumentV1,
        at address: WSSEffectAddress
    ) throws -> WSSSceneDocumentV1 {
        guard let seed = UInt32(exactly: value), rippleSeed(in: model, at: address) != nil,
            case .image(var image) = model.layers[address.layerIndex].content
        else { throw WSSDocumentError.invalid("ripple seed must be an unsigned 32-bit integer") }
        try image.effects[address.effectIndex].updateParameters { effect in
            if case .ripple(var ripple) = effect {
                ripple.seed = seed
                effect = .ripple(ripple)
            }
        }
        var candidate = model
        candidate.layers[address.layerIndex].content = .image(image)
        _ = try candidate.scene()
        return candidate
    }

    var title: String { localizedTitle() }
    func localizedTitle(language: String? = nil) -> String {
        switch self {
        case .flowSpeed: return EditorText.flowSpeed.localized(language: language)
        case .flowStrength: return EditorText.flowStrength.localized(language: language)
        case .flowEdgeProtection: return EditorText.flowEdgeProtection.localized(language: language)
        case .rippleStretch: return EditorText.rippleStretch.localized(language: language)
        case .rippleDirection: return EditorText.rippleDirection.localized(language: language)
        case .rippleStructureRotation:
            return EditorText.rippleStructureRotation.localized(language: language)
        case .rippleEvolution: return EditorText.rippleEvolution.localized(language: language)
        case .rippleLateralDetail:
            return EditorText.rippleLateralDetail.localized(language: language)
        case .rippleAmplitude: return EditorText.rippleAmplitude.localized(language: language)
        case .rippleWavelength: return EditorText.rippleWavelength.localized(language: language)
        case .rippleTravelSpeed: return EditorText.rippleTravelSpeed.localized(language: language)
        case .cloudsVelocityX: return EditorText.cloudsVelocityX.localized(language: language)
        case .cloudsVelocityY: return EditorText.cloudsVelocityY.localized(language: language)
        case .cloudsBrightness: return EditorText.cloudsBrightness.localized(language: language)
        case .cloudsSecondaryVelocityX:
            return EditorText.cloudsSecondaryVelocityX.localized(language: language)
        case .cloudsSecondaryVelocityY:
            return EditorText.cloudsSecondaryVelocityY.localized(language: language)
        case .cloudsIntensity: return EditorText.cloudsIntensity.localized(language: language)
        case .cloudsDensity: return EditorText.cloudsDensity.localized(language: language)
        case .cloudsScale: return EditorText.cloudsScale.localized(language: language)
        }
    }
    var sliderRange: ClosedRange<Float> {
        switch self {
        case .flowSpeed: return 0...256
        case .flowStrength: return 0...128
        case .flowEdgeProtection: return 0...4096
        case .rippleStretch: return 0.125...8
        case .rippleDirection: return 0...Float(360).nextDown
        case .rippleStructureRotation: return 0...Float(360).nextDown
        case .rippleEvolution: return 0...8
        case .rippleLateralDetail: return 0.125...8
        case .rippleAmplitude: return 0...64
        case .rippleWavelength: return 4...1024
        case .rippleTravelSpeed: return 0...256
        case .cloudsIntensity, .cloudsDensity: return 0...1
        case .cloudsVelocityX: return -256...256
        case .cloudsVelocityY: return -256...256
        case .cloudsBrightness: return 0...2
        case .cloudsSecondaryVelocityX: return -256...256
        case .cloudsSecondaryVelocityY: return -256...256
        case .cloudsScale: return 1...2048
        }
    }
    var validRange: ClosedRange<Float> {
        switch self {
        case .flowSpeed: return 0...1024
        case .flowStrength: return 0...128
        case .flowEdgeProtection: return 0...4096
        case .rippleStretch: return 0.125...8
        case .rippleDirection: return 0...Float(360).nextDown
        case .rippleStructureRotation: return 0...Float(360).nextDown
        case .rippleEvolution: return 0...8
        case .rippleLateralDetail: return 0.125...8
        case .rippleAmplitude: return 0...256
        case .rippleWavelength: return 4...8192
        case .rippleTravelSpeed: return 0...4096
        case .cloudsIntensity, .cloudsDensity: return 0...1
        case .cloudsVelocityX: return -4096...4096
        case .cloudsVelocityY: return -4096...4096
        case .cloudsBrightness: return 0...2
        case .cloudsSecondaryVelocityX: return -4096...4096
        case .cloudsSecondaryVelocityY: return -4096...4096
        case .cloudsScale: return 1...8192
        }
    }
    func sliderRange(in model: WSSSceneDocumentV1, at address: WSSEffectAddress) -> ClosedRange<
        Float
    > {
        guard self == .flowEdgeProtection,
            model.layers.indices.contains(address.layerIndex),
            case .image(let image) = model.layers[address.layerIndex].content
        else { return sliderRange }
        return 0...max(0, min(image.transform.size[0], image.transform.size[1]) / 2 - 0.5)
    }
    func value(in model: WSSSceneDocumentV1, at address: WSSEffectAddress) -> Float? {
        guard model.layers.indices.contains(address.layerIndex),
            case .image(let image) = model.layers[address.layerIndex].content,
            image.effects.indices.contains(address.effectIndex)
        else { return nil }
        switch (self, image.effects[address.effectIndex].native) {
        case (.flowSpeed, .flow(let f)): return f.speed
        case (.flowStrength, .flow(let f)): return f.strength
        case (.flowEdgeProtection, .flow(let f)): return f.edgeProtectionPixels
        case (.rippleStretch, .ripple(let r)): return r.stretch
        case (.rippleDirection, .ripple(let r)): return r.direction
        case (.rippleStructureRotation, .ripple(let r)): return r.structureRotation
        case (.rippleEvolution, .ripple(let r)): return r.evolutionRate
        case (.rippleLateralDetail, .ripple(let r)): return r.lateralDetail
        case (.rippleAmplitude, .ripple(let r)): return r.amplitude
        case (.rippleWavelength, .ripple(let r)): return r.wavelength
        case (.rippleTravelSpeed, .ripple(let r)): return r.travelSpeed
        case (.cloudsVelocityX, .clouds(let c)): return c.velocity.x
        case (.cloudsVelocityY, .clouds(let c)): return c.velocity.y
        case (.cloudsBrightness, .clouds(let c)): return c.brightness
        case (.cloudsSecondaryVelocityX, .clouds(let c)): return c.secondaryField?.velocity.x
        case (.cloudsSecondaryVelocityY, .clouds(let c)): return c.secondaryField?.velocity.y
        case (.cloudsIntensity, .clouds(let c)): return c.intensity
        case (.cloudsDensity, .clouds(let c)): return c.density
        case (.cloudsScale, .clouds(let c)): return c.scale
        default: return nil
        }
    }
    func applying(_ value: Float, to model: WSSSceneDocumentV1, at address: WSSEffectAddress) throws
        -> WSSSceneDocumentV1
    {
        guard value.isFinite, validRange.contains(value), self.value(in: model, at: address) != nil,
            case .image(var image) = model.layers[address.layerIndex].content
        else {
            throw WSSDocumentError.invalid("unsupported parameter address or value")
        }
        try image.effects[address.effectIndex].updateParameters { effect in
            switch effect {
            case .flow(var f):
                switch self {
                case .flowSpeed: f.speed = value
                case .flowStrength: f.strength = value
                case .flowEdgeProtection: f.edgeProtectionPixels = value
                default: break
                }
                effect = .flow(f)
            case .ripple(var r):
                switch self {
                case .rippleStretch: r.stretch = value
                case .rippleDirection: r.direction = value
                case .rippleStructureRotation: r.structureRotation = value
                case .rippleEvolution: r.evolutionRate = value
                case .rippleLateralDetail: r.lateralDetail = value
                case .rippleAmplitude: r.amplitude = value
                case .rippleWavelength: r.wavelength = value
                case .rippleTravelSpeed: r.travelSpeed = value
                default: break
                }
                effect = .ripple(r)
            case .clouds(var c):
                switch self {
                case .cloudsVelocityX: c.velocity.x = value
                case .cloudsVelocityY: c.velocity.y = value
                case .cloudsBrightness: c.brightness = value
                case .cloudsSecondaryVelocityX: c.secondaryField?.velocity.x = value
                case .cloudsSecondaryVelocityY: c.secondaryField?.velocity.y = value
                case .cloudsIntensity: c.intensity = value
                case .cloudsDensity: c.density = value
                case .cloudsScale: c.scale = value
                default: break
                }
                effect = .clouds(c)
            default: break
            }
        }
        var candidate = model
        candidate.layers[address.layerIndex].content = .image(image)
        _ = try candidate.scene()
        return candidate
    }
}
