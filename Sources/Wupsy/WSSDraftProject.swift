import Foundation

// Owns precisely the files written through its exclusive directory ledger.
// No scans, path-prefix ownership guesses, or persistent draft index.
final class WSSDraftOwner: @unchecked Sendable {
    let wallpaperID: UUID
    let token = UUID()
    private let staging: WSSSaveAsStaging
    private let lock = NSLock()
    private var discarded = false
    var root: URL { staging.url }
    init(wallpaperID: UUID) throws {
        self.wallpaperID = wallpaperID
        staging = try WSSSaveAsStaging(
            parent: FileManager.default.temporaryDirectory.resolvingSymlinksInPath(), draft: true)
    }
    func verify() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !discarded else { throw WSSSaveError.targetDisappeared }
        try staging.verifyOwnership()
    }
    fileprivate func write(_ bytes: Data, path: String) throws {
        try staging.write(bytes, path: path, checkpoint: nil)
    }
    func discard() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !discarded else { return }
        try staging.discard()
        discarded = true
    }
    deinit { try? discard() }
}

actor WSSDraftPreparation {
    func create(image url: URL) async throws -> WSSLoadedEditorProject {
        let generation = try await WSSImageImporter().load(url)
        try Task.checkCancellation()
        let id = UUID()
        let owner = try WSSDraftOwner(wallpaperID: id)
        do {
            let stem = url.deletingPathExtension().lastPathComponent
            let title = (try? WSSSaveAsSnapshot.title(stem)) ?? "Untitled Wallpaper"
            let width = generation.width
            let height = generation.height
            // Decode through the same strict DTO boundary as any native project.
            let json: [String: Any] = [
                "format": "wss-scene", "version": 1, "title": title,
                "canvas": ["width": width, "height": height], "background": [0, 0, 0],
                "layers": [
                    [
                        "type": "image", "image": generation.path,
                        "transform": [
                            "center": [Double(width) / 2, Double(height) / 2],
                            "size": [width, height], "scale": [1, 1], "rotation": 0,
                        ],
                        "opacity": 1, "visible": true, "composition": "sourceOver",
                        "effects": [] as [String],
                    ]
                ],
            ]
            var model = try WSSSceneDocumentV1.decode(
                data: JSONSerialization.data(withJSONObject: json))
            if case .image(var image) = model.layers[0].content {
                image.name = WSSImageLayerName.fromSource(url)
                image.definition = generation.definition
                model.layers[0].content = .image(image)
            }
            try owner.write(generation.read(), path: generation.path)
            try owner.write(model.encoded(), path: "scene.wss.json")
            let item = Wallpaper(
                id: id, title: title,
                path: owner.root.appendingPathComponent("scene.wss.json").path,
                root: owner.root.path,
                kind: .scene, sceneSource: .nativeWSS)
            let handle = WSSProjectHandle(
                wallpaper: item, root: owner.root, entry: item.url,
                origin: .draft, draftOwner: owner)
            let project = try WSSEditorProjectLoader.read(handle: handle)
            try Task.checkCancellation()
            return project
        } catch {
            do { try owner.discard() } catch { throw WSSSaveAsError.cleanup }
            throw error
        }
    }
}
