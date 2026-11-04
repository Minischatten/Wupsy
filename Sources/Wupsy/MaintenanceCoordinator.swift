import Foundation

// A task-local admission is valid only while its registered high-level owner lives.
// Child continuations may finish during freeze; escaped callbacks cannot reuse it later.
enum MaintenanceOperation {
    @TaskLocal static var id: UUID?
    @TaskLocal static var editorDecision = false
}

enum MaintenanceError: LocalizedError, Equatable {
    case frozen, jobActive, restartRequired, invalidTransition, drainFailed
    var errorDescription: String? {
        switch self {
        case .frozen: return "The library is temporarily unavailable during maintenance."
        case .jobActive: return "Another library backup or restore is already in progress."
        case .restartRequired: return "Quit and reopen Wupsy before using the library again."
        case .invalidTransition: return "The maintenance operation is not ready for this step."
        case .drainFailed: return "The library could not be stopped safely."
        }
    }
}

@MainActor final class MaintenanceCoordinator: ObservableObject {
    static let shared = MaintenanceCoordinator()
    enum Job { case backup, restore }
    enum State: Equatable {
        case normal, backup, restorePreparing, restoreFreezing, restartRequired
    }
    @Published private(set) var state: State = .normal
    private var jobID: UUID?
    enum OperationKind { case mutation, runtime }
    private var operations: [UUID: OperationKind] = [:]
    private var waiters: [(OperationKind?, CheckedContinuation<Void, Never>)] = []
    private var editorDecisions = false
    var allowsNewOperations: Bool {
        [.normal, .backup, .restorePreparing].contains(state)
    }
    var allowsMutation: Bool {
        if state == .restartRequired { return false }
        return allowsNewOperations
            || MaintenanceOperation.id.map { operations[$0] != nil } == true
            || (editorDecisions && MaintenanceOperation.editorDecision)
    }
    var activeOperationCount: Int { operations.count }
    final class Lease {
        let id: UUID
        private let release: (UUID) -> Void
        private var released = false
        init(id: UUID, release: @escaping (UUID) -> Void) {
            self.id = id
            self.release = release
        }
        func finish() {
            guard !released else { return }
            released = true
            release(id)
        }
    }
    func reserve(_ job: Job) throws -> Lease {
        guard state != .restartRequired else { throw MaintenanceError.restartRequired }
        guard state == .normal, jobID == nil else { throw MaintenanceError.jobActive }
        let id = UUID()
        jobID = id
        state = job == .backup ? .backup : .restorePreparing
        return Lease(id: id) { [self] id in
            guard jobID == id else { return }
            jobID = nil
            if state == .backup || state == .restorePreparing { state = .normal }
        }
    }
    func beginMutation(kind: OperationKind = .mutation) throws -> Lease {
        guard allowsMutation else {
            throw state == .restartRequired
                ? MaintenanceError.restartRequired : MaintenanceError.frozen
        }
        let id = UUID()
        operations[id] = kind
        return Lease(id: id) { [self] id in
            operations[id] = nil
            let pending = waiters
            waiters.removeAll()
            for (kind, waiter) in pending {
                if hasOperations(kind: kind) {
                    waiters.append((kind, waiter))
                } else {
                    waiter.resume()
                }
            }
        }
    }
    func withMutation<T>(_ body: () throws -> T) throws -> T {
        let lease = try beginMutation()
        defer { lease.finish() }
        return try MaintenanceOperation.$id.withValue(lease.id, operation: body)
    }
    func withMutationAsync<T>(_ body: () async throws -> T) async throws -> T {
        let lease = try beginMutation()
        defer { lease.finish() }
        return try await MaintenanceOperation.$id.withValue(lease.id) { try await body() }
    }
    func freeze() throws {
        guard state == .restorePreparing else { throw MaintenanceError.invalidTransition }
        state = .restoreFreezing
    }
    private func hasOperations(kind: OperationKind?) -> Bool {
        guard let kind else { return !operations.isEmpty }
        return operations.values.contains(kind)
    }
    // Normal mutations finish before editor close and terminal runtime shutdown.
    // Runtime requests may be paused indefinitely; stop their owners before drain().
    func drainMutations() async { await waitForOperations(kind: .mutation) }
    func drain() async { await waitForOperations(kind: nil) }
    private func waitForOperations(kind: OperationKind?) async {
        while hasOperations(kind: kind) {
            await withCheckedContinuation { waiters.append((kind, $0)) }
        }
    }
    // Only the coordinator's close-decision scope can admit a new save after freeze.
    func resolveEditors<T>(_ body: () async -> T) async throws -> T {
        guard state == .restoreFreezing, !editorDecisions else {
            throw MaintenanceError.invalidTransition
        }
        editorDecisions = true
        defer { editorDecisions = false }
        return await MaintenanceOperation.$editorDecision.withValue(true) { await body() }
    }
    func cancelFreeze() throws {
        // A cancelled, still-reversible maintenance phase must let a paused
        // runtime request resume. Only normal mutations need to have drained.
        guard state == .restoreFreezing, !hasOperations(kind: .mutation), !editorDecisions else {
            throw MaintenanceError.invalidTransition
        }
        state = .restorePreparing
    }
    func requireRestart() throws {
        guard state == .restoreFreezing, operations.isEmpty, !editorDecisions else {
            throw MaintenanceError.invalidTransition
        }
        state = .restartRequired
    }
}

// Retain cancelled tasks until their actual end, including tasks superseded before drain.
@MainActor final class RuntimeTaskDrain {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    func track(_ task: Task<Void, Never>) {
        let id = UUID()
        tasks[id] = task
        Task { [weak self] in
            await task.value
            self?.tasks[id] = nil
        }
    }
    func cancelAndDrain() async {
        while !tasks.isEmpty {
            let pending = tasks
            for task in pending.values { task.cancel() }
            for task in pending.values { await task.value }
            for id in pending.keys { tasks[id] = nil }
        }
    }
}
