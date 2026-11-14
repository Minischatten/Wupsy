import Foundation

// Original Wupsy implementation. Placement always refers to the visible (reversed) order.
enum LibraryMovePlacement { case before, after }

enum LibraryMove {
    static func reordered(
        _ items: [Wallpaper], wallpaperID: UUID, relativeTo targetID: UUID,
        placement: LibraryMovePlacement
    ) throws -> [Wallpaper] {
        guard wallpaperID != targetID,
            Set(items.map(\.id)).count == items.count,
            let source = items.firstIndex(where: { $0.id == wallpaperID }),
            items.contains(where: { $0.id == targetID })
        else { throw ImportFailure.message("Missing, identical or ambiguous wallpaper identity.") }
        var result = items
        let item = result.remove(at: source)
        let target = result.firstIndex(where: { $0.id == targetID })!
        // Visible 'before' means after the target in the internal array.
        result.insert(item, at: target + (placement == .before ? 1 : 0))
        return result
    }
}

/// Serializes Library metadata operations through their MainActor publication.
/// Waiters retain their maintenance admission. Cancellation is checked before starting,
/// never after a successful disk commit (which must still be published).
@MainActor final class LibraryEditQueue {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async throws {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        do { try Task.checkCancellation() } catch {
            release()
            throw error
        }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    func withEdit<T>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await body()
    }
}
