import Foundation

struct LibraryRestoreFile {
    let source: LibraryBackupFile
    let target: String
}
struct LibraryRestoreProject {
    let id: UUID
    let directory: String
    let recovery: Bool
}
// Values describe B only. Nothing here applies preferences or starts playback.
struct LibraryRestorePlan {
    let manifest: LibraryBackupManifest
    let library: [Wallpaper]
    let playlists: PlaylistCollectionState
    let favorites: [UUID]
    let settings: LibraryBackupSettings
    let widgets: LibraryBackupWidgets
    let files: [LibraryRestoreFile]
    let projects: [LibraryRestoreProject]
    let promotedToNative: [UUID]
    var incomplete: Bool { manifest.completeness == "incomplete" }
    var summary: String {
        LibraryBackupCompletionSummary.string(
            wallpapers: library.count, playlists: playlists.definitions.count,
            bytes: manifest.totalLogicalSize)
    }

    init(_ contents: LibraryBackupContents) throws {
        let m = contents.manifest
        try m.validate()
        let ids = Set(contents.library.map(\.id))
        guard contents.library == m.wallpapers,
            contents.playlists.definitions.map(\.id) == m.playlistIDs,
            Set(contents.organization.favorites).count == contents.organization.favorites.count,
            Set(contents.organization.favorites).isSubset(of: ids),
            (m.completeness == "incomplete") == contents.library.contains(where: \.missingSource),
            ["standard", "hiDPI"].contains(contents.settings.sceneRenderResolution),
            [24, 30, 60].contains(contents.settings.sceneFPS),
            contents.widgets.independentWidgets.allSatisfy({
                WidgetKind(rawValue: $0.key) != nil && $0.value.scale.isFinite
                    && (0.6...2.5).contains($0.value.scale)
            })
        else { throw LibraryBackupError("Invalid restore metadata projection.") }
        _ = try contents.widgets.customWidgetPackage?.validated()
        try contents.playlists.validate()
        guard contents.playlists.definitions.allSatisfy({ Set($0.wallpaperIDs).isSubset(of: ids) })
        else {
            throw LibraryBackupError("Invalid restore playlist reference.")
        }
        var records: [Wallpaper] = []
        var mappings: [LibraryRestoreFile] = []
        var projects: [LibraryRestoreProject] = []
        var promoted: [UUID] = []
        let payloads = Dictionary(grouping: m.files.filter { $0.path.contains("/") }) { file in
            let parts = file.path.split(separator: "/")
            return parts.prefix(parts.first == "recovery" ? 2 : 3).joined(separator: "/")
        }
        func map(_ source: String, to target: String, single: String? = nil) throws {
            let files = payloads[source] ?? []
            guard !files.isEmpty,
                single == nil || (files.count == 1 && files[0].path == source + "/" + single!)
            else {
                throw LibraryBackupError("Wallpaper payload does not match its kind.")
            }
            for file in files {
                let suffix = String(file.path.dropFirst(source.count + 1))
                mappings.append(LibraryRestoreFile(source: file, target: target + "/" + suffix))
            }
        }
        for item in contents.library {
            guard (item.ownership == .managed) == (item.managed != nil) else {
                throw LibraryBackupError("Inconsistent wallpaper ownership.")
            }
            if let old = item.managed {
                let components = try ManagedWallpaperStore.components(old.directory)
                _ = try ManagedWallpaperStore.components(old.entry)
                guard components.count == 2,
                    ["Media", "Web", "WSS"].contains(components[0])
                else {
                    throw LibraryBackupError("Invalid portable managed location.")
                }
            }
            let id = item.id.uuidString
            var category: String
            var entry: String
            var native = false
            guard !item.missingSource, item.native == nil else {
                throw LibraryBackupError("Legacy derived-project backups are no longer supported.")
            }
            do {
                guard let source = item.source, let originalEntry = item.entry else {
                    throw LibraryBackupError("Missing source payload.")
                }
                _ = try LibraryBackupLimits.path(originalEntry)
                entry = originalEntry
                let ext = URL(fileURLWithPath: entry).pathExtension.lowercased()
                switch item.kind {
                case .scene:
                    guard let sceneSource = item.sceneSource else {
                        throw LibraryBackupError("Missing scene source.")
                    }
                    guard sceneSource == .nativeWSS, entry == "scene.wss.json",
                        item.scenePlaybackMode == nil
                    else {
                        throw LibraryBackupError("Only native Wupsy scene backups are supported.")
                    }
                    category = "WSS"
                    native = true
                    try map(source, to: "Wallpapers/WSS/" + id)
                case .image, .video, .web:
                    guard item.sceneSource == nil, item.scenePlaybackMode == nil, item.native == nil
                    else {
                        throw LibraryBackupError("Scene metadata on non-scene wallpaper.")
                    }
                    let extensions: [String]
                    switch item.kind {
                    case .image: extensions = ["png", "jpg", "jpeg", "heic", "tiff"]
                    case .video: extensions = ["mp4", "mov", "m4v"]
                    default: extensions = ["gif", "html", "htm"]
                    }
                    guard extensions.contains(ext) else {
                        throw LibraryBackupError("Wallpaper kind and source extension disagree.")
                    }
                    category = item.kind == .web && ext != "gif" ? "Web" : "Media"
                    try map(
                        source, to: "Wallpapers/" + category + "/" + id,
                        single: category == "Media" ? entry : nil)
                }
            }
            let location = ManagedWallpaperLocation(directory: category + "/" + id, entry: entry)
            records.append(
                Wallpaper(
                    id: item.id, title: item.title, path: "", root: "", kind: item.kind,
                    managed: location, scenePlaybackMode: native ? nil : item.scenePlaybackMode,
                    sceneSource: native ? .nativeWSS : item.sceneSource))
            if native {
                projects.append(
                    LibraryRestoreProject(
                        id: item.id, directory: "Wallpapers/" + location.directory, recovery: false)
                )
            }
        }
        var recoveryIDs = Set<UUID>()
        for recovery in m.recovery {
            guard let id = UUID(uuidString: recovery.id), recovery.id == id.uuidString,
                id == recovery.originalProjectID, recovery.origin == "managed-native-project",
                !ids.contains(id), recoveryIDs.insert(id).inserted
            else {
                throw LibraryBackupError("Invalid or colliding recovery identity.")
            }
            let target = "Wallpapers/NativeProjects/" + id.uuidString
            try map(recovery.payload, to: target)
            projects.append(LibraryRestoreProject(id: id, directory: target, recovery: true))
        }
        try LibraryBackupLimits.paths(mappings.map(\.target))
        guard
            Set(mappings.map { $0.source.path })
                == Set(m.files.filter { $0.path.contains("/") }.map(\.path))
        else {
            throw LibraryBackupError("Unassigned restore payload.")
        }
        var playlists = contents.playlists
        playlists.playback = nil
        self.manifest = m
        library = records
        self.playlists = playlists
        favorites = contents.organization.favorites
        settings = contents.settings
        widgets = contents.widgets
        files = mappings
        self.projects = projects
        promotedToNative = promoted
    }
}

