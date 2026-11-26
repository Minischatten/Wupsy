import AppKit
import MetalKit

/// An opt-in acceptance window, entered before normal Wupsy startup.
@MainActor final class WSSSlimePreview: MTKView, MTKViewDelegate {
    private let renderer: WSSSlimePrototypeRenderer
    private let queue: MTLCommandQueue
    private var clock = WSSPlaybackClock()
    private var playing = true
    private var rate = 1.0
    private var darkBackground = true
    private var darkMaterial = true
    private var presentedFrames = 0

    init(device: MTLDevice, queue: MTLCommandQueue) throws {
        self.queue = queue
        renderer = try WSSSlimePrototypeRenderer(device: device)
        super.init(frame: NSRect(x: 0, y: 0, width: 720, height: 540), device: device)
        colorPixelFormat = .bgra8Unorm
        delegate = self
        preferredFramesPerSecond = 60
        clock.play(now: ProcessInfo.processInfo.systemUptime)
    }

    required init(coder: NSCoder) { fatalError("Use the Slime preview launcher") }

    override var acceptsFirstResponder: Bool { true }

    private func time(now: Double) -> Double { clock.time(now: now * rate) }

    private func seek(to time: Double, playing: Bool, now: Double) {
        self.playing = playing
        clock.freeze(at: max(0, time))
        if playing { clock.play(now: now * rate) }
        isPaused = !playing
        if !playing { draw() }
    }

    override func keyDown(with event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        let current = time(now: now)
        let release = WSSSlimePrototype.release
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ": seek(to: current, playing: !playing, now: now)
        case "r": seek(to: 0, playing: true, now: now)
        case "1": seek(to: release - 0.1, playing: false, now: now)
        case "2": seek(to: release, playing: false, now: now)
        case "3": seek(to: release + 0.1, playing: false, now: now)
        case "4": seek(to: release + 0.35, playing: false, now: now)
        case "5": seek(to: release + 0.8, playing: false, now: now)
        case "s":
            rate = rate == 1 ? 0.25 : 1
            seek(to: current, playing: playing, now: now)
        case "b":
            darkBackground.toggle()
            if !playing { draw() }
        case "m":
            darkMaterial.toggle()
            if !playing { draw() }
        case "\u{1B}": NSApplication.shared.terminate(nil)
        default:
            switch event.keyCode {
            case 123: seek(to: current - 1.0 / 60, playing: false, now: now)
            case 124: seek(to: current + 1.0 / 60, playing: false, now: now)
            default: super.keyDown(with: event)
            }
        }
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawFrame() }
    }

    private func drawFrame() {
        clearColor =
            darkBackground
            ? MTLClearColorMake(0.055, 0.067, 0.081, 1)
            : MTLClearColorMake(0.78, 0.77, 0.72, 1)
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
            let command = queue.makeCommandBuffer(),
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        // Clip the attachment pad at the synthetic ceiling plane.
        let width = drawable.texture.width
        let height = drawable.texture.height
        let ledgeHeight = max(1, height * 83 / 360)
        encoder.setScissorRect(
            MTLScissorRect(x: 0, y: ledgeHeight, width: width, height: height - ledgeHeight))
        renderer.encode(
            at: time(now: ProcessInfo.processInfo.systemUptime),
            material: darkMaterial ? .dark : .clear, encoder: encoder)
        encoder.endEncoding()
        if presentedFrames < 2 {
            drawable.addPresentedHandler { [weak self] drawable in
                guard drawable.presentedTime > 0 else { return }
                Task { @MainActor [weak self] in
                    guard let self, presentedFrames < 2 else { return }
                    presentedFrames += 1
                    print("Slime Metal drawable presented (\(presentedFrames))")
                    fflush(stdout)
                }
            }
        }
        command.present(drawable)
        command.commit()
    }

    static func run() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
        else { throw WSSSceneError.invalid("Slime preview requires Metal") }
        let app = NSApplication.shared
        let view = try WSSSlimePreview(device: device, queue: queue)
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title =
            "Slime • Space: pause   S: speed   B: background   M: material   1–5: release / retract"
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        let delegate = CloseDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.activate()
        withExtendedLifetime((window, delegate)) { app.run() }
    }

    @MainActor private final class CloseDelegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            true
        }
    }
}
