import XCTest

@testable import Wupsy

final class WSSFailurePresentationTests: XCTestCase {
    func testManifestClassificationAndUpdateHints() throws {
        let fixture = WSSNativeSceneTests()
        let valid = fixture.document(clouds: true)
        let validLayers = try XCTUnwrap(valid["layers"] as? [[String: Any]])
        let validEffects = try XCTUnwrap(validLayers[0]["effects"] as? [[String: Any]])

        func check(
            _ bytes: Data, expected: WSSDocumentError? = nil, hint: Bool,
            file: StaticString = #filePath, line: UInt = #line
        ) {
            XCTAssertThrowsError(try WSSSceneDocumentV1.decode(data: bytes), file: file, line: line)
            {
                error in
                if let expected {
                    XCTAssertEqual(error as? WSSDocumentError, expected, file: file, line: line)
                }
                for (language, phrase) in [("en", "newer version"), ("de", "neueren Version")] {
                    let presentation = WSSFailurePresentation(error, language: language)
                    let text = presentation?.explanation ?? ""
                    XCTAssertFalse(text.isEmpty, file: file, line: line)
                    XCTAssertEqual(
                        text.contains(phrase) || text.contains("neuere Version"), hint,
                        file: file, line: line)
                }
            }
        }

        for extra in [false, true] {
            var document = valid
            document["version"] = 2
            if extra { document["futureRoot"] = true }
            check(
                try JSONSerialization.data(withJSONObject: document), expected: .version(2),
                hint: true)
        }

        var document = valid
        var layers = validLayers
        var effects = validEffects
        effects[0]["futureField"] = 1
        layers[0]["effects"] = effects
        document["layers"] = layers
        check(
            try JSONSerialization.data(withJSONObject: document),
            expected: .unknownFields(["futureField"], path: "$.layers[0].effects[0]"), hint: true)
        effects[0]["type"] = "futureEffect"
        layers[0]["effects"] = effects
        document["layers"] = layers
        check(
            try JSONSerialization.data(withJSONObject: document),
            expected: .effect("futureEffect", path: "$.layers[0].effects[0]"), hint: true)
        layers[0]["type"] = "futureLayer"
        document["layers"] = layers
        check(
            try JSONSerialization.data(withJSONObject: document),
            expected: .unknownLayer("futureLayer", path: "$.layers[0]"), hint: true)

        check(Data("{ invalid".utf8), hint: false)
        document = valid
        document["canvas"] = nil
        check(try JSONSerialization.data(withJSONObject: document), hint: false)
        document = valid
        layers = validLayers
        effects = validEffects
        effects[0]["density"] = 5
        layers[0]["effects"] = effects
        document["layers"] = layers
        check(try JSONSerialization.data(withJSONObject: document), hint: false)
        XCTAssertNoThrow(
            try WSSSceneDocumentV1.decode(data: JSONSerialization.data(withJSONObject: valid)))
    }

    func testResourceAndOperationalFailuresDoNotSuggestAnUpdate() throws {
        let source = URL(fileURLWithPath: "/sample/scene.wss.json")
        let errors: [Error] = [
            WSSDocumentError.version(0), WSSDocumentError.missingAsset("assets/base.png"),
            WSSDocumentError.invalidResource("PNG asset"), WSSDocumentError.unsafePath("../asset"),
            WSSSceneError.unsupported("mask pixel layout"), WSSSceneError.decodedImageBudget,
            WSSMaskError.budget, WSSSceneError.metalUnavailable,
            WSSSceneError.preparationFailed("Metal queue"),
            WallpaperImportDiagnostic(.storage, detail: "disk full"),
            WallpaperImportDiagnostic(.rollback, detail: "Import: primary; rollback: secondary"),
            WallpaperImportDiagnostic(.cleanup, detail: "Import: primary; cleanup: secondary"),
        ]
        for error in errors {
            for (language, phrase) in [("en", "newer version"), ("de", "neuere")] {
                let report = ImportFailurePresentation(
                    source: source, error: error, language: language)
                XCTAssertFalse(report.explanation.contains(phrase))
                if let cause = WSSFailurePresentation(error, language: language) {
                    XCTAssertEqual(report.explanation, cause.explanation)
                    XCTAssertTrue(
                        EditorErrorPresentation.message(error, language: language)
                            .contains(cause.explanation) || error is WSSMaskError)
                }
            }
        }
        for error in errors.suffix(2) {
            let report = ImportFailurePresentation(source: source, error: error, language: "en")
            XCTAssertTrue(report.copyText.contains("primary"))
            XCTAssertTrue(report.copyText.contains("secondary"))
        }
    }

    func testFailedNativeImportsPreserveTypedManifestAndResourceCauses() async throws {
        let helper = ManagedLibraryTests()
        try helper.setUpWithError()
        defer { try? helper.tearDownWithError() }
        let source = try helper.nativeSource()
        let manifest = try Data(contentsOf: source)
        let asset = source.deletingLastPathComponent().appendingPathComponent("assets/base.png")
        let png = try Data(contentsOf: asset)

        func failure() async -> WSSDocumentError? {
            do {
                _ = try await helper.store.importWallpaper(source, existing: [])
                XCTFail("Expected failure before publication")
                return nil
            } catch {
                return error as? WSSDocumentError
            }
        }

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        json["version"] = 2
        json["futureRoot"] = true
        try JSONSerialization.data(withJSONObject: json).write(to: source)
        let version = await failure()
        XCTAssertEqual(version, .version(2))

        try manifest.write(to: source)
        try FileManager.default.removeItem(at: asset)
        let missing = await failure()
        XCTAssertEqual(missing, .missingAsset("assets/base.png"))

        try Data([0, 1, 2]).write(to: asset)
        let corrupt = await failure()
        XCTAssertEqual(corrupt, .invalidResource("PNG asset: assets/base.png"))

        var layers = try XCTUnwrap(json["layers"] as? [[String: Any]])
        layers[0]["image"] = "assets/base.unsupported"
        json["layers"] = layers
        json["version"] = 1
        json["futureRoot"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: source)
        let unsupported = await failure()
        XCTAssertEqual(
            unsupported, .invalidResource("only PNG assets supported: assets/base.unsupported"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: helper.store.storage.path))
        try manifest.write(to: source)
        try png.write(to: asset)
        _ = try await helper.store.importWallpaper(source, existing: [])
    }
}
