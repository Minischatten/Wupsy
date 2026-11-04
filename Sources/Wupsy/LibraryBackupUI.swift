import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum LibraryBackupCheckpoint: CaseIterable { case snapshot, archive, verification, publication }

@MainActor final class LibraryBackupCoordinator: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var progressState = LibraryBackupProgressState(phase: .analysis)
    var phase: String { progressState.title }
    private var task: Task<Void, Never>?
    private var panel: NSPanel?
    private var jobLease: MaintenanceCoordinator.Lease?
    private let maintenance: MaintenanceCoordinator
    init(maintenance: MaintenanceCoordinator? = nil) { self.maintenance = maintenance ?? .shared }

    func start(library: Library) {
        guard !running else { return }
        do { jobLease = try maintenance.reserve(.backup) } catch {
            let alert = NSAlert()
            alert.messageText = BackupText.unavailable.text
            alert.informativeText = BackupErrorPresentation.detail(error)
            alert.runModal()
            return
        }
        let save = NSSavePanel()
        save.title = BackupText.saveTitle.text
        save.message =
            BackupText.saveExplanation.text
        save.allowedContentTypes = [
            UTType(filenameExtension: "wssbackup", conformingTo: .zip) ?? .zip
        ]
        save.canCreateDirectories = true
        save.nameFieldStringValue = BackupText.suggestedFilename()
        NSApp.activate(ignoringOtherApps: true)
        guard save.runModal() == .OK, let destination = save.url else {
            jobLease?.finish()
            jobLease = nil
            return
        }
        running = true
        progressState = .init(phase: .analysis)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 150),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = BackupText.windowTitle.text
        panel.contentView = NSHostingView(rootView: LibraryBackupProgress(coordinator: self))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        let phaseTracker = LibraryBackupPhaseTracker()
        task = Task { [self] in
            var lease: LibraryMutationBarrier.Lease?
            do {
                while lease == nil {
                    try Task.checkCancellation()
                    lease = LibraryMutationBarrier.shared.trySnapshot()
                    if lease == nil { try await Task.sleep(for: .milliseconds(25)) }
                }
                // Main-actor preferences and organization are copied without suspension.
                let preferences = try library.backupPreferences
                let storage = library.backupStorage
                let manifest = try await Self.perform(
                    storage: storage, destination: destination,
                    preferences: preferences, release: { lease = nil },
                    progress: { [weak self] value in
                        phaseTracker.phase = value.phase
                        Task { @MainActor in
                            guard let self, self.running else { return }
                            self.progressState = value
                        }
                    })
                lease = nil
                finish()
                let alert = NSAlert()
                alert.messageText = LibraryBackupCompletionSummary.title(manifest)
                alert.informativeText = LibraryBackupCompletionSummary.detail(manifest)
                // Lay out the standard alert first, then move only its app icon.
                alert.layout()
                if let content = alert.window.contentView {
                    @MainActor func appIcon(in view: NSView) -> NSImageView? {
                        if let image = view as? NSImageView, image.image == alert.icon {
                            return image
                        }
                        return view.subviews.lazy.compactMap { appIcon(in: $0) }.first
                    }
                    if let icon = appIcon(in: content), let container = icon.superview {
                        let center = container.convert(
                            NSPoint(x: content.bounds.midX, y: 0), from: content)
                        icon.setFrameOrigin(
                            NSPoint(x: center.x - icon.frame.width / 2, y: icon.frame.minY))
                    }
                }
                alert.runModal()
            } catch {
                lease = nil
                let failedPhase = phaseTracker.phase
                finish()
                if !(error is CancellationError) {
                    let alert = NSAlert()
                    alert.messageText = failedPhase.failureTitle
                    alert.informativeText = BackupErrorPresentation.detail(error)
                    alert.runModal()
                }
            }
        }
    }
    func cancel() { task?.cancel() }
    private func finish() {
        jobLease?.finish()
        jobLease = nil
        progressState = .init(phase: .done)
        running = false
        task = nil
        panel?.close()
        panel = nil
    }
    // Heavy work runs off main. The lease is released only after the complete
    // independent snapshot exists; archive writing and verification follow unlocked.
    nonisolated static func perform(
        storage: URL, destination: URL,
        preferences: LibraryBackupPreferences,
        release: @escaping @MainActor () -> Void,
        progress: @escaping @Sendable (LibraryBackupProgressState) -> Void,
        checkpoint: @escaping @Sendable (LibraryBackupCheckpoint) throws -> Void = { _ in }
    ) async throws -> LibraryBackupManifest {
        let worker = Task.detached {
            () throws -> (LibraryBackupStaging, LibraryBackupPlan, LibraryBackupManifest) in
            let staging = try LibraryBackupStaging()
            do {
                progress(.init(phase: .analysis))
                let plan = try LibraryBackupPlan.analyze(storage: storage)
                try plan.validateDestination(destination, staging: staging.url)
                progress(.init(phase: .snapshot))
                try checkpoint(.snapshot)
                let manifest = try plan.snapshot(
                    to: staging.url, preferences: preferences,
                    progress: { _ in },
                    itemProgress: { current, total in
                        progress(
                            .init(
                                phase: .snapshot,
                                progress: .snapshot(current: current, total: total)))
                    })
                return (staging, plan, manifest)
            } catch {
                do { try staging.discard() } catch let cleanup {
                    throw LibraryBackupError(
                        "Snapshot failed; cleanup also failed: \(cleanup.localizedDescription)")
                }
                throw error
            }
        }
        let (staging, plan, manifest) = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        await release()
        let archive = Task.detached { () throws -> LibraryBackupManifest in
            var target: LibraryBackupDestination?
            do {
                progress(.init(phase: .archive))
                try Task.checkCancellation()
                try plan.validateDestination(destination, staging: staging.url)
                // STORE plus ZIP headers, central directory and manifest overhead.
                try LibraryBackupIO.available(
                    destination.deletingLastPathComponent(),
                    needed: manifest.totalLogicalSize + Int64(manifest.files.count * 4096)
                        + Int64(LibraryBackupLimits.manifest))
                let output = try LibraryBackupDestination(destination)
                target = output
                try checkpoint(.archive)
                try LibraryBackupArchive.write(
                    snapshot: staging.url, manifest: manifest, fd: output.fd,
                    progress: { _ in },
                    entryProgress: {
                        progress(.init(phase: .archive, progress: .archive(path: $0)))
                    })
                progress(.init(phase: .verification))
                try checkpoint(.verification)
                try output.verify(
                    expected: manifest,
                    entryProgress: {
                        progress(.init(phase: .verification, progress: .verification(path: $0)))
                    })
                // Snapshot cleanup can still fail without replacing an old backup.
                try staging.discard()
                progress(.init(phase: .publication))
                try checkpoint(.publication)
                try output.publish()
                try output.discard()
                return manifest
            } catch {
                var cleanupErrors: [String] = []
                do { try target?.discard() } catch {
                    cleanupErrors.append(error.localizedDescription)
                }
                if FileManager.default.fileExists(atPath: staging.url.path) {
                    do { try staging.discard() } catch {
                        cleanupErrors.append(error.localizedDescription)
                    }
                }
                if !cleanupErrors.isEmpty {
                    throw LibraryBackupError(
                        "\(error.localizedDescription) Cleanup failed: \(cleanupErrors.joined(separator: "; "))"
                    )
                }
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await archive.value
        } onCancel: {
            archive.cancel()
        }
    }
}

