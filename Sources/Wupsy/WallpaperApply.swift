import Foundation

/// Acceptance is a lifecycle handoff, not a first-frame or continuing-health guarantee.
enum WallpaperApplyOutcome {
    case accepted
    case failed(Error)
    /// Replaced by another request, explicitly stopped, or cancelled by its caller.
    case superseded
}

@MainActor final class WallpaperApplyRequest {
    private var result: WallpaperApplyOutcome?
    private var waiters: [CheckedContinuation<WallpaperApplyOutcome, Never>] = []
    var cancel: (() -> Void)?

    var outcome: WallpaperApplyOutcome {
        get async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if let result {
                        continuation.resume(returning: result)
                    } else {
                        waiters.append(continuation)
                    }
                }
            } onCancel: {
                Task { @MainActor in self.cancel?() }
            }
        }
    }

    func finish(_ outcome: WallpaperApplyOutcome) {
        guard result == nil else { return }
        result = outcome
        cancel = nil
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: outcome) }
    }
}

/// Distinguishes user intent from automation and startup without changing acceptance.
enum WallpaperApplySource { case manual, automatic, restoration }
enum WallpaperPlaybackCommand {
    case manualApply, stop, shutdown
    case remove(UUID)
}
