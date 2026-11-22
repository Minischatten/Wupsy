import Foundation

extension WSSMusicNotesLayer {
    enum Placement: String, Codable, CaseIterable {
        case animatedPath, freeSingle, anchoredSingle
    }

    enum SingleRotationMode: String, Codable, CaseIterable {
        case none, rocking, continuous
    }

    enum SpinDirection: String, Codable, CaseIterable {
        case clockwise, counterclockwise
    }

    enum SpinAxis: String, Codable, CaseIterable {
        case imagePlane, vertical
    }

    struct SingleSymbol: Codable, Equatable {
        var symbol: WSSMusicNoteSymbol = .quarter
        var size: Float = 48
        var color = WSSFogConfiguration.Color(red: 1, green: 1, blue: 1)
        var opacity: Float = 0.85
        var rotationMode: SingleRotationMode?
        var spinPeriod: Double?
        var spinDirection: SpinDirection?
        var spinAxis: SpinAxis?

        static let spinPeriodRange: ClosedRange<Double> = 5...300
        static let defaultSpinPeriod: Double = 60
        static let defaultSpinDirection: SpinDirection = .clockwise

        func effectiveRotationMode(legacyRocking: Bool) -> SingleRotationMode {
            rotationMode ?? (legacyRocking ? .rocking : .none)
        }

        func spinPhase(at time: Double) -> Float {
            guard time.isFinite else { return 0 }
            let period = spinPeriod ?? Self.defaultSpinPeriod
            let direction = spinDirection ?? Self.defaultSpinDirection
            // Reduce the clock in Double before sending the signed turn to Metal.
            let phase = time.truncatingRemainder(dividingBy: period) / period
            return Float(direction == .clockwise ? -phase : phase)
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case symbol, size, color, opacity, rotationMode, spinPeriod, spinDirection, spinAxis
        }

        init() {}

        init(from decoder: Decoder) throws {
            try decoder.fields(CodingKeys.allCases.map(\.rawValue))
            let c = try decoder.container(keyedBy: CodingKeys.self)
            symbol = try c.decode(WSSMusicNoteSymbol.self, forKey: .symbol)
            size = try c.decode(Float.self, forKey: .size)
            color = try c.decode(WSSFogConfiguration.Color.self, forKey: .color)
            opacity = try c.decode(Float.self, forKey: .opacity)
            rotationMode = try c.decodeIfPresent(SingleRotationMode.self, forKey: .rotationMode)
            spinPeriod = try c.decodeIfPresent(Double.self, forKey: .spinPeriod)
            spinDirection = try c.decodeIfPresent(SpinDirection.self, forKey: .spinDirection)
            spinAxis = try c.decodeIfPresent(SpinAxis.self, forKey: .spinAxis)
            try validate()
        }

        func validate() throws {
            guard WSSMusicNotesLayer.sizeRange.contains(size),
                [color.red, color.green, color.blue, opacity].allSatisfy({ (0...1).contains($0) }),
                Self.spinPeriodRange.contains(spinPeriod ?? Self.defaultSpinPeriod)
            else { throw WSSSceneError.invalid("musicNotes single symbol") }
        }
    }

    static let singlePositionRange: ClosedRange<Float> = -1_000_000...1_000_000
    var placementMode: Placement { placement ?? .animatedPath }
    var drawsStaff: Bool { visible && placementMode == .animatedPath }
    var usesActivePath: Bool { placementMode != .freeSingle && path?.enabled == true }
    var regionCenter: SIMD2<Float> {
        SIMD2(region.x + region.width / 2, region.y + region.height / 2)
    }
    var singleCenter: SIMD2<Float> { freePosition ?? regionCenter }

    var singleSymbol: SingleSymbol? {
        switch placementMode {
        case .animatedPath: return nil
        case .freeSingle: return freeSymbol ?? .init()
        case .anchoredSingle: return anchoredSymbol ?? .init()
        }
    }

    func rockingAmount(for single: SingleSymbol) -> Float {
        single.effectiveRotationMode(legacyRocking: notes.rotation) == .rocking
            ? Float(MotionParameter.rotationStrength.value(in: notes) / 100) : 0
    }

    var drawnSingleSize: Float {
        guard let singleSymbol else { return 0 }
        return placementMode == .freeSingle
            ? singleSymbol.size : min(singleSymbol.size, min(region.width, region.height) * 0.48)
    }

    func validatePlacement() throws {
        try freeSymbol?.validate()
        try anchoredSymbol?.validate()
        if let position = freePosition,
            !Self.singlePositionRange.contains(position.x)
                || !Self.singlePositionRange.contains(position.y)
        {
            throw WSSSceneError.invalid("musicNotes free symbol position")
        }
        if let anchorPosition, !(0...100).contains(anchorPosition) {
            throw WSSSceneError.invalid("musicNotes anchor position")
        }
    }
}
