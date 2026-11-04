import Darwin
import Foundation
import Metal

struct WSSValidatedManifestCandidate {
    let snapshot: WSSSaveSnapshot
    let handle: WSSProjectHandle
    let bytes: Data?
    let playback: PreparedScenePlayback?
    fileprivate init(
        snapshot: WSSSaveSnapshot, handle: WSSProjectHandle, bytes: Data?,
        playback: PreparedScenePlayback? = nil
    ) {
        self.snapshot = snapshot
        self.handle = handle
        self.bytes = bytes
        self.playback = playback
    }
}

actor WSSManifestSaveValidator {
    func prepare(_ snapshot: WSSSaveSnapshot, handle: WSSProjectHandle) throws
        -> WSSValidatedManifestCandidate
    {
        try Task.checkCancellation()
        try snapshot.diskBasis.verify(handle)
        if snapshot.model == snapshot.savedModel {
            return WSSValidatedManifestCandidate(snapshot: snapshot, handle: handle, bytes: nil)
        }
        do {
            let bytes = try snapshot.model.encoded()
            let document = try WSSSceneDocumentV1.decode(data: bytes)
            guard document == snapshot.model,
                document.referencedPaths.isSubset(
                    of: Set((snapshot.resourceCatalog ?? snapshot.diskBasis.assets).keys))
            else {
                throw WSSSaveError.validationFailed("unknown resource generation")
            }
            let capture = WSSProjectReadCapture()
            var assets = try document.assetSource(root: handle.root)
            assets.sessionAssets = snapshot.sessionAssets
            assets.didRead = { try capture.record($0, $1) }
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw WSSSaveError.validationFailed("Metal unavailable")
            }
            let resources = try WSSStaticResources(
                scene: document.scene(), assets: assets, device: device)
            let expected = (snapshot.resourceCatalog ?? snapshot.diskBasis.assets).filter {
                document.referencedPaths.contains($0.key)
            }
            guard capture.assets == expected else {
                throw WSSSaveError.externalConflict
            }
            try snapshot.diskBasis.verify(handle)
            try Task.checkCancellation()
            return WSSValidatedManifestCandidate(
                snapshot: snapshot, handle: handle, bytes: bytes,
                playback: PreparedScenePlayback(wss: resources))
        } catch let error as WSSSaveError { throw error } catch is CancellationError {
            throw CancellationError()
        } catch { throw WSSSaveError.validationFailed(error.localizedDescription) }
    }
}

// Immutable assets first, manifest last. The existing managed-store actor owns
// this complete synchronous publication, coordinated with Remove.
enum WSSManifestWriter {
    enum Stage {
        case assetWrite, assetPartialWrite, assetFlush, assetClose, assetPublish, afterAssetPublish,
            createTemp, partialWrite, flush, close, beforeCommit, replace, afterCommit
    }
    typealias Checkpoint = (Stage) throws -> Void

