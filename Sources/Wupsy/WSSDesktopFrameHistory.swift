import Foundation

// Main-actor owned by the desktop player. No references to Metal drawables.
struct WSSDesktopFrameHistory {
    struct Frame {
        let time: Double
        let trail: WSSTrailRenderContext.Snapshot?
    }
    private var nextID: UInt64 = 0
    private var pending: [UInt64: Frame] = [:]
    private var latestPresentation: (id: UInt64, hostTime: Double)?
    private(set) var confirmed: Frame?
    var hasPending: Bool { !pending.isEmpty }

    mutating func submit(_ frame: Frame) -> UInt64 {
        nextID += 1
        pending[nextID] = frame
        // GPU completion does not bound presentation callbacks on hidden displays.
        if pending.count > 8, let oldest = pending.keys.min() {
            pending.removeValue(forKey: oldest)
        }
        return nextID
    }

    @discardableResult
    mutating func presented(_ id: UInt64, at hostTime: Double) -> Bool {
        guard let frame = pending.removeValue(forKey: id), hostTime.isFinite, hostTime > 0 else {
            return false
        }
        if let latest = latestPresentation,
            hostTime < latest.hostTime || (hostTime == latest.hostTime && id <= latest.id)
        {
            return false
        }
        latestPresentation = (id, hostTime)
        confirmed = frame
        return true
    }

    mutating func discardPending() { pending.removeAll(keepingCapacity: true) }
}
