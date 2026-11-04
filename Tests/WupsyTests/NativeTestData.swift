import CryptoKit
import Foundation

@testable import Wupsy

enum NativeTestData {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static let rippleProfile: [WSSImageEffect] = [
        .ripple(
            WSSRippleEffect(
                amplitude: 14, wavelength: 140, stretch: 2.2, direction: 180, travelSpeed: 100,
                evolutionRate: 0.18, seed: 27181, structureRotation: 90, lateralDetail: 3)),
        .ripple(
            WSSRippleEffect(
                amplitude: 6, wavelength: 220, stretch: 1.15, direction: 130, travelSpeed: 65,
                evolutionRate: 0.12, seed: 81827)),
    ]
}
