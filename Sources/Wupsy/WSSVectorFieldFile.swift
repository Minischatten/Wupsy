import Foundation

// Own lossless WSS data container. No source-engine assets or color-image decoding.
// 32-byte header: magic[8], then LE UInt32 version, width, height,
// coverageWidth, coverageHeight, reserved=0. RG16F-LE followed by optional R8.
extension WSSVectorFieldAsset {
    static let fileFormat = "wss-vector-field-f16"
    static let fileVersion = 1
    static let fileHeaderBytes = 32
    private static var fileMagic: Data { Data("WSSVF16\0".utf8) }

    func encodedNative() throws -> Data {
        try validate()
        var data = Self.fileMagic
        for value in [
            Self.fileVersion, width, height,
            coverage == nil ? 0 : width, coverage == nil ? 0 : height, 0,
        ] {
            var word = UInt32(value).littleEndian
            withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
        }
        data.append(vectors)
        if let coverage { data.append(coverage) }
        return data
    }

    static func decodeNative(_ input: Data) throws -> Self {
        let data = Data(input)  // Rebase slices before indexed header/payload access.
        guard data.count >= fileHeaderBytes, data.count <= byteLimit + fileHeaderBytes,
            data.prefix(8) == fileMagic
        else {
            throw WSSSceneError.invalid("native vector field header/size")
        }
        func word(_ offset: Int) -> Int {
            data.withUnsafeBytes {
                Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
        }
        guard word(8) == fileVersion else {
            throw WSSSceneError.unsupported("native vector field version")
        }
        let width = word(12)
        let height = word(16)
        let cw = word(20)
        let ch = word(24)
        guard (1...8192).contains(width), (1...8192).contains(height),
            width * height <= byteLimit / 5, word(28) == 0,
            (cw == 0 && ch == 0) || (cw == width && ch == height)
        else {
            throw WSSSceneError.invalid("native vector field dimensions/coverage/reserved")
        }
        let end = fileHeaderBytes + width * height * 4
        let expected = end + (cw == 0 ? 0 : width * height)
        guard data.count == expected else {
            throw WSSSceneError.invalid("native vector field payload length")
        }
        let value = Self(
            width: width, height: height, vectors: Data(data[fileHeaderBytes..<end]),
            coverage: cw == 0 ? nil : Data(data[end..<expected]), isNeutral: false)
        let neutral = try value.validatedNeutrality()
        return Self(
            width: width, height: height, vectors: value.vectors,
            coverage: value.coverage, isNeutral: neutral)
    }
}

extension WSSNativeAssets {
    // The caller owns a native project and creates its asset directories first.
    // Validate before touching disk; never follow a symlink or create arbitrary parents.
    func writeVectorField(_ field: WSSVectorFieldAsset, to path: String) throws {
        try Self.validatePath(path)
        guard path.hasSuffix(".wssvf") else {
            throw WSSDocumentError.invalid("native vector field requires .wssvf")
        }
        let bytes = try field.encodedNative()
        let directory = root.standardizedFileURL
        let file = directory.appendingPathComponent(path)
        do {
            try ManagedWallpaperStore.checkPath(directory)
            try ManagedWallpaperStore.checkPath(file)
            let parent = file.deletingLastPathComponent()
            try ManagedWallpaperStore.checkPath(parent)
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                try parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            else {
                throw WSSDocumentError.invalid("native vector field parent directory")
            }
            try bytes.write(to: file, options: .atomic)
        } catch let error as WSSDocumentError { throw error } catch {
            throw WSSDocumentError.invalid("cannot safely write native vector field: " + path)
        }
    }
}
