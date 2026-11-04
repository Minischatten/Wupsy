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
    init(
        sessionID: UUID, operationID: UUID, revision: UInt64, model: WSSSceneDocumentV1,
        savedModel: WSSSceneDocumentV1, diskBasis: WSSProjectDiskBasis,
        resourceCatalog: [String: WSSContentFingerprint]? = nil,
        sessionAssets: [String: WSSImageGeneration] = [:]
    ) {
        self.sessionID = sessionID
        self.operationID = operationID
        self.revision = revision
        self.model = model
        self.savedModel = savedModel
        self.diskBasis = diskBasis
        self.resourceCatalog = resourceCatalog
        self.sessionAssets = sessionAssets
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
    private(set) var sessionAssets: [String: WSSImageGeneration] = [:]
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
        guard !closed, resourceCatalog[generation.path] == nil else {
            throw WSSImageImportError.storage
        }
        let used = sessionAssets.values.reduce(0) { $0 + $1.fingerprint.byteCount }
        guard generation.fingerprint.byteCount <= WSSImageImporter.stagingLimit - used else {
            throw WSSImageImportError.stagingBudget
        }
        if generation.kind == .vectorField || generation.kind == .flowRegion {
            try WSSVectorFieldEditorBudget.validateGeneration(
                byteCount: generation.fingerprint.byteCount, assets: sessionAssets)
        }
        sessionAssets[generation.path] = generation
        resourceCatalog[generation.path] = generation.fingerprint
    }
    mutating func retainGenerations(_ generations: [WSSImageGeneration]) throws {
        var candidate = self
        for generation in generations { try candidate.retainGeneration(generation) }
        self = candidate
    }
    mutating func replaceWorkingModel(_ model: WSSSceneDocumentV1) {
        guard !closed, model != workingModel else { return }
        workingModel = model
        workingRevision += 1
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
            sessionAssets: sessionAssets.filter { workingModel.referencedPaths.contains($0.key) })
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
    }
    mutating func failed(_ snapshot: WSSSaveSnapshot) {
        guard snapshot.sessionID == sessionID, pending == snapshot.operationID else { return }
        pending = nil
    }
    mutating func close() {
        closed = true
        pending = nil
        sessionAssets.removeAll()
    }
}
