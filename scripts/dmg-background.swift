import AppKit

// Reproduce the accepted WSS layout from the local EuroLotto distribution.
// The shared WSS logo is used unchanged; no product artwork is copied.
let w = 640
let h = 480
let logoURL = URL(fileURLWithPath: "Brand/WSS_Logo.png")
guard let logo = NSImage(contentsOf: logoURL) else {
    fatalError("Cannot load shared WSS distribution logo")
}
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
    bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(deviceWhite: 247.0 / 255.0, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: w, height: h).fill()
NSColor.black.setFill()
NSRect(x: 0, y: 0, width: w, height: 250).fill()
logo.draw(in: NSRect(x: 200, y: 5, width: 240, height: 240))
func text(
    _ value: String, _ y: CGFloat, _ size: CGFloat, _ color: NSColor,
    _ weight: NSFont.Weight = .regular
) {
    let p = NSMutableParagraphStyle()
    p.alignment = .center
    (value as NSString).draw(
        in: NSRect(x: 20, y: y, width: 600, height: size * 1.6),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
            .paragraphStyle: p,
        ])
}
text("Wupsy installieren", 428, 22, .black, .semibold)
text("App nach Applications ziehen", 404, 14, .darkGray)
// Finder supplies the current Wupsy app icon and the Applications folder icon.
text("→", 308, 44, .gray, .light)
NSGraphicsContext.restoreGraphicsState()
rep.size = NSSize(width: w, height: h)
try rep.representation(using: .png, properties: [:])!.write(
    to: URL(fileURLWithPath: CommandLine.arguments[1]))