    static func commit(
        _ candidate: WSSValidatedManifestCandidate,
        verifyTarget: () throws -> Void, checkpoint: Checkpoint? = nil
    ) throws -> WSSSaveReceipt {
        try verifyTarget()
        let snapshot = candidate.snapshot
        try snapshot.diskBasis.verify(candidate.handle)
        func verifyReferences() throws {
            let catalog = snapshot.resourceCatalog ?? snapshot.diskBasis.assets
            let source = WSSNativeAssets(root: candidate.handle.root)
            for path in snapshot.model.referencedPaths {
                guard let expected = catalog[path] else { throw WSSSaveError.externalConflict }
                let actual: Data
                do {
                    actual = try WSSAssetIO.read(
                        root: source.root, path: path, limit: expected.byteCount)
                } catch {
                    throw WSSSaveError.externalConflict
                }
                guard WSSContentFingerprint(actual) == expected else {
                    throw WSSSaveError.externalConflict
                }
            }
        }
        guard let bytes = candidate.bytes else {
            try verifyReferences()
            return WSSSaveReceipt(
                snapshot: snapshot, diskBasis: snapshot.diskBasis, outcome: .unchanged)
        }
        let directory = try WSSAssetIO.directory(candidate.handle.root)
        guard directory >= 0 else { throw WSSSaveError.targetDisappeared }
        defer { Darwin.close(directory) }
        var rootInfo = stat()
        guard fstat(directory, &rootInfo) == 0, rootInfo.st_uid == geteuid(),
            UInt64(rootInfo.st_dev) == snapshot.diskBasis.identity.device,
            UInt64(rootInfo.st_ino) == snapshot.diskBasis.identity.inode
        else { throw WSSSaveError.targetDisappeared }
        let original = openat(directory, "scene.wss.json", O_RDONLY | O_NOFOLLOW)
        guard original >= 0 else { throw WSSSaveError.targetDisappeared }
        defer { Darwin.close(original) }
        var attributes = stat()
        guard fstat(original, &attributes) == 0, attributes.st_uid == geteuid(),
            attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else {
            throw WSSSaveError.writeFailed("manifest must be a regular file owned by this user")
        }
        for path in snapshot.model.referencedPaths.sorted() {
            if let generation = snapshot.sessionAssets[path] {
                guard snapshot.resourceCatalog?[path] == generation.fingerprint else {
                    throw WSSSaveError.externalConflict
                }
                try verifyTarget()
                try snapshot.diskBasis.verify(candidate.handle)
                try WSSAssetPublication.install(
                    generation, directory: directory, identity: snapshot.diskBasis.identity,
                    checkpoint: checkpoint,
                    verifyTarget: {
                        try verifyTarget()
                        try snapshot.diskBasis.verify(candidate.handle)
                    })
            }
        }
        try verifyTarget()
        try snapshot.diskBasis.verify(candidate.handle)
        try verifyReferences()
        // Read/prepare the actual published resources, not just session staging.
        if !snapshot.sessionAssets.isEmpty {
            var assets = try snapshot.model.assetSource(root: candidate.handle.root)
            var files: [String: Data] = [:]
            for path in snapshot.model.referencedPaths {
                guard let fingerprint = snapshot.resourceCatalog?[path] else {
                    throw WSSSaveError.externalConflict
                }
                let bytes = try WSSAssetIO.read(
                    root: candidate.handle.root, path: path, limit: fingerprint.byteCount)
                guard WSSContentFingerprint(bytes) == fingerprint else {
                    throw WSSSaveError.externalConflict
                }
                files[path] = bytes
            }
            assets.fileBytes = files
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw WSSImageImportError.storage
            }
            _ = try WSSStaticResources(
                scene: snapshot.model.scene(), assets: assets, device: device)
        }
        let tempName = ".wss-save-" + UUID().uuidString + ".tmp"
        var descriptor: Int32 = -1
        var ownsTemp = false
        var warnings: [String] = []
        func message() -> String { String(cString: strerror(errno)) }
        do {
            try checkpoint?(.createTemp)
            descriptor = openat(
                directory, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
            guard descriptor >= 0 else { throw WSSSaveError.writeFailed(message()) }
            ownsTemp = true
            // Preserve security metadata (mode, owner/group and ACL) before writing.
            // If this fails, never publish a replacement with weaker permissions.
            guard fcopyfile(original, descriptor, nil, copyfile_flags_t(COPYFILE_SECURITY)) == 0
            else {
                throw WSSSaveError.writeFailed("cannot preserve manifest security: " + message())
            }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = offset == 0 ? max(1, buffer.count / 2) : buffer.count - offset
                    let written = Darwin.write(
                        descriptor, buffer.baseAddress!.advanced(by: offset), count)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw WSSSaveError.writeFailed(message()) }
                    if offset == 0 { try checkpoint?(.partialWrite) }
                    offset += written
                }
            }
            try checkpoint?(.flush)
            guard fsync(descriptor) == 0 else { throw WSSSaveError.writeFailed(message()) }
            if fcntl(descriptor, F_FULLFSYNC) != 0 {
                if errno == ENOTSUP || errno == EINVAL {
                    warnings.append(
                        EditorText.warningFullFlush.text)
                } else {
                    throw WSSSaveError.writeFailed(message())
                }
            }
            try checkpoint?(.close)
            let result = Darwin.close(descriptor)
            descriptor = -1
            guard result == 0 else { throw WSSSaveError.writeFailed(message()) }
            try checkpoint?(.beforeCommit)
            try verifyTarget()
            try snapshot.diskBasis.verify(candidate.handle)
            try verifyReferences()
            try Task.checkCancellation()
            do { try checkpoint?(.replace) } catch {
                throw WSSSaveError.commitFailed(error.localizedDescription)
            }
            guard renameat(directory, tempName, directory, "scene.wss.json") == 0 else {
                throw WSSSaveError.commitFailed(message())
            }
            // COMMIT: errors from this point are warnings, never an unsaved result.
            ownsTemp = false
        } catch {
            if descriptor >= 0 { Darwin.close(descriptor) }
            if ownsTemp, unlinkat(directory, tempName, 0) != 0, errno != ENOENT {
                throw WSSSaveError.writeFailed(
                    error.localizedDescription + "; temporary-file cleanup failed: " + message())
            }
            if let typed = error as? WSSSaveError { throw typed }
            if error is CancellationError { throw CancellationError() }
            throw WSSSaveError.writeFailed(error.localizedDescription)
        }
        if fsync(directory) != 0 {
            warnings.append(EditorText.warningManifestDirectory.format(message()))
        }
        do { try checkpoint?(.afterCommit) } catch {
            warnings.append(
                EditorText.warningManifestCommitted.format(EditorErrorPresentation.message(error)))
        }
        return WSSSaveReceipt(
            snapshot: snapshot,
            diskBasis: snapshot.diskBasis.replacingManifest(
                bytes,
                assets: (snapshot.resourceCatalog ?? snapshot.diskBasis.assets).filter {
                    snapshot.model.referencedPaths.contains($0.key)
                }),
            outcome: .committed(warnings: warnings))
    }
}

extension ManagedWallpaperStore {
    func commitWSSManifest(
        _ candidate: WSSValidatedManifestCandidate,
        checkpoint: WSSManifestWriter.Checkpoint? = nil
    ) throws -> WSSSaveReceipt {
        let backupLease = try LibraryMutationBarrier.shared.mutation()
        defer { withExtendedLifetime(backupLease) {} }
        func verify() throws {
            let identity = candidate.snapshot.diskBasis.identity
            let items: [Wallpaper]
            do { items = try load() } catch { throw WSSSaveError.targetDisappeared }
            guard let managed = identity.managed, identity.draftToken == nil,
                items.filter({ $0.id == identity.wallpaperID }).count == 1,
                let item = items.first(where: { $0.id == identity.wallpaperID }),
                item.kind == .scene,
                item.managed == identity.managed,
                items.filter({ $0.managed?.directory == managed.directory }).count == 1
            else { throw WSSSaveError.targetDisappeared }
            let handle: WSSProjectHandle
            do { handle = try WSSExistingProjectResolver.resolve(resolve(item)) } catch {
                throw WSSSaveError.targetDisappeared
            }
            guard try WSSProjectDiskBasis.Identity(handle) == identity else {
                throw WSSSaveError.targetDisappeared
            }
        }
        return try WSSManifestWriter.commit(candidate, verifyTarget: verify, checkpoint: checkpoint)
    }
}
