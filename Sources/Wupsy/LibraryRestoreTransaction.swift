import Darwin
import Foundation

// Test-only crash simulation bypasses normal rollback to exercise a new process's
// persistent recovery path. Ordinary errors always attempt precommit rollback.
struct RestoreSimulatedCrash: Error {}
struct RestoreRuntimeQuiescence {
    // 8B.3 must stop/drain controllers and exclude backup/mutations before this.
    // Intentionally no default, no production factory, no UI entry point.
    init(callerGuaranteesQuiescentRuntime: Bool) throws {
        guard callerGuaranteesQuiescentRuntime else {
            throw LibraryBackupError("Restore requires an exclusively quiescent runtime.")
        }
    }
}
struct RestoreCommitReceipt {
    let transactionID: UUID
    let planFingerprint: String
    let cleanupPending: Bool
}
struct LibraryRestoreTransaction {
    enum Point: String, Sendable {
        case beforePrepared, afterPrepared, beforeOldRename, afterOldRename, afterAllOld,
            beforeNewRename, afterNewRename, afterAllNew, beforePreferences, preferenceWrite,
            afterPreferences, beforeCommit, afterCommit, cleanupEntry, rollback, recovery,
            journalTempWritten, journalRenamed, beforeRename, afterRename, cleanupOwnerRemoved,
            cleanupRootRemoved, journalRemoved
    }
    typealias Checkpoint = @Sendable (Point, String) throws -> Void
    let root: URL
    let preferences: LibraryRestorePreferences
    var checkpoint: Checkpoint = { _, _ in }
    init(root: URL, preferenceDomain: String) throws {
        self.root = root
        preferences = try LibraryRestorePreferences(domain: preferenceDomain)
    }
    func publish(_ prepared: PreparedLibraryRestore, quiescence: RestoreRuntimeQuiescence) throws
        -> RestoreCommitReceipt
    {
        _ = quiescence
        try LibraryMetadataRecovery.requireReadable(root: root)
        let io = try RestoreTransactionIO(root: root)
        guard try io.load() == nil else {
            throw LibraryBackupError("Restore recovery is required before another transaction.")
        }
        try prepared.validate()
        let claimed = try prepared.claimTransaction()
        var journalExists = false
        defer { if !journalExists { prepared.releaseTransactionClaim() } }
        let expected = root.appendingPathComponent(
            ".restore/staging/" + prepared.stagingID.uuidString)
        guard
            claimed.standardizedFileURL.resolvingSymlinksInPath().path
                == expected.standardizedFileURL.resolvingSymlinksInPath().path
        else {
            throw LibraryBackupError("Prepared restore belongs to another support root.")
        }
        let transaction = try RestoreTransactionIO.folder(io.staging, prepared.stagingID.uuidString)
        defer { close(transaction) }
        let engine = RestoreTransactionEngine(
            io: io, preferences: preferences, checkpoint: checkpoint)
        var journal = try engine.capture(prepared, transaction: transaction)
        do {
            try checkpoint(.beforePrepared, "")
            try io.persist(journal, transaction: transaction, checkpoint: checkpoint)
            journalExists = true
            try checkpoint(.afterPrepared, "")
            journal.phase = .publishing
            try io.persist(journal, transaction: transaction, checkpoint: checkpoint)
            if !journal.hadWallpapers {
                try engine.move(
                    .init(action: .installParent, index: 0), journal: &journal,
                    transaction: transaction)
            }
            for i in journal.slots.indices where journal.slots[i].old != nil {
                try checkpoint(.beforeOldRename, journal.slots[i].name)
                try engine.move(
                    .init(action: .moveOld, index: i), journal: &journal, transaction: transaction)
                try checkpoint(.afterOldRename, journal.slots[i].name)
            }
            try checkpoint(.afterAllOld, "")
            for i in journal.slots.indices {
                try checkpoint(.beforeNewRename, journal.slots[i].name)
                try engine.move(
                    .init(action: .publishNew, index: i), journal: &journal,
                    transaction: transaction)
                try checkpoint(.afterNewRename, journal.slots[i].name)
            }
            try engine.checkLayout(journal, transaction: transaction)
            try engine.checkB(journal, transaction: transaction)
            journal.phase = .newStatePublished
            try io.persist(journal, transaction: transaction, checkpoint: checkpoint)
            try checkpoint(.afterAllNew, "")
            try engine.apply(journal.newPreferences, label: "B")
            try checkpoint(.beforeCommit, "")
            journal.phase = .metadataCommitted
            try io.persist(journal, transaction: transaction, checkpoint: checkpoint)
            try checkpoint(.afterCommit, "")
        } catch {
            // The visible commit record may already have been atomically renamed
            // even when its final directory flush failed. Never undo that record.
            let persisted = try io.load()
            journalExists = journalExists || persisted != nil
            if error is RestoreSimulatedCrash { throw error }
            if let persisted, persisted.committed {
                // Commit reached disk, or durability is uncertain: preserve B and
                // require recovery if the journal boundary cannot be synced now.
                try RestoreTransactionIO.sync(transaction)
                try RestoreTransactionIO.sync(io.restore)
                return RestoreCommitReceipt(
                    transactionID: persisted.id, planFingerprint: persisted.planFingerprint,
                    cleanupPending: true)
            }
            if var persisted {
                do {
                    try engine.rollback(&persisted, transaction: transaction)
                    try engine.cleanup(&persisted, transaction: transaction)
                } catch {
                    throw LibraryBackupError(
                        "Restore failed; rollback/recovery remains pending: \(error.localizedDescription)"
                    )
                }
            }
            throw error
        }
        do {
            try engine.cleanup(&journal, transaction: transaction)
            return RestoreCommitReceipt(
                transactionID: journal.id, planFingerprint: journal.planFingerprint,
                cleanupPending: false)
        } catch is RestoreSimulatedCrash { throw RestoreSimulatedCrash() } catch {
            return RestoreCommitReceipt(
                transactionID: journal.id, planFingerprint: journal.planFingerprint,
                cleanupPending: true)
        }
    }
}

