import Metal
import XCTest

@testable import Wupsy

final class WSSSlimePrototypeTests: XCTestCase {
    private typealias Slime = WSSSlimePrototype

    func testTimeLookupIsBoundedAndIndependentOfFrameHistory() {
        let expected = Slime.frame(at: 4.25)
        XCTAssertEqual(expected, Slime.frame(at: 4.25 + 7_000_000))
        for time in Array(stride(from: 7.0, through: 0, by: -0.01)) + [
            Double.greatestFiniteMagnitude
        ] {
            let frame = Slime.frame(at: time)
            XCTAssertEqual(frame.stem.count, Slime.segments + 1)
            XCTAssertEqual(frame.stem.first, SIMD4(Slime.anchor.x, Slime.anchor.y, 9, 0))
            for sample in frame.stem + [frame.neck, frame.drop] {
                XCTAssertTrue((0..<4).allSatisfy { sample[$0].isFinite })
                XCTAssertTrue((0...Slime.canvas.x).contains(sample.x))
                XCTAssertTrue((0...Slime.canvas.y).contains(sample.y))
                XCTAssertTrue((0...16).contains(sample.z))
            }
            XCTAssertTrue((0...1).contains(frame.visibility))
        }
        XCTAssertEqual(expected, Slime.frame(at: 4.25))
        XCTAssertEqual(Slime.frame(at: 0), Slime.frame(at: Slime.duration))
        XCTAssertEqual(Slime.frame(at: .infinity), Slime.frame(at: 0))
    }

    func testReleaseContinuityAndFall() {
        let before = Slime.frame(at: Slime.release - 0.001)
        let release = Slime.frame(at: Slime.release)
        let after = Slime.frame(at: Slime.release + 0.001)
        XCTAssertGreaterThan(before.neck.z, 0)
        XCTAssertEqual(release.neck.z, 0)
        for component in 0..<4 {
            XCTAssertEqual(before.drop[component], release.drop[component], accuracy: 0.002)
            XCTAssertEqual(after.drop[component], release.drop[component], accuracy: 0.002)
        }
        let early = Slime.frame(at: Slime.release + 0.2)
        let late = Slime.frame(at: Slime.release + 0.4)
        XCTAssertGreaterThan(late.drop.y - early.drop.y, early.drop.y - release.drop.y)
        XCTAssertLessThan(late.stem.last!.y, release.stem.last!.y)
        let end = Slime.frame(at: Slime.release + 2)
        XCTAssertEqual(end.drop.y - release.drop.y, Slime.fallLimit, accuracy: 0.001)
        XCTAssertEqual(end.visibility, 0)
    }

    func testRetractionGathersAtTheTipAndSettlesIntoTheAnchor() {
        let released = Slime.frame(at: Slime.release)
        let justAfter = Slime.frame(at: Slime.release + 0.001)
        for (initial, next) in zip(released.stem, justAfter.stem) {
            for axis in 0..<3 {
                XCTAssertEqual(initial[axis], next[axis], accuracy: 0.002)
            }
        }

        func tip(_ elapsed: Double) -> SIMD4<Float> {
            Slime.frame(at: Slime.release + elapsed).stem[Slime.segments]
        }

        XCTAssertGreaterThan(tip(0.35).z, 2)
        XCTAssertLessThan(tip(0.8).z, tip(0.35).z)
        func extent(_ elapsed: Double) -> Float {
            let frame = Slime.frame(at: Slime.release + elapsed)
            return max(Slime.anchor.y + 8, frame.stem.map { $0.y + $0.z }.max()!)
        }
        let extents = (0...56).map { extent(Double($0) / 60) }
        for (previous, next) in zip(extents, extents.dropFirst()) {
            XCTAssertLessThanOrEqual(next, previous + 0.001)
        }
        XCTAssertLessThan(extent(0.70) - extent(0.80), extent(0.30) - extent(0.40))
        let settled = Slime.frame(at: Slime.release + 0.92)
        XCTAssertEqual(settled.stem, Slime.frame(at: 0).stem)
    }

    func testMetalCoverageTransparencyAndRelease() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try WSSSlimePrototypeRenderer(device: device)
        let width = Int(Slime.canvas.x)
        let height = Int(Slime.canvas.y)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        func render(_ time: Double, _ material: Slime.Material = .dark) throws -> [UInt8] {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            renderer.encode(at: time, material: material, encoder: encoder)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed, String(describing: command.error))
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes {
                texture.getBytes(
                    $0.baseAddress!, bytesPerRow: width * 4,
                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            return pixels
        }

        func alpha(_ pixels: [UInt8], _ x: Int, _ y: Int) -> UInt8 {
            pixels[(y * width + x) * 4 + 3]
        }

        let attached = try render(Slime.release - 0.005)
        let release = try render(Slime.release)
        let justDetached = try render(Slime.release + 0.005)
        let transparent = try render(Slime.release, .clear)
        XCTAssertEqual(release, try render(Slime.release))
        XCTAssertEqual(alpha(release, 200, 190), 0)
        XCTAssertGreaterThan(alpha(release, 246, 194), 170)
        XCTAssertTrue((45...140).contains(alpha(transparent, 246, 194)))
        XCTAssertGreaterThan(alpha(release, 240, 83), 160)
        let edge = (252...258).map { alpha(release, $0, 194) }
        XCTAssertTrue(edge.contains { (5...150).contains($0) })
        XCTAssertEqual(edge.last, 0)
        for adjacent in [attached, justDetached] {
            let change = zip(release, adjacent).reduce(0) { total, pair in
                total + abs(Int(pair.0) - Int(pair.1))
            }
            XCTAssertLessThan(change, 3000)
        }
        let retractionTime = Slime.release + 0.35
        let retraction = try render(retractionTime)
        let tip = Slime.frame(at: retractionTime).stem[Slime.segments]
        let tipX = Int(tip.x)
        let tipY = Int(tip.y)
        XCTAssertGreaterThan(alpha(retraction, 240, 83), 160)
        XCTAssertGreaterThan(alpha(retraction, tipX, tipY), 70)
        XCTAssertGreaterThan(alpha(retraction, tipX, tipY + 1), 40)
        XCTAssertEqual(alpha(retraction, tipX + 5, tipY + 1), 0)
        XCTAssertEqual(alpha(retraction, tipX, tipY + 6), 0)

        let falling = try render(Slime.release + 0.6)
        XCTAssertGreaterThan(alpha(falling, 247, 228), 135)
        XCTAssertEqual(alpha(falling, 247, 194), 0)
        let settled = try render(Slime.release + 2)
        XCTAssertGreaterThan(alpha(settled, 240, 83), 160)
        XCTAssertEqual(alpha(settled, 249, 340), 0)

        // A softened reflection stays localized to the upper shoulder of the falling drop.
        func green(_ x: Int, _ y: Int) -> Int {
            Int(falling[(y * width + x) * 4 + 1])
        }
        let shoulder = green(243, 222)
        XCTAssertGreaterThan(shoulder - green(243, 234), 15)
        XCTAssertLessThan(shoulder, 150)

        let cyan = Slime.Material(tintAndOpacity: SIMD4(0.1, 0.55, 0.75, 0.30))
        let custom = try render(Slime.release + 0.6, cyan)
        let center = (228 * width + 247) * 4
        XCTAssertGreaterThan(Int(custom[center]) - Int(custom[center + 2]), 20)
        XCTAssertTrue((45...140).contains(custom[center + 3]))
    }
}
