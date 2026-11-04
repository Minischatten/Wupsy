import AppKit
import MetalKit

// One bounded native frame, not a player. Never materializes or writes a project.
enum WSSLibraryThumbnail {
    static func render(_ resources: WSSStaticResources, maxPixel: Int) throws -> NSImage {
        let scene = resources.scene
        let factor = min(
            1, Double(max(1, min(1280, maxPixel))) / Double(max(scene.width, scene.height)))
        let width = max(1, Int(Double(scene.width) * factor))
        let height = max(1, Int(Double(scene.height) * factor))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = resources.device.makeTexture(descriptor: descriptor),
            let command = resources.queue.makeCommandBuffer()
        else { throw WSSSceneError.invalid("thumbnail target") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(
            Double(scene.background.x), Double(scene.background.y), Double(scene.background.z), 1)
        let ripple = WSSRippleRenderContext(device: resources.device)
        let trail = WSSTrailRenderContext()
        try resources.encode(
            command: command, descriptor: pass, size: CGSize(width: width, height: height), time: 0,
            rippleContext: ripple, trailContext: trail, pointer: nil, projection: .fullCanvas,
            advanceTrail: false)
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw WSSSceneError.invalid("thumbnail rendering")
        }
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            target.getBytes(
                $0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0)
        }
        // The native wallpaper surface is opaque. Preserve composed RGB even for
        // the existing replace contract, whose output alpha can be below one.
        guard let provider = CGDataProvider(data: bytes as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let cg = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw WSSSceneError.invalid("thumbnail pixels") }
        return NSImage(cgImage: cg, size: CGSize(width: width, height: height))
    }
}

extension Notification.Name {
    static let wssPreviewCommitted = Notification.Name("Wupsy.WSSPreviewCommitted")
}
