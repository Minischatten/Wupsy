import AppKit
import XCTest

@testable import Wupsy

@MainActor final class ThumbnailCacheTests: XCTestCase {
    func testWarmHitAndCancelledWaiterCompleteWhileMissIsBlocked() async throws {
        let fixture = WSSNativeSceneTests()
        try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        let warm = try image("warm", fixture: fixture)
        let slow = try image("slow", fixture: fixture)
        let cancelled = try image("cancelled", fixture: fixture)
        let gate = WorkGate()
        let started = expectation(description: "Slow miss acquired generation slot")
        let loader = ImageLoader(beforeThumbnailWork: { item in
            if item.id == slow.id {
                await gate.pause(item.id, started: started)
            } else {
                await gate.record(item.id)
            }
        })
        let original = await loader.thumbnail(warm)
        let generation = Task { await loader.thumbnail(slow) }
        await fulfillment(of: [started], timeout: 3)

        let warmFinished = expectation(description: "Warm request bypassed blocked miss")
        let warmTask = Task {
            let image = await loader.thumbnail(warm)
            warmFinished.fulfill()
            return image
        }
        let cancelledFinished = expectation(description: "Cancelled request left the queue")
        let queued = Task {
            let image = await loader.thumbnail(cancelled)
            cancelledFinished.fulfill()
            return image
        }
        await Task.yield()
        queued.cancel()
        let duplicate = Task { await loader.thumbnail(slow) }
        await fulfillment(of: [warmFinished, cancelledFinished], timeout: 3)
        await gate.release()
        let hit = await warmTask.value
        let discarded = await queued.value
        let generated = await generation.value
        let reused = await duplicate.value
        let work = await gate.work
        XCTAssertTrue(hit === original)
        XCTAssertNil(discarded)
        XCTAssertFalse(work.contains(cancelled.id))
        XCTAssertEqual(work.filter { $0 == slow.id }.count, 1)
        XCTAssertNotNil(generated)
        XCTAssertTrue(generated === reused)
    }

    func testGridAndDetailBudgetsEvictLeastRecentlyUsedAcrossRepeatedRequests() async throws {
        let fixture = WSSNativeSceneTests()
        try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        let a = try image("a", fixture: fixture)
        let b = try image("b", fixture: fixture)
        let c = try image("c", fixture: fixture)
        let loader = ImageLoader(gridBudget: 16, detailBudget: 8)
        let first = await loader.thumbnail(a)
        let second = await loader.thumbnail(b)
        let detail = await loader.thumbnail(a, maxPixel: 1280)
        let reopened = await loader.thumbnail(a)
        XCTAssertTrue(reopened === first)

        _ = await loader.thumbnail(c)
        let scrolledBack = await loader.thumbnail(a)
        let detailAgain = await loader.thumbnail(a, maxPixel: 1280)
        let regenerated = await loader.thumbnail(b)
        XCTAssertNotNil(scrolledBack)
        XCTAssertTrue(scrolledBack === first)
        XCTAssertTrue(detailAgain === detail)
        XCTAssertNotNil(regenerated)
        XCTAssertFalse(regenerated === second)
        let usage = await loader.cacheUsage()
        XCTAssertEqual(usage.gridBytes, 16)
        XCTAssertEqual(usage.detailBytes, 8)
        await loader.clear()
        let afterClear = await loader.cacheUsage()
        XCTAssertEqual(afterClear.gridBytes + afterClear.detailBytes, 0)
    }

    func testChangedWebPreviewInvalidatesWithoutChangingEntryFile() async throws {
        let fixture = WSSNativeSceneTests()
        try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        let entry = fixture.root.appendingPathComponent("index.html")
        let preview = fixture.root.appendingPathComponent("preview.jpg")
        try Data("<html></html>".utf8).write(to: entry)
        try fixture.png().write(to: preview)
        let web = Wallpaper(title: "Web", path: entry.path, root: fixture.root.path, kind: .web)
        let loader = ImageLoader()
        let old = await loader.thumbnail(web)
        try fixture.png([255, 0, 0, 255, 255, 0, 0, 255]).write(to: preview)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: preview.path)
        let new = await loader.thumbnail(web)
        XCTAssertNotNil(old)
        XCTAssertNotNil(new)
        XCTAssertFalse(old === new)
    }

    func testLargeGridEvictsByCountEvenWhenPicturesAreTiny() async throws {
        let fixture = WSSNativeSceneTests()
        try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        let loader = ImageLoader()
        let first = try image("first", fixture: fixture)
        let original = await loader.thumbnail(first)
        for index in 1...64 {
            _ = await loader.thumbnail(try image("image-\(index)", fixture: fixture))
        }
        let usage = await loader.cacheUsage()
        XCTAssertEqual(usage.gridBytes, 64 * 8)
        let reloaded = await loader.thumbnail(first)
        XCTAssertNotNil(reloaded)
        XCTAssertFalse(original === reloaded)
    }

    private func image(_ name: String, fixture: WSSNativeSceneTests) throws -> Wallpaper {
        let url = fixture.root.appendingPathComponent(name + ".png")
        try fixture.png().write(to: url)
        return try WallpaperImporter.resolve(url)
    }

    private actor WorkGate {
        var work: [UUID] = []
        private var waiter: CheckedContinuation<Void, Never>?
        private var paused = false

        func record(_ id: UUID) { work.append(id) }

        func pause(_ id: UUID, started: XCTestExpectation) async {
            work.append(id)
            guard !paused else { return }
            paused = true
            await withCheckedContinuation {
                waiter = $0
                started.fulfill()
            }
        }

        func release() {
            waiter?.resume()
            waiter = nil
        }
    }
}
