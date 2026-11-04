import Foundation

enum WSSInspectionRowKind: Equatable {
    case visible
    case opacity
    case composition
    case center
    case size
    case scale
    case rotation
    case count
    case regionOrigin
    case regionSize
    case direction
    case speed
    case density
    case length
    case width
    case opacityMin
    case opacityMax
    case seed
    case colorMode
    case lifetime
    case emissionS
    case fadeIn
    case fadeOut
    case edgeSoftness
    case curveSmoothing
    case usedBy
    case asset
    case contract
    case encoding
    case dimensions
    case uvScale
    case filter
    case edge
    case mipmapped
    case fieldAsset
    case fieldFormat
    case coverage
    case amplitude
    case wavelength
    case stretch
    case travelSpeed
    case evolutionRate
    case structureRotation
    case lateralDetail
    case strength
    case flowEdgeProtection
    case primaryVelocity
    case primaryScale
    case intensity
    case secondaryInfluence
    case softness
    case brightness
    case shadingAmount
    case shadingDirection
    case secondaryVelocity
    case secondaryScale
    case secondaryField
    case color(Int)

    var title: String {
        switch self {
        case .visible: return "Visible"
        case .opacity: return "Opacity"
        case .composition: return "Composition"
        case .center: return "Center"
        case .size: return "Size"
        case .scale: return "Scale"
        case .rotation: return "Rotation"
        case .count: return "Count"
        case .regionOrigin: return "Region origin"
        case .regionSize: return "Region size"
        case .direction: return "Direction"
        case .speed: return "Speed"
        case .density: return "Density"
        case .length: return "Length"
        case .width: return "Width"
        case .opacityMin: return "Opacity min"
        case .opacityMax: return "Opacity max"
        case .seed: return "Seed"
        case .colorMode: return "Color mode"
        case .lifetime: return "Lifetime"
        case .emissionS: return "Emission / s"
        case .fadeIn: return "Fade in"
        case .fadeOut: return "Fade out"
        case .edgeSoftness: return "Edge softness"
        case .curveSmoothing: return EditorText.trailCurve.text
        case .usedBy: return "Used by"
        case .asset: return "Asset"
        case .contract: return "Contract"
        case .encoding: return "Encoding"
        case .dimensions: return "Dimensions"
        case .uvScale: return "UV scale"
        case .filter: return "Filter"
        case .edge: return "Edge"
        case .mipmapped: return "Mipmapped"
        case .fieldAsset: return "Field asset"
        case .fieldFormat: return "Field format"
        case .coverage: return "Coverage"
        case .amplitude: return "Amplitude"
        case .wavelength: return "Wavelength"
        case .stretch: return "Stretch"
        case .travelSpeed: return "Travel speed"
        case .evolutionRate: return "Evolution rate"
        case .structureRotation: return "Structure rotation"
        case .lateralDetail: return "Lateral detail"
        case .strength: return "Strength"
        case .flowEdgeProtection: return "Randberuhigung (px)"
        case .primaryVelocity: return "Primary velocity"
        case .primaryScale: return "Primary scale"
        case .intensity: return "Intensity"
        case .secondaryInfluence: return "Secondary influence"
        case .softness: return "Softness"
        case .brightness: return "Brightness"
        case .shadingAmount: return "Shading amount"
        case .shadingDirection: return "Shading direction"
        case .secondaryVelocity: return "Secondary velocity"
        case .secondaryScale: return "Secondary scale"
        case .secondaryField: return "Secondary field"
        case .color(let index): return "Color \(index) · linear RGB"
        }
    }

    var isAsset: Bool { self == .asset || self == .fieldAsset }
}

struct WSSInspectionRow {
    let kind: WSSInspectionRowKind
    var title: String
    let value: String

    init(_ kind: WSSInspectionRowKind, _ value: String) {
        self.kind = kind
        title = kind.title
        self.value = value
    }
}

struct WSSInspectionSection {
    enum Kind { case image, imageAsset, effects, rain, trail, effect, mask }
    enum Target: Equatable {
        case layer
        case effect(Int)
    }

    let kind: Kind
    var title: String
    var entries: [WSSInspectionRow]
    var target: Target = .layer
    var editableAddress: WSSEffectAddress? = nil

    // Presentation adapter for existing diagnostic consumers. Dispatch uses kinds.
    var rows: [(String, String)] { entries.map { ($0.title, $0.value) } }
    var assetPaths: [String] { entries.filter { $0.kind.isAsset }.map(\.value) }

    static func selected(
        _ sections: [Self], effectIndex: Int?
    ) -> [Self] {
        if let effectIndex { return sections.filter { $0.target == .effect(effectIndex) } }
        return sections.filter { $0.target == .layer && $0.kind != .effects }.map { section in
            var result = section
            let editable: [WSSInspectionRowKind] =
                section.kind == .image
                ? [.visible, .opacity, .center, .size, .scale, .rotation] : [.visible]
            result.entries.removeAll { editable.contains($0.kind) }
            return result
        }
    }

    static func summaries(_ sections: [Self]) -> [Self] {
        sections.filter { $0.kind != .imageAsset && $0.kind != .mask }.map { section in
            var result = section
            result.entries = []
            return result
        }
    }
}

extension WSSEditorParameter {
    var inspectionRowKind: WSSInspectionRowKind {
        switch self {
        case .rippleStretch: return .stretch
        case .rippleDirection: return .direction
        case .rippleStructureRotation: return .structureRotation
        case .rippleEvolution: return .evolutionRate
        case .rippleLateralDetail: return .lateralDetail
        case .rippleAmplitude: return .amplitude
        case .rippleWavelength: return .wavelength
        case .rippleTravelSpeed: return .travelSpeed
        case .cloudsVelocityX: return .primaryVelocity
        case .cloudsVelocityY: return .primaryVelocity
        case .cloudsBrightness: return .brightness
        case .cloudsSecondaryVelocityX: return .secondaryVelocity
        case .cloudsSecondaryVelocityY: return .secondaryVelocity
        case .cloudsIntensity: return .intensity
        case .cloudsDensity: return .density
        case .cloudsScale: return .primaryScale
        case .flowSpeed: return .speed
        case .flowStrength: return .strength
        case .flowEdgeProtection: return .flowEdgeProtection
        }
    }
}
