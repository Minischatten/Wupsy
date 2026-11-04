import AppKit
import XCTest

@testable import Wupsy

@MainActor final class WSSPNGVectorFieldEditingTests: XCTestCase {
    var fixture: WSSDirectionCanvasTests!
    var doc: WSSEditorDocument { fixture.doc }
    var session: WSSDirectionCanvasSession { doc.directionCanvas }
    var root: URL { doc.project.handle.root }
    var originalPNG: Data!
    override func setUp() async throws {
        fixture = WSSDirectionCanvasTests()
        try await fixture.setUp()
        doc.close()
        var pixels = Data()
        for _ in 0..<64 {
            for x in 0..<64 {
                pixels.append(contentsOf: [128, 128, 0, x < 16 ? 0 : (x < 32 ? 128 : 255)])
            }
        }
        originalPNG = try WSSNativeSceneTests().png(Array(pixels), width: 64, height: 64)
        try originalPNG.write(to: root.appendingPathComponent("assets/a.png"))
        let second = try WSSNativeSceneTests().png(
            Array(repeating: [UInt8(0), 255, 0, 255], count: 64 * 64).flatMap { $0 }, width: 64,
            height: 64)
        try second.write(to: root.appendingPathComponent("assets/b.png"))
        try await fixture.reload(pngModel(doc.state.workingModel))
        _ = try fixture.helper.select()
    }
    override func tearDown() async throws {
        try await fixture.tearDown()
        fixture = nil
        originalPNG = nil
    }
    func pngModel(_ model: WSSSceneDocumentV1) throws -> WSSSceneDocumentV1 {
        let text = try XCTUnwrap(String(data: model.encoded(), encoding: .utf8))
            .replacingOccurrences(of: WSSVectorFieldAsset.fileFormat, with: "wss-flow-rgba8")
            .replacingOccurrences(of: "a.wssvf", with: "a.png")
            .replacingOccurrences(of: "b.wssvf", with: "b.png")
        return try JSONDecoder().decode(WSSSceneDocumentV1.self, from: Data(text.utf8))
    }
    func paths() throws -> [String] { try fixture.helper.fields(doc.state.workingModel) }
    func stroke(reverse: Bool = false, outside: Bool = false) async throws {
        try await fixture.enable()
        session.setDiameter(20)
        session.setMagnitude(reverse ? 0.35 : 1)
        let first = SIMD2<Double>(reverse ? 0.8 : 0.2, 0.5)
        let last = SIMD2<Double>(outside ? 1.5 : (reverse ? 0.2 : 0.8), 0.5)
        XCTAssertTrue(session.begin(try fixture.scene(first), erase: false))
        session.finish(try fixture.scene(last))
        await session.waitForFinish()
        await session.waitForLoad()
        await doc.waitForPreview()
        XCTAssertNil(session.error)
    }
    func testEveryPNGComponentUsesRuntimeHalfMappingAndCoverageWithoutBias() throws {
        var pixels: [UInt8] = []
        for value in 0...255 { pixels += [UInt8(value), UInt8(255 - value), 0, UInt8(value)] }
        let data = try WSSNativeSceneTests().png(pixels, width: 256, height: 1)
        try WSSVectorFieldPreparation.validatePNGWorkingData(data)
        let field = try WSSVectorFieldAsset.decode(data)
        XCTAssertEqual(field.width, 256)
        XCTAssertEqual(field.height, 1)
        XCTAssertEqual(field.coverage, Data(0...255))
        field.vectors.withUnsafeBytes { raw in
            for index in 0..<256 {
                for axis in 0..<2 {
                    let byte = axis == 0 ? index : 255 - index
                    let expected = Float16(Float(byte - 128) / (byte < 128 ? 128 : 127))
                    XCTAssertEqual(
                        raw.loadUnaligned(fromByteOffset: index * 4 + axis * 2, as: UInt16.self)
                            .littleEndian, expected.bitPattern)
                }
            }
        }
        let opaque = try WSSVectorFieldAsset.decode(
            WSSNativeSceneTests().png([128, 128, 0, 255], width: 1, height: 1))
        XCTAssertNil(opaque.coverage)
        XCTAssertTrue(opaque.isNeutral)
        XCTAssertEqual(opaque.vectors, Data(repeating: 0, count: 4))
        XCTAssertEqual(
            try WSSVectorFieldAsset.decodeNative(field.encodedNative()).vectors, field.vectors)
    }
    func testSelectionOverlaySettingsClickCancelAndCloseNeverPublishConversion() async throws {
        let model = doc.state.workingModel
        let disk = try fixture.helper.helper.helper.snapshot()
        try await fixture.enable()
        XCTAssertEqual(session.samples.count, 3)
        XCTAssertTrue(session.samples.allSatisfy { $0.vector == .zero })
        session.setDiameter(30)
        session.setMagnitude(0.35)
        session.setOperation(.neutralize)
        session.setOperation(.direction)
        let point = try fixture.scene(SIMD2(0.4, 0.5))
        XCTAssertTrue(session.begin(point, erase: false))
        session.finish(point)
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertTrue(session.begin(point, erase: false))
        session.append(try fixture.scene(SIMD2(0.8, 0.5)))
        await session.waitForFeedback()
        XCTAssertTrue(session.samples.contains { $0.vector.x > 0 })
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertTrue(session.escape())
        XCTAssertFalse(session.escape())
        XCTAssertTrue(session.brushEnabled)
        XCTAssertFalse(session.requiresExplicitActivation)
        try await fixture.enable()
        XCTAssertTrue(session.begin(point, erase: false))
        session.append(try fixture.scene(SIMD2(0.8, 0.5)))
        doc.select(.layer(doc.identity.layers[0].id))
        await session.waitForFeedback()
        XCTAssertEqual(doc.state.workingModel, model)
        doc.close()
        XCTAssertEqual(try fixture.helper.helper.helper.snapshot(), disk)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
    }
    func testFirstChangedEditIsStageLocalOneUndoAndRedoUsesSameGeneration() async throws {
        let before = doc.state.workingModel
        let preview = doc.previewResources
        let beforeFrame = try WSSEditorLivePreviewTests().frame(
            XCTUnwrap(preview), time: 0.4, width: 128)
        try await stroke()
        XCTAssertNotEqual(
            try WSSEditorLivePreviewTests().frame(
                XCTUnwrap(doc.previewResources), time: 0.4, width: 128), beforeFrame)
        let fields = try paths()
        XCTAssertEqual(Array(fields.prefix(2)), ["assets/a.png", "assets/b.png"])
        XCTAssertTrue(fields[2].hasSuffix(".wssvf"))
        XCTAssertEqual(doc.state.sessionAssets.count, 1)
        let generation = try XCTUnwrap(doc.state.sessionAssets[fields[2]])
        let source = try WSSVectorFieldAsset.decode(originalPNG)
        let painted = try WSSVectorFieldAsset.decodeNative(generation.read())
        XCTAssertEqual(painted.width, 64)
        XCTAssertEqual(painted.height, 64)
        XCTAssertEqual(painted.coverage, source.coverage)
        XCTAssertNotEqual(painted.vectors, source.vectors)
        XCTAssertFalse(doc.previewResources === preview)
        let after = doc.state.workingModel
        let samples = session.samples
        doc.undoManager.undo()
        await session.waitForLoad()
        await doc.waitForPreview()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertFalse(doc.isDirty)
        doc.undoManager.redo()
        await session.waitForLoad()
        await doc.waitForPreview()
        XCTAssertEqual(doc.state.workingModel, after)
        XCTAssertEqual(session.samples, samples)
        XCTAssertTrue(doc.state.sessionAssets[fields[2]] === generation)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("assets/a.png")), originalPNG)
    }
    func testPNGAndPureNativeConversionAreFrameIdenticalForEveryConsumer() async throws {
        var pixels: [UInt8] = []
        let directions: [[UInt8]] = [
            [255, 128, 0, 255], [0, 255, 0, 128], [128, 0, 0, 0], [255, 255, 0, 255],
        ]
        for y in 0..<64 {
            for x in 0..<64 { pixels += directions[(x / 16 + y / 16) % directions.count] }
        }
        let pngBytes = try WSSNativeSceneTests().png(pixels, width: 64, height: 64)
        try pngBytes.write(to: root.appendingPathComponent("assets/a.png"))
        let field = try WSSVectorFieldAsset.decode(pngBytes)
        try field.encodedNative().write(to: root.appendingPathComponent("assets/converted.wssvf"))
        for kind in ["flow"] {
            var model = doc.state.workingModel
            guard case .image(var image) = model.layers[0].content else { return XCTFail() }
            image.effects = [try fixture.helper.effect(kind, "a")]
            model.layers[0].content = .image(image)
            let png = try pngModel(model)
            let text = try XCTUnwrap(String(data: png.encoded(), encoding: .utf8))
                .replacingOccurrences(of: "wss-flow-rgba8", with: WSSVectorFieldAsset.fileFormat)
                .replacingOccurrences(of: "a.png", with: "converted.wssvf")
            let native = try JSONDecoder().decode(WSSSceneDocumentV1.self, from: Data(text.utf8))
            let device = try WSSStaticTests().device()
            let a = try WSSStaticResources(
                scene: png.scene(), assets: png.assetSource(root: root), device: device)
            let b = try WSSStaticResources(
                scene: native.scene(), assets: native.assetSource(root: root), device: device)
            for time in [0.0, 0.35, 1.2] {
                XCTAssertEqual(
                    try WSSEditorLivePreviewTests().frame(a, time: time, width: 128),
                    try WSSEditorLivePreviewTests().frame(b, time: time, width: 128), kind)
            }
        }
    }
    func testSaveReopenKeepsOriginalPNGAndSaveAsIsPhysicallyIndependent() async throws {
        try await stroke(outside: true)
        let pendingPath = try paths()[2]
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(pendingPath).path))
        let copy = try await fixture.helper.store.saveWSSAs(
            .init(
                document: doc.state.workingModel, state: doc.state, source: doc.project.handle,
                name: "PNG Edited Copy"))
        XCTAssertTrue(doc.isDirty)
        let savedSuccessfully = await doc.save()
        XCTAssertTrue(savedSuccessfully)
        let path = try paths()[2]
        let reopened = try await WSSEditorProjectLoader().load(fixture.helper.helper.item)
        XCTAssertEqual(reopened.document, doc.state.workingModel)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("assets/a.png")), originalPNG)
        let oldFile = root.appendingPathComponent(path)
        let newFile = copy.project.handle.root.appendingPathComponent(path)
        XCTAssertEqual(try Data(contentsOf: oldFile), try Data(contentsOf: newFile))
        XCTAssertNotEqual(
            try FileManager.default.attributesOfItem(atPath: oldFile.path)[.systemFileNumber]
                as? NSNumber,
            try FileManager.default.attributesOfItem(atPath: newFile.path)[.systemFileNumber]
                as? NSNumber)
        let oldRoot = root
        doc.close()
        try FileManager.default.removeItem(at: oldRoot)
        let independent = try await WSSEditorProjectLoader().load(copy.project.handle.wallpaper)
        _ = try WSSEditorLivePreviewTests().frame(independent.resources, time: 0.4, width: 128)
    }
    func testRevertRestoresPNGBeforeSaveAndNativeAfterSave() async throws {
        let png = doc.state.workingModel
        try await stroke()
        doc.revert()
        await session.waitForLoad()
        await doc.waitForPreview()
        XCTAssertEqual(doc.state.workingModel, png)
        XCTAssertTrue(session.samples.allSatisfy { $0.vector == .zero })
        try await stroke()
        let savedSuccessfully = await doc.save()
        XCTAssertTrue(savedSuccessfully)
        let saved = doc.state.workingModel
        let samples = session.samples
        try await stroke(reverse: true)
        doc.revert()
        await session.waitForLoad()
        await doc.waitForPreview()
        XCTAssertEqual(doc.state.workingModel, saved)
        XCTAssertEqual(session.samples, samples)
    }
    func testPNGReentryPreservesFragmentsAndOutsideMouseUpFinalizesOneStroke() async throws {
        try await fixture.enable()
        session.setDiameter(8)
        let path: [SIMD2<Double>] = [
            SIMD2(0.5, 0.25), SIMD2(-0.5, 0.25), SIMD2(-0.5, 0.75), SIMD2(0.5, 0.75),
            SIMD2(1.5, 0.75),
        ]
        let before = doc.state.workingModel
        XCTAssertTrue(session.begin(try fixture.scene(path[0]), erase: false))
        for uv in path.dropFirst().dropLast() { session.append(try fixture.scene(uv)) }
        await session.waitForFeedback()
        XCTAssertEqual(doc.state.workingModel, before)
        session.finish(try fixture.scene(path.last!))
        await session.waitForFinish()
        await session.waitForLoad()
        let field = try WSSVectorFieldAsset.decodeNative(
            XCTUnwrap(doc.state.sessionAssets[paths()[2]]).read())
        let values = WSSDirectionSampling.samples(
            field, at: [SIMD2(0.04, 0.25), SIMD2(0.04, 0.75), SIMD2(0.0078125, 0.5)])
        XCTAssertLessThan(values[0].vector.x, -0.9)
        XCTAssertGreaterThan(values[1].vector.x, 0.9)
        XCTAssertEqual(values[2].vector, .zero)
        XCTAssertEqual(doc.state.sessionAssets.count, 1)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testInvalidDimensionsDecodeAndWorkingBudgetFailBeforeImageAllocation() throws {
        var data = originalPNG!
        for size: UInt32 in [8193, 8192, 2500] {
            var invalid = data
            func set(_ value: UInt32, at offset: Int) {
                var word = value.bigEndian
                withUnsafeBytes(of: &word) {
                    invalid.replaceSubrange(offset..<(offset + 4), with: $0)
                }
            }
            set(size, at: 16)
            set(size == 2500 ? 2000 : size, at: 20)
            XCTAssertThrowsError(try WSSVectorFieldPreparation.validatePNGWorkingData(invalid))
        }
        data[24] = 16
        XCTAssertThrowsError(try WSSVectorFieldAsset.decode(data))
        XCTAssertThrowsError(try WSSVectorFieldAsset.decode(Data([1, 2, 3])))
        XCTAssertThrowsError(
            try WSSVectorFieldAsset.rgba(width: 1, height: 1, pixels: Data([128, 128, 1, 255])))
        XCTAssertThrowsError(
            try WSSEditorAssetGeneration.vectorField(
                WSSVectorFieldAsset.decode(originalPNG), remainingBudget: 1))
        XCTAssertFalse(doc.isDirty)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
    }
    func testExternalPNGMutationMissingAndSymlinkNeverAdoptOrRepair() async throws {
        try await fixture.enable()
        let before = doc.state.workingModel
        let path = root.appendingPathComponent("assets/a.png")
        try FileManager.default.removeItem(at: path)
        for mode in 0..<3 {
            if mode == 1 { try Data("bad PNG".utf8).write(to: path) }
            if mode == 2 {
                try FileManager.default.createSymbolicLink(
                    at: path, withDestinationURL: root.appendingPathComponent("assets/b.png"))
            }
            let point = try fixture.scene(SIMD2(0.2, 0.5))
            XCTAssertTrue(session.begin(point, erase: false))
            session.finish(try fixture.scene(SIMD2(0.8, 0.5)))
            await session.waitForFinish()
            await session.waitForLoad()
            XCTAssertEqual(doc.state.workingModel, before)
            XCTAssertTrue(doc.state.sessionAssets.isEmpty)
            XCTAssertNotNil(session.error)
            if mode < 2 {
                if FileManager.default.fileExists(atPath: path.path) {
                    try FileManager.default.removeItem(at: path)
                }
                try originalPNG.write(to: path)
                session.setEnabled(false)
                try await fixture.enable()
                try FileManager.default.removeItem(at: path)
            }
        }
        for path in ["../a.png", "/a.png", "assets/../../a.png", "assets\\a.png"] {
            XCTAssertThrowsError(try WSSNativeAssets.validatePath(path))
        }
    }
    func testNeutralizeNoOpAndCloseDuringPNGStrokeDoNotConvert() async throws {
        let before = doc.state.workingModel
        try await fixture.enable()
        session.setOperation(.neutralize)
        let point = try fixture.scene(SIMD2(0.5, 0.5))
        XCTAssertTrue(session.begin(point, erase: false))
        session.finish(point)
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertFalse(doc.isDirty)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
        session.setOperation(.direction)
        XCTAssertTrue(session.begin(point, erase: false))
        session.append(try fixture.scene(SIMD2(0.8, 0.5)))
        doc.close()
        await session.waitForFeedback()
        XCTAssertEqual(doc.state.workingModel, before)
        XCTAssertTrue(doc.state.sessionAssets.isEmpty)
    }
}
