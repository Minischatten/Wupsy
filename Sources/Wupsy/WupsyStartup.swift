import AppKit
import Darwin

// No Library, widgets, playlist, editor or shared maintenance singleton is touched here.
struct WupsyLaunchContext {
    let supportRoot: URL
    let preferenceDomain: String
    static func current(arguments: [String] = CommandLine.arguments) throws -> Self {
        if arguments.contains("--benchmark") {
            return Self(
                supportRoot: ProductPaths.current.benchmarkSupport,
                preferenceDomain: ProductIdentity.benchmarkDomain)
        }
        guard NSClassFromString("XCTestCase") == nil else {
            throw LibraryBackupError("Tests must inject an isolated launch context.")
        }
        guard let domain = Bundle.main.bundleIdentifier, domain == ProductIdentity.bundleIdentifier
        else {
            throw LibraryBackupError("Wupsy could not determine its preference domain.")
        }
        return Self(
            supportRoot: ProductPaths.current.supportRoot, preferenceDomain: domain)
    }
}

enum WupsyStartupError: LocalizedError {
    case fatalRecovery(String)
    var errorDescription: String? {
        switch self {
        case .fatalRecovery(let detail): return detail
        }
    }
}

enum WupsyStartup {
    // Descriptor-relative probes distinguish ENOENT from all errors, links and wrong types.
    static func needsRecovery(_ context: WupsyLaunchContext) throws -> Bool {
        let path = context.supportRoot.path
        var components = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), !components.contains("."), !components.contains("..") else {
            throw LibraryBackupError("The support root must be an absolute safe path.")
        }
        // The same two trusted system aliases accepted by WSSAssetIO. Never resolve
        // arbitrary links in an injected or productive support path.
        if components.first == "var" || components.first == "tmp" {
            components.insert("private", at: 0)
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LibraryBackupError("Cannot inspect the support root.") }
        defer { close(fd) }
        for component in components + [".restore"] {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                if errno == ENOENT { return false }
                throw LibraryBackupError("Cannot safely inspect the support root (\(errno)).")
            }
            close(fd)
            fd = next
        }
        var info = stat()
        if fstatat(fd, "journal.json", &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return false }
            throw LibraryBackupError("Cannot inspect the restore journal (\(errno)).")
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw LibraryBackupError("The restore journal is not a safe regular file.")
        }
        return true
    }
    static func run(
        context: WupsyLaunchContext,
        probe: (WupsyLaunchContext) throws -> Bool = needsRecovery,
        recover: ((WupsyLaunchContext) throws -> Void)? = nil,
        constructRuntime: () -> Void
    ) throws {
        guard !context.preferenceDomain.isEmpty else {
            throw LibraryBackupError("Missing explicit preference domain.")
        }
        do {
            _ = try LibraryMetadataRecovery(root: context.supportRoot).preflight(
                quiescence: .init(callerGuaranteesQuiescentRuntime: true))
            if try probe(context) {
                if let recover {
                    try recover(context)
                } else {
                    _ = try LibraryRestoreRecovery(
                        root: context.supportRoot, preferenceDomain: context.preferenceDomain
                    ).recover(
                        quiescence: RestoreRuntimeQuiescence(callerGuaranteesQuiescentRuntime: true)
                    )
                }
            }
        } catch {
            throw WupsyStartupError.fatalRecovery(error.localizedDescription)
        }
        constructRuntime()
    }
}

@main enum WupsyEntry {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == "--verify-localization" {
            do {
                let expected = CommandLine.arguments.dropFirst(2).first
                print(try LocalizationAudit.run(expectedLanguage: expected))
            } catch {
                fputs("Localization audit failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        do {
            try WupsyStartup.run(context: WupsyLaunchContext.current()) {
                WupsyApp.main()
            }
        } catch {
            // Minimal AppKit failure path; none of the normal runtime has been constructed.
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            app.activate(ignoringOtherApps: true)
            let alert = StartupRecoveryPresentation.alert(error)
            alert.runModal()
        }
    }
}
