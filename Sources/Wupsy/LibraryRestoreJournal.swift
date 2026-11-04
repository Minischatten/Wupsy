import Darwin
import Foundation

struct RestoreObjectIdentity: Codable, Equatable, Hashable {
    let device: Int32
    let inode: UInt64
    let kind: UInt16
    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        kind = info.st_mode & mode_t(S_IFMT)
    }
    static func read(_ parent: Int32, _ name: String) throws -> Self? {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw LibraryBackupError("Cannot inspect restore object.")
        }
        guard
            info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
                || (info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && info.st_nlink == 1)
        else {
            throw LibraryBackupError("Unsafe restore slot or link.")
        }
        return Self(info)
    }
    static func descriptor(_ fd: Int32) throws -> Self {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw LibraryBackupError("Cannot identify restore descriptor.")
        }
        return Self(info)
    }
}
struct RestoreSlot: Codable {
    // Explicit order: payloads first, library.json last.
    static let names = [
        "Wallpapers/Packages", "Wallpapers/Loose", "Wallpapers/Media", "Wallpapers/Web",
        "Wallpapers/WSS", "Wallpapers/NativeProjects", "playlists.json", "library.json",
    ]
    let name: String
    let old: RestoreObjectIdentity?
    let new: RestoreObjectIdentity
    var oldMoved = false
    var newPublished = false
}
struct RestoreMove: Codable, Equatable {
    enum Action: String, Codable {
        case installParent, removeParent, moveOld, publishNew, returnNew, restoreOld
    }
    let action: Action
    let index: Int
}
struct RestoreSealFile: Codable {
    let path: String
    let size: Int64
    let hash: String
}
struct RestoreSeal: Codable {
    let files: [RestoreSealFile]
}
struct LibraryRestoreJournal: Codable {
    enum Phase: String, Codable {
        case prepared, publishing, newStatePublished, rollingBack, metadataCommitted,
            cleanupPending, cleanupComplete, rolledBack, rollbackCleanupComplete
    }
    var version = 1
    let id: UUID
    let owner: Data
    let support: RestoreObjectIdentity
    let stagingParent: RestoreObjectIdentity
    let transaction: RestoreObjectIdentity
    let wallpapers: RestoreObjectIdentity
    let hadWallpapers: Bool
    var parentInstalled: Bool
    let planFingerprint: String
    let sealHash: String
    let preferenceDomain: String
    let oldPreferences: [String: RestorePreferenceValue]
    let newPreferences: [String: RestorePreferenceValue]
    var slots: [RestoreSlot]
    var phase: Phase = .prepared
    var intent: RestoreMove?
    var committed: Bool {
        phase == .metadataCommitted || phase == .cleanupPending || phase == .cleanupComplete
    }
    func validate() throws {
        guard version == 1, owner.count <= 1024, slots.map(\.name) == RestoreSlot.names,
            planFingerprint.count == 64, sealHash.count == 64,
            Set(oldPreferences.keys) == Set(LibraryRestorePreferences.keys),
            Set(newPreferences.keys) == Set(LibraryRestorePreferences.keys),
            intent.map({ (0..<8).contains($0.index) }) ?? true,
            support.kind == UInt16(S_IFDIR), stagingParent.kind == UInt16(S_IFDIR),
            transaction.kind == UInt16(S_IFDIR), wallpapers.kind == UInt16(S_IFDIR),
            [support, stagingParent, transaction, wallpapers].allSatisfy({
                $0.device == support.device
            }),
            slots.allSatisfy({
                $0.new.device == support.device
                    && ($0.old?.device ?? support.device) == support.device
            })
        else {
            throw LibraryBackupError("Invalid or unsupported restore journal.")
        }
        let marker = try LibraryRestoreJSON.decode([String: String].self, from: owner)
        guard marker.count == 3, marker["version"] == "1", marker["id"] == id.uuidString,
            marker["token"].flatMap(UUID.init(uuidString:)) != nil
        else { throw LibraryBackupError("Invalid journal ownership.") }
        for value in Array(oldPreferences.values) + Array(newPreferences.values) {
            _ = try value.value()
        }
        for (index, slot) in slots.enumerated() {
            let kind = index < 6 ? UInt16(S_IFDIR) : UInt16(S_IFREG)
            guard slot.new.kind == kind, slot.old.map({ $0.kind == kind }) ?? true,
                slot.old != slot.new, slot.old != nil || !slot.oldMoved
            else { throw LibraryBackupError("Invalid restore slot identity.") }
        }
        guard Set(slots.map(\.new)).count == slots.count,
            Set(slots.compactMap(\.old)).count == slots.compactMap(\.old).count
        else {
            throw LibraryBackupError("Duplicate transaction slot identities.")
        }
        if let intent {
            let slot = slots[intent.index]
            let valid: Bool
            switch intent.action {
            case .installParent: valid = phase == .publishing && !hadWallpapers && !parentInstalled
            case .removeParent: valid = phase == .rollingBack && !hadWallpapers && parentInstalled
            case .moveOld:
                valid =
                    phase == .publishing && slot.old != nil && !slot.oldMoved && !slot.newPublished
            case .publishNew:
                valid =
                    phase == .publishing && !slot.newPublished && (slot.old == nil || slot.oldMoved)
            case .returnNew: valid = phase == .rollingBack && slot.newPublished
            case .restoreOld:
                valid =
                    phase == .rollingBack && slot.old != nil && slot.oldMoved && !slot.newPublished
            }
            guard valid else { throw LibraryBackupError("Contradictory restore rename intent.") }
        }
        if phase == .prepared {
            guard intent == nil, !slots.contains(where: { $0.oldMoved || $0.newPublished }),
                parentInstalled == hadWallpapers
            else {
                throw LibraryBackupError("Invalid prepared journal state.")
            }
        }
        if committed || phase == .newStatePublished {
            guard intent == nil, parentInstalled,
                slots.allSatisfy({ $0.newPublished && ($0.old == nil || $0.oldMoved) })
            else {
                throw LibraryBackupError("Invalid committed journal state.")
            }
        }
        if phase == .rolledBack || phase == .rollbackCleanupComplete {
            guard intent == nil, !slots.contains(where: { $0.oldMoved || $0.newPublished }),
                parentInstalled == hadWallpapers
            else {
                throw LibraryBackupError("Invalid rollback journal state.")
            }
        }
    }
}