private struct LibraryBackupProgress: View {
    @ObservedObject var coordinator: LibraryBackupCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(coordinator.phase).lineLimit(2).font(.callout)
            ProgressView().progressViewStyle(.linear)
            HStack {
                Spacer()
                Button(ProductText.cancel.text, action: coordinator.cancel)
            }
        }.padding(20).frame(width: 470, height: 150)
    }
}

// Derived only from structured manifest data, never from persisted Notes.
enum LibraryBackupCompletionSummary {
    static func title(_ manifest: LibraryBackupManifest, language: String? = nil) -> String {
        (manifest.completeness == "complete" ? BackupText.completed : .incomplete)
            .localized(language: language)
    }
    static func detail(_ manifest: LibraryBackupManifest, language: String? = nil) -> String {
        let summary = string(
            wallpapers: manifest.wallpapers.count,
            playlists: manifest.playlistIDs.count, bytes: manifest.totalLogicalSize,
            language: language)
        guard manifest.completeness != "complete" else { return summary }
        return BackupText.incompleteSummary.format(
            summary,
            BackupText.missingSources.localized(language: language), language: language)
    }
    // Preserve the existing Restore consumer until E.2. Backup UI passes language explicitly.
    static func string(wallpapers: Int, playlists: Int, bytes: Int64) -> String {
        let wallpaperLabel = wallpapers == 1 ? "wallpaper" : "wallpapers"
        let playlistLabel = playlists == 1 ? "playlist" : "playlists"
        return
            "\(wallpapers) \(wallpaperLabel) · \(playlists) \(playlistLabel) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }
    static func string(wallpapers: Int, playlists: Int, bytes: Int64, language: String?)
        -> String
    {
        let language = language.map(BackupText.presentationLanguage)
        let size = bytes.formatted(
            .byteCount(style: .file).locale(language.map(Locale.init(identifier:)) ?? .current))
        return BackupText.summary.format(
            ProductText.wallpaperCount.format(Int64(wallpapers), language: language),
            ProductText.playlistCount.format(Int64(playlists), language: language), size,
            language: language)
    }
}
