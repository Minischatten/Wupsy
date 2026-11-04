import CoreGraphics
import Foundation

// Scene raster density only. Media optimization and frame-rate policy remain separate.
enum SceneRenderResolution: String, CaseIterable, Identifiable {
    case standard
    case hiDPI
    var id: String { rawValue }
    var title: String {
        self == .standard ? ProductText.resolutionStandard.text : ProductText.resolutionHiDPI.text
    }
    static let preferenceKey = "sceneRenderResolution"
    static func stored(in defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .hiDPI
    }
    func drawableSize(bounds: CGSize, backing: CGSize, maxDimension: Int) -> CGSize {
        let desired = self == .standard ? bounds : backing
        guard desired.width.isFinite, desired.height.isFinite,
            desired.width > 0, desired.height > 0, maxDimension > 0
        else {
            return CGSize(width: 1, height: 1)
        }
        let factor = min(1, CGFloat(maxDimension) / max(desired.width, desired.height))
        return CGSize(
            width: max(1, (desired.width * factor).rounded()),
            height: max(1, (desired.height * factor).rounded()))
    }
}
