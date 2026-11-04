import AppKit
import Darwin
import XCTest

@testable import Wupsy

@MainActor final class WSSDraftTests: XCTestCase {
    var fixture: WSSNativeSceneTests!
    var root: URL { fixture.root }
    override func setUp() async throws {
        _ = NSApplication.shared
        fixture = WSSNativeSceneTests()
        try fixture.setUpWithError()
    }
    override func tearDown() async throws { try fixture.tearDownWithError() }
    func image(_ ext: String = "png", orientation: Int = 1) throws -> URL {
        let url = root.appendingPathComponent("Example." + ext)
        try WSSImageImportTests().image(ext == "png" ? .png : .jpeg, orientation: orientation)
            .write(to: url)
        return url
    }
    func draft(_ ext: String = "png", orientation: Int = 1) async throws -> WSSLoadedEditorProject {
        try await WSSDraftPreparation().create(image: image(ext, orientation: orientation))
    }
    func store() -> ManagedWallpaperStore {
        ManagedWallpaperStore(storage: root.appendingPathComponent("support/library.json"))
    }
    func snapshot(_ project: WSSLoadedEditorProject, model: WSSSceneDocumentV1? = nil) throws
        -> WSSSaveAsSnapshot
    {
        try WSSSaveAsSnapshot(
            document: model ?? project.document,
            state: WSSEditorDocumentState(model: project.document, diskBasis: project.diskBasis),
            source: project.handle, name: project.document.title, destinationID: project.handle.id)
    }
    func editor(_ project: WSSLoadedEditorProject, store: ManagedWallpaperStore)
        -> WSSEditorDocument
    {
        let doc = WSSEditorDocument(
            project: project,
            save: { snapshot in
                guard
                    let item = try store.load().first(where: {
                        $0.id == snapshot.diskBasis.identity.wallpaperID
                    })
                else {
                    throw WSSSaveError.targetDisappeared
                }
                let candidate = try await WSSManifestSaveValidator().prepare(
                    snapshot,
                    handle: WSSExistingProjectResolver.resolve(item))
                return try await store.commitWSSManifest(candidate)
            })
        doc.publishDraft = { try await store.publishWSSDraft($0) }
        doc.chooseFirstSaveName = { $0 }
        return doc
    }
    func testMaintenanceDraftFirstSaveAndNamingCancel() async throws {
        for cancel in [false, true] {
            let maintenance = MaintenanceCoordinator()
            var document: WSSEditorDocument!
            let store = self.store()
            let coordinator = WSSEditorCoordinator(
                maintenance: maintenance, lookup: { _ in throw WSSEditorOpenError.unavailable },
                publishDraft: { try await store.publishWSSDraft($0) },
                makeWindow: { doc, close in
                    document = doc
                    return DraftTestWindow(close)
                })
            coordinator.chooseNewImage = { try? self.image() }
            await coordinator.newWallpaper()
            let doc = try XCTUnwrap(document)
            let draftRoot = doc.project.handle.root
            doc.chooseClose = { .save }
            doc.chooseFirstSaveName = { _ in cancel ? nil : "Maintenance First Save" }
            let job = try maintenance.reserve(.restore)
            try maintenance.freeze()
            let result = await coordinator.resolveAndCloseAllForMaintenance()
            XCTAssertEqual(result, cancel ? .cancelled : .approved)
            if cancel {
                XCTAssertFalse(doc.closed)
                XCTAssertTrue(doc.isUnpublished)
                try maintenance.cancelFreeze()
            } else {
                XCTAssertTrue(doc.closed)
                XCTAssertEqual(try store.load().last?.title, "Maintenance First Save")
                XCTAssertFalse(FileManager.default.fileExists(atPath: draftRoot.path))
            }
            coordinator.shutdown()
            await doc.closeAndDrainForMaintenance()
            job.finish()
        }
    }
    func testImageDisplayNameNormalizationAndFallback() {
        for (source, expected) in [
            ("Example Vordergrund.png", "Example Vordergrund"),
            ("Photo.edit.jpeg", "Photo.edit"),
            ("  Photo  .png", "Photo"),
            ("A\nB.png", "A B"), ("   .png", "Image"),
            ("\u{1}.png", "Image"), (String(repeating: "a", count: 257) + ".png", "Image"),
        ] {
            XCTAssertEqual(WSSImageLayerName.fromSource(URL(fileURLWithPath: source)), expected)
        }
    }
    func testNewWallpaperBaseLayerNamePersistsSeparatelyFromWallpaperTitle() async throws {
        let project = try await draft()
        let doc = editor(project, store: store())
        defer { doc.close() }
        XCTAssertEqual(doc.layerNames, ["1 · Example"])
        let asset = try XCTUnwrap(project.document.referencedPaths.first)
        XCTAssertTrue(asset.hasPrefix("assets/editor-"))
        doc.chooseFirstSaveName = { _ in "Different Wallpaper Title" }
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(doc.layerNames, ["1 · Example"])
        let reloaded = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        guard case .image(let image) = reloaded.document.layers[0].content else { return XCTFail() }
        XCTAssertEqual(image.name, "Example")
        XCTAssertEqual(image.asset, asset)
        XCTAssertEqual(reloaded.document.title, "Different Wallpaper Title")
    }
    func testAddImageDuplicateDisplayNamesHaveIndependentImmutableAssetsAndReplaceKeepsName()
        async throws
    {
        let project = try await draft()
        let doc = editor(project, store: store())
        defer { doc.close() }
        let source = root.appendingPathComponent("Example Vordergrund.png")
        let bytes = try WSSImageImportTests().image()
        try bytes.write(to: source)
        doc.chooseImageFile = { source }
        await doc.chooseImage()
        await doc.chooseImage()
        XCTAssertEqual(
            Array(doc.layerNames.suffix(2)), ["2 · Example Vordergrund", "3 · Example Vordergrund"])
        guard case .image(let a) = doc.state.workingModel.layers[1].content,
            case .image(let b) = doc.state.workingModel.layers[2].content
        else { return XCTFail() }
        XCTAssertNotEqual(a.asset, b.asset)
        XCTAssertTrue(a.asset.hasPrefix("assets/editor-"))
        XCTAssertTrue(b.asset.hasPrefix("assets/editor-"))
        let id = doc.identity.layers[1].id
        let replacement = root.appendingPathComponent("NewPerson.png")
        try WSSImageImportTests().image(width: 20, height: 16).write(to: replacement)
        doc.chooseImageFile = { replacement }
        await doc.chooseImage(replacing: id)
        guard case .image(let changed) = doc.state.workingModel.layers[1].content else {
            return XCTFail()
        }
        XCTAssertEqual(changed.name, "Example Vordergrund")
        XCTAssertEqual(doc.identity.layers[1].id, id)
        XCTAssertNotEqual(changed.asset, a.asset)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let encoded = try doc.state.workingModel.encoded()
        XCTAssertEqual(try WSSSceneDocumentV1.decode(data: encoded), doc.state.workingModel)
    }
    func testLegacyUnnamedLayerRoundTripDoesNotInventMetadata() async throws {
        var model = try await draft().document
        guard case .image(var image) = model.layers[0].content else { return XCTFail() }
        image.name = nil
        model.layers[0].content = .image(image)
        let data = try model.encoded()
        let decoded = try WSSSceneDocumentV1.decode(data: data)
        guard case .image(let legacy) = decoded.layers[0].content else { return XCTFail() }
        XCTAssertNil(legacy.name)
        XCTAssertEqual(legacy.asset, image.asset)
        image.name = "\n"
        model.layers[0].content = .image(image)
        XCTAssertThrowsError(try model.encoded())
    }
    func testDraftAndPublishedSaveAsCommandStatesAreIntentional() async throws {
        let doc = editor(try await draft(), store: store())
        defer { doc.close() }
        var copies = 0
        doc.requestSaveAs = {
            copies += 1
            return true
        }
        XCTAssertTrue(doc.canSave)
        XCTAssertFalse(doc.canSaveAs)
        XCTAssertFalse(doc.canRevert)
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(doc.canSave)
        XCTAssertTrue(doc.canSaveAs)
        XCTAssertFalse(doc.canRevert)
        try doc.setImage(.opacity, value: 0.5, layer: doc.identity.layers[0].id)
        XCTAssertTrue(doc.canSave)
        XCTAssertTrue(doc.canSaveAs)
        XCTAssertTrue(doc.canRevert)
        XCTAssertEqual(copies, 0)
    }
    func testCreateWallpaperUsesEstablishedHeaderActionStyle() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: repo.appendingPathComponent("Sources/Wupsy/WallpaperActions.swift"))
        let create = try XCTUnwrap(source.range(of: "Button(ProductText.createWallpaper.text)"))
        let add = try XCTUnwrap(source.range(of: "Button(action: importWallpaper)"))
        let createStyle = source[create.lowerBound..<add.lowerBound]
        XCTAssertTrue(createStyle.contains(".buttonStyle(VioletButtonStyle())"))
        XCTAssertFalse(createStyle.contains("secondary:"))
        XCTAssertTrue(source[add.lowerBound...].hasPrefix("Button(action: importWallpaper)"))
    }
    func testFirstSaveRequestsDerivedNameAndPublishesConfirmedNormalizedTitleOnlyOnce() async throws
    {
        let project = try await draft()
        let store = store()
        let doc = editor(project, store: store)
        defer { doc.close() }
        var requests = 0
        doc.chooseFirstSaveName = { proposed in
            requests += 1
            XCTAssertEqual(proposed, "Example")
            return "  My Wallpaper  "
        }
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(doc.project.document.title, "My Wallpaper")
        XCTAssertEqual(try store.load().first?.title, "My Wallpaper")
        XCTAssertEqual(doc.project.handle.id, project.handle.id)
        try doc.setImage(.opacity, value: 0.5, layer: doc.identity.layers[0].id)
        let again = await doc.save()
        XCTAssertTrue(again)
        XCTAssertEqual(requests, 1)
    }
    func testFirstSaveCancelAndInvalidNameNeverPublishOrMutateDraft() async throws {
        for name: String? in [nil, "", "   ", String(repeating: "a", count: 1025)] {
            let project = try await draft()
            let store = store()
            let doc = editor(project, store: store)
            let before = doc.state.workingModel
            doc.chooseFirstSaveName = { _ in name }
            let saved = await doc.save()
            XCTAssertFalse(saved)
            XCTAssertTrue(doc.isUnpublished)
            XCTAssertFalse(doc.closed)
            XCTAssertEqual(doc.state.workingModel, before)
            XCTAssertNil(doc.draftPublicationReceipt)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.storage.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.wallpaperRoot.path))
            try project.diskBasis.verify(project.handle)
            doc.close()
            await doc.waitForDraftCleanup()
        }
    }
    func testCloseSaveNamingCancelKeepsDraftOpen() async throws {
        let project = try await draft()
        let doc = editor(project, store: store())
        defer { doc.close() }
        doc.chooseClose = { .save }
        doc.chooseFirstSaveName = { _ in nil }
        let closed = await doc.resolveChanges()
        XCTAssertFalse(closed)
        XCTAssertFalse(doc.closed)
        XCTAssertTrue(doc.isUnpublished)
        try project.diskBasis.verify(project.handle)
    }
    func testQuitSaveNamingCancelKeepsDraftOpen() async throws {
        var document: WSSEditorDocument?
        let coordinator = WSSEditorCoordinator(
            lookup: { _ in throw WSSEditorOpenError.unavailable },
            publishDraft: { _ in
                XCTFail("Unexpected publication")
                throw WSSSaveAsError.library
            },
            makeWindow: { doc, callback in
                document = doc
                return DraftTestWindow(callback)
            })
        let source = try image()
        coordinator.chooseNewImage = { source }
        await coordinator.newWallpaper()
        let doc = try XCTUnwrap(document)
        doc.chooseClose = { .save }
        doc.chooseFirstSaveName = { _ in nil }
        let approved = await coordinator.approveTermination()
        XCTAssertFalse(approved)
        XCTAssertFalse(doc.closed)
        XCTAssertTrue(doc.isUnpublished)
        XCTAssertEqual(coordinator.openIDs, [doc.project.handle.id])
        await coordinator.finishTermination()
    }
    func testConfirmedDuplicateFirstSaveNamesRemainIndependent() async throws {
        let store = store()
        var ids: Set<UUID> = []
        for _ in 0..<2 {
            let doc = editor(try await draft(), store: store)
            doc.chooseFirstSaveName = { _ in "Same Name" }
            let saved = await doc.save()
            XCTAssertTrue(saved)
            ids.insert(doc.project.handle.id)
            doc.close()
        }
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(try store.load().map(\.title), ["Same Name", "Same Name"])
    }
    func testCreationEntryPointsShareCoordinatorAndWupsyMenuHasNoCreationAction() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: repo.appendingPathComponent("Sources/Wupsy/App.swift"))
        let library = try String(
            contentsOf: repo.appendingPathComponent("Sources/Wupsy/WallpaperActions.swift"))
        let menu = try XCTUnwrap(app.components(separatedBy: "struct WupsyMenu: View").last)
        XCTAssertFalse(menu.contains("New Wallpaper"))
        XCTAssertFalse(menu.contains("ProductText.newWallpaper"))
        XCTAssertFalse(menu.contains("newWallpaper()"))
        XCTAssertTrue(
            app.contains(
                "Button(ProductText.newWallpaper.text) { Task { await editors.newWallpaper() } }"))
        XCTAssertTrue(app.contains(".keyboardShortcut(\"n\")"))
        XCTAssertEqual(ProductText.newWallpaper.localized(language: "en"), "New Wallpaper…")
        XCTAssertEqual(
            ProductText.newWallpaper.localized(language: "de"), "Neues Hintergrundbild …")
        XCTAssertEqual(ProductText.createWallpaper.localized(language: "en"), "Create wallpaper")
        XCTAssertEqual(
            ProductText.createWallpaper.localized(language: "de"), "Hintergrundbild erstellen")
        let create = try XCTUnwrap(
            library.range(
                of:
                    "Button(ProductText.createWallpaper.text)"
            ))
        let add = try XCTUnwrap(library.range(of: "Button(action: importWallpaper)"))
        XCTAssertLessThan(create.lowerBound, add.lowerBound)
        XCTAssertTrue(library.contains("await editors.newWallpaper(onFirstSave: onFirstSave)"))
    }
    func testNativeNamingSheetCancelReturnsNoName() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let request = Task {
            await WSSWallpaperNameRequest.present(
                title: "Save Wallpaper", proposedName: "Example", window: window)
        }
        for _ in 0..<100 {
            if window.attachedSheet != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let sheet = window.attachedSheet else {
            XCTFail("Naming sheet was not attached")
            request.cancel()
            return
        }
        let fieldEditor = try XCTUnwrap(sheet.firstResponder as? NSTextView)
        XCTAssertEqual(fieldEditor.string, "Example")
        XCTAssertEqual(fieldEditor.selectedRange(), NSRange(location: 0, length: 7))
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        let name = await request.value
        XCTAssertNil(name)
    }
    func testSharedNativeNamingSheetHasEditableFocusedProposalAndNativeKeys() throws {
        for title in ["Save Wallpaper", "Save Wallpaper As"] {
            let alert = WSSWallpaperNameRequest.alert(title: title, proposedName: "Example Copy")
            let field = try XCTUnwrap(alert.accessoryView as? NSTextField)
            XCTAssertEqual(alert.messageText, title)
            XCTAssertEqual(field.stringValue, "Example Copy")
            XCTAssertTrue(field.isEditable)
            XCTAssertTrue(alert.window.initialFirstResponder === field)
            XCTAssertEqual(
                alert.buttons.map(\.title), [ProductText.save.text, ProductText.cancel.text])
            XCTAssertEqual(alert.buttons.map(\.keyEquivalent), ["\r", "\u{1b}"])
        }
    }
    func testCloseWaitsForOwnedResourceOperationBeforeRemovingDraft() async throws {
        let project = try await draft()
        let doc = editor(project, store: store())
        doc.beginResourceOperation()
        doc.close()
        await Task.yield()
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.handle.root.path))
        doc.endResourceOperation()
        await doc.waitForDraftCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.handle.root.path))
    }
    func testApprovedQuitDiscardsDraftBeforeTerminationCompletes() async throws {
        var document: WSSEditorDocument?
        let coordinator = WSSEditorCoordinator(
            lookup: { _ in throw WSSEditorOpenError.unavailable },
            publishDraft: { _ in throw WSSSaveAsError.library },
            makeWindow: { doc, onClose in
                document = doc
                return DraftTestWindow(onClose)
            })
        let source = try image()
        coordinator.chooseNewImage = { source }
        await coordinator.newWallpaper()
        let doc = try XCTUnwrap(document)
        let path = doc.project.handle.root.path
        doc.chooseClose = { .discard }
        let approved = await coordinator.approveTermination()
        XCTAssertTrue(approved)
        await coordinator.finishTermination()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(coordinator.openIDs.isEmpty)
    }
    func testFirstSavePreservesPausedPreviewClock() async throws {
        let project = try await draft()
        let doc = editor(project, store: store())
        doc.playing = false
        doc.initialPreviewTime = 17
        let surface = WSSPreviewSurface(document: doc)
        defer { doc.close() }
        let before = try XCTUnwrap(surface.player).elapsed
        let saved = await doc.save()
        XCTAssertTrue(saved)
        surface.update(resources: doc.previewResources, playing: doc.playing)
        XCTAssertEqual(try XCTUnwrap(surface.player).elapsed, before, accuracy: 0.001)
        XCTAssertFalse(doc.playing)
    }
    func testPNGJPEGOrientationInitialModelAndUnpublishedState() async throws {
        for (ext, orientation, size) in [
            ("png", 1, [12, 8]), ("jpg", 1, [12, 8]), ("png", 6, [8, 12]),
        ] {
            let source = try image(ext, orientation: orientation)
            let bytes = try Data(contentsOf: source)
            let project = try await WSSDraftPreparation().create(image: source)
            let doc = editor(project, store: store())
            XCTAssertEqual(project.handle.origin, .draft)
            XCTAssertNil(project.handle.wallpaper.managed)
            XCTAssertEqual(project.document.title, "Example")
            XCTAssertEqual([project.scene.width, project.scene.height], size)
            XCTAssertEqual(project.document.layers.count, 1)
            guard case .image(let layer) = project.document.layers[0].content else {
                return XCTFail()
            }
            XCTAssertEqual(layer.transform.size, size.map(Float.init))
            XCTAssertEqual(layer.transform.center, size.map { Float($0) / 2 })
            XCTAssertEqual(layer.transform.scale, [1, 1])
            XCTAssertEqual(layer.transform.rotation, 0)
            XCTAssertEqual(layer.composition, "sourceOver")
            XCTAssertTrue(layer.effects.isEmpty)
            XCTAssertEqual(layer.definition?.uvScale, [1, 1])
            XCTAssertEqual(layer.definition?.mipmapped, true)
            XCTAssertTrue(doc.isUnpublished)
            XCTAssertTrue(doc.isDirty)
            XCTAssertFalse(doc.state.isDirty)
            XCTAssertTrue(doc.canSave)
            XCTAssertFalse(doc.canSaveAs)
            XCTAssertFalse(doc.canRevert)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("support/library.json").path))
            let draftRoot = project.handle.root
            doc.close()
            await doc.waitForDraftCleanup()
            XCTAssertFalse(FileManager.default.fileExists(atPath: draftRoot.path))
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }
    func testInvalidInputsAndLimitsLeaveNoDraftOrLibrary() async throws {
        let file = root.appendingPathComponent("invalid.png")
        try Data("invalid".utf8).write(to: file)
        do {
            _ = try await WSSDraftPreparation().create(image: file)
            XCTFail()
        } catch {}
        let huge = root.appendingPathComponent("huge.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: huge.path, contents: nil))
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(WSSImageImporter.inputLimit + 1))
        try handle.close()
        do {
            _ = try await WSSDraftPreparation().create(image: huge)
            XCTFail()
        } catch {}
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image())
        do {
            _ = try await WSSDraftPreparation().create(image: link)
            XCTFail()
        } catch {}
        XCTAssertThrowsError(try WSSImageImporter.validateDimensions(8193, 1))
        XCTAssertThrowsError(try WSSImageImporter.validateDimensions(8192, 8192))
    }
    func testMissingLibraryFirstSaveCurrentSnapshotAndNormalSecondSave() async throws {
        let project = try await draft()
        let store = store()
        let doc = editor(project, store: store)
        defer { doc.close() }
        let identity = doc.identity
        let originalSession = doc.state.sessionID
        let draftRoot = project.handle.root
        doc.select(.layer(identity.layers[0].id))
        try doc.addEffect(.ripple)
        doc.maskCanvas.setBrush(true)
        await doc.maskCanvas.waitForBrushActivation()
        let target = try XCTUnwrap(doc.selectedMaskTarget)
        doc.playing = false
        doc.previewExpanded = true
        let expected = doc.state.workingModel
        let editedIdentity = doc.identity
        let selected = doc.selection
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.isUnpublished)
        XCTAssertFalse(doc.state.isDirty)
        XCTAssertEqual(doc.project.handle.id, project.handle.id)
        XCTAssertEqual(doc.identity, editedIdentity)
        XCTAssertEqual(doc.selection, selected)
        XCTAssertNotEqual(doc.state.sessionID, originalSession)
        XCTAssertThrowsError(try doc.resolveMaskTarget(target))
        XCTAssertFalse(doc.undoManager.canUndo)
        XCTAssertFalse(doc.playing)
        XCTAssertTrue(doc.previewExpanded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftRoot.path))
        XCTAssertEqual(try store.load().map(\.id), [project.handle.id])
        XCTAssertEqual(doc.project.document, expected)
        XCTAssertEqual(Set(doc.project.diskBasis.assets.keys), expected.referencedPaths)
        try doc.setParameter(.rippleAmplitude, at: .init(layerIndex: 0, effectIndex: 0), value: 9)
        let again = await doc.save()
        XCTAssertTrue(again)
        let loaded = try await WSSEditorProjectLoader().load(doc.project.handle.wallpaper)
        XCTAssertEqual(loaded.document, doc.state.workingModel)
    }
    func testCloseWithoutEditsCancelDiscardSaveAndFailure() async throws {
        for choice in [WSSEditorDocument.CloseChoice.cancel, .discard, .save] {
            let project = try await draft()
            let doc = editor(project, store: store())
            var prompts = 0
            doc.chooseClose = {
                prompts += 1
                return choice
            }
            let result = await doc.resolveChanges()
            XCTAssertEqual(result, choice != .cancel)
            XCTAssertEqual(prompts, 1)
            if choice == .save { XCTAssertFalse(doc.isDirty) }
            let location = project.handle.root
            doc.close()
            await doc.waitForDraftCleanup()
            XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))
        }
        let project = try await draft()
        let doc = editor(project, store: store())
        doc.publishDraft = { _ in throw WSSSaveAsError.storage }
        doc.chooseClose = { .save }
        let result = await doc.resolveChanges()
        XCTAssertFalse(result)
        XCTAssertTrue(doc.isUnpublished)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.handle.root.path))
        doc.close()
        await doc.waitForDraftCleanup()
    }
    func testExistingAndCorruptLibraryAndDuplicateTitles() async throws {
        let store = store()
        let a = try await draft()
        let b = try await draft()
        defer {
            try? a.handle.draftOwner?.discard()
            try? b.handle.draftOwner?.discard()
        }
        _ = try await store.publishWSSDraft(snapshot(a))
        _ = try await store.publishWSSDraft(snapshot(b))
        XCTAssertEqual(try store.load().map(\.title), ["Example", "Example"])
        XCTAssertEqual(Set(try store.load().map(\.id)), [a.handle.id, b.handle.id])
        let before = try Data(contentsOf: store.storage)
        try Data("broken".utf8).write(to: store.storage)
        let c = try await draft()
        defer { try? c.handle.draftOwner?.discard() }
        do {
            _ = try await store.publishWSSDraft(snapshot(c))
            XCTFail()
        } catch {}
        XCTAssertEqual(try Data(contentsOf: store.storage), Data("broken".utf8))
        try before.write(to: store.storage)
    }
    func testPublicationFailuresRollbackOnlyOwnedCandidate() async throws {
        for stage in [
            WSSSaveAsStage.resourceRead, .staging, .write, .flush, .close, .fingerprint,
            .preparation, .projectPublish, .finalValidation, .libraryPersistence, .libraryCommit,
        ] {
            let project = try await draft()
            let store = store()
            do {
                _ = try await store.publishWSSDraft(
                    snapshot(project),
                    checkpoint: { current in
                        if current == stage { throw WSSSaveAsError.storage }
                    })
                XCTFail("failure ignored")
            } catch {}
            try project.diskBasis.verify(project.handle)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: store.wallpaperRoot.appendingPathComponent(
                        "WSS/" + project.handle.id.uuidString
                    ).path))
            try project.handle.draftOwner?.discard()
        }
    }
    func testCollisionNeverReplacesUnknownDestination() async throws {
        let project = try await draft()
        defer { try? project.handle.draftOwner?.discard() }
        let store = store()
        let final = store.wallpaperRoot.appendingPathComponent(
            "WSS/" + project.handle.id.uuidString)
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
        let marker = final.appendingPathComponent("unknown")
        try Data([12]).write(to: marker)
        do {
            _ = try await store.publishWSSDraft(snapshot(project))
            XCTFail()
        } catch {}
        XCTAssertEqual(try Data(contentsOf: marker), Data([12]))
    }
    func testPostCommitWarningAndRepeatedSaveNeverDuplicates() async throws {
        let project = try await draft()
        let store = store()
        let doc = editor(project, store: store)
        defer { doc.close() }
        var publications = 0
        doc.publishDraft = { value in
            publications += 1
            return try await store.publishWSSDraft(
                value,
                checkpoint: { stage in
                    if stage == .afterCommit { throw WSSSaveAsError.storage }
                })
        }
        let a = await doc.save()
        let b = await doc.save()
        XCTAssertTrue(a)
        XCTAssertTrue(b)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(try store.load().count, 1)
    }
    func testOwnerRejectsReplacedRootAndOtherDraftSurvives() async throws {
        let a = try await draft()
        let b = try await draft()
        let owner = try XCTUnwrap(a.handle.draftOwner)
        let saved = a.handle.root.appendingPathExtension("held")
        try FileManager.default.moveItem(at: owner.root, to: saved)
        try FileManager.default.createDirectory(at: owner.root, withIntermediateDirectories: false)
        let foreign = owner.root.appendingPathComponent("foreign")
        try Data([9]).write(to: foreign)
        XCTAssertThrowsError(try owner.discard())
        XCTAssertEqual(try Data(contentsOf: foreign), Data([9]))
        try b.diskBasis.verify(b.handle)
        try FileManager.default.removeItem(at: owner.root)
        try FileManager.default.moveItem(at: saved, to: owner.root)
        try owner.discard()
        try b.handle.draftOwner?.discard()
    }
    func testCoordinatorPickerCancelAndMultipleDraftsAndQuit() async throws {
        var docs: [WSSEditorDocument] = []
        let store = store()
        let coordinator = WSSEditorCoordinator(
            lookup: { _ in throw WSSEditorOpenError.unavailable },
            publishDraft: { try await store.publishWSSDraft($0) },
            makeWindow: { doc, onClose in
                doc.chooseFirstSaveName = { $0 }
                docs.append(doc)
                return DraftTestWindow(onClose)
            })
        coordinator.chooseNewImage = { nil }
        await coordinator.newWallpaper()
        XCTAssertTrue(coordinator.openIDs.isEmpty)
        let source = try image()
        coordinator.chooseNewImage = { source }
        await coordinator.newWallpaper()
        await coordinator.newWallpaper()
        XCTAssertEqual(coordinator.openIDs.count, 2)
        XCTAssertNotEqual(docs[0].project.handle.id, docs[1].project.handle.id)
        docs[0].chooseClose = { .cancel }
        docs[1].chooseClose = { .cancel }
        let cancelled = await coordinator.approveTermination()
        XCTAssertFalse(cancelled)
        for doc in docs { doc.chooseClose = { .save } }
        let allowed = await coordinator.approveTermination()
        XCTAssertTrue(allowed)
        XCTAssertEqual(try store.load().count, 2)
        coordinator.shutdown()
    }
}

