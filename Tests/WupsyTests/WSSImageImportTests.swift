import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import Wupsy

@MainActor final class WSSImageImportTests: XCTestCase {
    let importer = WSSImageImporter()
    func image(
        _ type: UTType = .png, width: Int = 12, height: Int = 8,
        orientation: Int = 1, alpha: CGFloat = 1
    ) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(
            CGColor(
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: [0.8, 0.2, 0.1, alpha])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(
            dest, context.makeImage()!,
            [
                kCGImagePropertyOrientation: orientation,
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "private metadata"],
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifUserComment: "private comment"
                ],
            ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }
    func testPNGAndJPEGBecomeExplicitEightBitSRGBPNG() async throws {
        for (type, ext) in [(UTType.png, "png"), (.jpeg, "jpg"), (.jpeg, "jpeg")] {
            let generation = try await importer.normalize(image(type), extension: ext)
            let bytes = try generation.read()
            let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(decoded.bitsPerComponent, 8)
            XCTAssertEqual(decoded.width, 12)
            XCTAssertEqual(decoded.height, 8)
            XCTAssertEqual(decoded.colorSpace?.name, CGColorSpace.sRGB)
            XCTAssertEqual(generation.fingerprint, WSSContentFingerprint(bytes))
            XCTAssertEqual(generation.definition.uvScale, [1, 1])
        }
    }
    func testOrientationBakedAndPrivateMetadataStripped() async throws {
        let generation = try await importer.normalize(
            image(.jpeg, orientation: 6), extension: "jpg")
        XCTAssertEqual(generation.width, 8)
        XCTAssertEqual(generation.height, 12)
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(try generation.read() as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertTrue(
            properties[kCGImagePropertyOrientation] == nil
                || properties[kCGImagePropertyOrientation] as? Int == 1)
        XCTAssertNil(
            (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[
                kCGImagePropertyTIFFArtist])
        XCTAssertNil(
            (properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[
                kCGImagePropertyExifUserComment])
    }
    func testWrongExtensionAndUnsupportedActualContentRejected() async throws {
        for (data, ext) in [
            (try image(.jpeg), "png"), (try image(), "jpg"),
            (try image(.tiff), "png"), (try image(.gif), "png"), (try image(), "heic"),
            (try image(), "gif"),
        ] {
            do {
                _ = try await importer.normalize(data, extension: ext)
                XCTFail("accepted unsupported/mismatched input")
            } catch { XCTAssertNotNil(error as? WSSImageImportError) }
        }
    }
    func testCorruptPNGAndJPEGRejected() async throws {
        for (type, ext) in [(UTType.png, "png"), (.jpeg, "jpg")] {
            let bytes = try image(type)
            do {
                _ = try await importer.normalize(Data(bytes.prefix(24)), extension: ext)
                XCTFail("accepted corrupt input")
            } catch { XCTAssertNotNil(error as? WSSImageImportError) }
        }
    }
    func testNormalizationPreservesPremultipliedColorAndAlpha() async throws {
        let generation = try await importer.normalize(image(alpha: 0.5), extension: "png")
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(try generation.read() as CFData, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        XCTAssertEqual(Int(bytes[3]), 128, accuracy: 1)
        XCTAssertEqual(Int(bytes[0]), 102, accuracy: 2)
        XCTAssertEqual(Int(bytes[1]), 26, accuracy: 2)
    }
    func testDimensionPixelAndOverflowBoundsBeforeDecode() throws {
        XCTAssertNoThrow(try WSSImageImporter.validateDimensions(8192, 1))
        XCTAssertNoThrow(try WSSImageImporter.validateDimensions(8192, 4096))
        for (w, h) in [(8193, 1), (1, 8193), (8192, 4097), (0, 1), (Int.max, Int.max)] {
            XCTAssertThrowsError(try WSSImageImporter.validateDimensions(w, h))
        }
    }
    func testInputFileSizeCheckedWithoutReadingSparsePayload() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".png")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let fd = Darwin.open(url.path, O_WRONLY)
        XCTAssertEqual(ftruncate(fd, off_t(WSSImageImporter.inputLimit + 1)), 0)
        Darwin.close(fd)
        do {
            _ = try await importer.load(url)
            XCTFail("accepted oversized file")
        } catch { XCTAssertNotNil(error as? WSSImageImportError) }
    }
    func testStagingBudgetBeforeGenerationCreation() async throws {
        do {
            _ = try await importer.normalize(image(), extension: "png", remainingBudget: 1)
            XCTFail("ignored budget")
        } catch {
            guard case WSSImageImportError.stagingBudget = error else {
                return XCTFail("wrong error")
            }
        }
    }
    func testSourceChangesCannotChangeGenerationAndNameIsAppControlled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("user-secret.png")
        try image().write(to: url)
        let generation = try await importer.load(url)
        let bytes = try generation.read()
        try Data("changed source".utf8).write(to: url)
        XCTAssertEqual(try generation.read(), bytes)
        XCTAssertFalse(generation.path.contains("user-secret"))
        XCTAssertTrue(generation.path.hasPrefix("assets/editor-"))
        let second = try await importer.normalize(image(), extension: "png")
        XCTAssertNotEqual(second.path, generation.path)
        XCTAssertEqual(second.fingerprint, generation.fingerprint)
    }
    func testTrustedMacOSTmpAliasRetainsSafeDescriptorImport() async throws {
        let url = URL(fileURLWithPath: "/tmp/wss-input-" + UUID().uuidString + ".png")
        try image().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let generation = try await importer.load(url)
        XCTAssertEqual(generation.width, 12)
        XCTAssertEqual(generation.height, 8)
    }
    func testSymlinkAndTraversalInputRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("real.png")
        let link = root.appendingPathComponent("link.png")
        try image().write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do {
            _ = try await importer.load(link)
            XCTFail("followed symlink")
        } catch {}
        XCTAssertThrowsError(try WSSAssetIO.read(root: root, path: "../real.png", limit: 1024))
    }
    func testEightThousandPixelAxisAcceptedWithoutResizing() async throws {
        let generation = try await importer.normalize(
            image(width: 8192, height: 1), extension: "png")
        XCTAssertEqual(generation.width, 8192)
        XCTAssertEqual(generation.height, 1)
    }
}
