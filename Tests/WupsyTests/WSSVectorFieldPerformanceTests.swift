import MetalKit
import XCTest

@testable import Wupsy

final class WSSVectorFieldPerformanceTests: XCTestCase {
    // Opt-in diagnostic: compare the same machine/load, not a flaky absolute time limit.
    func testNativeEncodingDecodingAndDeduplicatedUploadCost() throws {
        guard ProcessInfo.processInfo.environment["WUPSY_VECTOR_PERF"] == "1" else {
            throw XCTSkip("Set WUPSY_VECTOR_PERF=1 for native field diagnostics")
        }
        let device = try WSSStaticTests().device()
        func measure<T>(_ work: () throws -> T) rethrows -> (T, Double) {
            let begin = ProcessInfo.processInfo.systemUptime
            let result = try work()
            return (result, (ProcessInfo.processInfo.systemUptime - begin) * 1000)
        }
        for (width, height, covered) in [(960, 540, false), (1920, 1080, true)] {
            let pair =
                (UInt32(Float16(0.25).bitPattern)
                | UInt32(Float16(-0.5).bitPattern) << 16).littleEndian
            let vectors = Array(repeating: pair, count: width * height).withUnsafeBytes { Data($0) }
            let field = WSSVectorFieldAsset(
                width: width, height: height, vectors: vectors,
                coverage: covered ? Data(repeating: 128, count: width * height) : nil,
                isNeutral: false)
            let id = WSSAssetID(value: "native-diagnostic")
            var encodeTimes: [Double] = []
            var decodeTimes: [Double] = []
            var uploadTimes: [Double] = []
            for iteration in 0..<6 {
                let (encoded, encoding) = try measure { try field.encodedNative() }
                let (decoded, decoding) = try measure {
                    try WSSVectorFieldAsset.decodeNative(encoded)
                }
                XCTAssertEqual(decoded.vectors, field.vectors)
                XCTAssertEqual(decoded.coverage, field.coverage)
                var loads = 0
                let (resources, upload) = try measure {
                    try WSSVectorFieldResources(ids: [id, id], device: device) { _ in
                        loads += 1
                        return decoded
                    }
                }
                XCTAssertEqual(loads, 1)
                XCTAssertEqual(resources.fields.count, 1)
                let uploaded = try XCTUnwrap(resources.fields[id])
                XCTAssertEqual(uploaded.vectors.pixelFormat, .rg16Float)
                XCTAssertEqual(uploaded.vectors.width, width)
                XCTAssertEqual(uploaded.vectors.height, height)
                XCTAssertEqual(uploaded.coverage != nil, covered)
                XCTAssertEqual(
                    resources.textureBytes,
                    resources.white.allocatedSize + uploaded.vectors.allocatedSize
                        + (uploaded.coverage?.allocatedSize ?? 0))
                XCTAssertLessThanOrEqual(resources.textureBytes, WSSVectorFieldAsset.byteLimit)
                if iteration > 0 {
                    encodeTimes.append(encoding)
                    decodeTimes.append(decoding)
                    uploadTimes.append(upload)
                }
            }
            func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
            print(
                "Native vector diagnostic \(width)x\(height), coverage=\(covered), device=\(device.name), 5 measured iterations: encode \(mean(encodeTimes)) ms, decode \(mean(decodeTimes)) ms, validate/allocate/upload \(mean(uploadTimes)) ms"
            )
        }
    }
}
