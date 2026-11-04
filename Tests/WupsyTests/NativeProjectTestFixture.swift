import XCTest

@testable import Wupsy

final class NativeProjectTestFixture: XCTestCase {
    let helper = WSSNativeSceneTests()
    var root: URL { helper.root }
    override func setUpWithError() throws { try helper.setUpWithError() }
    override func tearDownWithError() throws { try helper.tearDownWithError() }
    func item() throws -> Wallpaper {
        try WallpaperImporter.resolve(helper.fixture())
    }
    func project(_ item: Wallpaper) throws -> URL { URL(fileURLWithPath: item.root) }
    func snapshot(_ path: URL) throws -> [String: Data] { try ManagedLibraryTests().snapshot(path) }
}
