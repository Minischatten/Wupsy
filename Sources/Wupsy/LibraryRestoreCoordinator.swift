import Foundation

// One job owns preparation until handoff; only the transaction/recovery owns it afterwards.
@MainActor final class LibraryRestoreCoordinator: ObservableObject {
    enum Outcome: Equatable { case committed, restoredA, unresolved }
    struct Actions {
        var select: () -> URL?
        var prepare:
            (URL, @escaping @Sendable (LibraryRestorePresentationPhase) -> Void) async throws ->
                PreparedLibraryRestore
        var confirm: (LibraryRestorePlan) -> Bool
        var cancelPendingEditors: () async throws -> Void
        var resolveEditors:
            (@escaping () -> Bool) async -> WSSEditorCoordinator.MaintenanceCloseResult
        var stopPlaylist: () async -> Void
        var stopLibrary: () async -> Void
        var closeLibrary: () -> Void
        var stopWidgets: () -> Void
        var snapshot: () async -> LibraryMutationBarrier.Lease
        var publish: (PreparedLibraryRestore) async throws -> Void
        var recover: () async throws -> Outcome
        var progress: () -> Void = {}
        var closeProgress: () -> Void = {}
        var cancelDialogs: () -> Void = {}
        var failure: (Bool) -> Void = { _ in }
        var completion: (Outcome) -> Void = { _ in }
    }
    @Published private(set) var running = false
    @Published private(set) var presentationPhase: LibraryRestorePresentationPhase = .validating
    var phase: String { presentationPhase.localized() }
    @Published private(set) var canCancel = false
    private(set) var terminal = false
    @Published private(set) var blocksLibrary = false
    private(set) var outcome: Outcome?
    private let maintenance: MaintenanceCoordinator
    private var task: Task<Void, Never>?
    private var job: MaintenanceCoordinator.Lease?
    private var barrier: LibraryMutationBarrier.Lease?
    private var quitting = false
    private var cancelDialogs: (() -> Void)?

    init(maintenance: MaintenanceCoordinator? = nil) { self.maintenance = maintenance ?? .shared }

    // Reserve synchronously, before opening any native panel (including nested modal events).
    @discardableResult func start(_ actions: Actions) throws -> Task<Void, Never> {
        guard !running else { throw MaintenanceError.jobActive }
        job = try maintenance.reserve(.restore)
        running = true
        canCancel = true
        quitting = false
        cancelDialogs = actions.cancelDialogs
        task = Task { await run(actions) }
        return task!
    }
    func cancel() { if canCancel { task?.cancel() } }
    // Quit during publication waits for classification; it never writes old A state back.
    func prepareToQuit() async {
        quitting = true
        cancel()
        if !terminal { cancelDialogs?() }
        await task?.value
    }
    private func run(_ actions: Actions) async {
        var owned: PreparedLibraryRestore?
        var frozen = false
        do {
            guard let url = actions.select() else { throw CancellationError() }
            try Task.checkCancellation()
            presentationPhase = .validating
            actions.progress()
            let jobID = job?.id
            owned = try await actions.prepare(url) { [weak self] phase in
                Task { @MainActor in
                    guard let self, self.job?.id == jobID, self.running, !self.terminal,
                        self.maintenance.state == .restorePreparing
                    else { return }
                    self.presentationPhase = phase
                }
            }
            try Task.checkCancellation()
            guard let prepared = owned else { throw MaintenanceError.invalidTransition }
            actions.closeProgress()
            guard actions.confirm(prepared.plan) else { throw CancellationError() }
            try Task.checkCancellation()
            try maintenance.freeze()
            frozen = true
            presentationPhase = .waiting
            actions.progress()
            try await actions.cancelPendingEditors()
            await maintenance.drainMutations()
            try Task.checkCancellation()
            let decision = await actions.resolveEditors { [self] in
                // Called after all save decisions/drain, BEFORE any document is closed.
                guard !Task.isCancelled else { return false }
                terminal = true
                canCancel = false
                return true
            }
            switch decision {
            case .cancelled: throw CancellationError()
            case .failure: throw MaintenanceError.drainFailed
            case .approved: break
            }
            guard terminal else { throw MaintenanceError.drainFailed }
            presentationPhase = .restoring
            await actions.stopPlaylist()
            await actions.stopLibrary()
            blocksLibrary = true
            actions.closeLibrary()
            actions.stopWidgets()
            await maintenance.drain()
            // Never hold the final filesystem barrier across explicit editor saves.
            barrier = await actions.snapshot()
            // Relinquish ownership before invoking publish. A thrown publish can have committed B.
            owned = nil
            let result: Outcome
            do {
                try await actions.publish(prepared)
                result = .committed
            } catch {
                presentationPhase = .finishing
                do { result = try await actions.recover() } catch { result = .unresolved }
            }
            finishTerminal(result, actions: actions)
        } catch {
            if terminal {
                // Fail closed if an orchestration invariant fails after irreversible close.
                await actions.stopPlaylist()
                await actions.stopLibrary()
                blocksLibrary = true
                actions.closeLibrary()
                actions.stopWidgets()
                await maintenance.drain()
                finishTerminal(.unresolved, actions: actions)
                return
            }
            var cleanupFailed = false
            if let owned {
                do { try await Task.detached { try owned.discard() }.value } catch {
                    cleanupFailed = true
                }
            }
            if frozen {
                await maintenance.drainMutations()
                do { try maintenance.cancelFreeze() } catch {
                    // No terminal shutdown occurred, but admission must remain closed if invalid.
                    cleanupFailed = true
                }
            }
            actions.closeProgress()
            job?.finish()
            job = nil
            running = false
            canCancel = false
            task = nil
            cancelDialogs = nil
            if !quitting, cleanupFailed || !(error is CancellationError) {
                actions.failure(cleanupFailed)
            }
        }
    }
    private func finishTerminal(_ result: Outcome, actions: Actions) {
        presentationPhase = .finishing
        // All writers have ended. Keep both leases for the remainder of this process.
        do { try maintenance.requireRestart() } catch {
            // Gates remain frozen even if a violated invariant prevents the transition.
            outcome = .unresolved
        }
        outcome = outcome ?? result
        actions.closeProgress()
        running = false
        canCancel = false
        task = nil
        cancelDialogs = nil
        if !quitting { actions.completion(outcome!) }
    }
}

// This adapter deliberately treats no remaining journal as unresolved on a thrown publish:
// absence alone cannot prove A or B (e.g. interruption after committed cleanup).
enum LibraryRestorePublication {
    static func publish(_ prepared: PreparedLibraryRestore, context: WupsyLaunchContext)
        async throws
    {
        try await Task.detached {
            _ = try LibraryRestoreTransaction(
                root: context.supportRoot, preferenceDomain: context.preferenceDomain
            ).publish(prepared, quiescence: .init(callerGuaranteesQuiescentRuntime: true))
        }.value
    }
    static func recover(context: WupsyLaunchContext) async throws
        -> LibraryRestoreCoordinator.Outcome
    {
        try await Task.detached {
            switch try LibraryRestoreRecovery(
                root: context.supportRoot, preferenceDomain: context.preferenceDomain
            ).recover(quiescence: .init(callerGuaranteesQuiescentRuntime: true)) {
            case .restoredA: return LibraryRestoreCoordinator.Outcome.restoredA
            case .retainedB: return LibraryRestoreCoordinator.Outcome.committed
            case .none: return LibraryRestoreCoordinator.Outcome.unresolved
            }
        }.value
    }
}
