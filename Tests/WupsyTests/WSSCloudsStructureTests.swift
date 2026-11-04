import MetalKit
import XCTest

@testable import Wupsy

final class WSSCloudsStructureTests: XCTestCase {
    func energy(_ bytes: Data, width: Int) -> Double {
        var result = 0.0
        for y in 1..<width {
            for x in 1..<width {
                let p = (y * width + x) * 4
                result +=
                    abs(Double(bytes[p]) - Double(bytes[p - 4]))
                    + abs(Double(bytes[p]) - Double(bytes[p - width * 4]))
            }
        }
        return result / Double(width * width * 255)
    }
    func testSoftStructureIsDeterministicBoundedAndLessFragmented() throws {
        let helper = WSSCloudsExtensionTests()
        var e = WSSCloudsEffect(
            velocity: SIMD2(20, 0), scale: 300, intensity: 1, density: 0.5, seed: 7,
            secondaryField: .init(velocity: SIMD2(-15, 20), scale: 500), secondaryInfluence: 0.4)
        let old = try helper.render(e, size: 512)
        e.softness = 0
        XCTAssertEqual(old, try helper.render(e, size: 512))
        e.softness = 1
        let soft = try helper.render(e, size: 512)
        XCTAssertNotEqual(old, soft)
        XCTAssertEqual(soft, try helper.render(e, size: 512))
        XCTAssertLessThan(energy(soft, width: 512), energy(old, width: 512) * 0.8)
        var low = 255
        var high = 0
        for i in stride(from: 0, to: soft.count, by: 4) {
            low = min(low, Int(soft[i]))
            high = max(high, Int(soft[i]))
        }
        XCTAssertGreaterThan(high - low, 40)  // Not a uniform gray veil.
        let clearOld = stride(from: 0, to: old.count, by: 4).filter { old[$0] < 10 }.count
        let clearSoft = stride(from: 0, to: soft.count, by: 4).filter { soft[$0] < 10 }.count
        XCTAssertLessThan(clearSoft, clearOld)
        print(
            "Native structure gradient old=\(energy(old,width:512)) soft=\(energy(soft,width:512)); near-clear pixels \(clearOld) -> \(clearSoft)"
        )
        if let path = ProcessInfo.processInfo.environment["AMBIENT_CLOUDS_STORM_QA"] {
            let folder = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, pixels) in [("coverage-structured", old), ("coverage-soft", soft)] {
                try NativeImageTestWriter().save(
                    pixels, width: 512, height: 512,
                    to: folder.appendingPathComponent(name + ".png"))
            }
        }
        e.density = 0
        let none = try helper.render(e)
        XCTAssertTrue(stride(from: 0, to: none.count, by: 4).allSatisfy { none[$0] == 0 })
        e.density = 1
        let full = try helper.render(e)
        XCTAssertTrue(stride(from: 0, to: full.count, by: 4).allSatisfy { full[$0] == 255 })
        for bad: Float in [-1, 1.01, .nan, .infinity] {
            e.softness = bad
            XCTAssertThrowsError(try e.validate())
        }
    }
    func testSoftShadingBrightnessIndependentFieldsAndLongTime() throws {
        let helper = WSSCloudsExtensionTests()
        var e = WSSCloudsEffect(
            velocity: .zero, scale: 300, intensity: 1, density: 0.6, seed: 7,
            secondaryField: .init(velocity: SIMD2(-25, 10), scale: 500), secondaryInfluence: 0.7,
            softness: 0.9)
        let a = try helper.render(e)
        XCTAssertNotEqual(a, try helper.render(e, time: 2))
        e.secondaryInfluence = 0
        XCTAssertEqual(try helper.render(e), try helper.render(e, time: 2))
        let unshaded = try helper.render(e)
        e.shadingAmount = 0.6
        let shade = try helper.render(e)
        XCTAssertNotEqual(unshaded, shade)
        e.shadingDirection = 180
        XCTAssertNotEqual(shade, try helper.render(e))
        e.brightness = 0.25
        let half = try helper.render(e)
        e.brightness = 0.5
        let whole = try helper.render(e)
        for i in stride(from: 0, to: half.count, by: 4) {
            XCTAssertEqual(half[i + 3], whole[i + 3])
            XCTAssertLessThanOrEqual(abs(Int(half[i]) * 2 - Int(whole[i])), 2)
        }
        e.secondaryInfluence = 0.7
        for time in [1e12, Double.greatestFiniteMagnitude] {
            XCTAssertEqual(try helper.render(e, time: time), try helper.render(e, time: time))
        }
    }
    func testNativeSoftnessDocumentAndRasterParity() async throws {
        let source = WSSCloudsFixtureTests().fixture.deletingLastPathComponent()
            .appendingPathComponent("WSS-Clouds-Storm")
        let item = try WallpaperImporter.resolve(source)
        let r = try await WSSStaticPreparation.shared.prepare(item)
        guard case .image(let image) = r.scene.layers[0], case .clouds(let e) = image.effects[0]
        else { return XCTFail("clouds") }
        XCTAssertEqual(e.softness, 0.9)
        let helper = WSSCloudsTests()
        let a = try helper.render(r, time: 4, width: 960, height: 540).0
        let b = try helper.render(r, time: 4, width: 1920, height: 1080).0
        var error = 0.0
        for y in stride(from: 8, to: 532, by: 8) {
            for x in stride(from: 8, to: 952, by: 8) {
                error += abs(Double(a[(y * 960 + x) * 4]) - Double(b[(y * 2 * 1920 + x * 2) * 4]))
            }
        }
        XCTAssertLessThan(error / Double(66 * 118), 2)
        var json =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: source.appendingPathComponent("scene.wss.json")))
            as! [String: Any]
        var layers = json["layers"] as! [[String: Any]]
        var effects = layers[0]["effects"] as! [[String: Any]]
        for bad: Any in [NSNull(), 2, "soft"] {
            effects[0]["softness"] = bad
            layers[0]["effects"] = effects
            json["layers"] = layers
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    WSSSceneDocumentV1.self, from: JSONSerialization.data(withJSONObject: json)))
        }
        if let path = ProcessInfo.processInfo.environment["AMBIENT_CLOUDS_STORM_QA"] {
            let folder = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for t in [0.0, 2, 4] {
                try NativeImageTestWriter().save(
                    try helper.render(r, time: t, width: 1920, height: 1080).0, width: 1920,
                    height: 1080, to: folder.appendingPathComponent("storm-t\(Int(t)).png"))
            }
        }
    }
}
