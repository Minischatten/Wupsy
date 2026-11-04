import AVFoundation
import Darwin
import Foundation

// File work runs off the main actor. Final names are claimed with an exclusive
// same-volume rename, so collisions never replace an existing wallpaper.
actor ManagedWallpaperStore {
    nonisolated let supportRoot: URL
    nonisolated private let rootWasSymlink: Bool
    nonisolated let storage: URL
    nonisolated var wallpaperRoot: URL { supportRoot.appendingPathComponent("Wallpapers") }

    enum ImportStage {
        case sourcePublished, libraryPersistence
    }
    private let importCheckpoint: (ImportStage) throws -> Void

    init(storage: URL, importCheckpoint: @escaping (ImportStage) throws -> Void = { _ in }) {
        self.importCheckpoint = importCheckpoint
        let requestedRoot = storage.deletingLastPathComponent().standardizedFileURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: requestedRoot.path)
        rootWasSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
        supportRoot = requestedRoot.resolvingSymlinksInPath()
        self.storage = supportRoot.appendingPathComponent(storage.lastPathComponent)
    }

    nonisolated private func checkRoot() throws {
        guard !rootWasSymlink else {
            throw ImportFailure.message(
                "Application Support library root is a symlink; refusing managed file operations.")
        }
        try Self.checkPath(supportRoot)
    }
    nonisolated static func components(_ path: String) throws -> [String] {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !pieces.isEmpty,
            pieces.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0")
            })
        else {
            throw ImportFailure.message("Unsafe managed wallpaper path.")
        }
        return pieces
    }
    nonisolated static func checkPath(_ url: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType != .typeSymbolicLink,
            url.standardizedFileURL.resolvingSymlinksInPath().path == url.standardizedFileURL.path
        else {
            throw ImportFailure.message("Unsafe symlink in wallpaper library path.")
        }
    }
    nonisolated func folder(for location: ManagedWallpaperLocation) throws -> URL {
        let parts = try Self.components(location.directory)
        guard parts.count == 2, ["Media", "Web", "WSS"].contains(parts[0])
        else {
            throw ImportFailure.message(
                "Unsafe managed wallpaper directory; refusing to access or delete a library root.")
        }
        let target = wallpaperRoot.appendingPathComponent(location.directory, isDirectory: true)
        try checkRoot()
        try Self.checkPath(target)
        return target
    }
    nonisolated func resolve(_ item: Wallpaper) throws -> Wallpaper {
        guard let location = item.managed else { return item }
        _ = try Self.components(location.entry)
        let root = try folder(for: location)
        let entry = root.appendingPathComponent(location.entry)
        try Self.checkPath(entry)
        var result = item
        result.root = root.path
        result.path = entry.path
        return result
    }
    nonisolated static func inspectTree(_ root: URL) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        func inspect(_ url: URL) throws {
            let info = try url.resourceValues(forKeys: keys)
            guard info.isSymbolicLink != true else {
                throw WallpaperImportDiagnostic(
                    .unsafePath, disposition: .invalidOrUnsafe, file: url.lastPathComponent)
            }
            guard info.isDirectory == true || info.isRegularFile == true else {
                throw WallpaperImportDiagnostic(
                    .unsafePath, disposition: .invalidOrUnsafe, file: url.lastPathComponent,
                    detail: "Special file")
            }
        }
        try inspect(root)
        if try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            // Explicit traversal propagates directory read errors instead of silently
            // accepting an incomplete enumeration.
            var pending = [root]
            while let directory = pending.popLast() {
                try Task.checkCancellation()
                for child in try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: Array(keys))
                {
                    try inspect(child)
                    if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                        pending.append(child)
                    }
                }
            }
        }
    }
    nonisolated func load() throws -> [Wallpaper] {
        try LibraryMetadataRecovery.requireReadable(root: supportRoot)
        try checkRoot()
        try Self.checkPath(storage)
        return try JSONDecoder().decode([Wallpaper].self, from: Data(contentsOf: storage)).map {
            try resolve($0)
        }
    }
    private func discardTemporary(_ target: URL) throws {
        try checkRoot()
        guard target.deletingLastPathComponent() == wallpaperRoot,
            target.lastPathComponent.hasPrefix(".import-")
                || target.lastPathComponent.hasPrefix(".remove-")
        else {
            throw ImportFailure.message("Unsafe temporary wallpaper cleanup path.")
        }
        try Self.checkPath(target)
        if FileManager.default.fileExists(atPath: target.path) {
            try Self.inspectTree(target)
            try FileManager.default.removeItem(at: target)
        }
    }
    nonisolated static func readableName(_ title: String) -> String {
        let cleaned = title.precomposedStringWithCanonicalMapping.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || "/\\:".unicodeScalars.contains($0)
                ? "-" : String($0)
        }.joined().trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var name = ""
        var count = 0
        for character in cleaned {
            let size = String(character).utf8.count
            guard count + size <= 120 else { break }
            name.append(character)
            count += size
        }
        return name.isEmpty ? "Wallpaper" : name
    }
    private func exclusiveMove(_ source: URL, _ destination: URL) throws {
        let result = source.path.withCString { old in
            destination.path.withCString { new in renamex_np(old, new, UInt32(RENAME_EXCL)) }
        }
        if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    private func validate(_ item: Wallpaper) async throws {
        switch item.kind {
        case .scene:
            guard item.sceneSource == .nativeWSS else {
                throw SceneError.unsupported("legacy scene")
            }
            _ = try await WSSStaticPreparation.shared.prepare(item)
        case .video:
            guard try await AVURLAsset(url: item.url).load(.isPlayable) else {
                throw ImportFailure.message("This video cannot be played by macOS.")
            }
        case .image:
            guard await ImageLoader.shared.image(item.url, maxPixel: 64) != nil else {
                throw ImportFailure.message("The image could not be decoded.")
            }
        case .web:
            if item.url.pathExtension.lowercased() == "gif" {
                guard await ImageLoader.shared.image(item.url, maxPixel: 64) != nil else {
                    throw ImportFailure.message("The GIF could not be decoded.")
                }
            }
            guard FileManager.default.isReadableFile(atPath: item.path) else {
                throw ImportFailure.message("The wallpaper file is not readable.")
            }
        }
    }
    private func persist(_ items: [Wallpaper]) throws {
        try LibraryMetadataRecovery.requireReadable(root: supportRoot)
        do {
            try checkRoot()
            try Self.checkPath(storage)
            try FileManager.default.createDirectory(
                at: supportRoot, withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: storage, options: .atomic)
        } catch {
            throw ImportFailure.message(
                "Could not update library.json: \(error.localizedDescription)")
        }
    }
    func importWallpaper(_ input: URL, existing: [Wallpaper]) async throws -> Wallpaper {
        do { return try await performImport(input, existing: existing) } catch is CancellationError
        { throw CancellationError() } catch {
            throw WallpaperImportDiagnostic.wrapping(error, as: .storage)
        }
    }
    private func performImport(_ input: URL, existing: [Wallpaper]) async throws -> Wallpaper {
        let backupLease = try LibraryMutationBarrier.shared.mutation()
        defer { withExtendedLifetime(backupLease) {} }
        try checkRoot()
        let fileManager = FileManager.default
        let inputValues = try input.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard inputValues.isSymbolicLink != true else {
            throw WallpaperImportDiagnostic(
                .unsafePath, disposition: .invalidOrUnsafe, file: input.lastPathComponent)
        }
        try Self.inspectTree(input)
        let source = try WallpaperImporter.resolve(input)
        let project =
            source.kind == .scene
            || (source.kind == .web && source.url.pathExtension.lowercased() != "gif")
        let category =
            source.sceneSource == .nativeWSS
            ? "WSS"
            : project ? "Web" : "Media"
        let originalRoot = URL(fileURLWithPath: source.root).standardizedFileURL
        if project {
            try Self.inspectTree(originalRoot)
            let parent = originalRoot.pathComponents
            guard !wallpaperRoot.pathComponents.starts(with: parent) else {
                throw ImportFailure.message(
                    "The source project contains the managed library; recursive import refused.")
            }
        }
        try await validate(source)
        let entry: String
        if project {
            let parts = source.url.pathComponents
            guard parts.starts(with: originalRoot.pathComponents),
                parts.count > originalRoot.pathComponents.count
            else {
                throw ImportFailure.message("Unsafe source project entry.")
            }
            entry = parts.dropFirst(originalRoot.pathComponents.count).joined(separator: "/")
        } else {
            entry = source.url.lastPathComponent
        }
        try Self.checkPath(wallpaperRoot)
        let area = wallpaperRoot.appendingPathComponent(category, isDirectory: true)
        try Self.checkPath(area)
        do { try fileManager.createDirectory(at: area, withIntermediateDirectories: true) } catch {
            throw ImportFailure.message(
                "Could not create managed wallpaper destination: \(error.localizedDescription)")
        }
        let temporary = wallpaperRoot.appendingPathComponent(".import-" + UUID().uuidString)
        // Claim the container exclusively before installing cleanup. A failed copy
        // must never cause cleanup of a directory that existed before this import.
        guard temporary.path.withCString({ mkdir($0, 0o700) }) == 0 else {
            throw ImportFailure.message(
                "Could not create temporary wallpaper destination: \(String(cString: strerror(errno)))"
            )
        }
        do {
            let staging = temporary.appendingPathComponent("payload")
            do {
                if project {
                    try fileManager.copyItem(at: originalRoot, to: staging)
                } else {
                    try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
                    try fileManager.copyItem(
                        at: source.url, to: staging.appendingPathComponent(entry))
                }
                try Self.inspectTree(staging)
            } catch {
                throw WallpaperImportDiagnostic.wrapping(error, as: .storage)
            }
            let title =
                source.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (project
                    ? originalRoot.lastPathComponent
                    : source.url.deletingPathExtension().lastPathComponent)
                : source.title
            var item = Wallpaper(
                title: title, path: staging.appendingPathComponent(entry).path,
                root: staging.path, kind: source.kind, sceneSource: source.sceneSource)
            try await validate(item)
            try Task.checkCancellation()
            let name = Self.readableName(item.title)
            for number in 1...10_000 {
                let directory = name + (number == 1 ? "" : " \(number)")
                let location = ManagedWallpaperLocation(
                    directory: category + "/" + directory, entry: entry)
                let final = try folder(for: location)
                do { try exclusiveMove(staging, final) } catch let error as NSError
                    where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST)
                { continue } catch {
                    throw WallpaperImportDiagnostic.wrapping(error, as: .publish)
                }
                item.managed = location
                do {
                    item = try resolve(item)
                    try importCheckpoint(.sourcePublished)
                    // The empty container is removed before the Library commit. A
                    // cleanup failure is still a failed import and rolls back its source.
                    try discardTemporary(temporary)
                    // Re-read after validation awaits so another completed import cannot
                    // be lost, even when the actor was re-entered during media validation.
                    let current =
                        fileManager.fileExists(atPath: storage.path) ? try load() : existing
                    try importCheckpoint(.libraryPersistence)
                    try Task.checkCancellation()
                    try persist(current + [item])
                } catch {
                    // Remove only this import's freshly claimed directory, never a preexisting one.
                    let original = error
                    do {
                        guard try folder(for: location) == final else {
                            throw WallpaperImportDiagnostic(
                                .unsafePath, disposition: .invalidOrUnsafe)
                        }
                        try Self.inspectTree(final)
                        try fileManager.removeItem(at: final)
                    } catch {
                        throw WallpaperImportDiagnostic(
                            .rollback, disposition: .invalidOrUnsafe,
                            detail: "Import: \(original); rollback: \(error)")
                    }
                    throw original
                }
                return item
            }
            throw ImportFailure.message("Could not find an unused wallpaper name.")
        } catch {
            let original = error
            var cleanupFailures: [String] = []
            do { try discardTemporary(temporary) } catch {
                cleanupFailures.append("Source staging: \(error)")
            }
            if !cleanupFailures.isEmpty {
                throw WallpaperImportDiagnostic(
                    .cleanup, disposition: .invalidOrUnsafe,
                    detail:
                        "Import: \(original); cleanup: \(cleanupFailures.joined(separator: "; "))")
            }
            throw original
        }
    }
    /// Edits metadata only; media and native projects are deliberately not inspected.
    func rename(wallpaperID: UUID, newTitle: String) throws -> Wallpaper {
        let backupLease = try LibraryMutationBarrier.shared.mutation()
        defer { withExtendedLifetime(backupLease) {} }
        let title = try WallpaperTitle.normalized(newTitle)
        var current = try load()
        let matches = current.indices.filter { current[$0].id == wallpaperID }
        guard matches.count == 1, let index = matches.first else {
            throw ImportFailure.message(
                "The wallpaper no longer exists or its identity is ambiguous.")
        }
        if current[index].title != title {
            current[index].title = title
            try persist(current)
        }
        return current[index]
    }

    func remove(_ item: Wallpaper, existing: [Wallpaper]) throws -> String? {
        let backupLease = try LibraryMutationBarrier.shared.mutation()
        defer { withExtendedLifetime(backupLease) {} }
        let current = FileManager.default.fileExists(atPath: storage.path) ? try load() : existing
        guard let saved = current.first(where: { $0.id == item.id }), saved.managed == item.managed,
            saved.path == item.path, saved.root == item.root
        else {
            throw ImportFailure.message(
                "Wallpaper entry changed; refusing to remove a different item.")
        }
        let remaining = current.filter { $0.id != item.id }
        guard let location = item.managed else {
            try persist(remaining)
            return nil
        }
        guard current.filter({ $0.managed?.directory == location.directory }).count == 1 else {
            throw ImportFailure.message(
                "Managed wallpaper ownership is ambiguous; refusing to delete.")
        }
        let resolved = try resolve(item)
        guard item.root == resolved.root, item.path == resolved.path else {
            throw ImportFailure.message(
                "Managed wallpaper paths do not match ownership; refusing to delete.")
        }
        let folder = try folder(for: location)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            try persist(remaining)
            return nil
        }
        try Self.inspectTree(folder)
        let trash = wallpaperRoot.appendingPathComponent(".remove-" + UUID().uuidString)
        try exclusiveMove(folder, trash)
        do { try persist(remaining) } catch {
            do { try exclusiveMove(trash, folder) } catch let recoveryError {
                throw ImportFailure.message(
                    "Library update failed; managed files retained at \(trash.path). Restore failed: \(recoveryError.localizedDescription)"
                )
            }
            throw error
        }
        do {
            try discardTemporary(trash)
            return nil
        } catch {
            return
                "Entry removed, but managed files could not be cleaned up: \(error.localizedDescription)"
        }
    }
}

