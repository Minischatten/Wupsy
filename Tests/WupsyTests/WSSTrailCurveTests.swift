import CryptoKit
import MetalKit
import XCTest

@testable import Wupsy

final class WSSTrailCurveTests: XCTestCase {
    func fingerprint(_ vertices: [WSSTrailVertex]) -> String {
        var data = Data()
        for v in vertices {
            for f in [
                v.position.x, v.position.y, v.side, v.color.x, v.color.y, v.color.z, v.color.w,
            ] {
                var bits = f.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func testAcceptedDefaultGeometryAndLocalFrames() throws {
        // CPU geometry captured from d2c52e7 before this task's curve implementation.
        let accepted: [String: String] = [
            "1.0 straight": "705179ba53cfd1416407be93b1eaf819649967e7e68491a3eee2ad0a1964f468",
            "1.0 slowArc": "1be8ced1e286c0ed0f6ba33bee51fc4361ebea33436f9d19bff13e99dbb672ef",
            "1.0 quickTurn": "c98bcb80fdcb54ce671a4152b55195b3d07851521912b354b21af6586b1b35a6",
            "4.8 straight": "209fa963df0afbb04805db9c448b3f4559ecb27b549b5c35ee977a3a630461ec",
            "4.8 slowArc": "5dcf25fdd5b54af47f73660a4c4af8ff79dc40950c86930edfbd188e60a22a01",
            "4.8 quickTurn": "8eaac70115991ef1bea71dac8e838cc6fc8832348d64045a77f90d416129133a",
        ]
        for scale: Float in [1, 4.8] {
            for path in WSSTrailPrototypePath.allCases {
                let c = WSSTrailTests().configuration()
                var simulation = try WSSTrailSimulation(configuration: c)
                for i in 0...96 {
                    let t = Double(i) / 128
                    simulation.update(time: t, pointer: path.pointer(time: t) * scale)
                }
                let mesh = fingerprint(simulation.vertices(time: 0.75))
                XCTAssertEqual(mesh, accepted["\(scale) \(path.rawValue)"])
                let pixels = try WSSTrailTests().render(
                    c, path: path, time: 0.75, logicalScale: scale)
                let frame = SHA256.hash(data: Data(pixels)).map { String(format: "%02x", $0) }
                    .joined()
                print("TRAIL_COMPAT \(scale) \(path.rawValue) \(mesh) \(frame)")
            }
        }
    }
    func testKnownControlsEndpointsAndCornerValues() {
        let curve = WSSTrailCurve(
            previous: SIMD2(0, -10), start: .zero,
            end: SIMD2(10, 0), following: SIMD2(10, 10), amount: 0.15)
        XCTAssertEqual(curve.firstControl, SIMD2(1.5, 1.5))
        XCTAssertEqual(curve.secondControl, SIMD2(8.5, -1.5))
        XCTAssertEqual(curve.point(at: 0), .zero)
        XCTAssertEqual(curve.point(at: 1), SIMD2(10, 0))
        XCTAssertEqual(curve.point(at: 0.5), SIMD2(5, 0))
        XCTAssertEqual(curve.point(at: 0.25), SIMD2(1.984375, 0.421875))
        XCTAssertEqual(WSSTrailCurve.subdivisions, 5)
    }

    func testStraightDuplicateReversalAndRepeatedBoundaryPoints() {
        for amount: Float in [0, 0.15, 0.5] {
            let straight = WSSTrailCurve(
                previous: SIMD2(-10, 0), start: .zero,
                end: SIMD2(10, 0), following: SIMD2(20, 0), amount: amount)
            let duplicate = WSSTrailCurve(
                previous: SIMD2(2, 3), start: SIMD2(2, 3),
                end: SIMD2(2, 3), following: SIMD2(2, 3), amount: amount)
            let reverse = WSSTrailCurve(
                previous: SIMD2(10, 0), start: .zero,
                end: SIMD2(10, 0), following: .zero, amount: amount)
            let boundary = WSSTrailCurve(
                previous: .zero, start: .zero,
                end: SIMD2(10, 0), following: SIMD2(10, 0), amount: amount)
            for i in 0...100 {
                let t = Float(i) / 100
                let point = straight.point(at: t)
                XCTAssertEqual(point.y, 0)
                XCTAssertTrue((-0.0001...10.0001).contains(point.x))
                XCTAssertEqual(duplicate.point(at: t).x, 2, accuracy: 0.000001)
                XCTAssertEqual(duplicate.point(at: t).y, 3, accuracy: 0.000001)
                XCTAssertTrue(reverse.point(at: t).x.isFinite)
                XCTAssertTrue(boundary.point(at: t).x.isFinite)
            }
            XCTAssertEqual(reverse.firstControl, .zero)
            XCTAssertEqual(reverse.secondControl, SIMD2(10, 0))
        }
        let zero = WSSTrailCurve(
            previous: SIMD2(-20, 70), start: .zero,
            end: SIMD2(10, 0), following: SIMD2(40, -30), amount: 0)
        XCTAssertEqual(zero.point(at: 0.25), SIMD2(1.5625, 0))
    }

    func testSharedInteriorTangentsAndOvershootMeaning() {
        let a = SIMD2<Float>(0, 0)
        let p = SIMD2<Float>(10, 20)
        let q = SIMD2<Float>(20, 10)
        let d = SIMD2<Float>(30, 0)
        for k: Float in [0, 0.15, 0.5] {
            let first = WSSTrailCurve(previous: a, start: a, end: p, following: q, amount: k)
            let second = WSSTrailCurve(previous: a, start: p, end: q, following: d, amount: k)
            let outgoing = 3 * (first.end - first.secondControl)
            let incoming = 3 * (second.firstControl - second.start)
            XCTAssertEqual(outgoing.x, incoming.x, accuracy: 0.00001)
            XCTAssertEqual(outgoing.y, incoming.y, accuracy: 0.00001)
        }
        let corner = WSSTrailCurve(
            previous: SIMD2(0, -10), start: .zero,
            end: SIMD2(10, 0), following: SIMD2(10, 10), amount: 0.5)
        XCTAssertEqual(corner.point(at: 0.25).y, 1.40625)
    }

    func testDefaultValidationAndLegacyDecodeWithoutNullFallback() throws {
        let c = WSSTrailTests().configuration()
        XCTAssertEqual(c.curveSmoothing, 0.15)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
        json.removeValue(forKey: "curveSmoothing")
        XCTAssertEqual(
            try JSONDecoder().decode(
                WSSTrailConfiguration.self,
                from: JSONSerialization.data(withJSONObject: json)), c)
        for invalid: Any in [NSNull(), -0.001, 0.5001, "0.15", false] {
            json["curveSmoothing"] = invalid
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    WSSTrailConfiguration.self,
                    from: JSONSerialization.data(withJSONObject: json)))
        }
        for invalid: Float in [-0.001, 0.5001, .nan, .infinity] {
            var bad = c
            bad.curveSmoothing = invalid
            XCTAssertThrowsError(try bad.validate())
        }
        for valid: Float in [0, 0.15, 0.234567, 0.5] {
            var changed = c
            changed.curveSmoothing = valid
            try changed.validate()
            XCTAssertEqual(
                try JSONDecoder().decode(
                    WSSTrailConfiguration.self,
                    from: JSONEncoder().encode(changed)), changed)
        }
    }

    func testGeometryChangesNeverChangeSamplesAlphaColorsOrExpiry() throws {
        var base = WSSTrailTests().configuration()
        base.maxLength = 250
        var simulations: [WSSTrailSimulation] = []
        for k: Float in [0, 0.15, 0.5] {
            var c = base
            c.curveSmoothing = k
            var simulation = try WSSTrailSimulation(configuration: c)
            for i in 0...96 {
                let t = Double(i) / 128
                simulation.update(
                    time: t, pointer: WSSTrailPrototypePath.quickTurn.pointer(time: t))
            }
            simulations.append(simulation)
        }
        for time in [0.75, 0.8, 1.0, 1.5] {
            let expected = simulations[0].vertices(time: time)
            for simulation in simulations.dropFirst() {
                XCTAssertEqual(simulation.samples, simulations[0].samples)
                let vertices = simulation.vertices(time: time)
                XCTAssertEqual(vertices.map(\.color), expected.map(\.color))
                XCTAssertEqual(vertices.map(\.side), expected.map(\.side))
            }
            for k: Float in [0, 0.15, 0.5] {
                var c = base
                c.curveSmoothing = k
                XCTAssertEqual(c.alpha(age: time), base.alpha(age: time))
            }
        }
        XCTAssertNotEqual(
            fingerprint(simulations[0].vertices(time: 0.75)),
            fingerprint(simulations[2].vertices(time: 0.75)))
        for i in simulations.indices {
            simulations[i].update(time: 2, pointer: nil)
            XCTAssertTrue(simulations[i].samples.isEmpty)
            XCTAssertTrue(simulations[i].vertices(time: 2).isEmpty)
        }
    }

    func testNondefaultCurveChangesRenderedGeometryDeterministically() throws {
        var straight = WSSTrailTests().configuration()
        straight.curveSmoothing = 0
        var rounded = straight
        rounded.curveSmoothing = 0.5
        let a = try WSSTrailTests().render(straight, path: .quickTurn, time: 0.75)
        let b = try WSSTrailTests().render(rounded, path: .quickTurn, time: 0.75)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(b, try WSSTrailTests().render(rounded, path: .quickTurn, time: 0.75))
    }

}
