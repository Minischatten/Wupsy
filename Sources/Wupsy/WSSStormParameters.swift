import Foundation

// Storage bounds and editor access share one exact Double path, including UInt32 seeds.
enum WSSStormParameter: String, CaseIterable {
    case x, y, direction, length, spread, width, glow, brightness, red, green, blue
    case branchDepth, interval, duration, flashes, flashGap, seed
    var range: ClosedRange<Double> {
        switch self {
        case .x, .y: return -1_000_000...1_000_000
        case .direction: return 0...Double(360).nextDown
        case .length: return 1...8192
        case .spread: return 0...2048
        case .width: return 0.25...32
        case .glow: return 0...128
        case .brightness: return 0...8
        case .red, .green, .blue: return 0...1
        case .branchDepth: return 0...3
        case .interval: return 0.5...3600
        case .duration: return 0.01...0.5
        case .flashes: return 1...3
        case .flashGap: return 0.02...0.5
        case .seed: return 0...Double(UInt32.max)
        }
    }
    var integral: Bool { self == .seed || self == .branchDepth || self == .flashes }
    var path: WritableKeyPath<WSSStormConfiguration, Double>? {
        switch self {
        case .x: return \.x
        case .y: return \.y
        case .direction: return \.direction
        case .length: return \.length
        case .spread: return \.spread
        case .width: return \.width
        case .glow: return \.glow
        case .brightness: return \.brightness
        case .red: return \.red
        case .green: return \.green
        case .blue: return \.blue
        case .interval: return \.interval
        case .duration: return \.duration
        case .flashGap: return \.flashGap
        default: return nil
        }
    }
    func value(_ c: WSSStormConfiguration) -> Double {
        if let path { return c[keyPath: path] }
        switch self {
        case .seed: return Double(c.seed)
        case .flashes: return Double(c.flashes)
        case .branchDepth: return Double(c.branchDepth)
        default: preconditionFailure("Missing storm parameter")
        }
    }
    func apply(_ value: Double, to c: inout WSSStormConfiguration) throws {
        guard value.isFinite, range.contains(value), !integral || value.rounded() == value else {
            throw WSSSceneError.invalid("storm parameter " + rawValue)
        }
        if let path {
            c[keyPath: path] = value
        } else {
            switch self {
            case .seed: c.seed = UInt32(value)
            case .flashes: c.flashes = Int(value)
            case .branchDepth: c.branchDepth = Int(value)
            default: break
            }
        }
        try c.validate()
    }
    var title: String { Localization.string(key: "editor.storm." + rawValue) }
}
enum WSSStormText {
    static func transformUndo(_ kind: WSSCanvasGesture.Kind) -> String {
        let key: String
        switch kind {
        case .move: key = "move"
        case .scale: key = "scale"
        case .rotate: key = "rotate"
        }
        return Localization.string(key: "editor.storm." + key)
    }
    static var transformHelp: String { Localization.string(key: "editor.storm.transformHelp") }
    static var color: String { Localization.string(key: "editor.storm.color") }
    static var title: String { Localization.string(key: "editor.storm.title") }
    static var name: String { Localization.string(key: "editor.storm.name") }
    static var rename: String { Localization.string(key: "editor.storm.rename") }
    static var help: String { Localization.string(key: "editor.storm.help") }
}