extension ManagedWallpaperStore {
    func saveWSSAs(
        _ snapshot: WSSSaveAsSnapshot, id requestedID: UUID? = nil,
        checkpoint: WSSSaveAsCheckpoint? = nil
    ) async throws -> WSSSaveAsReceipt {
        guard snapshot.source.origin != .draft else { throw WSSSaveAsError.conflict }
        return try await publishWSSProject(
            snapshot, id: requestedID ?? snapshot.destinationID,
            ownedDraft: false, checkpoint: checkpoint)
    }
    func publishWSSDraft(
        _ snapshot: WSSSaveAsSnapshot,
        checkpoint: WSSSaveAsCheckpoint? = nil
    ) async throws -> WSSSaveAsReceipt {
        guard snapshot.source.origin == .draft, snapshot.destinationID == snapshot.source.id else {
            throw WSSSaveAsError.conflict
        }
        return try await publishWSSProject(
            snapshot, id: snapshot.destinationID,
            ownedDraft: true, checkpoint: checkpoint)
    }
    private func publishWSSProject(
        _ snapshot: WSSSaveAsSnapshot, id: UUID,
        ownedDraft: Bool, checkpoint: WSSSaveAsCheckpoint?
    ) async throws -> WSSSaveAsReceipt {
        let backupLease = try LibraryMutationBarrier.shared.mutation()
        defer { withExtendedLifetime(backupLease) {} }
        func readLibrary() throws -> (bytes: Data?, items: [Wallpaper]) {
            try checkRoot()
            let directory = try WSSAssetIO.directory(supportRoot)
            defer { Darwin.close(directory) }
            let file = openat(
                directory, storage.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard file >= 0 else {
                guard errno == ENOENT else { throw WSSSaveAsError.library }
                return (nil, [])
            }
            defer { Darwin.close(file) }
            let bytes = try WSSAssetIO.read(file, limit: WSSSaveAsPreparation.projectLimit)
            return (
                bytes,
                try JSONDecoder().decode([Wallpaper].self, from: bytes).map { try resolve($0) }
            )
        }
        func verifySource(_ items: [Wallpaper]) throws {
            if ownedDraft {
                guard let owner = snapshot.source.draftOwner,
                    snapshot.diskBasis.identity.draftToken == owner.token
                else { throw WSSSaveAsError.conflict }
                try owner.verify()
                try snapshot.diskBasis.verify(snapshot.source)
                return
            }
            let identity = snapshot.diskBasis.identity
            let matches = items.filter { $0.id == identity.wallpaperID }
            guard let managed = identity.managed, identity.draftToken == nil,
                matches.count == 1, let source = matches.first,
                source.managed == identity.managed, source.sceneSource == identity.source,
                items.filter({ $0.managed?.directory == managed.directory }).count == 1,
                try WSSProjectDiskBasis.Identity(WSSExistingProjectResolver.resolve(source))
                    == identity
            else { throw WSSSaveAsError.conflict }
            try snapshot.diskBasis.verify(snapshot.source)
        }
        try checkRoot()
        try snapshot.checkBudget()
        if ownedDraft {
            try FileManager.default.createDirectory(
                at: wallpaperRoot, withIntermediateDirectories: true)
            try checkRoot()
        }
        let initial = try readLibrary().items
        try verifySource(initial)
        let location = ManagedWallpaperLocation(
            directory: "WSS/" + id.uuidString, entry: "scene.wss.json")
        guard
            !initial.contains(where: { $0.id == id || $0.managed?.directory == location.directory })
        else { throw WSSSaveAsError.collision }
        let final = try folder(for: location)
        let root = try WSSAssetIO.directory(wallpaperRoot)
        defer { Darwin.close(root) }
        if mkdirat(root, "WSS", mode_t(0o755)) != 0, errno != EEXIST {
            throw WSSSaveAsError.storage
        }
        guard fsync(root) == 0 else { throw WSSSaveAsError.storage }
        let item = Wallpaper(
            id: id, title: snapshot.model.title,
            path: final.appendingPathComponent("scene.wss.json").path, root: final.path,
            kind: .scene, managed: location, sceneSource: .nativeWSS)
        let staging: WSSSaveAsStaging
        do {
            staging = try await WSSSaveAsPreparation().prepare(
                snapshot, item: item, checkpoint: checkpoint)
        } catch let error as WSSSaveAsError { throw error } catch { throw WSSSaveAsError.conflict }
        do {
            try checkRoot()
            try verifySource(readLibrary().items)
            try checkpoint?(.projectPublish)
            try verifySource(readLibrary().items)
            try Task.checkCancellation()
            try staging.publish(to: id.uuidString)
            try checkpoint?(.finalValidation)
            let project = try WSSEditorProjectLoader.read(item)
            guard project.document == snapshot.model, project.diskBasis.assets == snapshot.catalog
            else { throw WSSSaveAsError.invalid }
            try checkpoint?(.libraryPersistence)
            // Re-read after preparation's await and project publication. Preserve every
            // entry committed by another actor operation while preparation was running.
            let library = try readLibrary()
            let before = library.bytes
            var current = library.items
            try verifySource(current)
            guard
                !current.contains(where: {
                    $0.id == id || $0.managed?.directory == location.directory
                })
            else { throw WSSSaveAsError.collision }
            try project.diskBasis.verify(project.handle)
            current.append(item)
            let warnings = try WSSSaveAsLibraryWriter.commit(
                before: before, after: JSONEncoder().encode(current), storage: storage,
                checkpoint: checkpoint)
            return WSSSaveAsReceipt(
                operationID: snapshot.operationID, project: project, warnings: warnings)
        } catch {
            if !staging.published {
                do { try staging.discard() } catch { throw WSSSaveAsError.cleanup }
            } else if ownedDraft {
                do {
                    let current = try readLibrary().items
                    guard
                        !current.contains(where: {
                            $0.id == id || $0.managed?.directory == location.directory
                        })
                    else { throw WSSSaveAsError.cleanup }
                    try staging.rollbackUnregisteredPublication()
                } catch { throw WSSSaveAsError.cleanup }
            }
            if let known = error as? WSSSaveAsError { throw known }
            throw staging.published ? WSSSaveAsError.library : WSSSaveAsError.invalid
        }
    }
}
