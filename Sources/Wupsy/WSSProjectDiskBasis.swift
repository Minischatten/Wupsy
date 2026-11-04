import CryptoKit
import Foundation

enum WSSSaveError: LocalizedError, Equatable {
    case validationFailed(String)
    case externalConflict
    case targetDisappeared
    case writeFailed(String)
    case commitFailed(String)
    var errorDescription: String? {
        switch self {
        case .validationFailed(let detail): return "WSS save validation failed: " + detail
        case .externalConflict:
            return "The WSS project changed outside this editor. Reload before saving."
        case .targetDisappeared:
            return "The managed WSS save target no longer exists or its ownership changed."
        case .writeFailed(let detail): return "Could not write the WSS save candidate: " + detail
        case .commitFailed(let detail): return "Could not commit the WSS manifest: " + detail
        }
    }
}

struct WSSContentFingerprint: Equatable {
    let byteCount: Int
    let sha256: Data
    init(_ bytes: Data) {
        byteCount = bytes.count
        sha256 = Data(SHA256.hash(data: bytes))
    }
}

struct WSSProjectDiskBasis: Equatable {
    struct Identity: Equatable {
        let wallpaperID: UUID
        let managed: ManagedWallpaperLocation?
        let draftToken: UUID?
        let source: SceneSource?
        let root: String
        let device: UInt64
        let inode: UInt64
        init(_ handle: WSSProjectHandle) throws {
            if handle.origin == .draft {
                guard let owner = handle.draftOwner, handle.wallpaper.managed == nil,
                    owner.wallpaperID == handle.id, owner.root == handle.root
                else {
                    throw WSSSaveError.targetDisappeared
                }
                try owner.verify()
                draftToken = owner.token
            } else {
                guard handle.wallpaper.managed != nil, handle.draftOwner == nil else {
                    throw WSSSaveError.targetDisappeared
                }
                draftToken = nil
            }
            do {
                try ManagedWallpaperStore.checkPath(handle.root)
                let attributes = try FileManager.default.attributesOfItem(atPath: handle.root.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory,
                    let device = attributes[.systemNumber] as? NSNumber,
                    let inode = attributes[.systemFileNumber] as? NSNumber
                else { throw WSSSaveError.targetDisappeared }
                self.device = device.uint64Value
                self.inode = inode.uint64Value
            } catch { throw WSSSaveError.targetDisappeared }
            wallpaperID = handle.id
            self.managed = handle.wallpaper.managed
            source = handle.wallpaper.sceneSource
            root = handle.root.standardizedFileURL.path
        }
    }
    let identity: Identity
    let manifest: WSSContentFingerprint
    let assets: [String: WSSContentFingerprint]

    func verify(_ handle: WSSProjectHandle) throws {
        guard try Identity(handle) == identity else { throw WSSSaveError.targetDisappeared }
        let source = WSSNativeAssets(root: handle.root)
        let bytes: Data
        do {
            bytes = try source.read("scene.wss.json", limit: WSSSceneDocumentV1.byteLimit)
        } catch WSSDocumentError.missingAsset { throw WSSSaveError.targetDisappeared } catch {
            throw WSSSaveError.externalConflict
        }
        guard WSSContentFingerprint(bytes) == manifest else { throw WSSSaveError.externalConflict }
        for (path, expected) in assets {
            do {
                let bytes = try source.read(path, limit: expected.byteCount)
                guard WSSContentFingerprint(bytes) == expected else {
                    throw WSSSaveError.externalConflict
                }
            } catch { throw WSSSaveError.externalConflict }
        }
        guard try Identity(handle) == identity else { throw WSSSaveError.targetDisappeared }
    }
    func replacingManifest(_ bytes: Data, assets: [String: WSSContentFingerprint]? = nil) -> Self {
        Self(
            identity: identity, manifest: WSSContentFingerprint(bytes),
            assets: assets ?? self.assets)
    }
}

// Confined to one synchronous preparation. Records exactly the bytes consumed,
// including repeated reads; no separate post-load hash is mistaken for that input.
final class WSSProjectReadCapture {
    private(set) var assets: [String: WSSContentFingerprint] = [:]
    func record(_ path: String, _ bytes: Data) throws {
        let fingerprint = WSSContentFingerprint(bytes)
        if let previous = assets[path], previous != fingerprint {
            throw WSSSaveError.externalConflict
        }
        assets[path] = fingerprint
    }
    func basis(
        handle: WSSProjectHandle, identity: WSSProjectDiskBasis.Identity,
        manifest: Data, references: Set<String>
    ) throws -> WSSProjectDiskBasis {
        guard Set(assets.keys) == references else {
            throw WSSSaveError.validationFailed("not every referenced asset was read")
        }
        return WSSProjectDiskBasis(
            identity: identity, manifest: WSSContentFingerprint(manifest), assets: assets)
    }
}
