import MetalKit
import XCTest

@testable import Wupsy

final class WSSStaticTests: XCTestCase {
    struct Assets: WSSImageAssetSource {
        var values: [WSSAssetID: WSSImageAsset]
        func image(for id: WSSAssetID) throws -> WSSImageAsset {
            guard let image = values[id] else {
                throw WSSSceneError.invalid("missing native asset")
            }
            return image
        }
    }
    func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal required") }
        return device
    }
    func solid(_ rgba: [UInt8]) -> WSSImageAsset {
        WSSImageAsset(width: 1, height: 1, payload: .rgba8(Data(rgba)))
    }
    func testAggregateDecodedBudgetThrowsTypedIdentityBeforeUploadingOversizedTotal() throws {
        let small = WSSAssetID(value: "small")
        let large = WSSAssetID(value: "large")
        let scene = WSSScene(
            width: 64, height: 64,
            layers: [small, large].map {
                WSSImageLayer(
                    asset: $0,
                    transform: WSSImageTransform(center: SIMD2(32, 32), size: SIMD2(64, 64)))
            })
        let assets = Assets(values: [
            small: solid([0, 0, 0, 255]),
            // Exactly 128 MiB by itself; the first image makes the aggregate exceed the limit.
            // Empty payload also proves rejection precedes the large image upload.
            large: WSSImageAsset(width: 8192, height: 4096, payload: .rgba8(Data())),
        ])
        let device = try device()
        XCTAssertThrowsError(try WSSStaticResources(scene: scene, assets: assets, device: device)) {
            XCTAssertEqual($0 as? WSSSceneError, .decodedImageBudget)
        }
    }
    func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func render(_ resources: WSSStaticResources, width: Int = 8, height: Int = 8) throws -> Data {
        let target = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        target.storageMode = .shared
        target.usage = [.renderTarget]
        let texture = try XCTUnwrap(resources.device.makeTexture(descriptor: target))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let c = resources.scene.background
        pass.colorAttachments[0].clearColor = MTLClearColorMake(
            Double(c.x), Double(c.y), Double(c.z), 1)
        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
        try resources.encode(
            command: command, descriptor: pass, size: CGSize(width: width, height: height))
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0)
        }
        return data
    }
    func pixel(_ data: Data, _ x: Int, _ y: Int, width: Int = 8) -> [UInt8] {
        Array(data[(y * width + x) * 4..<(y * width + x) * 4 + 4])
    }

    func testNativeModelWithoutAnyWEInput() throws {
        let transform = WSSImageTransform(
            center: SIMD2(5, 3), size: SIMD2(2, 4), scale: SIMD2(2, 0.5), rotation: .pi / 2)
        XCTAssertEqual(transform.point(.zero), SIMD2(5, 3))
        XCTAssertEqual(transform.axisX.x, 0, accuracy: 0.00001)
        XCTAssertEqual(transform.axisX.y, 4, accuracy: 0.00001)
        XCTAssertEqual(transform.axisY.x, -2, accuracy: 0.00001)
        let id = WSSAssetID(value: "editor/image-1")
        var scene = WSSScene(
            width: 8, height: 8,
            layers: [WSSImageLayer(asset: id, transform: transform, opacity: 0.5, visible: false)])
        try scene.validate()
        XCTAssertEqual(scene.testImages[0].asset, id)
        XCTAssertEqual(scene.testImages[0].opacity, 0.5)
        XCTAssertFalse(scene.testImages[0].visible)
        scene.width = 0
        XCTAssertThrowsError(try scene.validate())
        scene.width = 8
        scene.testImages[0].opacity = .nan
        XCTAssertThrowsError(try scene.validate())
    }

    func testNativeGPUOpacityOrderVisibilityAndRotatedScaledGeometry() throws {
        let red = WSSAssetID(value: "red")
        let blue = WSSAssetID(value: "blue")
        let assets = Assets(values: [red: solid([255, 0, 0, 255]), blue: solid([0, 0, 255, 128])])
        let full = WSSImageTransform(center: SIMD2(4, 4), size: SIMD2(8, 8))
        let back = WSSImageLayer(asset: red, transform: full, composition: .replace)
        var front = WSSImageLayer(asset: blue, transform: full, opacity: 0.5)
        let d = try device()
        func gpu(_ layers: [WSSImageLayer]) throws -> Data {
            try render(
                WSSStaticResources(
                    scene: WSSScene(width: 8, height: 8, layers: layers), assets: assets, device: d)
            )
        }
        let mixed = try pixel(gpu([back, front]), 4, 4)
        XCTAssertEqual(mixed, [64, 0, 191, 255])
        XCTAssertEqual(try pixel(gpu([front, back]), 4, 4), [0, 0, 255, 255])
        front.visible = false
        XCTAssertEqual(try pixel(gpu([back, front]), 4, 4), [0, 0, 255, 255])
        front.visible = true
        front.opacity = 1
        front.transform = WSSImageTransform(
            center: SIMD2(5, 3), size: SIMD2(2, 4), scale: SIMD2(2, 0.5), rotation: .pi / 2)
        let transformed = try gpu([back, front])
        XCTAssertEqual(pixel(transformed, 4, 3), [128, 0, 127, 255])
        XCTAssertEqual(pixel(transformed, 3, 4), [0, 0, 255, 255])
        XCTAssertEqual(pixel(transformed, 4, 2), [0, 0, 255, 255])
        let highResolution = try render(
            WSSStaticResources(
                scene: WSSScene(width: 8, height: 8, layers: [back, front]), assets: assets,
                device: d), width: 16, height: 16)
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(
                    pixel(transformed, x, y), pixel(highResolution, x * 2 + 1, y * 2 + 1, width: 16)
                )
            }
        }

        XCTAssertThrowsError(
            try WSSStaticResources(
                scene: WSSScene(width: 8, height: 8, layers: [back]), assets: Assets(values: [:]),
                device: d))
    }

    @MainActor func testStaticPlayerResolutionAndRendererPauseResume() async throws {
        let (root, original) = try ScenePlaybackTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = original
        let prepared = try await ScenePlayback.prepare(for: item)
        let player = try XCTUnwrap(
            prepared.makePlayer(
                size: CGSize(width: 100, height: 50), scale: 2, maxDimension: 1000, fps: 24,
                resolution: .standard, offset: 7, onError: { XCTFail($0) }) as? WSSStaticPlayer)
        defer { player.stop() }
        XCTAssertEqual(player.view.drawableSize, CGSize(width: 100, height: 50))
        let resources = player.resources
        player.setRenderResolution(.hiDPI)
        XCTAssertEqual(player.view.drawableSize, CGSize(width: 200, height: 100))
        player.setRenderResolution(.standard)
        XCTAssertEqual(player.view.drawableSize, CGSize(width: 100, height: 50))
        XCTAssertTrue(resources === player.resources)
        XCTAssertEqual(player.diagnostics.intermediateTextureBytes, 0)
        XCTAssertEqual(player.diagnostics.shader, "WSS static images")
        guard let screen = NSScreen.main else { throw XCTSkip("Display required") }
        let renderer = Renderer(
            wallpaper: item, screen: screen, scenePlayback: prepared, onError: { XCTFail($0) })
        defer { renderer.stop() }
        XCTAssertTrue(renderer.scene is WSSStaticPlayer)
        renderer.setPaused(true)
        XCTAssertFalse(renderer.hasLiveResources)
        renderer.setPaused(false)
        for _ in 0..<100 {
            if renderer.scene != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(renderer.scene is WSSStaticPlayer)
    }

}
