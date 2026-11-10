import Foundation

// A session knows its generations without owning every historical byte forever.
// Current/saved models, Undo closures and async snapshots hold the strong handles.
// Weak lookup still counts handles retained by an in-flight operation after a branch
// is discarded. There is no eviction, history limit or project-file deletion here.
final class WSSSessionResourcePool: @unchecked Sendable {
    private final class Entry {
        weak var generation: WSSImageGeneration?
        init(_ generation: WSSImageGeneration) { self.generation = generation }
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private struct Pin { weak var lease: WSSSessionResourceLease? }
    private var pins: [Pin] = []
    func pin(_ paths: Set<String>) -> WSSSessionResourceLease {
        lock.lock()
        defer { lock.unlock() }
        let lease = WSSSessionResourceLease(paths)
        pins.append(Pin(lease: lease))
        return lease
    }
    var pinnedPaths: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        pins = pins.filter { $0.lease != nil }
        return pins.reduce(into: []) { $0.formUnion($1.lease?.paths ?? []) }
    }

    func register(_ generations: [WSSImageGeneration]) {
        lock.lock()
        defer { lock.unlock() }
        for generation in generations { entries[generation.path] = Entry(generation) }
    }

    func liveGenerations() -> [String: WSSImageGeneration] {
        lock.lock()
        defer { lock.unlock() }
        var live: [String: WSSImageGeneration] = [:]
        for (path, entry) in entries {
            if let generation = entry.generation { live[path] = generation }
        }
        entries = entries.filter { live[$0.key] != nil }
        return live
    }
}

// A save can outlive a discarded Redo branch. Its protected paths participate in
// prospective history budgeting until the last snapshot copy is released.
final class WSSSessionResourceLease: @unchecked Sendable {
    let paths: Set<String>
    init(_ paths: Set<String>) { self.paths = paths }
}
