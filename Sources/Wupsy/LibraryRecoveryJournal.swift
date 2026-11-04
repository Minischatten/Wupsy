import Darwin
import Foundation

struct LibraryRecoveryJournal: Codable {
    enum Phase: String, Codable { case prepared, installing, rollingBack, rolledBack, committed }
    struct Slot: Codable {
        let path: String
        let backup: String
        let candidate: String
        let before: RecoveryFileFingerprint
        let after: RecoveryFileFingerprint
        var installed = false
    }
    let version: Int
    let id: UUID
    let support: RestoreObjectIdentity
    let staging: RestoreObjectIdentity
    let transaction: RestoreObjectIdentity
    let planHash: String
    var phase: Phase
    var slots: [Slot]
    var intent: String?

    var terminal: Bool { phase == .committed || phase == .rolledBack }
    func validate() throws {
        guard version == 1, slots.map(\.path) == LibraryMetadataRecovery.names,
            planHash.count == 64, planHash.allSatisfy({ "0123456789abcdef".contains($0) }),
            [support, staging, transaction].allSatisfy({
                $0.kind == UInt16(S_IFDIR) && $0.device == support.device
            }),
            intent.map({ LibraryMetadataRecovery.names.contains($0) }) ?? true,
            !terminal || intent == nil,
            phase != .committed || slots.allSatisfy(\.installed),
            phase != .rolledBack || slots.allSatisfy({ !$0.installed })
        else { throw LibraryBackupError("Invalid metadata recovery journal.") }
        for slot in slots {
            try slot.before.validate()
            try slot.after.validate()
            guard slot.before.path == slot.path, slot.after.path == slot.path,
                slot.backup == "before-" + slot.path, slot.candidate == "after-" + slot.path
            else {
                throw LibraryBackupError("Invalid metadata recovery journal slot.")
            }
        }
    }
}

/// Shared Phase-8 primitives: pinned descriptors, no-follow traversal, exclusive
/// writes, file/directory sync, root flock and controlled atomic renames.
/// Only two allowlisted metadata destinations can be installed by this adapter.
extension RestoreTransactionIO {
    static func replaceMetadata(
        _ data: Data, directory: Int32, name: String,
        expected: RestoreObjectIdentity?
    ) throws {
        guard ["library.json", "playlists.json", "metadata-recovery.json"].contains(name) else {
            throw LibraryBackupError("Unapproved recovery destination.")
        }
        let temporary = ".metadata-" + UUID().uuidString
        try write(data, root: directory, name: temporary)
        defer { unlinkat(directory, temporary, 0) }
        guard try RestoreObjectIdentity.read(directory, name) == expected,
            renameatx_np(
                directory, temporary, directory, name, expected == nil ? UInt32(RENAME_EXCL) : 0)
                == 0
        else { throw LibraryBackupError("Metadata destination changed or atomic install failed.") }
        try sync(directory)
    }
}
