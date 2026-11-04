import MetalKit
import XCTest

@testable import Wupsy

final class WSSVectorFieldRegressionTests: XCTestCase {
    // Optional cross-revision capture: compare raw GPU bytes, never update repository goldens.
    func testCrossRevisionFrames() throws {
        guard let directory = ProcessInfo.processInfo.environment["AMBIENT_VECTOR_REGRESSION"]
        else {
            throw XCTSkip("Set AMBIENT_VECTOR_REGRESSION for cross-revision captures")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let device = try WSSStaticTests().device()
        let helper = WSSRippleChainTests()
        var hashes: [String: String] = [:]
        func capture(_ name: String, _ scene: WSSScene, _ assets: any WSSImageAssetSource) throws {
            let resources = try WSSStaticResources(scene: scene, assets: assets, device: device)
            let context = WSSRippleRenderContext(device: device)
            for time in [0.0, 0.25, 1, 2, 8] {
                let bytes = try helper.render(
                    resources, context: context, time: time, width: 960, height: 540
                ).0
                hashes["\(name)/\(time)"] = NativeTestData.digest(bytes)
            }
        }
        for name in [
            "WSS-Flow-v1", "WSS-Flow-Ripple-v1", "WSS-Ripple-v1",
            "WSS-Ripple-Chain-v1", "WSS-Rain-v1",
        ] {
            let folder = root.appendingPathComponent("Test-Wallpaper/" + name)
            let scene = try WSSSceneDocumentV1.load(
                entry: folder.appendingPathComponent("scene.wss.json"), root: folder
            ).scene()
            try capture(name, scene, WSSNativeAssets(root: folder))
        }
        try capture("static", helper.scene([]), helper.assets())
        let out = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: hashes, options: [.sortedKeys, .prettyPrinted])
            .write(to: out.appendingPathComponent("frames.json"))
        if let baseline = ProcessInfo.processInfo.environment["AMBIENT_VECTOR_BASELINE"] {
            let previous = try JSONDecoder().decode(
                [String: String].self, from: Data(contentsOf: URL(fileURLWithPath: baseline)))
            XCTAssertEqual(hashes, previous)
        }
    }
}
