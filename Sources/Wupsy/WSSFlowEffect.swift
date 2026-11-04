import Foundation

// Independently authored bounded transport distortion, local image units, y down.
// No engine units, shader identity, phase texture or frame feedback.
struct WSSFlowEffect: Sendable, Equatable {
    var flowMap: WSSAssetID
    var speed: Float = 40
    var strength: Float = 12
    enum EdgeProtectionMode: String, Codable, Sendable { case imageBounds, region }
    var edgeProtectionPixels: Float = 0
    var edgeProtectionMode: EdgeProtectionMode = .imageBounds
    var flowRegion: WSSAssetID? = nil
    func validate() throws {
        guard (edgeProtectionMode == .region) == (flowRegion != nil),
            flowRegion.map({ !$0.value.isEmpty }) ?? true,
            !flowMap.value.isEmpty, speed.isFinite, (0...1024).contains(speed),
            strength.isFinite, (0...128).contains(strength),
            edgeProtectionPixels.isFinite, (0...4096).contains(edgeProtectionPixels)
        else { throw WSSSceneError.invalid("flow map or parameters") }
    }
    var isIdentity: Bool { speed == 0 || strength == 0 }
    // Three overlapping age windows have constant sum and squared-weight sum.
    // A reset bank has zero weight and zero weight derivative at both endpoints.
    func phase(at time: Double) throws -> Float {
        try validate()
        guard time.isFinite, time >= 0 else { throw WSSSceneError.invalid("flow time") }
        guard !isIdentity else { return 0 }
        let period = 2 * Double(strength) / Double(speed)
        return Float(time.truncatingRemainder(dividingBy: period) / period)
    }
}
