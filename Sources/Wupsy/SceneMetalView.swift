import MetalKit

// AppKit owns contentsScale. Only drawable pixel dimensions are controlled here.
@MainActor final class SceneMetalView: MTKView {
    var geometryChanged: (() -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        geometryChanged?()
    }
    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        geometryChanged?()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        geometryChanged?()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        geometryChanged?()
    }
}
