import CryptoKit
import Foundation

struct LibraryBackupError: LocalizedError {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var errorDescription: String? { detail }
}

enum LibraryBackupLimits {
    static let total: Int64 = 1 << 40
    static let file: Int64 = 256 << 30
    static let files = 100_000
    static let manifest = 16 << 20
    static let chunk = 1 << 20
    static func path(_ path: String) throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.utf8.elementsEqual(path.precomposedStringWithCanonicalMapping.utf8),
            path.utf8.count <= 1024, parts.count <= 32,
            !path.contains("\\"), !path.contains(":"),
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 })
        else { throw LibraryBackupError("Unsafe or oversized backup path.") }
        return path.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    // File keys and sorted neighbors detect ancestor/duplicate/directory spelling
    // collisions without retaining every full directory prefix in a dictionary.
    static func paths(_ names: [String]) throws {
        let sorted = try names.map { (name: $0, key: try path($0)) }.sorted { $0.key < $1.key }
        let keys = Set(sorted.map(\.key))
        for item in sorted {
            let parts = item.key.split(separator: "/")
            for count in 1..<parts.count
            where keys.contains(parts.prefix(count).joined(separator: "/")) {
                throw LibraryBackupError("File/directory collision in backup paths.")
            }
        }
        for index in sorted.indices.dropFirst() {
            let a = sorted[index - 1]
            let b = sorted[index]
            guard a.key != b.key, !b.key.hasPrefix(a.key + "/") else {
                throw LibraryBackupError("Duplicate or file/directory collision in backup paths.")
            }
            let ak = a.key.split(separator: "/")
            let bk = b.key.split(separator: "/")
            let an = a.name.split(separator: "/")
            let bn = b.name.split(separator: "/")
            for component in 0..<min(ak.count, bk.count) {
                if ak[component] != bk[component] { break }
                guard an[component].utf8.elementsEqual(bn[component].utf8) else {
                    throw LibraryBackupError("Case or Unicode directory collision in backup paths.")
                }
            }
        }
    }

}

