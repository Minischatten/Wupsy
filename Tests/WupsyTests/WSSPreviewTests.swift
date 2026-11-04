import AppKit
import MetalKit
import XCTest

@testable import Wupsy

@MainActor final class WSSPreviewTests: XCTestCase {
    func resources(trail: Bool = false) throws -> WSSStaticResources {
        let image = WSSAssetID(value: "base")
        var layers: [WSSSceneLayer] = [
            .image(
                WSSImageLayer(
                    asset: image,
                    transform: WSSImageTransform(center: SIMD2(32, 32), size: SIMD2(64, 64))))
        ]
        if trail { layers.append(.trail(.init(configuration: WSSTrailTests().configuration()))) }
        return try WSSStaticResources(
            scene: WSSScene(width: 64, height: 64, layers: layers),
            assets: WSSStaticTests.Assets(values: [
                image: WSSImageAsset(
                    width: 4, height: 1,
                    payload: .rgba8(
                        Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255])))
            ]),
            device: WSSStaticTests().device())
    }
    func render(
        _ r: WSSStaticResources, size: CGSize, projection: WSSRenderProjection? = nil,
        time: Double = 0, advanceTrail: Bool = true, trail: WSSTrailRenderContext? = nil,
        pointer: SIMD2<Float>? = nil
    ) throws -> Data {
        let width = Int(size.width)
        let height = Int(size.height)
        let texture = try WSSRippleChainTests().target(r.device, width: width, height: height)
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(r.queue.makeCommandBuffer())
        if let projection {
            try r.encode(
                command: command, descriptor: descriptor, size: size, time: time,
                trailContext: trail, pointer: pointer, projection: projection,
                advanceTrail: advanceTrail)
        } else {
            try r.encode(
                command: command, descriptor: descriptor, size: size, time: time,
                trailContext: trail, pointer: pointer, advanceTrail: advanceTrail)
        }
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        var result = Data(count: width * height * 4)
        result.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0)
        }
        return result
    }
    func testFullCanvasAndUnchangedDesktopDefault() throws {
        let r = try resources()
        let size = CGSize(width: 8, height: 16)
        let desktop = try render(r, size: size)
        XCTAssertEqual(desktop, try render(r, size: size, projection: .cover))
        let full = try render(r, size: size, projection: .fullCanvas)
        XCTAssertNotEqual(desktop, full)
        XCTAssertEqual(
            try render(r, size: CGSize(width: 16, height: 16)),
            try render(r, size: CGSize(width: 16, height: 16), projection: .fullCanvas))
    }
    func testFitPointerAndHiDPILogicalCoordinates() {
        let canvas = CGSize(width: 1920, height: 1080)
        let fitted = WSSPreviewGeometry.fit(
            canvas: canvas, available: CGSize(width: 800, height: 800))
        XCTAssertEqual(fitted, CGSize(width: 800, height: 450))
        let bounds = CGRect(origin: .zero, size: fitted)
        let center = CGPoint(x: 400, y: 225)
        XCTAssertEqual(
            WSSPreviewGeometry.point(center, bounds: bounds, canvas: canvas, flipped: false),
            SIMD2(960, 540))
        XCTAssertEqual(
            WSSPreviewGeometry.point(
                CGPoint(x: 0, y: 0), bounds: bounds, canvas: canvas, flipped: true), SIMD2(0, 1080))
        XCTAssertNil(
            WSSPreviewGeometry.point(
                CGPoint(x: 400, y: 600), bounds: bounds, canvas: canvas, flipped: false))
        for resolution in SceneRenderResolution.allCases {
            let backing = CGSize(width: 1600, height: 900)
            let size = resolution.drawableSize(bounds: fitted, backing: backing, maxDimension: 2560)
            XCTAssertEqual(size, resolution == .standard ? fitted : backing)
            XCTAssertEqual(
                WSSPreviewGeometry.point(center, bounds: bounds, canvas: canvas, flipped: false),
                SIMD2(960, 540))
        }
    }
    func testExplicitNilPointerPauseResumeTrailAndStop() async throws {
        let r = try resources(trail: true)
        var pointer: SIMD2<Float>? = SIMD2(10, 20)
        var player: WSSStaticPlayer? = WSSStaticPlayer(
            resources: r, size: CGSize(width: 64, height: 64),
            scale: 2, maxDimension: 2560, fps: 30, resolution: .hiDPI, offset: 0,
            projection: .fullCanvas, pointerProvider: { pointer },
            onError: { _ in XCTFail("unexpected failure") })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = player?.view
        XCTAssertEqual(player?.currentPointer(), pointer)
        pointer = nil
        // Explicit nil must never fall through to the global cursor.
        XCTAssertNil(player?.currentPointer())
        pointer = SIMD2(10, 20)
        player?.play()
        _ = try render(
            r, size: CGSize(width: 32, height: 32), time: player!.elapsed,
            trail: player!.trailContext, pointer: pointer)
        XCTAssertEqual(player!.trailContext.sampleCount(index: 1), 1)
        player?.pause()
        let frozen = player!.elapsed
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(player!.elapsed, frozen)
        _ = try render(
            r, size: CGSize(width: 100, height: 80), time: frozen,
            advanceTrail: false, trail: player!.trailContext, pointer: nil)
        XCTAssertEqual(player!.trailContext.sampleCount(index: 1), 1)
        player?.view.setFrameSize(CGSize(width: 100, height: 80))
        XCTAssertEqual(player!.elapsed, frozen)
        pointer = SIMD2(60, 60)
        player?.play()
        XCTAssertEqual(player!.trailContext.sampleCount(index: 1), 0)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertGreaterThan(player!.elapsed, frozen)
        _ = try render(
            r, size: CGSize(width: 32, height: 32), time: player!.elapsed,
            trail: player!.trailContext, pointer: pointer)
        XCTAssertEqual(player!.trailContext.sampleCount(index: 1), 1)
        weak var released = player
        player?.stop()
        XCTAssertNil(player?.view.delegate)
        XCTAssertNil((player?.view as? SceneMetalView)?.geometryChanged)
        window.contentView = nil
        player = nil
        XCTAssertNil(released)
    }
    func testSurfaceCloseReleasesPlayerAndDocumentCallbacks() async throws {
        let helper = WSSEditorCoordinatorTests()
        let document = WSSEditorDocument(project: try await helper.project())
        var surface: WSSPreviewSurface? = WSSPreviewSurface(document: document)
        weak var player = surface?.player
        document.close()
        XCTAssertNil(surface?.player)
        surface = nil
        XCTAssertNil(player)
        XCTAssertNil(document.stopPreview)
    }
}
