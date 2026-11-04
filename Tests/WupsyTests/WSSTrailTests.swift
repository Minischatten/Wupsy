import AppKit
import Metal
import XCTest

@testable import Wupsy

final class WSSTrailTests: XCTestCase {
    func configuration() -> WSSTrailConfiguration {
        .init(colors: [.init(r: 0, g: 0.7, b: 1), .init(r: 1, g: 0.25, b: 0)])
    }
    func testDocumentRoundTripAndInvalidParameters() throws {
        var c = configuration()
        c.width = 21
        c.lifetime = 2
        c.emissionRate = 48
        c.fadeIn = 0.2
        c.fadeOut = 0.4
        c.opacity = 0.6
        c.edgeSoftness = 0.3
        c.colorMode = .ageGradient
        c.seed = 123
        let decoded = try JSONDecoder().decode(
            WSSTrailConfiguration.self,
            from: JSONEncoder().encode(c))
        XCTAssertEqual(c, decoded)
        try decoded.validate()
        for change: (inout WSSTrailConfiguration) -> Void in [
            { $0.colors = [] }, { $0.colors[0].r = .nan }, { $0.width = 0 },
            { $0.lifetime = -.infinity }, { $0.emissionRate = 0 },
            { $0.fadeOut = 3 }, { $0.opacity = 2 }, { $0.edgeSoftness = -1 },
        ] {
            var bad = c
            change(&bad)
            XCTAssertThrowsError(try WSSTrailSimulation(configuration: bad))
        }
    }
    func testSamplingIndependentOfFrameScheduleAndSeed() throws {
        let c = configuration()
        var a = try WSSTrailSimulation(configuration: c)
        var b = a
        for i in 0...60 {
            let t = Double(i) / 60
            a.update(time: t, pointer: SIMD2(Float(t) * 600, 200))
        }
        for i in 0...144 {
            let t = Double(i) / 144
            b.update(time: t, pointer: SIMD2(Float(t) * 600, 200))
        }
        XCTAssertEqual(a.samples.count, 32)
        XCTAssertEqual(a.samples.count, b.samples.count)
        for (x, y) in zip(a.samples, b.samples) {
            XCTAssertEqual(x.birth, y.birth, accuracy: 1e-9)
            XCTAssertEqual(x.position.x, y.position.x, accuracy: 0.001)
            XCTAssertEqual(x.colorCoordinate, y.colorCoordinate)
        }
        XCTAssertEqual(a.samples.last!.position.x, 600, accuracy: 0.001)
        var other = c
        other.seed = 5
        var seeded = try WSSTrailSimulation(configuration: other)
        for i in 0...60 {
            let t = Double(i) / 60
            seeded.update(time: t, pointer: SIMD2(Float(t) * 600, 200))
        }
        XCTAssertNotEqual(a.samples.map(\.colorCoordinate), seeded.samples.map(\.colorCoordinate))
    }
    func testConfiguredRateLifetimeAndLargeGap() throws {
        var c = configuration()
        c.emissionRate = 64
        c.lifetime = 0.5
        c.fadeOut = 0.4
        var s = try WSSTrailSimulation(configuration: c)
        for i in 0...64 {
            let t = Double(i) / 64
            s.update(time: t, pointer: SIMD2(Float(t) * 100, 100))
        }
        XCTAssertEqual(s.samples.count, 32)
        XCTAssertEqual(s.samples.first!.birth, 0.515625, accuracy: 1e-9)
        XCTAssertEqual(s.samples.last!.birth, 1, accuracy: 1e-9)
        s.update(time: 1000, pointer: SIMD2(300, 100))
        XCTAssertEqual(s.samples.count, 1)  // no fabricated bridge across suspension
        XCTAssertTrue(s.vertices(time: 1000).isEmpty)
    }
    func testStopExpiryAndExplicitPointerLoss() throws {
        var s = try WSSTrailSimulation(configuration: configuration())
        for i in 0...128 {
            let t = Double(i) / 64
            s.update(time: t, pointer: WSSTrailPrototypePath.straight.pointer(time: t))
        }
        XCTAssertEqual(s.samples.count, 32)  // still emits at rest
        XCTAssertTrue(s.samples.allSatisfy { $0.position == SIMD2(700, 240) })
        XCTAssertTrue(s.vertices(time: 2).isEmpty)  // coincident geometry, no stationary glow
        s.update(time: 2.1, pointer: nil)
        XCTAssertTrue(s.samples.isEmpty)
        s.update(time: 2.2, pointer: SIMD2(1, 1))
        XCTAssertTrue(s.vertices(time: 2.2).isEmpty)
        s.update(time: 1, pointer: SIMD2(3, 3))  // backward clock resets
        XCTAssertEqual(s.samples.count, 1)
        s.update(time: 1e100, pointer: SIMD2(3, 3))
        XCTAssertTrue(s.samples.isEmpty)
    }
    func testPaletteFadeAndWidthReachGeometry() throws {
        var c = configuration()
        c.colors = [.init(r: 1, g: 0, b: 0), .init(r: 0, g: 1, b: 0)]
        c.colorMode = .ageGradient
        c.width = 20
        XCTAssertEqual(c.color(0.5), SIMD3(0.5, 0.5, 0))
        XCTAssertEqual(c.alpha(age: 0), 0)
        XCTAssertEqual(c.alpha(age: 0.1), 1)
        XCTAssertEqual(c.alpha(age: 0.55), 0.5, accuracy: 0.0001)
        XCTAssertEqual(c.alpha(age: 1), 0)
        var s = try WSSTrailSimulation(configuration: c)
        s.update(time: 0, pointer: SIMD2(100, 200))
        s.update(time: 0.5, pointer: SIMD2(400, 200))
        let v = s.vertices(time: 0.5)
        XCTAssertFalse(v.isEmpty)
        XCTAssertEqual(v.map { $0.position.y }.min()!, 190, accuracy: 0.001)
        XCTAssertEqual(v.map { $0.position.y }.max()!, 210, accuracy: 0.001)
        XCTAssertTrue(v.allSatisfy { $0.color.z == 0 })
        XCTAssertTrue(v.contains { $0.color.y > 0.4 })
    }
    func render(
        _ c: WSSTrailConfiguration, path: WSSTrailPrototypePath, time: Double,
        logicalScale: Float = 1, background: SIMD3<Double> = SIMD3(repeating: 0.02)
    )
        throws -> [UInt8]
    {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let r = try WSSTrailRenderer(device: d)
        var s = try WSSTrailSimulation(configuration: c)
        for i in 0...Int((time * 128).rounded()) {
            let t = Double(i) / 128
            s.update(time: t, pointer: path.pointer(time: t) * logicalScale)
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 800, height: 480, mipmapped: false)
        desc.storageMode = .shared
        desc.usage = [.renderTarget]
        let texture = try XCTUnwrap(d.makeTexture(descriptor: desc))
        let queue = try XCTUnwrap(d.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(
            background.x, background.y, background.z, 1)
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        try r.encode(
            encoder: encoder, simulation: s, time: time, canvas: SIMD2(800, 480) * logicalScale)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        var bytes = [UInt8](repeating: 0, count: 800 * 480 * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!, bytesPerRow: 3200,
                from: MTLRegionMake2D(0, 0, 800, 480), mipmapLevel: 0)
        }
        return bytes
    }
    func testMetalPaletteAndSoftnessWithoutTextures() throws {
        var red = configuration()
        red.colors = [.init(r: 1, g: 0, b: 0)]
        var green = red
        green.colors = [.init(r: 0, g: 1, b: 0)]
        let a = try render(red, path: .straight, time: 0.75)
        let b = try render(green, path: .straight, time: 0.75)
        XCTAssertNotEqual(a, b)
        let pixels = stride(from: 0, to: a.count, by: 4)
        XCTAssertTrue(pixels.contains { a[$0 + 2] > a[$0 + 1] + 10 })
        XCTAssertTrue(pixels.contains { b[$0 + 1] > b[$0 + 2] + 10 })
        var hard = red
        hard.edgeSoftness = 0
        XCTAssertNotEqual(a, try render(hard, path: .straight, time: 0.75))
        XCTAssertEqual(a, try render(red, path: .straight, time: 0.75))
    }
    func testOptionalPrototypeContactSheet() throws {
        guard let root = ProcessInfo.processInfo.environment["AMBIENT_TRAIL_QA"] else {
            throw XCTSkip("Set AMBIENT_TRAIL_QA to export original analytic prototype frames")
        }
        let folder = URL(fileURLWithPath: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for path in WSSTrailPrototypePath.allCases {
            for t in [0.5, 0.75, 1.0, 1.25, 1.5, 2.1] {
                let bytes = try render(configuration(), path: path, time: t)
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 480,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 3200, bitsPerPixel: 32)!
                let dst = rep.bitmapData!
                for i in stride(from: 0, to: bytes.count, by: 4) {
                    dst[i] = bytes[i + 2]
                    dst[i + 1] = bytes[i + 1]
                    dst[i + 2] = bytes[i]
                    dst[i + 3] = 255
                }
                try rep.representation(using: .png, properties: [:])!.write(
                    to: folder.appendingPathComponent("\(path.rawValue)-\(t).png"))
            }
        }
        try JSONEncoder().encode(configuration()).write(
            to: folder.appendingPathComponent("trail.json"))
    }
    func w3Calibration() throws -> WSSTrailConfiguration {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/WSSTrail")
        let c = try JSONDecoder().decode(
            WSSTrailConfiguration.self,
            from: Data(contentsOf: root.appendingPathComponent("w3-calibration.json")))
        try c.validate()
        return c
    }
    func testW3CalibrationIsOrdinaryConfiguration() throws {
        let c = try w3Calibration()
        XCTAssertEqual(c.colors.count, 2)
        XCTAssertEqual(c.emissionRate, 32)
        XCTAssertEqual(c.lifetime, 1)
        var alternate = c
        alternate.colors = [.init(r: 0, g: 1, b: 0)]
        XCTAssertNotEqual(
            try render(c, path: .quickTurn, time: 0.75, logicalScale: 4.8),
            try render(alternate, path: .quickTurn, time: 0.75, logicalScale: 4.8))
    }
    func testCalibratedRasterWidthAndDecay() throws {
        let c = try w3Calibration()
        let image = try render(c, path: .straight, time: 0.75, background: .zero)
        let column = (0..<480).map { y -> Int in
            let i = (y * 800 + 500) * 4
            return max(Int(image[i]), Int(image[i + 2]))
        }
        let peak = try XCTUnwrap(column.max())
        XCTAssertGreaterThan(peak, 20)
        let halfMaximumWidth = column.filter { $0 * 2 >= peak }.count
        XCTAssertTrue((6...10).contains(halfMaximumWidth), "analytic 12px ribbon core")
        func energy(_ t: Double) throws -> Int {
            try render(c, path: .quickTurn, time: t, logicalScale: 4.8, background: .zero)
                .enumerated().reduce(0) { $0 + ($1.offset % 4 == 3 ? 0 : Int($1.element)) }
        }
        XCTAssertGreaterThan(try energy(1.2), try energy(1.6))
        XCTAssertEqual(try energy(2.1), 0)
        var s = try WSSTrailSimulation(configuration: c)
        for i in 0...96 {
            let t = Double(i) / 128
            s.update(time: t, pointer: WSSTrailPrototypePath.quickTurn.pointer(time: t))
        }
        XCTAssertTrue(
            s.vertices(time: 0.75).allSatisfy {
                $0.position.x.isFinite && $0.position.y.isFinite && $0.color.w.isFinite
            })
    }
    func testOptionalCalibrationSheets() throws {
        guard let root = ProcessInfo.processInfo.environment["AMBIENT_TRAIL_CALIBRATION_QA"] else {
            throw XCTSkip("Set AMBIENT_TRAIL_CALIBRATION_QA for native-only calibration sheets")
        }
        let folder = URL(fileURLWithPath: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let selected = try w3Calibration()
        // Own synthetic warm background; no wallpaper or video pixels.
        let background = SIMD3<Double>(0.35, 0.25, 0.18)
        func sheet(
            _ name: String,
            _ cells: [(String, WSSTrailConfiguration, WSSTrailPrototypePath, Double)],
            columns: Int = 3, scale: Float = 4.8
        ) throws {
            let rows = (cells.count + columns - 1) / columns
            let image = NSImage(size: NSSize(width: columns * 800, height: rows * 510))
            image.lockFocus()
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: columns * 800, height: rows * 510).fill()
            for (i, cell) in cells.enumerated() {
                let bytes = try render(
                    cell.1, path: cell.2, time: cell.3,
                    logicalScale: scale, background: background)
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 480,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 3200, bitsPerPixel: 32)!
                let dst = rep.bitmapData!
                for j in stride(from: 0, to: bytes.count, by: 4) {
                    dst[j] = bytes[j + 2]
                    dst[j + 1] = bytes[j + 1]
                    dst[j + 2] = bytes[j]
                    dst[j + 3] = 255
                }
                let x = (i % columns) * 800
                let y = (rows - 1 - i / columns) * 510
                NSImage(cgImage: rep.cgImage!, size: .zero).draw(
                    in: NSRect(x: x, y: y + 30, width: 800, height: 480))
                (cell.0 as NSString).draw(
                    at: NSPoint(x: x + 12, y: y + 6),
                    withAttributes: [
                        .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 16),
                    ])
            }
            image.unlockFocus()
            // Explicit pixel dimensions avoid Retina-dependent output size.
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: columns * 800, pixelsHigh: rows * 510,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: columns * 800 * 4, bitsPerPixel: 32)!
            let context = NSGraphicsContext(bitmapImageRep: rep)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: NSRect(x: 0, y: 0, width: columns * 800, height: rows * 510))
            NSGraphicsContext.restoreGraphicsState()
            try rep.representation(using: .png, properties: [:])!.write(
                to: folder.appendingPathComponent(name + ".png"))
        }
        var neutral = selected
        neutral.colors = [.init(r: 1, g: 1, b: 1)]
        try sheet(
            "01-width",
            [Float(10), 12, 15].map { w in
                var c = neutral
                c.width = w
                return ("width \(w) / 3840 logical canvas", c, .straight, 0.75)
            })
        try sheet(
            "02-edge",
            [Float(0.35), 0.65, 0.9].map { e in
                var c = neutral
                c.edgeSoftness = e
                return ("edge softness \(e) / 1:1 detail", c, .quickTurn, 0.75)
            }, scale: 1)
        try sheet(
            "03-fade",
            [0.0, 0.2, 0.4, 0.6, 0.8, 1.1].map { dt in
                ("stopped + \(dt) s", neutral, .quickTurn, 1 + dt)
            })
        try sheet(
            "04-final-paths",
            WSSTrailPrototypePath.allCases.map { p in
                ("W3 candidate / \(p.rawValue) / t=0.75", selected, p, 0.75)
            })
        try sheet(
            "05-final-decay",
            [0.0, 0.2, 0.4, 0.6, 0.8, 1.1].map { dt in
                ("W3 candidate / stopped + \(dt) s", selected, .quickTurn, 1 + dt)
            })
        try sheet(
            "06-profile-detail",
            [("W3 candidate / 1 logical pixel = 1 output pixel", selected, .quickTurn, 0.75)],
            columns: 1, scale: 1)
        try sheet(
            "07-color-options",
            [
                ("prototype demo palette", configuration(), .quickTurn, 0.75),
                ("W3 two-color candidate", selected, .quickTurn, 0.75),
                (
                    "age gradient alternative",
                    {
                        var c = selected
                        c.colorMode = .ageGradient
                        return c
                    }(), .quickTurn, 0.75
                ),
            ])
    }

}