struct LibraryBackupFile: Codable, Equatable {
    let path: String
    let size: Int64
    let sha256: String
}
struct LibraryBackupWallpaper: Codable, Equatable {
    let id: UUID
    let title: String
    let kind: WallpaperKind
    let ownership: Wallpaper.Ownership
    let managed: ManagedWallpaperLocation?
    let sceneSource: SceneSource?
    let scenePlaybackMode: ScenePlaybackMode?
    let source: String?
    let entry: String?
    let native: String?
    let missingSource: Bool
}
struct LibraryBackupRecovery: Codable, Equatable {
    let id: String
    let originalProjectID: UUID
    let origin: String
    let payload: String
}
struct LibraryBackupManifest: Codable, Equatable {
    var format = ProductIdentity.backupFormat
    var backupFormatVersion = 1
    var libraryRepresentationVersion = 1
    var playlistFormatVersion = 1
    var wssSceneSchemaVersion = 1
    var createdAt: Date
    var appVersion: String?
    var appBuild: String?
    var requiredFeatures = ["sha256", "portable-library-v1", "zip64"]
    var optionalFeatures = ["recovery", "portable-settings", "widgets"]
    var completeness: String
    var notes: [String]
    var wallpapers: [LibraryBackupWallpaper]
    var playlistIDs: [UUID]
    var recovery: [LibraryBackupRecovery]
    var files: [LibraryBackupFile]
    var fileCount: Int
    var totalLogicalSize: Int64
    // backup.json itself is excluded to avoid a circular hash.
    private enum CodingKeys: String, CodingKey {
        case format, backupFormatVersion, libraryRepresentationVersion, playlistFormatVersion,
            wssSceneSchemaVersion, createdAt, appVersion, appBuild, requiredFeatures,
            optionalFeatures,
            completeness, notes, wallpapers, playlistIDs, recovery, files, fileCount,
            totalLogicalSize
    }
    func validate() throws {
        guard format == ProductIdentity.backupFormat else {
            throw LibraryBackupError(
                "This is not a Wupsy library backup. Only Wupsy backups can be restored.")
        }
        guard backupFormatVersion == 1,
            libraryRepresentationVersion == 1, playlistFormatVersion == 1,
            wssSceneSchemaVersion == 1,
            Set(requiredFeatures) == Set(["sha256", "portable-library-v1", "zip64"]),
            ["complete", "incomplete"].contains(completeness),
            Set(wallpapers.map(\.id)).count == wallpapers.count,
            Set(playlistIDs).count == playlistIDs.count,
            fileCount == files.count + 1, files.count + 1 <= LibraryBackupLimits.files
        else { throw LibraryBackupError("Invalid or unsupported backup manifest.") }
        try LibraryBackupLimits.paths(files.map(\.path))
        var total: Int64 = 0
        for file in files {
            guard file.path != "backup.json",
                file.size >= 0, file.size <= LibraryBackupLimits.file,
                file.sha256.count == 64,
                file.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
                file.size <= LibraryBackupLimits.total - total
            else {
                throw LibraryBackupError("Invalid backup file inventory or size limit exceeded.")
            }
            total += file.size
        }
        guard total == totalLogicalSize else { throw LibraryBackupError("Backup size mismatch.") }
        let names = Set(files.map(\.path))
        for name in [
            "library.json", "playlists.json", "organization.json", "settings.json", "widgets.json",
        ] {
            guard names.contains(name) else { throw LibraryBackupError("Missing backup metadata.") }
        }
        for item in wallpapers {
            let prefix = "payloads/" + item.id.uuidString + "/"
            if let source = item.source, let entry = item.entry {
                guard source == prefix + "source", names.contains(source + "/" + entry) else {
                    throw LibraryBackupError("Invalid wallpaper source mapping.")
                }
            } else if !item.missingSource {
                throw LibraryBackupError("Missing wallpaper source mapping.")
            }
            if let native = item.native {
                guard native == prefix + "native", names.contains(native + "/scene.wss.json") else {
                    throw LibraryBackupError("Invalid native project mapping.")
                }
            }
        }
        guard Set(recovery.map(\.id)).count == recovery.count else {
            throw LibraryBackupError("Duplicate recovery identity.")
        }
        for item in recovery {
            guard item.payload == "recovery/" + item.id,
                names.contains(item.payload + "/scene.wss.json")
            else {
                throw LibraryBackupError("Invalid recovery mapping.")
            }
        }
        let metadata = Set([
            "library.json", "playlists.json", "organization.json", "settings.json", "widgets.json",
        ])
        let payloadRoots = Set(
            wallpapers.flatMap { [$0.source, $0.native].compactMap { $0 } }
                + recovery.map(\.payload))
        for file in files where !metadata.contains(file.path) {
            let parts = file.path.split(separator: "/")
            let count = parts.first == "recovery" ? 2 : 3
            guard parts.count > count,
                payloadRoots.contains(parts.prefix(count).joined(separator: "/"))
            else {
                throw LibraryBackupError("Unmapped file in backup inventory.")
            }
        }

    }
}
struct LibraryBackupOrganization: Codable { let favorites: [UUID] }
struct LibraryBackupSettings: Codable {
    let profile: QualityProfile
    let sceneRenderResolution: String
    let sceneFPS: Int
    let conserve: Bool
    let pauseOnBattery: Bool
    let allDisplays: Bool
}
struct LibraryBackupWidgets: Codable {
    let customWidgetPackage: CustomWidgetPackage?
    let independentWidgets: [String: WidgetPlacement]
    let allDisplays: Bool
}
struct LibraryBackupPreferences {
    let organization: LibraryBackupOrganization
    let settings: LibraryBackupSettings
    let widgets: LibraryBackupWidgets
    init(defaults: UserDefaults) throws {
        organization = LibraryBackupOrganization(
            favorites: Array(
                Set(
                    (defaults.stringArray(forKey: "favorites") ?? []).compactMap(
                        UUID.init(uuidString:))
                )
            ).sorted { $0.uuidString < $1.uuidString })
        let fps = defaults.integer(forKey: "sceneFPS")
        settings = LibraryBackupSettings(
            profile: QualityProfile(rawValue: defaults.string(forKey: "profile") ?? "")
                ?? .original,
            sceneRenderResolution: SceneRenderResolution.stored(in: defaults).rawValue,
            sceneFPS: [24, 30, 60].contains(fps) ? fps : 30,
            conserve: defaults.object(forKey: "conserve") as? Bool ?? true,
            pauseOnBattery: defaults.object(forKey: "pauseOnBattery") as? Bool ?? true,
            allDisplays: defaults.object(forKey: "allDisplays") as? Bool ?? true)
        let custom = try defaults.data(forKey: "customWidgetPackage").map {
            try JSONDecoder().decode(CustomWidgetPackage.self, from: $0).validated()
        }
        let old =
            try defaults.data(forKey: "desktopWidgets").map {
                try JSONDecoder().decode(DesktopWidgetSettings.self, from: $0)
            } ?? DesktopWidgetSettings()
        let placements =
            try defaults.data(forKey: "independentWidgets").map {
                try JSONDecoder().decode([String: WidgetPlacement].self, from: $0)
            }
            ?? Dictionary(
                uniqueKeysWithValues: WidgetKind.allCases.map { kind in
                    let enabled: Bool
                    switch kind {
                    case .clock, .date: enabled = old.clock
                    case .cpu, .memory: enabled = old.stats
                    case .network:
                        enabled =
                            old.stats && (defaults.object(forKey: "widgetGraph") as? Bool ?? true)
                    case .custom: enabled = defaults.bool(forKey: "customWidgetEnabled")
                    }
                    return (kind.rawValue, WidgetPlacement(enabled: enabled, scale: 1))
                })
        guard
            placements.allSatisfy({
                WidgetKind(rawValue: $0.key) != nil && $0.value.scale.isFinite
                    && (0.6...2.5).contains($0.value.scale)
            })
        else {
            throw LibraryBackupError("Invalid saved widget configuration.")
        }
        widgets = LibraryBackupWidgets(
            customWidgetPackage: custom,
            independentWidgets: placements, allDisplays: old.allDisplays)
    }
}

// A lease survives actor reentrancy and awaits. Snapshot acquisition never blocks
// the main actor. Preferences are copied on the main actor at the lease boundary;
// later UI preference edits cannot change that independent value snapshot.
final class LibraryMutationBarrier: @unchecked Sendable {
    static let shared = LibraryMutationBarrier()
    private let lock = NSLock()
    private var mutations = 0
    private var snapshot = false
    final class Lease: @unchecked Sendable {
        private let release: () -> Void
        init(_ release: @escaping () -> Void) { self.release = release }
        deinit { release() }
    }
    func mutation() throws -> Lease {
        lock.lock()
        defer { lock.unlock() }
        guard !snapshot else {
            throw LibraryBackupError("Library backup is taking a snapshot. Try again shortly.")
        }
        mutations += 1
        return Lease {
            self.lock.lock()
            self.mutations -= 1
            self.lock.unlock()
        }
    }
    func trySnapshot() -> Lease? {
        lock.lock()
        defer { lock.unlock() }
        guard !snapshot, mutations == 0 else { return nil }
        snapshot = true
        return Lease {
            self.lock.lock()
            self.snapshot = false
            self.lock.unlock()
        }
    }
}
