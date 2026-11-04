import AppKit
import SwiftUI

// Explicit boundary between system color management and the linear scene palette.
enum WSSTrailColorAdapter {
    private static let space = NSColorSpace(
        cgColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)!
    static func system(_ color: WSSTrailColor) -> NSColor {
        NSColor(
            colorSpace: space,
            components: [CGFloat(color.r), CGFloat(color.g), CGFloat(color.b), 1], count: 4)
    }
    static func linear(_ color: NSColor) -> WSSTrailColor? {
        guard let converted = color.usingColorSpace(space) else { return nil }
        let values = [converted.redComponent, converted.greenComponent, converted.blueComponent]
        guard values.allSatisfy({ $0.isFinite }) else { return nil }
        return .init(
            r: Float(min(1, max(0, values[0]))), g: Float(min(1, max(0, values[1]))),
            b: Float(min(1, max(0, values[2]))))
    }
}

enum WSSTrailAuthoringError: Error { case invalid }
enum WSSTrailParameter: CaseIterable {
    case length, lifetime, width, curveSmoothing
    var title: String {
        switch self {
        case .length: return EditorText.trailLength.text
        case .lifetime: return EditorText.trailLifetime.text
        case .width: return EditorText.trailWidth.text
        case .curveSmoothing: return EditorText.trailCurve.text
        }
    }
    var range: ClosedRange<Float> {
        switch self {
        case .length: return Float.leastNonzeroMagnitude...16384
        case .lifetime: return Float.leastNonzeroMagnitude...10
        case .width: return Float.leastNonzeroMagnitude...256
        case .curveSmoothing: return 0...0.5
        }
    }
    func slider(canvas: WSSSceneDocumentV1) -> ClosedRange<Float> {
        switch self {
        case .length:
            return 1...min(16384, hypot(Float(canvas.canvas.width), Float(canvas.canvas.height)))
        case .lifetime: return 0.1...5
        case .width: return 1...64
        case .curveSmoothing: return 0...0.5
        }
    }
    func value(_ configuration: WSSTrailConfiguration) -> Float? {
        switch self {
        case .length: return configuration.maxLength
        case .lifetime: return Float(configuration.lifetime)
        case .width: return configuration.width
        case .curveSmoothing: return configuration.curveSmoothing
        }
    }
}

extension WSSEditorDocument {
    func trailLayer(_ id: WSSLayerID) -> WSSTrailConfiguration? {
        guard let index = identity.layers.firstIndex(where: { $0.id == id }),
            case .trail(let configuration, _) = state.workingModel.layers[index].content
        else { return nil }
        return configuration
    }
    func addTrail() throws {
        guard permitsStructureEditing, finishEditing(), permitsStructureEditing else { return }
        try maintenance.withMutation {
            var model = state.workingModel
            let dimension = Float(min(model.canvas.width, model.canvas.height))
            var configuration = WSSTrailConfiguration(colors: [
                .init(r: 0, g: 0.7, b: 1), .init(r: 1, g: 0.25, b: 0),
            ])
            configuration.colorMode = .ageGradient
            configuration.maxLength = min(4096, max(1, dimension * 0.25))
            configuration.width = min(24, max(2, dimension / 180))
            model.layers.append(.init(content: .trail(configuration, visible: true)))
            do {
                _ = try model.scene()
                _ = try model.encoded()
            } catch { throw WSSTrailAuthoringError.invalid }
            var ids = identity
            let id = WSSLayerID()
            ids.layers.append(.init(id: id, effects: []))
            try mutate(model, name: EditorText.trailAdd.text, ids: ids, selected: .layer(id))
        }
    }
    func changeTrail(
        _ layer: WSSLayerID, name: String, undo: Bool = true,
        change: (inout WSSTrailConfiguration) throws -> Void
    ) throws {
        guard permitsStructureEditing,
            let index = identity.layers.firstIndex(where: { $0.id == layer }),
            case .trail(var configuration, let visible) = state.workingModel.layers[index].content
        else { return }
        if undo { endTrailInteraction() }
        try change(&configuration)
        var model = state.workingModel
        model.layers[index].content = .trail(configuration, visible: visible)
        do { _ = try model.scene() } catch { throw WSSTrailAuthoringError.invalid }
        guard model != state.workingModel else { return }
        try mutate(model, name: name, undo: undo)
    }
    func setTrail(
        _ parameter: WSSTrailParameter, value: Float, layer: WSSLayerID, undo: Bool = true
    ) throws {
        guard value.isFinite, parameter.range.contains(value) else {
            throw WSSTrailAuthoringError.invalid
        }
        if parameter == .lifetime {
            try setTrailLifetime(Double(value), layer: layer, undo: undo)
            return
        }
        try changeTrail(layer, name: parameter.title, undo: undo) { configuration in
            if parameter.value(configuration) == value { return }
            switch parameter {
            case .length: configuration.maxLength = value
            case .width: configuration.width = value
            case .curveSmoothing: configuration.curveSmoothing = value
            case .lifetime: break
            }
        }
    }
    func setTrailLifetime(_ value: Double, layer: WSSLayerID, undo: Bool = true) throws {
        guard value.isFinite, value > 0, value <= 10 else { throw WSSTrailAuthoringError.invalid }
        try changeTrail(layer, name: WSSTrailParameter.lifetime.title, undo: undo) {
            configuration in
            guard configuration.lifetime != value else { return }
            // Divide first: extreme valid legacy durations must not overflow a ratio.
            configuration.fadeIn = (configuration.fadeIn / configuration.lifetime) * value
            configuration.fadeOut = (configuration.fadeOut / configuration.lifetime) * value
            configuration.lifetime = value
        }
    }
    func convertTrailColors(_ layer: WSSLayerID) throws {
        try changeTrail(layer, name: EditorText.trailConvert.text) { configuration in
            configuration.colors = [configuration.colors.first!, configuration.colors.last!]
            configuration.colorMode = .ageGradient
        }
    }
    func setTrailColor(_ color: WSSTrailColor, index: Int, layer: WSSLayerID, undo: Bool = true)
        throws
    {
        try changeTrail(
            layer, name: index == 0 ? EditorText.trailColor1.text : EditorText.trailColor2.text,
            undo: undo
        ) { configuration in
            guard configuration.colorMode == .ageGradient, configuration.colors.count == 2,
                (0...1).contains(index)
            else { throw WSSTrailAuthoringError.invalid }
            configuration.colors[index] = color
        }
    }
    func beginTrailInteraction(_ layer: WSSLayerID, name: String) {
        endTrailInteraction()
        trailDrag = (layer, name, state.workingModel)
    }
    func endTrailInteraction() {
        guard let (_, name, original) = trailDrag else { return }
        trailDrag = nil
        if original != state.workingModel { registerModelUndo(original, name: name) }
    }
}
