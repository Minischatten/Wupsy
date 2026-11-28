import Foundation

// Plans a batch without changing the source or relaxing the store's validation.
struct WallpaperImportBatch {
    struct Project {
        let input: URL
        let manifest: URL
        var additionalInputs: [URL] = []
        var components: [URL] = []

        func committedComponents(of wallpaper: Wallpaper) -> Set<URL> {
            let root = URL(fileURLWithPath: wallpaper.root)
            return Self.componentURLs(
                manifest: wallpaper.url, root: root,
                sourceRoot: manifest.deletingLastPathComponent())
        }

        fileprivate static func componentURLs(manifest: URL, root: URL, sourceRoot: URL) -> Set<URL>
        {
            guard let document = try? WSSSceneDocumentV1.load(entry: manifest, root: root) else {
                return []
            }
            let root = sourceRoot.standardizedFileURL
            var components: Set<URL> = []
            for reference in document.referencedPaths {
                guard (try? WSSNativeAssets.validatePath(reference)) != nil else { continue }
                var part = root.appendingPathComponent(reference).standardizedFileURL
                while part.path != root.path && components.insert(key(part)).inserted {
                    part.deleteLastPathComponent()
                }
            }
            return components
        }
    }

    let projects: [Project]
    let independentInputs: [URL]

    init(_ inputs: [URL]) {
        let ordered = inputs.map(Self.key).sorted { $0.path < $1.path }
        var byManifest: [URL: Project] = [:]
        var independent: [URL] = []
        for input in ordered {
            guard input.isFileURL, (try? ManagedWallpaperStore.checkPath(input)) != nil,
                let manifest = WallpaperImporter.nativeEntry(for: input)
            else {
                independent.append(input)
                continue
            }
            let manifestKey = Self.key(manifest)
            if var project = byManifest[manifestKey] {
                if input != project.input, !project.additionalInputs.contains(input) {
                    project.additionalInputs.append(input)
                }
                byManifest[manifestKey] = project
            } else {
                byManifest[manifestKey] = Project(input: input, manifest: manifest)
            }
        }

        var projects = byManifest.values.sorted { $0.input.path < $1.input.path }
        var owners: [URL: Int] = [:]
        // Prefer the closest explicitly selected project if references are shared by nested projects.
        for index in projects.indices.sorted(by: {
            projects[$0].manifest.pathComponents.count > projects[$1].manifest.pathComponents.count
        }) {
            let manifest = projects[index].manifest
            let root = manifest.deletingLastPathComponent()
            for component in Project.componentURLs(manifest: manifest, root: root, sourceRoot: root)
            where owners[component] == nil {
                owners[component] = index
            }
        }
        independentInputs = independent.filter { input in
            guard let owner = owners[input],
                (try? ManagedWallpaperStore.checkPath(input)) != nil
            else { return true }
            if !projects[owner].components.contains(input) {
                projects[owner].components.append(input)
            }
            return false
        }
        self.projects = projects
    }

    private static func key(_ url: URL) -> URL {
        // Strip URL spelling differences such as a directory's trailing slash.
        guard url.isFileURL else { return url }
        return URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: false)
    }
}