struct LibraryRestoreRecovery {
    enum Inspection: Equatable {
        case none
        case rollback(UUID)
        case finishCommitted(UUID)
        case finishRollback(UUID)
    }
    enum Result {
        case none, restoredA
        case retainedB(RestoreCommitReceipt)
    }
    let root: URL
    let preferences: LibraryRestorePreferences
    var checkpoint: LibraryRestoreTransaction.Checkpoint = { _, _ in }
    init(root: URL, preferenceDomain: String) throws {
        self.root = root
        preferences = try LibraryRestorePreferences(domain: preferenceDomain)
    }
    func inspect() throws -> Inspection {
        let io = try RestoreTransactionIO(root: root)
        guard let journal = try io.load() else { return .none }
        let fd = try io.verify(journal, preferenceDomain: preferences.domain)
        if let fd { close(fd) }
        if journal.committed { return .finishCommitted(journal.id) }
        if journal.phase == .rolledBack || journal.phase == .rollbackCleanupComplete {
            return .finishRollback(journal.id)
        }
        return .rollback(journal.id)
    }
    func recover(quiescence: RestoreRuntimeQuiescence) throws -> Result {
        _ = quiescence
        try LibraryMetadataRecovery.requireReadable(root: root)
        let io = try RestoreTransactionIO(root: root)
        guard var journal = try io.load() else { return .none }
        let transaction = try io.verify(journal, preferenceDomain: preferences.domain)
        defer { if let transaction { close(transaction) } }
        let engine = RestoreTransactionEngine(
            io: io, preferences: preferences, checkpoint: checkpoint)
        try checkpoint(.recovery, journal.phase.rawValue)
        if let transaction {
            if journal.committed {
                if journal.phase == .metadataCommitted {
                    try engine.checkLayout(journal, transaction: transaction)
                } else {
                    try engine.checkAuthoritativeRoots(journal)
                }
                try engine.apply(journal.newPreferences, label: "B-recovery")
            } else if journal.phase != .rolledBack && journal.phase != .rollbackCleanupComplete {
                try engine.rollback(&journal, transaction: transaction)
            } else {
                try engine.apply(journal.oldPreferences, label: "A-recovery")
            }
            try engine.cleanup(&journal, transaction: transaction)
        } else {
            try engine.checkAuthoritativeRoots(journal)
            try engine.apply(
                journal.committed ? journal.newPreferences : journal.oldPreferences,
                label: "final-recovery")
            try engine.removeJournal(journal)
        }
        if journal.committed {
            return .retainedB(
                .init(
                    transactionID: journal.id, planFingerprint: journal.planFingerprint,
                    cleanupPending: false))
        }
        return .restoredA
    }
    // 8B.1 markers have no independently authenticated persistent registry after
    // process death. Never infer ownership just from a plausible UUID/owner file.
    // Unknown/orphan staging is deliberately retained; callers may discard a live
    // PreparedLibraryRestore whose in-memory token still proves ownership.
}