final class PreparedLibraryRestore: @unchecked Sendable {
    let plan: LibraryRestorePlan
    private let staging: LibraryRestoreStaging
    var stagingID: UUID { staging.id }
    var newRoot: URL { staging.root.appendingPathComponent("new") }
    init(plan: LibraryRestorePlan, staging: LibraryRestoreStaging) {
        self.plan = plan
        self.staging = staging
    }
    // Serializes with discard and verifies ownership again; 8B.2 can revalidate B.
    func validate() throws { try staging.validate(plan) }
    func discard() throws { try staging.discard() }
    func claimTransaction() throws -> URL { try staging.claimTransaction() }
    func releaseTransactionClaim() { staging.releaseTransactionClaim() }
}

struct LibraryRestorePreparer: Sendable {
    enum Phase: Sendable { case bootstrap, extracting, reconstructing, validating }
    typealias Checkpoint = @Sendable (Phase, String, Int) throws -> Void
    let supportRoot: URL
    var limits = LibraryRestoreLimits()
    var checkpoint: Checkpoint = { _, _, _ in }
    var progress: @Sendable (LibraryRestorePresentationPhase) -> Void = { _ in }
    init(
        supportRoot: URL = ProductPaths.current.supportRoot
    ) {
        self.supportRoot = supportRoot
    }
    func prepare(_ backupURL: URL) async throws -> PreparedLibraryRestore {
        let work = Task.detached { try prepareSynchronously(backupURL) }
        return try await withTaskCancellationHandler(
            operation: { try await work.value }, onCancel: { work.cancel() })
    }
    private func prepareSynchronously(_ url: URL) throws -> PreparedLibraryRestore {
        let archive = try LibraryRestoreArchive(url: url, limits: limits)
        let manifest = try archive.manifest()
        try checkpoint(.bootstrap, "backup.json", 0)
        try Task.checkCancellation()
        progress(.preparing)
        let stage = try LibraryRestoreStaging(supportRoot: supportRoot)
        do {
            try LibraryBackupIO.available(
                stage.root, needed: manifest.totalLogicalSize + Int64(LibraryBackupLimits.manifest))
            let contents = try LibraryBackupArchive.read(
                fd: archive.fd, expected: manifest,
                metadataLimit: limits.metadata, validateJSON: LibraryRestoreJSON.validate,
                sink: stage.sink(checkpoint: checkpoint))
            try archive.unchanged()
            let plan = try LibraryRestorePlan(contents)
            try checkpoint(.reconstructing, "", 0)
            try stage.reconstruct(plan)
            try checkpoint(.validating, "", 0)
            try stage.validate(plan)
            try Task.checkCancellation()
            return PreparedLibraryRestore(plan: plan, staging: stage)
        } catch {
            let original = error
            do { try stage.discard() } catch {
                throw LibraryBackupError(
                    "Restore failed (\(original.localizedDescription)); owned staging cleanup failed (\(error.localizedDescription))."
                )
            }
            throw original
        }
    }
}

// Read-only product gate before the UI reserves maintenance or creates staging.
// Preparation reopens and revalidates the archive; this is never authorization to publish.
enum LibraryRestorePreflight {
    static func validate(_ url: URL) throws {
        let archive = try LibraryRestoreArchive(url: url, limits: LibraryRestoreLimits())
        _ = try archive.manifest()
        try archive.unchanged()
    }
}
