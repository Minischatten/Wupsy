import Foundation

// Product boundaries only; never probes another application's namespace.
// Inject base directories in tests. Constructing this value performs no I/O.
enum ProductIdentity {
    static let name = "Wupsy"
    static let bundleIdentifier = "com.wirdschonsoftware.wupsy"
    static let benchmarkDomain = bundleIdentifier + ".benchmark"
    static let backupFormat = "wupsy-library-backup"
    static let backupTemporaryTemplate = "Wupsy-backup-XXXXXX"
    static let backupPartialPrefix = ".Wupsy-backup-"
    static let draftPrefix = ".wupsy-draft-"
    static let editorTemporaryTemplate = "wupsy-editor-XXXXXX"
}

struct ProductPaths: Sendable {
    let supportRoot: URL
    let cacheRoot: URL
    let temporaryRoot: URL

    init(applicationSupport: URL, caches: URL, temporary: URL) {
        supportRoot = applicationSupport.appendingPathComponent(ProductIdentity.name)
        cacheRoot = caches.appendingPathComponent(ProductIdentity.name)
        temporaryRoot = temporary
    }
    static var current: Self {
        let files = FileManager.default
        return Self(
            applicationSupport: files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
                0],
            caches: files.urls(for: .cachesDirectory, in: .userDomainMask)[0],
            temporary: files.temporaryDirectory.resolvingSymlinksInPath())
    }
    var library: URL { supportRoot.appendingPathComponent("library.json") }
    var playlists: URL { supportRoot.appendingPathComponent("playlists.json") }
    var videoCache: URL { cacheRoot.appendingPathComponent("Video-v2") }
    var benchmarkSupport: URL { temporaryRoot.appendingPathComponent("Wupsy-benchmark-support") }
    var benchmarkLibrary: URL {
        temporaryRoot.appendingPathComponent("Wupsy-benchmark-no-library.json")
    }
    var benchmarkPlaylists: URL {
        temporaryRoot.appendingPathComponent("Wupsy-benchmark-playlists.json")
    }
}
