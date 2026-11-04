import Darwin
import Foundation

/// Internal, explicit-plan API. Caller must hold exclusive maintenance admission,
/// drain all runtime users (or run offline), and never start the app concurrently.
/// Precommit interruptions always roll back; a durable commit retains the target.
struct LibraryMetadataRecovery {
    static let names = ["playlists.json", "library.json"]
    static let journalName = "metadata-recovery.json"
    enum Point: String, CaseIterable {
        case beforeFirstInstall, afterFirstInstall, beforeSecondInstall, afterSecondInstall,
            beforeCommit, afterCommit, rollback, beforeRename, afterRename, journalRenamed
    }
    typealias Checkpoint = (Point, String) throws -> Void
    enum Outcome: Equatable {
        case none
        case rolledBack(UUID)
        case committed(UUID)
    }
    let root: URL
    var checkpoint: Checkpoint = { _, _ in }

    func apply(_ plan: LibraryRecoveryPlan, quiescence: RestoreRuntimeQuiescence) throws -> Outcome
    {
        _ = quiescence
        // Read-only validation first: invalid plans cannot create even staging files.
        try Self.requireReadable(root: root)
        try plan.validate(root: root, verifyOriginalMetadata: true)
        let io = try RestoreTransactionIO(root: root)
        guard try io.load() == nil else {
            throw LibraryBackupError("Full restore recovery must finish before metadata recovery.")
        }
        if let prior = try Self.load(io.restore) {
            guard prior.terminal, prior.id != plan.id else {
                throw LibraryBackupError(
                    "Recovery transaction is pending or has already been used.")
            }
        }
        try plan.validate(root: root, verifyOriginalMetadata: true)
        guard mkdirat(io.staging, plan.id.uuidString, 0o700) == 0 else {
            throw LibraryBackupError(
                "Recovery transaction ID already exists; retained evidence was not overwritten.")
        }
        let tx = try RestoreTransactionIO.folder(io.staging, plan.id.uuidString)
        defer { close(tx) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let planBytes = try encoder.encode(plan)
        guard planBytes.count <= RestoreTransactionIO.journalLimit else {
            throw LibraryBackupError("Recovery plan exceeds its budget.")
        }
        try RestoreTransactionIO.write(planBytes, root: tx, name: "plan.json")
        var slots: [LibraryRecoveryJournal.Slot] = []
        for (index, path) in Self.names.enumerated() {
            let bytes = try RestoreTransactionIO.read(
                io.support, path, limit: LibraryBackupLimits.manifest)
            guard LibraryBackupIO.digest(bytes) == plan.expectedMetadata[index].sha256,
                bytes.count == plan.expectedMetadata[index].size
            else {
                throw LibraryBackupError("Recovery baseline changed before capture.")
            }
            let target = path == "library.json" ? plan.library : plan.playlists
            try RestoreTransactionIO.write(bytes, root: tx, name: "before-" + path)
            try RestoreTransactionIO.write(target, root: tx, name: "after-" + path)
            slots.append(
                .init(
                    path: path, backup: "before-" + path, candidate: "after-" + path,
                    before: plan.expectedMetadata[index],
                    after: .init(
                        path: path, size: Int64(target.count),
                        sha256: LibraryBackupIO.digest(target))))
        }
        try RestoreTransactionIO.flushTree(tx)
        try RestoreTransactionIO.sync(io.staging)
        try RestoreTransactionIO.sync(io.restore)
        try RestoreTransactionIO.sync(io.support)
        var journal = LibraryRecoveryJournal(
            version: 1, id: plan.id,
            support: try .descriptor(io.support), staging: try .descriptor(io.staging),
            transaction: try .descriptor(tx),
            planHash: LibraryBackupIO.digest(planBytes), phase: .prepared, slots: slots)
        do {
            try plan.validate(root: root, verifyOriginalMetadata: true)
            try persist(journal, io: io)
            journal.phase = .installing
            try persist(journal, io: io)
            for index in Self.names.indices {
                try checkpoint(
                    index == 0 ? .beforeFirstInstall : .beforeSecondInstall, Self.names[index])
                try install(index, rollback: false, journal: &journal, io: io, tx: tx)
                try checkpoint(
                    index == 0 ? .afterFirstInstall : .afterSecondInstall, Self.names[index])
            }
            try plan.validate(root: root, verifyOriginalMetadata: false)
            try verifyFiles(journal, io: io, after: true)
            try checkpoint(.beforeCommit, "")
            journal.phase = .committed
            try persist(journal, io: io)
            try checkpoint(.afterCommit, "")
            return .committed(plan.id)
        } catch {
            if error is RestoreSimulatedCrash { throw error }
            let original = error
            do {
                if var persisted = try Self.load(io.restore) {
                    guard persisted.id == plan.id else {
                        throw LibraryBackupError("Recovery journal ownership changed.")
                    }
                    if persisted.phase == .committed {
                        throw LibraryBackupError(
                            "Commit record exists; recovery preflight must confirm durability.")
                    }
                    try rollback(&persisted, io: io, tx: tx)
                }
            } catch {
                throw LibraryBackupError(
                    "Metadata recovery failed (\(original.localizedDescription)); rollback unresolved: \(error.localizedDescription). Runtime must remain stopped."
                )
            }
            throw original
        }
    }

    /// Read-only startup gate. A terminal journal is not replayed, even if users
    /// subsequently edit the library. Corrupt journals/unsafe namespaces fail closed.
    static func requireReadable(root: URL) throws {
        try ManagedWallpaperStore.checkPath(root)
        let restoreURL = root.appendingPathComponent(".restore")
        try ManagedWallpaperStore.checkPath(restoreURL)
        var info = stat()
        if lstat(restoreURL.path, &info) != 0 {
            if errno == ENOENT { return }
            throw LibraryBackupError("Cannot inspect metadata recovery namespace.")
        }
        let parent = try WSSAssetIO.directory(root)
        defer { close(parent) }
        let fd = try RestoreTransactionIO.folder(parent, ".restore")
        defer { close(fd) }
        if let journal = try load(fd) {
            guard journal.terminal else {
                throw LibraryBackupError(
                    "Incomplete metadata recovery; startup recovery is required before loading or saving."
                )
            }
            let support = try WSSAssetIO.directory(root)
            defer { close(support) }
            let staging = try RestoreTransactionIO.folder(fd, "staging")
            defer { close(staging) }
            let tx = try RestoreTransactionIO.folder(staging, journal.id.uuidString)
            defer { close(tx) }
            try verifyEvidence(journal, support: support, staging: staging, tx: tx)
        }
    }
    static func load(_ restore: Int32) throws -> LibraryRecoveryJournal? {
        guard try RestoreObjectIdentity.read(restore, journalName) != nil else { return nil }
        let journal = try LibraryRestoreJSON.decode(
            LibraryRecoveryJournal.self,
            from: RestoreTransactionIO.read(
                restore, journalName, limit: RestoreTransactionIO.journalLimit))
        try journal.validate()
        return journal
    }

    /// Runs before construction of Library/Playlist/Editor. No journal => no writes.
    /// Incomplete transactions restore exact A; terminal transactions are never replayed.
    func preflight(quiescence: RestoreRuntimeQuiescence) throws -> Outcome {
        _ = quiescence
        let restoreURL = root.appendingPathComponent(".restore")
        try ManagedWallpaperStore.checkPath(root)
        try ManagedWallpaperStore.checkPath(restoreURL)
        var info = stat()
        if lstat(restoreURL.path, &info) != 0 {
            if errno == ENOENT { return .none }
            throw LibraryBackupError("Cannot inspect recovery state.")
        }
        let support = try WSSAssetIO.directory(root)
        defer { close(support) }
        let restore = try RestoreTransactionIO.folder(support, ".restore")
        defer { close(restore) }
        guard try Self.load(restore) != nil else { return .none }
        let io = try RestoreTransactionIO(root: root)
        guard var journal = try Self.load(io.restore) else {
            throw LibraryBackupError("Recovery journal disappeared.")
        }
        let tx = try RestoreTransactionIO.folder(io.staging, journal.id.uuidString)
        defer { close(tx) }
        try Self.verifyEvidence(journal, support: io.support, staging: io.staging, tx: tx)
        if journal.phase == .committed {
            try RestoreTransactionIO.sync(io.restore)
            return .committed(journal.id)
        }
        if journal.phase != .rolledBack { try rollback(&journal, io: io, tx: tx) }
        try RestoreTransactionIO.sync(io.restore)
        return .rolledBack(journal.id)
    }

    private static func verifyEvidence(
        _ journal: LibraryRecoveryJournal, support: Int32, staging: Int32, tx: Int32
    ) throws {
        try journal.validate()
        guard try RestoreObjectIdentity.descriptor(support) == journal.support,
            try RestoreObjectIdentity.descriptor(staging) == journal.staging,
            try RestoreObjectIdentity.descriptor(tx) == journal.transaction
        else {
            throw LibraryBackupError("Recovery root or transaction identity changed.")
        }
        let bytes = try RestoreTransactionIO.read(
            tx, "plan.json", limit: RestoreTransactionIO.journalLimit)
        guard LibraryBackupIO.digest(bytes) == journal.planHash else {
            throw LibraryBackupError("Recovery plan seal mismatch.")
        }
        let plan = try LibraryRestoreJSON.decode(LibraryRecoveryPlan.self, from: bytes)
        guard plan.version == 1, plan.id == journal.id,
            plan.expectedMetadata == journal.slots.map(\.before),
            plan.library
                == (try RestoreTransactionIO.read(
                    tx, "after-library.json", limit: LibraryBackupLimits.manifest)),
            plan.playlists
                == (try RestoreTransactionIO.read(
                    tx, "after-playlists.json", limit: WallpaperPlaylistStore.byteLimit))
        else { throw LibraryBackupError("Recovery journal/plan mismatch.") }
        for slot in journal.slots {
            for (prefix, fingerprint) in [("before-", slot.before), ("after-", slot.after)] {
                let bytes = try RestoreTransactionIO.read(
                    tx, prefix + slot.path, limit: LibraryBackupLimits.manifest)
                guard bytes.count == fingerprint.size,
                    LibraryBackupIO.digest(bytes) == fingerprint.sha256
                else {
                    throw LibraryBackupError("Recovery snapshot integrity failure.")
                }
            }
        }
    }
    private func authorize(_ journal: LibraryRecoveryJournal, io: RestoreTransactionIO, tx: Int32)
        throws
    {
        let support = try WSSAssetIO.directory(root)
        defer { close(support) }
        let restore = try RestoreTransactionIO.folder(support, ".restore")
        defer { close(restore) }
        let staging = try RestoreTransactionIO.folder(restore, "staging")
        defer { close(staging) }
        guard try RestoreObjectIdentity.descriptor(support) == journal.support,
            try RestoreObjectIdentity.descriptor(restore)
                == RestoreObjectIdentity.descriptor(io.restore),
            try RestoreObjectIdentity.descriptor(staging) == journal.staging,
            try RestoreObjectIdentity.read(staging, journal.id.uuidString) == journal.transaction
        else { throw LibraryBackupError("Recovery namespace changed.") }
        try Self.verifyEvidence(journal, support: io.support, staging: io.staging, tx: tx)
    }
    private func persist(_ journal: LibraryRecoveryJournal, io: RestoreTransactionIO) throws {
        try journal.validate()
        let support = try WSSAssetIO.directory(root)
        defer { close(support) }
        let restore = try RestoreTransactionIO.folder(support, ".restore")
        defer { close(restore) }
        guard try RestoreObjectIdentity.descriptor(support) == journal.support,
            try RestoreObjectIdentity.descriptor(restore)
                == RestoreObjectIdentity.descriptor(io.restore)
        else {
            throw LibraryBackupError("Recovery namespace changed before journal publication.")
        }
        let prior = try RestoreObjectIdentity.read(io.restore, Self.journalName)
        if let current = try Self.load(io.restore) {
            guard current.id == journal.id || (journal.phase == .prepared && current.terminal)
            else {
                throw LibraryBackupError("Another recovery owns the journal.")
            }
        } else if journal.phase != .prepared {
            throw LibraryBackupError("The active recovery journal disappeared.")
        }
        try RestoreTransactionIO.replaceMetadata(
            JSONEncoder().encode(journal), directory: io.restore,
            name: Self.journalName, expected: prior)
        try checkpoint(.journalRenamed, journal.phase.rawValue)
    }
    private func install(
        _ index: Int, rollback: Bool, journal: inout LibraryRecoveryJournal,
        io: RestoreTransactionIO, tx: Int32
    ) throws {
        try authorize(journal, io: io, tx: tx)
        let slot = journal.slots[index]
        let actual = try RecoveryFileFingerprint.capture(root: root, path: slot.path)
        // Covers a crash between rename and status publication. Never overwrite an
        // unrelated third value, including during rollback.
        guard actual == slot.before || actual == slot.after else {
            throw LibraryBackupError("Unexpected metadata bytes; refusing recovery overwrite.")
        }
        let identity = try RestoreObjectIdentity.read(io.support, slot.path)
        journal.intent = slot.path
        try persist(journal, io: io)
        let bytes = try RestoreTransactionIO.read(
            tx, (rollback ? "before-" : "after-") + slot.path,
            limit: LibraryBackupLimits.manifest)
        try checkpoint(.beforeRename, slot.path)
        try authorize(journal, io: io, tx: tx)
        guard try RecoveryFileFingerprint.capture(root: root, path: slot.path) == actual else {
            throw LibraryBackupError("Metadata changed immediately before installation.")
        }
        try RestoreTransactionIO.replaceMetadata(
            bytes, directory: io.support, name: slot.path, expected: identity)
        try checkpoint(.afterRename, slot.path)
        journal.slots[index].installed = !rollback
        journal.intent = nil
        try persist(journal, io: io)
    }
    private func verifyFiles(
        _ journal: LibraryRecoveryJournal, io: RestoreTransactionIO, after: Bool
    ) throws {
        for slot in journal.slots {
            guard
                try RecoveryFileFingerprint.capture(root: root, path: slot.path)
                    == (after ? slot.after : slot.before)
            else {
                throw LibraryBackupError("Installed recovery metadata failed disk verification.")
            }
        }
    }
    private func rollback(
        _ journal: inout LibraryRecoveryJournal, io: RestoreTransactionIO, tx: Int32
    ) throws {
        try authorize(journal, io: io, tx: tx)
        // Validate both endpoints before rolling back either one.
        for slot in journal.slots {
            let actual = try RecoveryFileFingerprint.capture(root: root, path: slot.path)
            guard actual == slot.before || actual == slot.after else {
                throw LibraryBackupError("Rollback endpoint changed; manual resolution required.")
            }
        }
        journal.phase = .rollingBack
        try persist(journal, io: io)
        for index in Self.names.indices.reversed() {
            try checkpoint(.rollback, Self.names[index])
            try install(index, rollback: true, journal: &journal, io: io, tx: tx)
        }
        try verifyFiles(journal, io: io, after: false)
        journal.phase = .rolledBack
        try persist(journal, io: io)
    }
}
