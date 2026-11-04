import AppKit
import Darwin
import XCTest

@testable import Wupsy

@MainActor final class WSSSaveAsTests: XCTestCase {
    var helper: WSSEditorWorkspaceTests!
    var doc: WSSEditorDocument!
    var store: ManagedWallpaperStore!
    var storage: URL!
    override func setUp() async throws {
        helper = WSSEditorWorkspaceTests()
        try await helper.setUp()
        doc = helper.document()
        storage = helper.helper.root.appendingPathComponent("library.json")
        try JSONEncoder().encode([helper.item!]).write(to: storage)
        store = ManagedWallpaperStore(storage: storage)
    }
    override func tearDown() async throws {
        doc.close()
        doc = nil
        store = nil
        try await helper.tearDown()
        helper = nil
    }
    func snapshot(_ name: String = "Copy") throws -> WSSSaveAsSnapshot {
        try .init(
            document: doc.state.workingModel, state: doc.state, source: doc.project.handle,
            name: name)
    }
    func assertSource(
        _ original: [String: Data], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let current = try helper.helper.snapshot()
        for (path, bytes) in original where path.hasPrefix("Wallpapers/WSS/Native/") {
            XCTAssertEqual(current[path], bytes, file: file, line: line)
        }
    }
    func testCleanCopyNewIdentityTitlePathAndIndependentInodes() async throws {
        let original = try helper.helper.snapshot()
        let snapshot = try snapshot("Same / Name: 😀")
        let receipt = try await store.saveWSSAs(snapshot)
        let project = receipt.project
        XCTAssertNotEqual(project.handle.id, helper.item.id)
        XCTAssertEqual(project.handle.id, snapshot.destinationID)
        XCTAssertEqual(
            project.handle.wallpaper.managed?.directory, "WSS/" + snapshot.destinationID.uuidString)
        XCTAssertEqual(project.handle.wallpaper.sceneSource, .nativeWSS)
        XCTAssertEqual(project.document, snapshot.model)
        XCTAssertEqual(project.diskBasis.assets, snapshot.catalog)
        XCTAssertFalse(project.handle.root.path.contains("Same"))
        XCTAssertEqual(try store.load().count, 2)
        for path in snapshot.model.referencedPaths {
            let a = try FileManager.default.attributesOfItem(
                atPath: helper.project.handle.root.appendingPathComponent(path).path)
            let b = try FileManager.default.attributesOfItem(
                atPath: project.handle.root.appendingPathComponent(path).path)
            XCTAssertNotEqual(a[.systemFileNumber] as? NSNumber, b[.systemFileNumber] as? NSNumber)
        }
        try assertSource(original)
    }
    func testDirtyCombinedWorkingStateAndSessionAssetsCopiedExactlyAndIndependently() async throws {
        let original = try helper.helper.snapshot()
        let first = doc.identity.layers[0].id
        try doc.setParameter(.cloudsIntensity, at: .init(layerIndex: 0, effectIndex: 0), value: 0.8)
        try doc.setImage(.centerX, value: 25, layer: first)
        try doc.setImage(.opacity, value: 0.6, layer: first)
        try doc.setVisibility(false, layer: first)
        let importer = WSSImageImporter()
        let a = try await importer.normalize(WSSImageImportTests().image(), extension: "png")
        let b = try await importer.normalize(
            WSSImageImportTests().image(width: 7, height: 13), extension: "png")
        try await doc.installImage(a)
        try await doc.installImage(b, replacing: doc.identity.layers[1].id)
        try doc.moveLayer(doc.identity.layers.last!.id, by: -1)
        let snapshot = try snapshot()
        let receipt = try await store.saveWSSAs(snapshot)
        XCTAssertEqual(receipt.project.document, snapshot.model)
        XCTAssertEqual(Set(receipt.project.diskBasis.assets.keys), snapshot.model.referencedPaths)
        XCTAssertTrue(doc.isDirty)
        try assertSource(original)
        doc.close()
        // Remove only this test's generated A. B must have no source/staging dependency.
        try FileManager.default.removeItem(at: helper.project.handle.root)
        let loaded = try await WSSEditorProjectLoader().load(receipt.project.handle.wallpaper)
        XCTAssertEqual(loaded.document, snapshot.model)
        XCTAssertEqual(loaded.diskBasis.assets, snapshot.catalog)
    }
    func testOnlyReferencedAssetsCopiedNotUndoHistoryOrOtherFiles() async throws {
        let importer = WSSImageImporter()
        let old = try await importer.normalize(WSSImageImportTests().image(), extension: "png")
        let new = try await importer.normalize(
            WSSImageImportTests().image(width: 9, height: 17), extension: "png")
        let target = doc.identity.layers[1].id
        try await doc.installImage(old, replacing: target)
        try await doc.installImage(new, replacing: target)
        try Data("unreferenced".utf8).write(
            to: helper.project.handle.root.appendingPathComponent("unrelated.txt"))
        let receipt = try await store.saveWSSAs(snapshot())
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: receipt.project.handle.root.appendingPathComponent(old.path).path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: receipt.project.handle.root.appendingPathComponent("unrelated.txt").path))
        XCTAssertTrue(receipt.project.document.referencedPaths.contains(new.path))
    }
    func testMaskAndVectorFieldCopiedWithoutChangingBytes() async throws {
        let fixtures = WSSEditorLivePreviewTests()
        try await fixtures.setUp()
        defer { try? fixtures.helper.tearDownWithError() }
        let initial = try await fixtures.project("WSS-Ripple-v1")
        let field = WSSAssetID(value: "assets/directions.wssvf")
        try WSSFlowTestSupport().field(SIMD2(1, 0)).encodedNative().write(
            to: initial.handle.root.appendingPathComponent(field.value))
        var model = initial.document
        guard case .image(var image) = model.layers[0].content else { return XCTFail() }
        image.effects.append(try WSSAddableEffect.flow.definition(field: field))
        model.layers[0].content = .image(image)
        try model.encoded().write(to: initial.handle.entry)
        let source = try await WSSEditorProjectLoader().load(initial.handle.wallpaper)
        for (path, fp) in source.diskBasis.assets {
            let target = helper.project.handle.root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try source.assets.read(path, limit: fp.byteCount).write(to: target)
        }
        try source.document.encoded().write(to: helper.project.handle.entry)
        let loaded = try await WSSEditorProjectLoader().load(helper.item)
        doc.close()
        doc = WSSEditorDocument(project: loaded)
        let snapshot = try snapshot()
        let receipt = try await store.saveWSSAs(snapshot)
        XCTAssertTrue(snapshot.model.referencedPaths.contains { $0.hasSuffix(".wssvf") })
        XCTAssertEqual(receipt.project.diskBasis.assets, loaded.diskBasis.assets)
        XCTAssertEqual(
            receipt.project.scene.imageLayers.map(\.effects),
            loaded.scene.imageLayers.map(\.effects))
    }
    func testSameVisibleNameAllowedWithoutIdentityReuse() async throws {
        let first = try await store.saveWSSAs(snapshot("Identical"))
        let second = try await store.saveWSSAs(snapshot("Identical"))
        XCTAssertNotEqual(first.project.handle.id, second.project.handle.id)
        XCTAssertNotEqual(first.project.handle.root, second.project.handle.root)
        XCTAssertEqual(try store.load().count, 3)
    }
    func testNameValidationNoTruncationAndBothUnicodeLimits() throws {
        for name in [
            "", "   ", "line\nbreak", String(repeating: "x", count: 257),
            String(repeating: "a\u{0301}", count: 256) + "x",
        ] {
            XCTAssertThrowsError(try snapshot(name))
        }
        XCTAssertEqual(try snapshot("  Name 😀  ").model.title, "Name 😀")
        XCTAssertNoThrow(try snapshot(String(repeating: "x", count: 256)))
        let cluster = "a" + String(repeating: "\u{0301}", count: 600)
        XCTAssertEqual(cluster.count, 1)
        XCTAssertThrowsError(try snapshot(cluster))
    }
    func testProjectBudgetBeforeWritingAnyAssets() throws {
        var model = doc.state.workingModel
        let fp = WSSContentFingerprint(Data(repeating: 0, count: 128 * 1024 * 1024))
        var assets: [String: WSSContentFingerprint] = [:]
        model.layers = (0..<5).map { index in
            var node = model.layers[1]
            if case .image(var image) = node.content {
                image.asset = "assets/large-\(index).png"
                node.content = .image(image)
                assets[image.asset] = fp
            }
            return node
        }
        let basis = WSSProjectDiskBasis(
            identity: doc.state.diskBasis.identity, manifest: doc.state.diskBasis.manifest,
            assets: assets)
        let state = WSSEditorDocumentState(model: model, diskBasis: basis)
        let snapshot = try WSSSaveAsSnapshot(
            document: model, state: state, source: doc.project.handle, name: "Large")
        XCTAssertThrowsError(try snapshot.checkBudget())
    }
    func testUUIDAndDestinationCollisionsNeverOverwrite() async throws {
        let original = try helper.helper.snapshot()
        do {
            _ = try await store.saveWSSAs(snapshot(), id: helper.item.id)
            XCTFail("UUID collision")
        } catch {}
        let snapshot = try snapshot()
        let target = helper.project.handle.root.deletingLastPathComponent().appendingPathComponent(
            snapshot.destinationID.uuidString)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let sentinel = target.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        do {
            _ = try await store.saveWSSAs(snapshot)
            XCTFail("destination collision")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertEqual(try store.load().count, 1)
        try assertSource(original)
    }
    func testEveryPrecommitFaultPreservesAAndNoLibraryEntry() async throws {
        let original = try helper.helper.snapshot()
        for stage: WSSSaveAsStage in [
            .resourceRead, .staging, .write, .flush, .close, .fingerprint, .preparation,
            .projectPublish, .finalValidation, .libraryPersistence, .libraryCommit,
        ] {
            let snapshot = try snapshot()
            do {
                _ = try await store.saveWSSAs(
                    snapshot, checkpoint: { if $0 == stage { throw WSSSaveAsError.storage } })
                XCTFail("fault ignored")
            } catch {}
            XCTAssertEqual(try store.load().map(\.id), [helper.item.id])
            try assertSource(original)
            let names = try FileManager.default.contentsOfDirectory(
                atPath: helper.project.handle.root.deletingLastPathComponent().path)
            XCTAssertFalse(names.contains { $0.hasPrefix(".wss-saveas-") })
            let libraryTemps = try FileManager.default.contentsOfDirectory(
                atPath: helper.helper.root.path)
            XCTAssertFalse(libraryTemps.contains { $0.hasPrefix(".wss-library-") })
        }
    }
    func testPostcommitFailureReturnsCommittedWarningAndValidB() async throws {
        let receipt = try await store.saveWSSAs(
            snapshot(), checkpoint: { if $0 == .afterCommit { throw WSSSaveAsError.storage } })
        XCTAssertFalse(receipt.warnings.isEmpty)
        XCTAssertEqual(try store.load().count, 2)
        let loaded = try await WSSEditorProjectLoader().load(receipt.project.handle.wallpaper)
        XCTAssertEqual(loaded.document, receipt.project.document)
    }
    func testPublishedOrphanAfterLibraryFailureIsCompleteAndUnreferenced() async throws {
        let snapshot = try snapshot()
        do {
            _ = try await store.saveWSSAs(
                snapshot,
                checkpoint: { if $0 == .libraryPersistence { throw WSSSaveAsError.storage } })
            XCTFail("fault ignored")
        } catch {}
        let root = helper.project.handle.root.deletingLastPathComponent().appendingPathComponent(
            snapshot.destinationID.uuidString)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("scene.wss.json").path))
        XCTAssertFalse(try store.load().contains { $0.id == snapshot.destinationID })
        let model = try WSSSceneDocumentV1.load(
            entry: root.appendingPathComponent("scene.wss.json"), root: root)
        XCTAssertEqual(model, snapshot.model)
    }
    func testConcurrentLibraryAdditionIsRetainedAtCommit() async throws {
        let other = Wallpaper(title: "Other", path: "/external", root: "/", kind: .image)
        let receipt = try await store.saveWSSAs(
            snapshot(),
            checkpoint: { stage in
                if stage == .libraryPersistence {
                    try JSONEncoder().encode([self.helper.item!, other]).write(to: self.storage)
                }
            })
        XCTAssertEqual(
            Set(try store.load().map(\.id)), [helper.item.id, other.id, receipt.project.handle.id])
    }
    func testLibraryChangeAtCommitFailsClosedWithoutDroppingNewData() async throws {
        let other = Wallpaper(title: "Concurrent", path: "/external", root: "/", kind: .image)
        do {
            _ = try await store.saveWSSAs(
                snapshot(),
                checkpoint: { stage in
                    if stage == .libraryCommit {
                        try JSONEncoder().encode([self.helper.item!, other]).write(to: self.storage)
                    }
                })
            XCTFail("stale library overwritten")
        } catch {}
        XCTAssertEqual(Set(try store.load().map(\.id)), [helper.item.id, other.id])
    }
    func testSourceMutationFingerprintMismatchFailsClosed() async throws {
        let snapshot = try snapshot()
        let file = helper.project.handle.root.appendingPathComponent("assets/second.png")
        try Data("changed".utf8).write(to: file)
        do {
            _ = try await store.saveWSSAs(snapshot)
            XCTFail("changed source copied")
        } catch {}
        XCTAssertEqual(try store.load().count, 1)
    }
    func testTraversalAndAbsoluteReferencesRejected() throws {
        for path in ["../outside.png", "/outside.png", "assets/../../outside.png"] {
            var model = doc.state.workingModel
            if case .image(var image) = model.layers[0].content {
                image.asset = path
                model.layers[0].content = .image(image)
            }
            XCTAssertThrowsError(
                try WSSSaveAsSnapshot(
                    document: model, state: doc.state, source: doc.project.handle, name: "Unsafe"))
        }
    }
    func testSymlinkAndNonRegularSourceRejectedWithoutFollowing() async throws {
        let asset = helper.project.handle.root.appendingPathComponent("assets/second.png")
        let original = try Data(contentsOf: asset)
        let external = helper.helper.root.appendingPathComponent("external.png")
        try original.write(to: external)
        try FileManager.default.removeItem(at: asset)
        try FileManager.default.createSymbolicLink(at: asset, withDestinationURL: external)
        do {
            _ = try await store.saveWSSAs(snapshot())
            XCTFail("symlink followed")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: external), original)
        try FileManager.default.removeItem(at: asset)
        XCTAssertEqual(mkfifo(asset.path, mode_t(0o600)), 0)
        do {
            _ = try await store.saveWSSAs(snapshot())
            XCTFail("special file followed")
        } catch {}
    }
    func testOwnedStagingNeverOverwritesAndRejectsUnsafePaths() throws {
        let owned = try WSSSaveAsStaging(
            parent: helper.project.handle.root.deletingLastPathComponent())
        defer { try? owned.discard() }
        try owned.write(Data("first".utf8), path: "assets/first.bin", checkpoint: nil)
        XCTAssertThrowsError(
            try owned.write(Data("second".utf8), path: "assets/first.bin", checkpoint: nil))
        XCTAssertThrowsError(try owned.write(Data(), path: "../escape.bin", checkpoint: nil))
        XCTAssertThrowsError(try owned.write(Data(), path: "/absolute.bin", checkpoint: nil))
        XCTAssertEqual(
            try WSSAssetIO.read(root: owned.url, path: "assets/first.bin", limit: 5),
            Data("first".utf8))
    }
    func testSourceChangeAtPublishFailsBeforeDestinationExists() async throws {
        let snapshot = try snapshot()
        do {
            _ = try await store.saveWSSAs(
                snapshot,
                checkpoint: { stage in
                    if stage == .projectPublish {
                        try Data("changed".utf8).write(
                            to: self.helper.project.handle.root.appendingPathComponent(
                                "assets/second.png"))
                    }
                })
            XCTFail("source change accepted")
        } catch {}
        let final = helper.project.handle.root.deletingLastPathComponent().appendingPathComponent(
            snapshot.destinationID.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        XCTAssertEqual(try store.load().count, 1)
    }
    func testLibrarySymlinkAtCommitDoesNotOverwriteExternalFile() async throws {
        let outside = helper.helper.root.appendingPathComponent("outside.json")
        let bytes = Data("keep external".utf8)
        try bytes.write(to: outside)
        do {
            _ = try await store.saveWSSAs(
                snapshot(),
                checkpoint: { stage in
                    if stage == .libraryCommit {
                        try FileManager.default.removeItem(at: self.storage)
                        try FileManager.default.createSymbolicLink(
                            at: self.storage, withDestinationURL: outside)
                    }
                })
            XCTFail("library symlink accepted")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
    }
    func testUnsafeStagingCleanupDoesNotDeleteForeignReplacement() async throws {
        let parent = helper.project.handle.root.deletingLastPathComponent()
        let owned = try WSSSaveAsStaging(parent: parent)
        try owned.write(Data("own".utf8), path: "own.txt", checkpoint: nil)
        let moved = parent.appendingPathComponent("moved-" + UUID().uuidString)
        try FileManager.default.moveItem(at: owned.url, to: moved)
        try FileManager.default.createDirectory(at: owned.url, withIntermediateDirectories: false)
        let sentinel = owned.url.appendingPathComponent("sentinel.txt")
        try Data("foreign".utf8).write(to: sentinel)
        XCTAssertThrowsError(try owned.discard())
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("foreign".utf8))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: moved.appendingPathComponent("own.txt").path))
    }
}
