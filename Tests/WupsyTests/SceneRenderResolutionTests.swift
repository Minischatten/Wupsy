import MetalKit
import XCTest

@testable import Wupsy

final class SceneRenderResolutionTests: XCTestCase {
    func testDensityAndProfileLimits() {
        let bounds = CGSize(width: 3200, height: 1800)
        let backing = CGSize(width: 6400, height: 3600)
        for (profile, standard, hiDPI): (QualityProfile, CGSize, CGSize) in [
            (.original, bounds, backing),
            (.balanced, CGSize(width: 2560, height: 1440), CGSize(width: 2560, height: 1440)),
            (.eco, CGSize(width: 1280, height: 720), CGSize(width: 1280, height: 720)),
        ] {
            XCTAssertEqual(
                SceneRenderResolution.standard.drawableSize(
                    bounds: bounds, backing: backing, maxDimension: profile.maxDimension), standard)
            XCTAssertEqual(
                SceneRenderResolution.hiDPI.drawableSize(
                    bounds: bounds, backing: backing, maxDimension: profile.maxDimension), hiDPI)
        }
        let one = CGSize(width: 1920, height: 1080)
        for mode in SceneRenderResolution.allCases {
            XCTAssertEqual(mode.drawableSize(bounds: one, backing: one, maxDimension: 8192), one)
        }
        XCTAssertEqual(
            SceneRenderResolution.hiDPI.drawableSize(
                bounds: CGSize(width: 1200, height: 800),
                backing: CGSize(width: 1800, height: 1200), maxDimension: 8192),
            CGSize(width: 1800, height: 1200))
        XCTAssertEqual(
            SceneRenderResolution.hiDPI.drawableSize(
                bounds: bounds, backing: CGSize(width: 12800, height: 7200), maxDimension: 8192),
            CGSize(width: 8192, height: 4608))
        XCTAssertEqual(
            SceneRenderResolution.standard.drawableSize(
                bounds: .zero, backing: backing, maxDimension: 8192), CGSize(width: 1, height: 1))
        XCTAssertEqual(QualityProfile.eco.fps, 24)
        XCTAssertEqual(QualityProfile.balanced.fps, 30)
        XCTAssertEqual(QualityProfile.original.fps, 60)
    }
    @MainActor func testPersistenceAndIndependentSettings() throws {
        let name = "WupsyResolutionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        let first = Library(storage: storage, defaults: defaults)
        defer { first.stop() }
        XCTAssertEqual(first.sceneRenderResolution, .hiDPI)
        XCTAssertEqual(first.profile, .original)
        XCTAssertEqual(first.sceneFPS, 30)
        first.sceneRenderResolution = .standard
        XCTAssertEqual(defaults.string(forKey: SceneRenderResolution.preferenceKey), "standard")
        let second = Library(storage: storage, defaults: defaults)
        defer { second.stop() }
        XCTAssertEqual(second.sceneRenderResolution, .standard)
        XCTAssertEqual(second.profile, .original)
        XCTAssertEqual(second.sceneFPS, 30)
        defaults.set("unknown", forKey: SceneRenderResolution.preferenceKey)
        XCTAssertEqual(SceneRenderResolution.stored(in: defaults), .hiDPI)
    }
}
