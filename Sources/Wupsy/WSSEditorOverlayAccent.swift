import AppKit

// The active effect's editor accent, independent of effect kind. Other overlay
// identities can receive another value later without changing their data model.
struct WSSEditorOverlayAccent: Sendable {
    let red: Float
    let green: Float
    let blue: Float
    static var selected: Self {
        let color = NSColor.controlAccentColor.usingColorSpace(.deviceRGB) ?? .systemBlue
        return Self(
            red: Float(color.redComponent), green: Float(color.greenComponent),
            blue: Float(color.blueComponent))
    }
    var rgba: SIMD4<Float> { SIMD4(red, green, blue, 0.35) }
}
