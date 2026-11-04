import Foundation

enum WSSRainAuthoringError: Error { case capacity, smallRegion }

// Scene-layer parameters deliberately have no Image-Effect ID.
enum WSSRainParameter: Hashable, CaseIterable {
    case density, speed, slant
    case length(Int)
    case width(Int)
    static var allCases: [Self] {
        [.density, .speed, .slant] + (0..<3).flatMap { [.length($0), .width($0)] }
    }
    var title: String {
        switch self {
        case .density: return EditorText.rainAmount.text
        case .speed: return EditorText.rainSpeed.text
        case .slant: return EditorText.rainSlant.text
        case .length(let index): return EditorText.rainDropLength.format(index + 1)
        case .width(let index): return EditorText.rainDropWidth.format(index + 1)
        }
    }
    var range: ClosedRange<Float> {
        switch self {
        case .density: return 0...2000
        case .speed: return 0...6000
        case .slant: return -180...180
        case .length: return 0.25...384
        case .width: return 0.25...8
        }
    }
    var sliderRange: ClosedRange<Float> {
        switch self {
        case .density: return 0...300
        case .speed: return 0...3000
        case .slant: return -60...60
        case .length: return 1...128
        case .width: return 0.25...4
        }
    }
    func value(_ rain: WSSRainEffect) -> Float {
        switch self {
        case .density: return rain.density
        case .speed: return rain.speed
        case .slant: return rain.direction > 180 ? rain.direction - 360 : rain.direction
        case .length(let i):
            guard (0..<3).contains(i) else { return .nan }
            return rain.profiles?[i].length ?? rain.length * WSSRainPopulation.lengthScales[i]
        case .width(let i):
            guard (0..<3).contains(i) else { return .nan }
            return rain.profiles?[i].width ?? rain.width
        }
    }
    func apply(_ value: Float, to rain: inout WSSRainEffect) throws {
        guard value.isFinite, range.contains(value) else {
            throw WSSDocumentError.invalid("rain parameter")
        }
        switch self {
        case .density: rain.density = value
        case .speed: rain.speed = value
        case .slant: rain.direction = value < 0 ? value + 360 : value
        case .length(let i), .width(let i):
            guard (0..<3).contains(i) else { throw WSSDocumentError.invalid("rain parameter") }
            // Only an explicit profile edit opts a legacy layer into profile semantics.
            var profiles =
                rain.profiles
                ?? (0..<3).map {
                    WSSRainEffect.Profile(
                        length: rain.length * WSSRainPopulation.lengthScales[$0], width: rain.width)
                }
            if case .length = self { profiles[i].length = value } else { profiles[i].width = value }
            rain.profiles = profiles
        }
        try rain.validate()
    }
}

extension WSSEditorDocument {
    func rainLayer(_ id: WSSLayerID) -> WSSSceneDocumentV1.RainLayer? {
        guard let index = identity.layers.firstIndex(where: { $0.id == id }),
            state.workingModel.layers.indices.contains(index),
            case .rain(let rain) = state.workingModel.layers[index].content
        else { return nil }
        return rain
    }
    func addRain() throws {
        guard permitsStructureEditing, finishEditing(), permitsStructureEditing else { return }
        try maintenance.withMutation {
            var model = state.workingModel
            guard model.layers.count < 128 else { throw WSSImageImportError.layerLimit }
            var rain = WSSRainEffect(profiles: WSSRainEffect.authoredProfiles, density: 150)
            // Keep the general default except where rounding would produce no drops.
            let area = Double(model.canvas.width) * Double(model.canvas.height)
            if (Double(rain.density) * area / 1_000_000).rounded() == 0 {
                let minimum = Float(1_000_000 / area)
                guard minimum <= 2000 else { throw WSSRainAuthoringError.smallRegion }
                rain.density = minimum
            }
            model.layers.append(
                .init(
                    content: .rain(
                        .init(
                            region: .init(
                                x: 0, y: 0, width: Float(model.canvas.width),
                                height: Float(model.canvas.height)),
                            rain: .init(effect: rain), visible: true, composition: "sourceOver"))))
            try validateRainCandidate(model)
            _ = try model.encoded()
            var ids = identity
            let id = WSSLayerID()
            ids.layers.append(.init(id: id, effects: []))
            try mutate(model, name: EditorText.addRain.text, ids: ids, selected: .layer(id))
        }
    }
    func setRain(_ parameter: WSSRainParameter, value: Float, layer: WSSLayerID, undo: Bool = true)
        throws
    {
        guard permitsStructureEditing,
            let index = identity.layers.firstIndex(where: { $0.id == layer }),
            case .rain(var rain) = state.workingModel.layers[index].content
        else { return }
        guard parameter.value(rain.rain.effect) != value else { return }
        if undo { endRainSlider() }
        var effect = rain.rain.effect
        try parameter.apply(value, to: &effect)
        rain.rain = .init(effect: effect)
        var model = state.workingModel
        model.layers[index].content = .rain(rain)
        // Validate real padded population across all layers before installing anything.
        try validateRainCandidate(model)
        try mutate(model, name: parameter.title, undo: undo)
    }
    private func validateRainCandidate(_ model: WSSSceneDocumentV1) throws {
        do { _ = try model.scene() } catch { throw WSSRainAuthoringError.capacity }
    }
    func beginRainSlider(_ parameter: WSSRainParameter, layer: WSSLayerID) {
        endRainSlider()
        rainDrag = (layer, parameter, state.workingModel)
    }
    func endRainSlider() {
        guard let (_, parameter, original) = rainDrag else { return }
        rainDrag = nil
        if original != state.workingModel { registerModelUndo(original, name: parameter.title) }
    }
}
