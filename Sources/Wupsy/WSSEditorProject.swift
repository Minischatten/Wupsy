import Foundation
import Metal

// Read-only handles deliberately expose no materialization or writing operation.
struct WSSProjectHandle {
    enum Origin: String { case native, draft }
    let wallpaper: Wallpaper
    let root: URL
    let entry: URL
    let origin: Origin
    var draftOwner: WSSDraftOwner? = nil
    var id: UUID { wallpaper.id }
}

enum WSSEditorOpenError: LocalizedError {
    case unavailable
    case missingProject
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The WSS editor requires an existing managed Scene library entry."
        case .missingProject:
            return
                "No native WSS project exists for this wallpaper. An editable WSS project must be created from a fully supported source first."
        }
    }
}

enum WSSExistingProjectResolver {
    static func resolve(_ wallpaper: Wallpaper) throws -> WSSProjectHandle {
        guard wallpaper.managed != nil, wallpaper.kind == .scene else {
            throw WSSEditorOpenError.unavailable
        }
        if wallpaper.sceneSource == .nativeWSS {
            let root = URL(fileURLWithPath: wallpaper.root)
            try ManagedWallpaperStore.checkPath(root)
            return WSSProjectHandle(
                wallpaper: wallpaper, root: root, entry: wallpaper.url, origin: .native)
        }
        throw WSSEditorOpenError.unavailable
    }
}

struct WSSLoadedEditorProject {
    let handle: WSSProjectHandle
    let document: WSSSceneDocumentV1
    let scene: WSSScene
    let assets: WSSNativeAssets
    let resources: WSSStaticResources
    let diskBasis: WSSProjectDiskBasis
}

actor WSSEditorProjectLoader {
    func load(_ wallpaper: Wallpaper) throws -> WSSLoadedEditorProject { try Self.read(wallpaper) }
    nonisolated static func read(_ wallpaper: Wallpaper) throws -> WSSLoadedEditorProject {
        try Task.checkCancellation()
        return try read(handle: WSSExistingProjectResolver.resolve(wallpaper))
    }
    nonisolated static func read(handle: WSSProjectHandle) throws -> WSSLoadedEditorProject {
        try Task.checkCancellation()
        let identity = try WSSProjectDiskBasis.Identity(handle)
        guard handle.entry.lastPathComponent == "scene.wss.json",
            handle.entry.deletingLastPathComponent().standardizedFileURL.path
                == handle.root.standardizedFileURL.path
        else { throw WSSDocumentError.invalid("native scene entry") }
        let bytes = try WSSNativeAssets(root: handle.root).read(
            "scene.wss.json", limit: WSSSceneDocumentV1.byteLimit)
        let document = try WSSSceneDocumentV1.decode(data: bytes)
        let scene = try document.scene()
        let capture = WSSProjectReadCapture()
        var assets = try document.assetSource(root: handle.root)
        assets.didRead = { try capture.record($0, $1) }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw WSSSceneError.invalid("Metal unavailable")
        }
        let resources = try WSSStaticResources(scene: scene, assets: assets, device: device)
        let basis = try capture.basis(
            handle: handle, identity: identity, manifest: bytes,
            references: document.referencedPaths)
        try basis.verify(handle)
        try Task.checkCancellation()
        assets.didRead = nil
        return WSSLoadedEditorProject(
            handle: handle, document: document, scene: scene, assets: assets, resources: resources,
            diskBasis: basis)
    }
}
