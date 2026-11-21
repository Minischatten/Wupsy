import Foundation
import SwiftUI

// UI units only. Persisted frequency and the deterministic scheduler stay per minute.
extension WSSShootingStarParameter {
    private var displayScale: Double { self == .frequency ? 10 : 1 }
    var displayRange: ClosedRange<Double> {
        (range.lowerBound * displayScale)...(range.upperBound * displayScale)
    }
    func displayValue(_ configuration: WSSStarfieldShootingStars) -> Double {
        value(configuration) * displayScale
    }
    func applyDisplayValue(_ value: Double, to configuration: inout WSSStarfieldShootingStars)
        throws
    {
        guard value.isFinite, displayRange.contains(value) else {
            throw WSSSceneError.invalid("shooting star display parameter")
        }
        // Opening/confirming an unchanged field must retain arbitrary saved precision.
        guard value != displayValue(configuration) else { return }
        try apply(value / displayScale, to: &configuration)
    }
}
enum WSSShootingStarDirection: Double, CaseIterable {
    case right = 0
    case upRight = 45
    case up = 90
    case upLeft = 135
    case left = 180
    case downLeft = 225
    case down = 270
    case downRight = 315
    var key: String {
        switch self {
        case .right: return "right"
        case .upRight: return "upRight"
        case .up: return "up"
        case .upLeft: return "upLeft"
        case .left: return "left"
        case .downLeft: return "downLeft"
        case .down: return "down"
        case .downRight: return "downRight"
        }
    }
    var symbol: String {
        switch self {
        case .right: return "arrow.right"
        case .upRight: return "arrow.up.right"
        case .up: return "arrow.up"
        case .upLeft: return "arrow.up.left"
        case .left: return "arrow.left"
        case .downLeft: return "arrow.down.left"
        case .down: return "arrow.down"
        case .downRight: return "arrow.down.right"
        }
    }
    var title: String { WSSStarfieldText.text("shootingStars.direction." + key) }
    static let rows: [[Self?]] = [
        [.upLeft, .up, .upRight], [.left, nil, .right], [.downLeft, .down, .downRight],
    ]
    static func selection(for angle: Double) -> Self? {
        Self(rawValue: angle == 360 ? 0 : angle)
    }
}
struct WSSShootingStarDirectionPicker: View {
    let angle: Double
    let select: (WSSShootingStarDirection) -> Void
    var body: some View {
        WSSDirectionGrid(
            angle: angle, currentTitle: WSSStarfieldText.text("shootingStars.direction.current"),
            identifierPrefix: "wss.starfield.direction.", select: select)
    }
}

struct WSSDirectionGrid: View {
    let angle: Double?
    let currentTitle: String
    let identifierPrefix: String
    let select: (WSSShootingStarDirection) -> Void

    private var angleText: String {
        guard let angle else { return "—" }
        return angle.formatted(.number.grouping(.never).precision(.fractionLength(0...3))) + "°"
    }
    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<3) { row in
                GridRow {
                    ForEach(0..<3) { column in
                        if let direction = WSSShootingStarDirection.rows[row][column] {
                            directionButton(direction)
                        } else {
                            Image(systemName: angle == nil ? "minus" : "arrow.right")
                                .rotationEffect(.degrees(-(angle ?? 0)))
                                .wupsyControlFrame(width: 24, height: 24)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(currentTitle)
                                .accessibilityValue(angleText)
                                .help(angleText)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
    private func directionButton(_ direction: WSSShootingStarDirection) -> some View {
        let selected = angle.flatMap(WSSShootingStarDirection.selection(for:)) == direction
        let degrees = String(Int(direction.rawValue)) + "°"
        let hint = direction.title + " (" + degrees + ")"
        return Button(action: { select(direction) }) {
            Image(systemName: direction.symbol).wupsyControlFrame(width: 24, height: 24)
        }
        .buttonStyle(.bordered)
        .tint(selected ? Color.accentColor : Color.secondary)
        .accessibilityLabel(direction.title)
        .accessibilityValue(degrees)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifierPrefix + direction.key)
        .help(hint)
    }

}
