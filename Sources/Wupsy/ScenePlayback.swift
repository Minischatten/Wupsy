import MetalKit

// Playback boundary only. ManagedWallpaperStore.validate and MediaDetails.read
// retain their parsing/validation responsibilities; neither starts playback.
// Every scene uses WSS. Historical backend fields are persistence metadata only.
enum ScenePlayback {
    enum WSSSupport: Equatable {
        case supported
        case unavailable(String)
    }

    // The actual WSS preparation is the support check: no second feature list,
    // no player/window, no persistence and no external engine resources.
    static func wssSupport(for wallpaper: Wallpaper) async -> WSSSupport {
        do {
            try requireAvailableBackend(for: wallpaper)
            _ = try await WSSStaticPreparation.shared.prepare(wallpaper)
            return .supported
        } catch {
            return .unavailable(
                "WSS-Effekte sind für dieses Wallpaper noch nicht vollständig verfügbar. Alle Bild-Layer, Effekte und benötigten Dateien müssen vom WSS-Pfad vollständig unterstützt werden."
            )
        }
    }

    static func requireAvailableBackend(for wallpaper: Wallpaper) throws {
        guard wallpaper.kind == .scene, wallpaper.sceneSource == .nativeWSS else {
            throw ScenePlaybackError.notSceneWallpaper
        }
    }

    static func prepare(for wallpaper: Wallpaper) async throws -> PreparedScenePlayback {
        try requireAvailableBackend(for: wallpaper)
        do {
            return PreparedScenePlayback(
                wss: try await WSSStaticPreparation.shared.prepare(wallpaper))
        } catch let error as WSSSceneError {
            if case .unsupported = error {
                throw RuntimeDiagnostic.sceneUnsupported(error.localizedDescription)
            }
            throw error
        }
    }
}

struct PreparedScenePlayback {
    let resources: WSSStaticResources
    var mode: ScenePlaybackMode { .wss }
    init(wss resources: WSSStaticResources) { self.resources = resources }
    func validate(for wallpaper: Wallpaper) throws {
        try ScenePlayback.requireAvailableBackend(for: wallpaper)
    }
    @MainActor func makePlayer(
        size: CGSize, scale: CGFloat, maxDimension: Int, fps: Int,
        resolution: SceneRenderResolution, offset: Double,
        onDiagnostic: ((RuntimeDiagnostic) -> Void)? = nil,
        onError: @escaping (String) -> Void
    ) -> any ScenePlaybackSession {
        WSSStaticPlayer(
            resources: resources, size: size, scale: scale, maxDimension: maxDimension,
            fps: fps, resolution: resolution, offset: offset,
            onDiagnostic: onDiagnostic, onError: onError)
    }
}

@MainActor protocol ScenePlaybackSession: AnyObject {
    var view: MTKView { get }
    var elapsed: Double { get }
    var metrics: SceneMetrics { get }
    var diagnostics: ScenePlaybackDiagnostics { get }
    func play()
    func stop()
    func setRenderResolution(_ resolution: SceneRenderResolution)
}

struct ScenePlaybackDiagnostics {
    let sourceWidth: Int
    let sourceHeight: Int
    let textureBytes: Int
    let intermediateTextureBytes: Int
    let deviceName: String
    let shader: String
}
