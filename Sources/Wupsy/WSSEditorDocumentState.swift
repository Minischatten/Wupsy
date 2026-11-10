import Foundation

struct WSSSaveSnapshot {
    let sessionID: UUID
    let operationID: UUID
    let revision: UInt64
    let model: WSSSceneDocumentV1
    let savedModel: WSSSceneDocumentV1
    let diskBasis: WSSProjectDiskBasis
    let resourceCatalog: [String: WSSContentFingerprint]?
    let sessionAssets: [String: WSSImageGeneration]
    let resourceLease: WSSSessionResourceLease?
    init(
        sessionID: UUID, operationID: UUID, revision: UInt64, model: WSSSceneDocumentV1,
        savedModel: WSSSceneDocumentV1, diskBasis: WSSProjectDiskBasis,
        resourceCatalog: [String: WSSContentFingerprint]? = nil,
        sessionAssets: [String: WSSImageGeneration] = [:],
        resourceLease: WSSSessionResourceLease? = nil
    ) {
        self.sessionID = sessionID
        self.operationID = operationID
        self.revision = revision
        self.model = model
        self.savedModel = savedModel
        self.diskBasis = diskBasis
        self.resourceCatalog = resourceCatalog
        self.sessionAssets = sessionAssets
        self.resourceLease = resourceLease
    }
}

struct WSSSaveReceipt {
    enum Outcome: Equatable {
        case unchanged
        case committed(warnings: [String])
    }
    let snapshot: WSSSaveSnapshot
    let diskBasis: WSSProjectDiskBasis
    let outcome: Outcome
}

// Internal value-state core only. No UI binding, autosave or undo history.
struct WSSEditorDocumentState {
    let sessionID = UUID()
    private(set) var workingModel: WSSSceneDocumentV1
    private(set) var workingRevision: UInt64 = 0
    private(set) var savedModel: WSSSceneDocumentV1
    private(set) var savedRevision: UInt64 = 0
    private(set) var diskBasis: WSSProjectDiskBasis
    private(set) var resourceCatalog: [String: WSSContentFingerprint]
    private var ownedGenerations: [String: WSSImageGeneration] = [:]
    private let resourcePool = WSSSessionResourcePool()
    private var vectorGenerationPaths: Set<String> = []
    var sessionAssets: [String: WSSImageGeneration] {
        closed ? [:] : resourcePool.liveGenerations()
    }
    var protectedGenerationPaths: Set<String> {
        workingModel.referencedPaths.union(savedModel.referencedPaths).union(
            resourcePool.pinnedPaths)
    }
    func pinPreviewResources(_ paths: Set<String>) -> WSSSessionResourceLease {
        resourcePool.pin(paths)
    }
    private var pending: UUID?
    private var closed = false
    var isDirty: Bool { workingModel != savedModel }
    init(model: WSSSceneDocumentV1, diskBasis: WSSProjectDiskBasis) {
        workingModel = model
        savedModel = model
        self.diskBasis = diskBasis
        resourceCatalog = diskBasis.assets
    }
    mutating func retainGeneration(_ generation: WSSImageGeneration) throws {
        try retainGenerations([generation])
    }
    mutating func retainGenerations(
        _ generations: [WSSImageGeneration], reusingExisting: Bool = false,
        excludingHistoryPaths: Set<String> = []
    ) throws {
        guard !closed else { throw WSSImageImportError.storage }
        let live = sessionAssets
        var candidate = live.filter { !excludingHistoryPaths.contains($0.key) }
        for generation in generations {
            if reusingExisting, live[generation.path] === generation {
                guard resourceCatalog[generation.path] == generation.fingerprint else {
                    throw WSSImageImportError.storage
                }
                continue
            }
            guard resourceCatalog[generation.path] == nil, candidate[generation.path] == nil else {
                throw WSSImageImportError.storage
            }
            let used = candidate.values.reduce(0) { $0 + $1.fingerprint.byteCount }
            guard generation.fingerprint.byteCount <= WSSImageImporter.stagingLimit - used else {
                throw WSSImageImportError.stagingBudget
            }
            if generation.kind == .vectorField || generation.kind == .flowRegion {
                try WSSVectorFieldEditorBudget.validateGeneration(
                    byteCount: generation.fingerprint.byteCount, assets: candidate)
            }
            candidate[generation.path] = generation
        }
        // Register only after the entire batch validates. A rejected batch cannot
        // enter the weak pool merely because its caller still holds a candidate.
        for path in vectorGenerationPaths where live[path] == nil {
            resourceCatalog.removeValue(forKey: path)
        }
        vectorGenerationPaths = vectorGenerationPaths.intersection(live.keys)
        for generation in generations {
            ownedGenerations[generation.path] = generation
            resourceCatalog[generation.path] = generation.fingerprint
            if generation.kind == .vectorField || generation.kind == .flowRegion {
                vectorGenerationPaths.insert(generation.path)
            }
        }
        resourcePool.register(generations)
    }
    private mutating func releaseUnusedVectorOwnership() {
        let required = workingModel.referencedPaths.union(savedModel.referencedPaths)
        // During Undo/Redo the consumed action owns the restored resources only
        // until its callback returns. Acquire model ownership before that release.
        let live = resourcePool.liveGenerations()
        for path in required {
            if let generation = live[path] { ownedGenerations[path] = generation }
        }
        ownedGenerations = ownedGenerations.filter {
            $0.value.kind == .png || required.contains($0.key)
        }
        // Undo/Redo and async snapshots keep their own strong generation handles.
        // Their bytes remain visible to all budget checks through the weak pool.
    }
    mutating func replaceWorkingModel(_ model: WSSSceneDocumentV1) {
        guard !closed, model != workingModel else { return }
        workingModel = model
        workingRevision += 1
        releaseUnusedVectorOwnership()
    }
    mutating func beginSave() -> WSSSaveSnapshot? {
        guard !closed, pending == nil else { return nil }
        let operation = UUID()
        pending = operation
        return WSSSaveSnapshot(
            sessionID: sessionID, operationID: operation,
            revision: workingRevision, model: workingModel, savedModel: savedModel,
            diskBasis: diskBasis,
            resourceCatalog: resourceCatalog.filter {
                workingModel.referencedPaths.contains($0.key)
            },
            sessionAssets: sessionAssets.filter { workingModel.referencedPaths.contains($0.key) },
            resourceLease: resourcePool.pin(workingModel.referencedPaths))
    }
    mutating func accept(_ receipt: WSSSaveReceipt) {
        let snapshot = receipt.snapshot
        guard !closed, snapshot.sessionID == sessionID, pending == snapshot.operationID else {
            return
        }
        pending = nil
        if case .unchanged = receipt.outcome { return }
        savedModel = snapshot.model
        savedRevision = snapshot.revision
        diskBasis = receipt.diskBasis
        releaseUnusedVectorOwnership()
    }
    mutating func failed(_ snapshot: WSSSaveSnapshot) {
        guard snapshot.sessionID == sessionID, pending == snapshot.operationID else { return }
        pending = nil
    }
    mutating func close() {
        closed = true
        pending = nil
        ownedGenerations.removeAll()
    }
}
