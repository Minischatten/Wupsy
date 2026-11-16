import ImageIO
import MetalKit
import XCTest

@testable import Wupsy

// Frozen old shader is test data; no old/new renderer switch exists in the app.
final class WSSMilkyWayVisualComparisonTests: XCTestCase {
    func oldPipeline(_ device: MTLDevice) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(
            source: WSSMilkyWayPreviousReference.shader, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "galaxyVertex")
        d.fragmentFunction = library.makeFunction(name: "galaxyFragment")
        let a = d.colorAttachments[0]!
        a.pixelFormat = .bgra8Unorm
        a.isBlendingEnabled = true
        a.sourceRGBBlendFactor = .one
        a.destinationRGBBlendFactor = .one
        a.writeMask = [.red, .green, .blue]
        return try device.makeRenderPipelineState(descriptor: d)
    }
    func previous(
        _ c: WSSStarfieldConfiguration, resources r: WSSStaticResources,
        pipeline: MTLRenderPipelineState, width: Int, height: Int
    ) throws -> (Data, Double) {
        let target = try WSSRippleChainTests().target(r.device, width: width, height: height)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        let command = try XCTUnwrap(r.queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        let m = c.milkyWay
        let angle = m.angle * .pi / 180
        // Exact original uniform layout; time zero, full-canvas fixture aspect.
        let u: [SIMD4<Float>] = [
            SIMD4(
                Float(r.scene.width), Float(r.scene.height), Float(r.scene.width),
                Float(r.scene.height)),
            SIMD4(Float(c.x), Float(c.y), Float(c.width), Float(c.height)),
            SIMD4(Float(m.positionX), Float(m.positionY), Float(cos(angle)), Float(sin(angle))),
            SIMD4(Float(m.width), Float(m.intensity), Float(m.structure), Float(m.dust)),
            SIMD4(Float(m.red), Float(m.green), Float(m.blue), 0),
            SIMD4(0, 0, Float(width), Float(height)),
        ]
        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(.none)
        u.withUnsafeBytes {
            encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
            encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
        }
        var seed = m.seed
        encoder.setFragmentBytes(&seed, length: 4, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        // Same unchanged stars and foreground, over the reference band.
        pass.colorAttachments[0].loadAction = .load
        try r.encode(
            command: command, descriptor: pass, size: CGSize(width: width, height: height), time: 0)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes {
            target.getBytes(
                $0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0)
        }
        return (data, max(0, command.gpuEndTime - command.gpuStartTime) * 1000)
    }
    func png(_ data: Data, width: Int, height: Int, path: URL) throws {
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                    .union(.byteOrder32Little), provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(path as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    func bandContrast(_ data: Data) -> (mean: Double, coefficient: Double) {
        var patches: [Double] = []
        for y in stride(from: 0, to: 524, by: 16) {
            for x in stride(from: 0, to: 464, by: 16) {
                let dx = Double(x + 8) - 480
                let dy = 270 - Double(y + 8)
                let cross = dy * cos(Double.pi / 6) - dx * sin(Double.pi / 6)
                guard abs(cross) < 540 * 0.22 * 0.35 else { continue }
                var sum: Double = 0
                for yy in y..<y + 16 {
                    for xx in x..<x + 16 {
                        let p = (yy * 960 + xx) * 4
                        sum += Double(data[p]) + Double(data[p + 1]) + Double(data[p + 2])
                    }
                }
                patches.append(sum / (256 * 3))
            }
        }
        let mean = patches.reduce(0, +) / Double(patches.count)
        let variance = patches.reduce(0) { $0 + pow($1 - mean, 2) } / Double(patches.count)
        return (mean, sqrt(variance) / max(mean, 0.0001))
    }
    func testMatchedBeforeAfterDefaultAndLowIntensityAnd4KTimings() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
                "Test-Wallpaper/WSS-Starfield-Milky-Way-v1")
        let doc = try WSSSceneDocumentV1.load(
            entry: root.appendingPathComponent("scene.wss.json"), root: root)
        let device = try WSSStaticTests().device()
        let pipeline = try oldPipeline(device)
        var scene = try doc.scene()
        guard case .starfield(var layer) = scene.layers[0] else { return XCTFail("Fixture") }
        var defaults: Data?
        var low: Data?
        for intensity in [0.45, 0.12] {
            layer.starfield.milkyWay.intensity = intensity
            scene.layers[0] = .starfield(layer)
            let after = try WSSStaticResources(
                scene: scene, assets: doc.assetSource(root: root), device: device)
            var legacyScene = scene
            var legacyLayer = layer
            legacyLayer.starfield.milkyWay.enabled = false
            legacyScene.layers[0] = .starfield(legacyLayer)
            let before = try WSSStaticResources(
                scene: legacyScene, assets: doc.assetSource(root: root), device: device)
            let a = try previous(
                layer.starfield, resources: before, pipeline: pipeline, width: 960, height: 540
            ).0
            let b = try WSSStormLightingRenderTests().render(
                after, time: 0, width: 960, height: 540
            ).0
            XCTAssertNotEqual(a, b)
            XCTAssertEqual(
                b,
                try WSSStormLightingRenderTests().render(after, time: 0, width: 960, height: 540).0)
            if intensity == 0.45 {
                defaults = b
                let oldContrast = bandContrast(a)
                let newContrast = bandContrast(b)
                print(
                    "Milky main-band patch contrast: before=\(oldContrast.coefficient), after=\(newContrast.coefficient); mean before=\(oldContrast.mean), after=\(newContrast.mean)"
                )
                XCTAssertGreaterThan(newContrast.coefficient, oldContrast.coefficient * 1.1)
                XCTAssertLessThan(newContrast.mean, oldContrast.mean)
            } else {
                low = b
            }
            if let folder = ProcessInfo.processInfo.environment["WUPSY_MILKY_COMPARISON"] {
                let directory = URL(fileURLWithPath: folder)
                let name = intensity == 0.45 ? "default" : "low"
                try png(
                    a, width: 960, height: 540,
                    path: directory.appendingPathComponent("before-" + name + ".png"))
                try png(
                    b, width: 960, height: 540,
                    path: directory.appendingPathComponent("after-" + name + ".png"))
            }
            if intensity == 0.45 {
                // Warm both paths, then compare full-frame GPU timings on equal 4K targets.
                _ = try previous(
                    layer.starfield, resources: before, pipeline: pipeline, width: 3840,
                    height: 2160)
                _ = try WSSStormLightingRenderTests().render(
                    after, time: 0, width: 3840, height: 2160)
                var old: [Double] = []
                var new: [Double] = []
                for _ in 0..<3 {
                    old.append(
                        try previous(
                            layer.starfield, resources: before, pipeline: pipeline, width: 3840,
                            height: 2160
                        ).1)
                    new.append(
                        try WSSStormLightingRenderTests().render(
                            after, time: 0, width: 3840, height: 2160
                        ).1)
                }
                print(
                    "Milky matched 4K GPU median: before=\(old.sorted()[1]) ms, after=\(new.sorted()[1]) ms; same source scene, seed and parameters; reference uses a separate composition encoder"
                )
                XCTAssertEqual(before.textureBytes, after.textureBytes)
                XCTAssertEqual(before.starfield?.bufferBytes, after.starfield?.bufferBytes)
            }
        }
        let a = try XCTUnwrap(defaults)
        let b = try XCTUnwrap(low)
        for i in 0..<a.count where i % 4 != 3 { XCTAssertLessThanOrEqual(b[i], a[i]) }
        XCTAssertTrue(b.enumerated().contains { $0.offset % 4 != 3 && $0.element > 0 })
    }
}