@MainActor private final class DraftTestWindow: WSSEditorWindow {
    let onClose: () -> Void
    init(_ onClose: @escaping () -> Void) { self.onClose = onClose }
    func focus() {}
    func close() { onClose() }
}

extension WSSDraftTests {
    func testFirstSaveCopiesOnlyReferencesAndContinuesSaveAsAndRevert() async throws {
        let project = try await draft()
        let store = store()
        let doc = editor(project, store: store)
        defer { doc.close() }
        let initialPath = try XCTUnwrap(project.document.referencedPaths.first)
        let generation = try await WSSImageImporter().normalize(
            WSSImageImportTests().image(width: 20, height: 16), extension: "png")
        try await doc.installImage(generation, replacing: doc.identity.layers[0].id)
        let id = doc.identity.layers[0].id
        try doc.setImage(.opacity, value: 0.7, layer: id)
        doc.undoManager.undo()
        let current = doc.state.workingModel
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(doc.state.savedModel, current)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: doc.project.handle.root.appendingPathComponent(initialPath).path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: doc.project.handle.root.appendingPathComponent(generation.path).path))
        try doc.setImage(.opacity, value: 0.4, layer: id)
        doc.revert()
        XCTAssertEqual(doc.state.workingModel, current)
        let copy = try WSSSaveAsSnapshot(
            document: current, state: doc.state,
            source: doc.project.handle, name: "Copy")
        let receipt = try await store.saveWSSAs(copy)
        XCTAssertNotEqual(receipt.project.handle.id, doc.project.handle.id)
        XCTAssertEqual(receipt.project.document.layers, current.layers)
    }
    func testRollbackRefusesReplacedPublishedCandidate() async throws {
        let project = try await draft()
        defer { try? project.handle.draftOwner?.discard() }
        let store = store()
        let final = store.wallpaperRoot.appendingPathComponent(
            "WSS/" + project.handle.id.uuidString)
        let held = final.appendingPathExtension("held")
        do {
            _ = try await store.publishWSSDraft(
                snapshot(project),
                checkpoint: { stage in
                    if stage == .finalValidation {
                        try FileManager.default.moveItem(at: final, to: held)
                        try FileManager.default.createDirectory(
                            at: final, withIntermediateDirectories: false)
                        try Data([42]).write(to: final.appendingPathComponent("foreign"))
                        throw WSSSaveAsError.storage
                    }
                })
            XCTFail()
        } catch { XCTAssertEqual(error as? WSSSaveAsError, .cleanup) }
        XCTAssertEqual(try Data(contentsOf: final.appendingPathComponent("foreign")), Data([42]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storage.path))
    }
    func testMissingLibraryWriterNeverOverwritesConcurrentFirstWriter() throws {
        let store = store()
        try FileManager.default.createDirectory(
            at: store.supportRoot, withIntermediateDirectories: true)
        do {
            _ = try WSSSaveAsLibraryWriter.commit(
                before: nil, after: Data("[]".utf8), storage: store.storage,
                checkpoint: { stage in
                    if stage == .libraryCommit { try Data("winner".utf8).write(to: store.storage) }
                })
            XCTFail()
        } catch {}
        XCTAssertEqual(try Data(contentsOf: store.storage), Data("winner".utf8))
    }
    func testEditorFailureCleansOwnedDraftAndDoesNotPromoteAppMode() async throws {
        var abandoned: WSSEditorDocument?
        var policies = 0
        let presentation = WSSEditorAppPresentation(setPolicy: { _ in
            policies += 1
            return true
        })
        let coordinator = WSSEditorCoordinator(
            lookup: { _ in throw WSSEditorOpenError.unavailable },
            publishDraft: { _ in throw WSSSaveAsError.storage },
            makeWindow: { document, _ in
                abandoned = document
                throw WSSSaveAsError.invalid
            },
            presentation: presentation)
        var errors = 0
        coordinator.presentCreationError = { _ in errors += 1 }
        let source = try image()
        coordinator.chooseNewImage = { source }
        await coordinator.newWallpaper()
        XCTAssertEqual(errors, 1)
        XCTAssertEqual(policies, 0)
        XCTAssertTrue(coordinator.openIDs.isEmpty)
        let failed = try XCTUnwrap(abandoned)
        XCTAssertTrue(failed.closed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.project.handle.root.path))
    }
    func testUndoToInitialStillUnpublishedAndRevertDisabled() async throws {
        let project = try await draft()
        let doc = editor(project, store: store())
        defer { doc.close() }
        let initial = doc.state.workingModel
        try doc.addEffect(.ripple)
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, initial)
        XCTAssertFalse(doc.state.isDirty)
        XCTAssertTrue(doc.isDirty)
        let commands = WSSEditorCommands(document: doc, window: nil)
        XCTAssertTrue(commands.canPerform(.save))
        XCTAssertFalse(commands.canPerform(.saveAs))
        XCTAssertFalse(commands.canPerform(.revert))
    }
    func testFirstSaveKeepsNativeWindowCanvasAndSelection() async throws {
        let source = root.appendingPathComponent("large.png")
        try WSSImageImportTests().image(width: 1920, height: 1080).write(to: source)
        let project = try await WSSDraftPreparation().create(image: source)
        let doc = editor(project, store: store())
        let controller = WSSEditorWindowController(document: doc, onClose: {})
        doc.chooseFirstSaveName = { $0 }
        defer {
            doc.close()
            controller.close()
        }
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        func find<T: NSView>(_ type: T.Type, _ view: NSView) -> T? {
            if let value = view as? T { return value }
            return view.subviews.lazy.compactMap { find(type, $0) }.first
        }
        let content = try XCTUnwrap(window.contentView)
        let canvas = try XCTUnwrap(find(WSSCanvasScrollView.self, content))
        _ = doc.canvasZoomCommand?(.actualSize)
        canvas.contentView.scroll(to: NSPoint(x: 30, y: 20))
        canvas.reflectScrolledClipView(canvas.contentView)
        let pan = canvas.contentView.bounds.origin
        let zoom = canvas.presentationZoom
        let selection = doc.selection
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertTrue(controller.editorDocument === doc)
        XCTAssertTrue(window.contentView === content)
        XCTAssertTrue(find(WSSCanvasScrollView.self, content) === canvas)
        XCTAssertEqual(canvas.contentView.bounds.origin, pan)
        XCTAssertEqual(canvas.presentationZoom, zoom)
        XCTAssertEqual(doc.selection, selection)
        XCTAssertFalse(window.isDocumentEdited)
    }
    func testPublishingThroughLibraryPreservesSelectionAndPlaylist() async throws {
        let suite = "WSSDraft-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = root.appendingPathComponent("library.json")
        let library = Library(storage: storage, defaults: defaults, restoreOnLaunch: false)
        defer { library.stop() }
        let playlistURL = root.appendingPathComponent("playlist.json")
        let playlist = WallpaperPlaylist(
            library: library, storage: playlistURL,
            defaults: defaults, restoreOnLaunch: false)
        defer { playlist.shutdown() }
        _ = try playlist.createPlaylist(name: "Unchanged")
        let before = try Data(contentsOf: playlistURL)
        let selection = library.selected
        let project = try await draft()
        defer { try? project.handle.draftOwner?.discard() }
        _ = try await library.publishWSSDraft(snapshot(project))
        XCTAssertEqual(library.items.map(\.id), [project.handle.id])
        XCTAssertEqual(library.selected, selection)
        XCTAssertNil(library.active)
        XCTAssertEqual(try Data(contentsOf: playlistURL), before)
    }
    func testOverviewFirstPublicationFollowUpIsScopedAndOnceOnly() async throws {
        let suite = "OverviewFirstSave-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = Library(
            storage: root.appendingPathComponent("overview/library.json"), defaults: defaults,
            restoreOnLaunch: false)
        defer { library.stop() }
        var fail = false
        var document: WSSEditorDocument!
        var revealed: [UUID] = []
        let coordinator = WSSEditorCoordinator(
            maintenance: MaintenanceCoordinator(),
            lookup: { try library.wallpaperForEditor(id: $0) },
            save: { try await library.saveWSSManifest($0) },
            publishDraft: {
                if fail { throw WSSSaveAsError.invalid }
                return try await library.publishWSSDraft($0)
            },
            makeWindow: { doc, close in
                document = doc
                return DraftTestWindow(close)
            })
        defer { coordinator.shutdown() }
        coordinator.chooseNewImage = { nil }
        await coordinator.newWallpaper(onFirstSave: { revealed.append($0) })
        XCTAssertNil(document)
        XCTAssertTrue(revealed.isEmpty)
        coordinator.chooseNewImage = { try? self.image() }
        await coordinator.newWallpaper(onFirstSave: { id in
            XCTAssertTrue(library.items.contains { $0.id == id })
            revealed.append(id)
        })
        let doc = try XCTUnwrap(document)
        XCTAssertTrue(revealed.isEmpty)
        doc.chooseFirstSaveName = { _ in nil }
        let cancelled = await doc.save()
        XCTAssertFalse(cancelled)
        XCTAssertTrue(revealed.isEmpty)
        doc.chooseFirstSaveName = { $0 }
        fail = true
        let failed = await doc.save()
        XCTAssertFalse(failed)
        XCTAssertTrue(revealed.isEmpty)
        XCTAssertTrue(library.items.isEmpty)
        fail = false
        let saved = await doc.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(revealed, [doc.project.handle.id])
        XCTAssertEqual(library.items.count, 1)
        XCTAssertFalse(doc.closed)
        try doc.setImage(.opacity, value: 0.5, layer: doc.identity.layers[0].id)
        let savedAgain = await doc.save()
        XCTAssertTrue(savedAgain)
        XCTAssertEqual(revealed.count, 1)
        XCTAssertEqual(library.items.count, 1)
        coordinator.close(wallpaperID: doc.project.handle.id)
        await doc.closeAndDrainForMaintenance()
        try await coordinator.open(wallpaperID: doc.project.handle.id)
        let existing = try XCTUnwrap(document)
        try existing.setImage(.opacity, value: 0.6, layer: existing.identity.layers[0].id)
        let edited = await existing.save()
        XCTAssertTrue(edited)
        XCTAssertEqual(revealed.count, 1)
        coordinator.close(wallpaperID: existing.project.handle.id)
        await existing.closeAndDrainForMaintenance()
        // The collection/menu entry uses the parameterless workflow, with no follow-up.
        await coordinator.newWallpaper()
        let unscoped = try XCTUnwrap(document)
        unscoped.chooseFirstSaveName = { $0 }
        let unscopedSaved = await unscoped.save()
        XCTAssertTrue(unscopedSaved)
        XCTAssertEqual(revealed.count, 1)
        XCTAssertEqual(library.items.count, 2)
        await unscoped.closeAndDrainForMaintenance()
    }

    func testRemoveSelfCreatedWallpaperDeletesManagedFilesAndPreservesSource() async throws {
        let source = try image()
        let original = try Data(contentsOf: source)
        let project = try await WSSDraftPreparation().create(image: source)
        defer { try? project.handle.draftOwner?.discard() }
        let store = store()
        let receipt = try await store.publishWSSDraft(snapshot(project))
        let item = receipt.project.handle.wallpaper
        let managedRoot = receipt.project.handle.root
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedRoot.path))
        _ = try await store.remove(item, existing: [item])
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedRoot.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

}
