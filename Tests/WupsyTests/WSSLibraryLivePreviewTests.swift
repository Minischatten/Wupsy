import AppKit
import SwiftUI
import XCTest

@testable import Wupsy

@MainActor final class WSSLibraryLivePreviewTests: XCTestCase {
    private var helper: WSSEditorWorkspaceTests!
    override func setUp() async throws {
        helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
    }
    override func tearDown() async throws { try await helper.tearDown() }

    func testExistingManagedProjectRenameFitFillAndPolicyKeepPlayer() async throws {
        var loads = 0
        let owner = WSSLibraryPreviewOwner(load: { item in
            loads += 1
            return try await WSSEditorProjectLoader().load(item)
        })
        let host = WSSLibraryPreviewHost(owner: owner)
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 245)
        owner.select(helper.item)
        await owner.waitForPreparation()
        XCTAssertEqual(owner.state, .live)
        let surface = try XCTUnwrap(owner.surface)
        let player = try XCTUnwrap(surface.player)
        let originalResources = player.resources
        var renamed = helper.item!
        renamed.title = "Renamed"
        owner.select(renamed)
        XCTAssertEqual(loads, 1)
        owner.configure(policy: .library(profile: .eco, resolution: .standard, fps: 60), fit: false)
        host.layoutSubtreeIfNeeded()
        surface.layoutSubtreeIfNeeded()
        XCTAssertTrue(owner.surface === surface)
        XCTAssertTrue(surface.player === player)
        XCTAssertTrue(player.resources === originalResources)
        XCTAssertEqual(surface.frame, host.bounds)
        XCTAssertEqual(player.resolution, .standard)
        XCTAssertEqual(player.view.preferredFramesPerSecond, 24)
        XCTAssertEqual(player.view.drawableSize, host.bounds.size)
        owner.configure(
            policy: .library(profile: .original, resolution: .hiDPI, fps: 60), fit: true)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            surface.frame.size,
            WSSPreviewGeometry.fit(
                canvas: CGSize(
                    width: helper.project.scene.width, height: helper.project.scene.height),
                available: host.bounds.size))
        XCTAssertTrue(surface.player === player)
        XCTAssertEqual(player.view.preferredFramesPerSecond, 60)
        host.shutdown()
        XCTAssertNil(owner.surface)
        XCTAssertNil(player.view.delegate)
        await owner.shutdownAndDrain()
    }

    func testLibraryUsesSavedStateAndCommitReloadsSameUUIDOnly() async throws {
        let owner = WSSLibraryPreviewOwner()
        let host = WSSLibraryPreviewHost(owner: owner)
        owner.select(helper.item)
        await owner.waitForPreparation()
        let oldPlayer = try XCTUnwrap(owner.surface?.player)
        let oldFingerprint = owner.fingerprint
        let doc = helper.document()
        defer { doc.close() }
        try doc.setImage(.centerX, value: 100, layer: doc.identity.layers[0].id)
        XCTAssertNotEqual(doc.state.workingModel, helper.project.document)
        XCTAssertTrue(owner.surface?.player === oldPlayer)
        XCTAssertEqual(
            owner.surface?.player?.resources.scene.imageLayers[0].transform.center.x,
            helper.project.scene.imageLayers[0].transform.center.x)
        NotificationCenter.default.post(name: .wssPreviewCommitted, object: UUID())
        XCTAssertTrue(owner.surface?.player === oldPlayer)
        try doc.state.workingModel.encoded().write(to: helper.item.url)
        NotificationCenter.default.post(name: .wssPreviewCommitted, object: helper.item.id)
        await owner.waitForPreparation()
        XCTAssertEqual(owner.state, .live)
        XCTAssertFalse(owner.surface?.player === oldPlayer)
        XCTAssertNotEqual(owner.fingerprint, oldFingerprint)
        XCTAssertEqual(
            owner.surface?.player?.resources.scene.imageLayers[0].transform.center.x, 100)
        host.shutdown()
        await owner.shutdownAndDrain()
    }

    func testRapidABCDSerializesPreparationAndRejectsStaleSuccessAndError() async throws {
        var gates: [UUID: CheckedContinuation<WSSLoadedEditorProject, Error>] = [:]
        var started: [UUID] = []
        var simultaneous = 0
        var maximum = 0
        let project = helper.project!
        let owner = WSSLibraryPreviewOwner(load: { item in
            started.append(item.id)
            simultaneous += 1
            maximum = max(maximum, simultaneous)
            defer { simultaneous -= 1 }
            return try await withCheckedThrowingContinuation { gates[item.id] = $0 }
        })
        let host = WSSLibraryPreviewHost(owner: owner)
        var items = (0..<4).map { _ in helper.item! }
        for index in items.indices { items[index].id = UUID() }
        owner.select(items[0])
        while gates[items[0].id] == nil { await Task.yield() }
        owner.select(items[1])
        owner.select(items[2])
        owner.select(items[3])
        gates.removeValue(forKey: items[0].id)?.resume(throwing: WSSSceneError.invalid("stale A"))
        while gates[items[3].id] == nil { await Task.yield() }
        XCTAssertNil(owner.surface)
        XCTAssertNil(owner.diagnostic)
        gates.removeValue(forKey: items[3].id)?.resume(returning: project)
        await owner.waitForPreparation()
        XCTAssertEqual(started, [items[0].id, items[3].id])
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(owner.wallpaperID, items[3].id)
        XCTAssertEqual(owner.state, .live)
        // A non-cooperative successful result must also be ignored after disappearance.
        owner.select(items[0])
        while gates[items[0].id] == nil { await Task.yield() }
        host.shutdown()
        gates.removeValue(forKey: items[0].id)?.resume(returning: project)
        await owner.waitForPreparation()
        XCTAssertNil(owner.surface)
        XCTAssertNil(owner.wallpaperID)
        await owner.shutdownAndDrain()
    }

    func testVisibilityPauseResumeNotificationsAndCleanup() async throws {
        let owner = WSSLibraryPreviewOwner()
        let host = WSSLibraryPreviewHost(owner: owner)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 245),
            styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        owner.select(helper.item)
        await owner.waitForPreparation()
        await Task.yield()
        let player = try XCTUnwrap(owner.surface?.player)
        XCTAssertFalse(player.view.isPaused)
        for (center, pause, resume) in [
            (
                NotificationCenter.default, NSApplication.didHideNotification,
                NSApplication.didUnhideNotification
            ),
            (
                NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification,
                NSWorkspace.screensDidWakeNotification
            ),
            (
                NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification,
                NSWorkspace.didWakeNotification
            ),
            (
                NSWorkspace.shared.notificationCenter,
                NSWorkspace.sessionDidResignActiveNotification,
                NSWorkspace.sessionDidBecomeActiveNotification
            ),
        ] {
            center.post(name: pause, object: nil)
            XCTAssertTrue(player.view.isPaused)
            let frozen = player.elapsed
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertEqual(player.elapsed, frozen)
            center.post(name: resume, object: nil)
            XCTAssertFalse(player.view.isPaused)
            XCTAssertGreaterThanOrEqual(player.elapsed, frozen)
        }
        window.miniaturize(nil)
        let minimizedDeadline = ProcessInfo.processInfo.systemUptime + 3
        while !window.isMiniaturized && ProcessInfo.processInfo.systemUptime < minimizedDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(window.isMiniaturized)
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
        XCTAssertTrue(player.view.isPaused)
        window.deminiaturize(nil)
        let restoredDeadline = ProcessInfo.processInfo.systemUptime + 3
        while window.isMiniaturized && ProcessInfo.processInfo.systemUptime < restoredDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        XCTAssertFalse(player.view.isPaused)
        host.shutdown()
        XCTAssertNil(owner.surface)
        XCTAssertNil(player.view.delegate)
        window.contentView = nil
        window.close()
        await owner.shutdownAndDrain()
    }

    func testMaintenanceCancelsAndDrainsNonCooperativeLoad() async throws {
        let maintenance = MaintenanceCoordinator()
        var gate: CheckedContinuation<WSSLoadedEditorProject, Error>?
        let project = helper.project!
        let owner = WSSLibraryPreviewOwner(
            maintenance: maintenance,
            load: { _ in
                try await withCheckedThrowingContinuation { gate = $0 }
            })
        let host = WSSLibraryPreviewHost(owner: owner)
        owner.select(helper.item)
        while gate == nil { await Task.yield() }
        let lease = try maintenance.reserve(.restore)
        try maintenance.freeze()
        XCTAssertNil(owner.surface)
        var drained = false
        let drain = Task {
            await owner.shutdownAndDrain()
            await maintenance.drain()
            drained = true
        }
        await Task.yield()
        XCTAssertFalse(drained)
        gate?.resume(returning: project)
        await drain.value
        XCTAssertTrue(drained)
        XCTAssertEqual(maintenance.activeOperationCount, 0)
        XCTAssertNil(owner.surface)
        host.shutdown()
        lease.finish()
    }

    func testSelectionLossAndNewSelectionResetTimeAndTrail() async throws {
        let owner = WSSLibraryPreviewOwner()
        let host = WSSLibraryPreviewHost(owner: owner)
        owner.select(helper.item)
        await owner.waitForPreparation()
        let old = try XCTUnwrap(owner.surface?.player)
        owner.select(nil)  // Delete, search/filter with no results, or Hero disappearance.
        XCTAssertNil(owner.surface)
        XCTAssertNil(old.view.delegate)
        XCTAssertNil(owner.wallpaperID)
        owner.select(helper.item)
        await owner.waitForPreparation()
        let new = try XCTUnwrap(owner.surface?.player)
        XCTAssertFalse(old === new)
        XCTAssertEqual(new.elapsed, 0)  // Detached window: not started yet.
        XCTAssertFalse(old.trailContext === new.trailContext)
        host.shutdown()
        await owner.shutdownAndDrain()
    }

    func testFitLetterboxFillInverseCropAndLocalMouseExit() async throws {
        let canvas = CGSize(width: 1920, height: 1080)
        let hero = CGRect(x: 0, y: 0, width: 800, height: 245)
        let fitted = WSSPreviewGeometry.fit(canvas: canvas, available: hero.size)
        let frame = CGRect(
            x: (800 - fitted.width) / 2, y: 0, width: fitted.width, height: fitted.height)
        XCTAssertNil(
            WSSPreviewGeometry.point(
                CGPoint(x: 0, y: 100), bounds: frame,
                canvas: canvas, flipped: false))
        XCTAssertEqual(
            WSSPreviewGeometry.point(
                CGPoint(x: 400, y: 122.5), bounds: frame,
                canvas: canvas, flipped: false), SIMD2(960, 540))
        let point = CGPoint(x: 200, y: 50)
        XCTAssertEqual(
            WSSPreviewGeometry.point(
                point, bounds: hero, canvas: canvas,
                flipped: false, projection: .cover),
            SceneCursor.scenePoint(global: point, screen: hero, canvas: canvas))
        let resources = try WSSPreviewTests().resources(trail: true)
        let surface = WSSPreviewSurface(resources: resources, onError: { _ in XCTFail() })
        surface.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let window = NSWindow(
            contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved,
                location: CGPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0,
                pressure: 0))
        surface.mouseMoved(with: event)
        XCTAssertEqual(surface.player?.currentPointer(), SIMD2(32, 32))
        surface.mouseExited(with: event)
        XCTAssertNil(surface.player?.currentPointer())
        surface.configure(policy: .editor, projection: .cover)
        XCTAssertNil(surface.player?.currentPointer())
        surface.shutdown()
        window.contentView = nil
        window.close()
    }

    func testSwiftUIHeroMountSelectionAndDisappearance() async throws {
        let owner = WSSLibraryPreviewOwner()
        let preview = WSSLibraryLivePreview(
            item: helper.item, fit: false,
            policy: .library(profile: .balanced, resolution: .hiDPI, fps: 30), owner: owner)
        let hosting = NSHostingView(rootView: AnyView(preview))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 245),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while owner.state != .live && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(owner.state, .live)
        let player = try XCTUnwrap(owner.surface?.player)
        XCTAssertFalse(player.view.isPaused)
        hosting.rootView = AnyView(
            WSSLibraryLivePreview(
                item: helper.item, fit: true,
                policy: .library(profile: .eco, resolution: .standard, fps: 60), owner: owner))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(owner.surface?.player === player)
        XCTAssertEqual(player.view.preferredFramesPerSecond, 24)
        hosting.rootView = AnyView(EmptyView())
        let removalDeadline = ProcessInfo.processInfo.systemUptime + 3
        while owner.surface != nil && ProcessInfo.processInfo.systemUptime < removalDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(owner.surface)
        XCTAssertNil(player.view.delegate)
        window.contentView = nil
        window.close()
        await owner.shutdownAndDrain()
    }

    func testExistingDerivedProjectIsLiveWithoutSourceAndOtherKindsNeverLoad() async throws {
        var calls = 0
        let otherOwner = WSSLibraryPreviewOwner(load: { _ in
            calls += 1
            throw WSSSceneError.invalid("must not load")
        })
        let otherHost = WSSLibraryPreviewHost(owner: otherOwner)
        for kind in [WallpaperKind.image, .video, .web, .scene] {
            let item = Wallpaper(title: "External", path: "/missing", root: "/", kind: kind)
            otherOwner.select(item)
            XCTAssertEqual(otherOwner.state, .staticPreview)
        }
        XCTAssertEqual(calls, 0)
        otherHost.shutdown()
        await otherOwner.shutdownAndDrain()
    }

    func testCancelFreezeResumesAndNativeResizeUsesCurrentBacking() async throws {
        let maintenance = MaintenanceCoordinator()
        let owner = WSSLibraryPreviewOwner(maintenance: maintenance)
        let host = WSSLibraryPreviewHost(owner: owner)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 245),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        owner.select(helper.item)
        await owner.waitForPreparation()
        let lease = try maintenance.reserve(.restore)
        try maintenance.freeze()
        XCTAssertNil(owner.surface)
        try maintenance.cancelFreeze()
        await Task.yield()
        await owner.waitForPreparation()
        XCTAssertEqual(owner.state, .live)
        owner.configure(
            policy: .library(profile: .original, resolution: .hiDPI, fps: 30), fit: false)
        host.layoutSubtreeIfNeeded()
        let surface = try XCTUnwrap(owner.surface)
        surface.layoutSubtreeIfNeeded()
        let player = try XCTUnwrap(surface.player)
        let time = player.elapsed
        window.setContentSize(CGSize(width: 900, height: 300))
        host.layoutSubtreeIfNeeded()
        surface.layoutSubtreeIfNeeded()
        player.view.viewDidChangeBackingProperties()
        XCTAssertEqual(
            player.view.drawableSize,
            SceneRenderResolution.hiDPI.drawableSize(
                bounds: player.view.bounds.size,
                backing: player.view.convertToBacking(player.view.bounds).size, maxDimension: 8192))
        XCTAssertGreaterThanOrEqual(player.elapsed, time)
        owner.configure(
            policy: .library(profile: .original, resolution: .standard, fps: 30), fit: false)
        XCTAssertEqual(player.view.drawableSize, player.view.bounds.size)
        host.shutdown()
        await owner.shutdownAndDrain()
        window.contentView = nil
        window.close()
        lease.finish()
    }

    func testReplacementHostReusesOnePlayerAndOldTeardownCannotStopIt() async throws {
        let owner = WSSLibraryPreviewOwner()
        let oldHost = WSSLibraryPreviewHost(owner: owner)
        owner.select(helper.item)
        await owner.waitForPreparation()
        let player = try XCTUnwrap(owner.surface?.player)
        let newHost = WSSLibraryPreviewHost(owner: owner)
        oldHost.shutdown()
        owner.select(helper.item)
        XCTAssertEqual(owner.state, .live)
        XCTAssertTrue(owner.surface?.superview === newHost)
        XCTAssertTrue(owner.surface?.player === player)
        newHost.shutdown()
        XCTAssertNil(owner.surface)
        XCTAssertNil(player.view.delegate)
        await owner.shutdownAndDrain()
    }

    func testEffectivePolicyAndPreviewDensity() {
        for (profile, fps): (QualityProfile, Int) in [(.eco, 24), (.balanced, 30), (.original, 60)]
        {
            let policy = WSSPreviewRenderPolicy.library(
                profile: profile, resolution: .hiDPI, fps: 60)
            XCTAssertEqual(policy.fps, fps)
            XCTAssertEqual(policy.maxDimension, profile.maxDimension)
            let bounds = CGSize(width: 800, height: 245)
            XCTAssertEqual(
                policy.resolution.drawableSize(
                    bounds: bounds,
                    backing: CGSize(width: 1600, height: 490), maxDimension: policy.maxDimension),
                profile == .eco
                    ? CGSize(width: 1280, height: 392) : CGSize(width: 1600, height: 490))
        }
        XCTAssertEqual(
            WSSPreviewRenderPolicy.library(profile: .balanced, resolution: .standard, fps: 24).fps,
            24)
    }
}