private struct RestoreTransactionEngine {
    let io: RestoreTransactionIO
    let preferences: LibraryRestorePreferences
    let checkpoint: LibraryRestoreTransaction.Checkpoint
    func capture(_ prepared: PreparedLibraryRestore, transaction: Int32) throws
        -> LibraryRestoreJournal
    {
        guard
            try RestoreObjectIdentity.descriptor(transaction).device
                == RestoreObjectIdentity.descriptor(io.support).device
        else {
            throw LibraryBackupError("Restore staging must be on the support volume.")
        }
        for name in ["old", ".parents"] {
            guard mkdirat(transaction, name, 0o700) == 0 else {
                throw LibraryBackupError("Unexpected transaction destination already exists.")
            }
        }
        let old = try RestoreTransactionIO.folder(transaction, "old")
        defer { close(old) }
        close(try RestoreTransactionIO.folder(old, "Wallpapers", create: true))
        let parentArea = try RestoreTransactionIO.folder(transaction, ".parents")
        defer { close(parentArea) }
        let existing = try RestoreObjectIdentity.read(io.support, "Wallpapers")
        let wallpapers: RestoreObjectIdentity
        if let existing {
            wallpapers = existing
        } else {
            let candidate = try RestoreTransactionIO.folder(parentArea, "Wallpapers", create: true)
            defer { close(candidate) }
            wallpapers = try RestoreObjectIdentity.descriptor(candidate)
        }
        let new = try RestoreTransactionIO.folder(transaction, "new")
        defer { close(new) }
        try RestoreTransactionIO.flushTree(new)
        var slots: [RestoreSlot] = []
        for name in RestoreSlot.names {
            let oldID =
                name.hasPrefix("Wallpapers/") && existing == nil
                ? nil : try RestoreTransactionIO.identity(io.support, name)
            guard let newID = try RestoreTransactionIO.identity(new, name) else {
                throw LibraryBackupError("A prepared B slot is missing.")
            }
            slots.append(RestoreSlot(name: name, old: oldID, new: newID))
        }
        var files = prepared.plan.files.map {
            RestoreSealFile(path: $0.target, size: $0.source.size, hash: $0.source.sha256)
        }
        for path in ["library.json", "playlists.json"] {
            let fd = try LibraryBackupIO.input(prepared.newRoot.appendingPathComponent(path))
            defer { close(fd) }
            let (size, hash) = try LibraryBackupIO.stream(fd) { _ in }
            files.append(RestoreSealFile(path: path, size: size, hash: hash))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let seal = try encoder.encode(RestoreSeal(files: files.sorted { $0.path < $1.path }))
        try RestoreTransactionIO.write(seal, root: transaction, name: "seal.json")
        try RestoreTransactionIO.flushTree(old)
        try RestoreTransactionIO.flushTree(parentArea)
        try RestoreTransactionIO.sync(transaction)
        try RestoreTransactionIO.sync(io.staging)
        try RestoreTransactionIO.sync(io.restore)
        // Capture A at the transaction boundary, including local legacy layout.
        let a = try preferences.snapshot()
        let b = try LibraryRestorePreferences.projection(prepared.plan, preservingLocalState: a)
        let identity = [
            "manifest": LibraryBackupIO.digest(try encoder.encode(prepared.plan.manifest)),
            "library": LibraryBackupIO.digest(try encoder.encode(prepared.plan.library)),
            "playlists": LibraryBackupIO.digest(try encoder.encode(prepared.plan.playlists)),
            "preferences": LibraryBackupIO.digest(try encoder.encode(b)),
            "seal": LibraryBackupIO.digest(seal),
        ]
        let result = LibraryRestoreJournal(
            id: prepared.stagingID,
            owner: try RestoreTransactionIO.read(transaction, "owner.json", limit: 1024),
            support: try .descriptor(io.support), stagingParent: try .descriptor(io.staging),
            transaction: try .descriptor(transaction),
            wallpapers: wallpapers, hadWallpapers: existing != nil,
            parentInstalled: existing != nil,
            planFingerprint: LibraryBackupIO.digest(try encoder.encode(identity)),
            sealHash: LibraryBackupIO.digest(seal),
            preferenceDomain: preferences.domain, oldPreferences: a,
            newPreferences: b, slots: slots)
        try result.validate()
        try checkLayout(result, transaction: transaction)
        return result
    }
    func location(_ move: RestoreMove, _ journal: LibraryRestoreJournal, transaction: Int32) throws
        -> (Int32, String, Int32, String, RestoreObjectIdentity)
    {
        switch move.action {
        case .installParent:
            return (
                transaction, ".parents/Wallpapers", io.support, "Wallpapers", journal.wallpapers
            )
        case .removeParent:
            return (
                io.support, "Wallpapers", transaction, ".parents/Wallpapers", journal.wallpapers
            )
        case .moveOld:
            return (
                io.support, journal.slots[move.index].name, transaction,
                "old/" + journal.slots[move.index].name, journal.slots[move.index].old!
            )
        case .publishNew:
            return (
                transaction, "new/" + journal.slots[move.index].name, io.support,
                journal.slots[move.index].name, journal.slots[move.index].new
            )
        case .returnNew:
            return (
                io.support, journal.slots[move.index].name, transaction,
                "new/" + journal.slots[move.index].name, journal.slots[move.index].new
            )
        case .restoreOld:
            return (
                transaction, "old/" + journal.slots[move.index].name, io.support,
                journal.slots[move.index].name, journal.slots[move.index].old!
            )
        }
    }
    func completed(_ move: RestoreMove, journal: inout LibraryRestoreJournal) {
        switch move.action {
        case .installParent: journal.parentInstalled = true
        case .removeParent: journal.parentInstalled = false
        case .moveOld: journal.slots[move.index].oldMoved = true
        case .publishNew: journal.slots[move.index].newPublished = true
        case .returnNew: journal.slots[move.index].newPublished = false
        case .restoreOld: journal.slots[move.index].oldMoved = false
        }
    }
    func move(_ move: RestoreMove, journal: inout LibraryRestoreJournal, transaction: Int32) throws
    {
        try authorize(journal)
        journal.intent = move
        try io.persist(journal, transaction: transaction, checkpoint: checkpoint)
        let (from, source, to, target, identity) = try location(
            move, journal, transaction: transaction)
        let (sp, sn) = try RestoreTransactionIO.parent(from, source)
        defer { close(sp) }
        let (tp, tn) = try RestoreTransactionIO.parent(to, target)
        defer { close(tp) }
        guard try RestoreObjectIdentity.read(sp, sn) == identity,
            try RestoreObjectIdentity.read(tp, tn) == nil
        else {
            throw LibraryBackupError("Restore rename identity/absence mismatch.")
        }
        try checkpoint(.beforeRename, move.action.rawValue + ":" + target)
        try authorize(journal)
        guard try RestoreObjectIdentity.read(sp, sn) == identity,
            try RestoreObjectIdentity.read(tp, tn) == nil
        else {
            throw LibraryBackupError("Restore rename endpoints changed.")
        }
        guard renameatx_np(sp, sn, tp, tn, UInt32(RENAME_EXCL)) == 0 else {
            throw LibraryBackupError("Restore rename failed.")
        }
        try checkpoint(.afterRename, move.action.rawValue + ":" + target)
        try RestoreTransactionIO.sync(sp)
        try RestoreTransactionIO.sync(tp)
        completed(move, journal: &journal)
        journal.intent = nil
        try io.persist(journal, transaction: transaction, checkpoint: checkpoint)
    }
    func authorize(_ journal: LibraryRestoreJournal) throws {
        let fd = try io.verify(journal, preferenceDomain: preferences.domain)
        guard let fd else { throw LibraryBackupError("The active transaction root disappeared.") }
        close(fd)
    }
    func reconcile(_ journal: inout LibraryRestoreJournal, transaction: Int32) throws {
        try authorize(journal)
        guard let intent = journal.intent else { return }
        let (from, source, to, target, identity) = try location(
            intent, journal, transaction: transaction)
        let a = try RestoreTransactionIO.identity(from, source)
        let b = try RestoreTransactionIO.identity(to, target)
        if a == nil, b == identity {
            completed(intent, journal: &journal)
        } else if a != identity || b != nil {
            throw LibraryBackupError("Ambiguous restore rename intent.")
        }
        let (sp, _) = try RestoreTransactionIO.parent(from, source)
        defer { close(sp) }
        let (tp, _) = try RestoreTransactionIO.parent(to, target)
        defer { close(tp) }
        try RestoreTransactionIO.sync(sp)
        try RestoreTransactionIO.sync(tp)
        journal.intent = nil
        try io.persist(journal, transaction: transaction, checkpoint: checkpoint)
    }
    func checkLayout(_ journal: LibraryRestoreJournal, transaction: Int32) throws {
        let parent = try RestoreObjectIdentity.read(io.support, "Wallpapers")
        guard parent == (journal.parentInstalled ? journal.wallpapers : nil) else {
            throw LibraryBackupError("Productive wallpaper parent changed.")
        }
        for slot in journal.slots {
            let productive =
                !journal.parentInstalled && slot.name.hasPrefix("Wallpapers/")
                ? nil : try RestoreTransactionIO.identity(io.support, slot.name)
            let old = try RestoreTransactionIO.identity(transaction, "old/" + slot.name)
            let new = try RestoreTransactionIO.identity(transaction, "new/" + slot.name)
            guard productive == (slot.newPublished ? slot.new : (slot.oldMoved ? nil : slot.old)),
                old == (slot.oldMoved ? slot.old : nil), new == (slot.newPublished ? nil : slot.new)
            else {
                throw LibraryBackupError("Restore journal and slot layout disagree.")
            }
        }
    }
    func checkAuthoritativeRoots(_ journal: LibraryRestoreJournal) throws {
        guard
            try RestoreObjectIdentity.read(io.support, "Wallpapers")
                == ((journal.committed || journal.hadWallpapers) ? journal.wallpapers : nil)
        else {
            throw LibraryBackupError("Authoritative wallpaper root changed.")
        }
        for slot in journal.slots {
            let current =
                !journal.committed && !journal.hadWallpapers && slot.name.hasPrefix("Wallpapers/")
                ? nil : try RestoreTransactionIO.identity(io.support, slot.name)
            guard current == (journal.committed ? slot.new : slot.old) else {
                throw LibraryBackupError("Authoritative restore slot changed.")
            }
        }
    }
    func checkB(_ journal: LibraryRestoreJournal, transaction: Int32) throws {
        let bytes = try RestoreTransactionIO.read(
            transaction, "seal.json", limit: RestoreTransactionIO.journalLimit)
        guard LibraryBackupIO.digest(bytes) == journal.sealHash else {
            throw LibraryBackupError("Restore target seal changed.")
        }
        let seal = try LibraryRestoreJSON.decode(RestoreSeal.self, from: bytes)
        try LibraryBackupLimits.paths(seal.files.map(\.path))
        var actual: [String] = []
        var count = 0
        for slot in journal.slots {
            let (parent, name) = try RestoreTransactionIO.parent(io.support, slot.name)
            defer { close(parent) }
            if slot.new.kind == UInt16(S_IFDIR) {
                let dir = try RestoreTransactionIO.folder(parent, name)
                defer { close(dir) }
                actual += try RestoreTransactionIO.inventory(
                    dir, prefix: slot.name + "/", count: &count)
            } else {
                actual.append(slot.name)
            }
        }
        guard Set(actual) == Set(seal.files.map(\.path)) else {
            throw LibraryBackupError("Published restore inventory mismatch.")
        }
        for file in seal.files {
            guard
                RestoreSlot.names.contains(where: {
                    file.path == $0 || file.path.hasPrefix($0 + "/")
                })
            else { throw LibraryBackupError("Unsafe restore seal path.") }
            let fd = try LibraryBackupIO.input(io.root.appendingPathComponent(file.path))
            defer { close(fd) }
            let (size, hash) = try LibraryBackupIO.stream(fd) { _ in }
            guard size == file.size, hash == file.hash else {
                throw LibraryBackupError("Published restore target integrity mismatch.")
            }
        }
    }
    func apply(_ values: [String: RestorePreferenceValue], label: String) throws {
        try checkpoint(.beforePreferences, label)
        for key in LibraryRestorePreferences.keys {
            try preferences.write(values[key]!, key: key)
            // Per-write synchronization makes every injected intermediate state
            // a real persistent partial projection, not just a process cache.
            try preferences.synchronize()
            try checkpoint(.preferenceWrite, label + ":" + key)
        }
        try preferences.confirm(values)
        try checkpoint(.afterPreferences, label)
    }
    func rollback(_ journal: inout LibraryRestoreJournal, transaction: Int32) throws {
        guard !journal.committed else {
            throw LibraryBackupError("A committed restore cannot roll back.")
        }
        try reconcile(&journal, transaction: transaction)
        try checkLayout(journal, transaction: transaction)
        journal.phase = .rollingBack
        try io.persist(journal, transaction: transaction, checkpoint: checkpoint)
        try checkpoint(.rollback, "begin")
        for i in journal.slots.indices.reversed() where journal.slots[i].newPublished {
            try move(
                .init(action: .returnNew, index: i), journal: &journal, transaction: transaction)
            try checkpoint(.rollback, "returned:" + journal.slots[i].name)
        }
        for i in journal.slots.indices where journal.slots[i].oldMoved {
            try move(
                .init(action: .restoreOld, index: i), journal: &journal, transaction: transaction)
            try checkpoint(.rollback, "restored:" + journal.slots[i].name)
        }
        if !journal.hadWallpapers, journal.parentInstalled {
            let wallpapers = try RestoreTransactionIO.folder(io.support, "Wallpapers")
            defer { close(wallpapers) }
            guard try RestoreTransactionIO.children(wallpapers).isEmpty else {
                throw LibraryBackupError(
                    "Unexpected data prevents removing the restore-created parent.")
            }
            try move(
                .init(action: .removeParent, index: 0), journal: &journal, transaction: transaction)
        }
        try apply(journal.oldPreferences, label: "A-rollback")
        journal.phase = .rolledBack
        try io.persist(journal, transaction: transaction, checkpoint: checkpoint)
        try checkpoint(.rollback, "complete")
    }
    func cleanup(_ journal: inout LibraryRestoreJournal, transaction: Int32) throws {
        let verified = try io.verify(journal, preferenceDomain: preferences.domain)
        if let verified { close(verified) }
        try checkAuthoritativeRoots(journal)
        guard
            journal.committed || journal.phase == .rolledBack
                || journal.phase == .rollbackCleanupComplete
        else {
            throw LibraryBackupError("Cleanup is forbidden before commit or confirmed rollback.")
        }
        if journal.phase != .cleanupComplete && journal.phase != .rollbackCleanupComplete {
            for slot in journal.slots {
                let old = try RestoreTransactionIO.optionalIdentity(transaction, "old/" + slot.name)
                let new = try RestoreTransactionIO.optionalIdentity(transaction, "new/" + slot.name)
                guard old == nil || (journal.committed && old == slot.old),
                    new == nil || (!journal.committed && new == slot.new)
                else {
                    throw LibraryBackupError("A remaining cleanup slot has an unknown identity.")
                }
            }
            if journal.committed {
                journal.phase = .cleanupPending
                try io.persist(journal, transaction: transaction, checkpoint: checkpoint)
            }
            for name in try RestoreTransactionIO.children(transaction) where name != "owner.json" {
                try RestoreTransactionIO.remove(transaction, name, checkpoint: checkpoint)
            }
            journal.phase = journal.committed ? .cleanupComplete : .rollbackCleanupComplete
            try io.persist(journal, transaction: transaction, checkpoint: checkpoint)
        }
        // Durable terminal intent permits recovery after owner/root removal, but
        // before journal unlink. No other missing-owner state is accepted.
        if try RestoreObjectIdentity.read(transaction, "owner.json") != nil {
            guard
                try RestoreTransactionIO.read(transaction, "owner.json", limit: 1024)
                    == journal.owner
            else { throw LibraryBackupError("Cleanup owner changed.") }
            guard unlinkat(transaction, "owner.json", 0) == 0 else {
                throw LibraryBackupError("Cannot remove cleanup marker.")
            }
        }
        try checkpoint(.cleanupOwnerRemoved, "")
        try RestoreTransactionIO.sync(transaction)
        guard unlinkat(io.staging, journal.id.uuidString, AT_REMOVEDIR) == 0 else {
            throw LibraryBackupError("Cannot finalize transaction cleanup.")
        }
        try checkpoint(.cleanupRootRemoved, "")
        try RestoreTransactionIO.sync(io.staging)
        try removeJournal(journal)
    }
    func removeJournal(_ journal: LibraryRestoreJournal) throws {
        guard let current = try io.load(), current.id == journal.id, current.phase == journal.phase
        else { throw LibraryBackupError("Journal changed before final removal.") }
        guard unlinkat(io.restore, "journal.json", 0) == 0 else {
            throw LibraryBackupError("Cannot remove completed restore journal.")
        }
        try checkpoint(.journalRemoved, "")
        try RestoreTransactionIO.sync(io.restore)
    }
}
