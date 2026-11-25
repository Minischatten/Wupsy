import SwiftUI

enum LibraryGridDirection: CaseIterable {
    case left, right, up, down

    init?(key: KeyEquivalent) {
        switch key {
        case .leftArrow: self = .left
        case .rightArrow: self = .right
        case .upArrow: self = .up
        case .downArrow: self = .down
        default: return nil
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .left: .leftArrow
        case .right: .rightArrow
        case .up: .upArrow
        case .down: .downArrow
        }
    }

    func destination(from index: Int?, count: Int, columns: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index, (0..<count).contains(index) else { return 0 }
        switch self {
        case .left: return index > 0 ? index - 1 : nil
        case .right: return index + 1 < count ? index + 1 : nil
        case .up: return index >= columns ? index - columns : nil
        case .down:
            guard index / columns < (count - 1) / columns else { return nil }
            return min(index + columns, count - 1)
        }
    }
}

enum LibraryGridLayout {
    static let columnSpacing: CGFloat = 8

    static func columnCount(width: CGFloat, minimum: CGFloat) -> Int {
        max(1, Int((width + columnSpacing) / (minimum + columnSpacing)))
    }
}
