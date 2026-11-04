import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class LibraryRestoreUI: ObservableObject {
    let coordinator = LibraryRestoreCoordinator()
    private var panel: NSPanel?
    private var selection: NSOpenPanel?
    private var confirmation: NSAlert?
    init() { WupsyDelegate.restoreCoordinator = coordinator }

    func start(
        library: Library, playlist: WallpaperPlaylist, widgets: DesktopWidgets,
        editors: WSSEditorCoordinator, closeLibrary: @escaping () -> Void
    ) {
        do {
            let context = try WupsyLaunchContext.current()
            // Benchmark runtime uses different metadata paths; it must never publish a restore.
            guard !CommandLine.arguments.contains("--benchmark") else {
                throw MaintenanceError.invalidTransition
            }
            guard !coordinator.running, selection == nil else { throw MaintenanceError.jobActive }
            let open = Self.openPanel()
            selection = open
            defer { selection = nil }
            NSApp.activate(ignoringOtherApps: true)
            guard open.runModal() == .OK, let url = open.url else { return }
            try LibraryRestorePreflight.validate(url)

            try coordinator.start(
                .init(
                    select: { url },
                    prepare: { url, progress in
                        var preparer = LibraryRestorePreparer(supportRoot: context.supportRoot)
                        preparer.progress = progress
                        return try await preparer.prepare(url)
                    },
                    confirm: { [self] plan in
                        let alert = Self.confirmationAlert(plan)
                        confirmation = alert
                        defer { confirmation = nil }
                        return alert.runModal() == .alertFirstButtonReturn
                    },
                    cancelPendingEditors: { try await editors.cancelPendingForMaintenance() },
                    resolveEditors: { boundary in
                        await editors.resolveAndCloseAllForMaintenance(beforeClosing: boundary)
                    },
                    stopPlaylist: { await playlist.shutdownAndDrainForMaintenance() },
                    stopLibrary: { await library.stopAndDrainForMaintenance() },
                    closeLibrary: closeLibrary,
                    stopWidgets: { widgets.shutdownForMaintenance() },
                    snapshot: {
                        while true {
                            if let lease = LibraryMutationBarrier.shared.trySnapshot() {
                                return lease
                            }
                            // Publication is terminal: cancellation is no longer a user operation.
                            try? await Task<Never, Never>.sleep(for: .milliseconds(25))
                        }
                    },
                    publish: { try await LibraryRestorePublication.publish($0, context: context) },
                    recover: { try await LibraryRestorePublication.recover(context: context) },
                    progress: { [self] in showProgress() },
                    closeProgress: { [self] in closeProgress() },
                    cancelDialogs: { [self] in
                        selection?.cancel(nil)
                        if confirmation != nil { NSApp.abortModal() }
                    },
                    failure: { cleanupFailed in
                        let alert = Self.preparationFailureAlert(cleanupFailed: cleanupFailed)
                        alert.runModal()
                    },
                    completion: { outcome in
                        let alert = Self.completionAlert(outcome)
                        alert.runModal()
                        NSApp.terminate(nil)
                    }))
        } catch {
            let alert = Self.unavailableAlert(error)
            alert.runModal()
        }
    }
    static func openPanel(language: String? = nil) -> NSOpenPanel {
        let open = NSOpenPanel()
        open.title = RestoreText.openTitle.localized(language: language)
        open.allowedContentTypes = [
            UTType(filenameExtension: "wssbackup", conformingTo: .zip) ?? .zip
        ]
        open.allowsOtherFileTypes = false
        open.canChooseFiles = true
        open.canChooseDirectories = false
        open.allowsMultipleSelection = false
        open.treatsFilePackagesAsDirectories = true
        return open
    }
    static func confirmationAlert(_ plan: LibraryRestorePlan, language: String? = nil) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = RestoreText.confirmTitle.localized(language: language)
        alert.informativeText = LibraryRestoreSummary.text(plan, language: language)
        let restore = alert.addButton(withTitle: RestoreText.replace.localized(language: language))
        restore.hasDestructiveAction = true
        // No Return-key shortcut for the destructive action.
        restore.keyEquivalent = ""
        alert.addButton(withTitle: ProductText.cancel.localized(language: language)).keyEquivalent =
            "\u{1b}"
        return alert
    }
    static func preparationFailureAlert(cleanupFailed: Bool, language: String? = nil) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = RestoreText.preparationFailed.localized(language: language)
        alert.informativeText = (cleanupFailed ? RestoreText.cleanupDetail : .preparationDetail)
            .localized(language: language)
        return alert
    }
    static func completionAlert(
        _ outcome: LibraryRestoreCoordinator.Outcome, language: String? = nil
    ) -> NSAlert {
        let alert = NSAlert()
        let presentation = RestoreTerminalPresentation(outcome, language: language)
        alert.messageText = presentation.title
        alert.informativeText = presentation.detail
        switch outcome {
        case .committed: break
        case .restoredA: alert.alertStyle = .warning
        case .unresolved: alert.alertStyle = .critical
        }
        alert.addButton(withTitle: ProductText.quit.localized(language: language))
        return alert
    }
    static func unavailableAlert(_ error: Error, language: String? = nil) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = RestoreText.unavailable.localized(language: language)
        alert.informativeText = RestoreErrorPresentation.detail(error, language: language)
        return alert
    }
    private func showProgress() {
        closeProgress()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 150),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = RestoreText.windowTitle.text
        panel.contentView = NSHostingView(
            rootView: LibraryRestoreProgress(coordinator: coordinator))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }
    private func closeProgress() {
        panel?.close()
        panel = nil
    }
}

private struct LibraryRestoreProgress: View {
    @ObservedObject var coordinator: LibraryRestoreCoordinator
    var body: some View {
        LibraryMaintenanceProgress(
            phase: coordinator.phase, canCancel: coordinator.canCancel, cancel: coordinator.cancel)
    }
}

struct LibraryMaintenanceProgress: View {
    let phase: String
    let canCancel: Bool
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(phase).lineLimit(2).font(.callout)
            ProgressView().progressViewStyle(.linear)
            HStack {
                Spacer()
                Button(ProductText.cancel.text, action: cancel).disabled(!canCancel)
            }
        }.padding(20).frame(width: 470, height: 150)
    }
}

enum LibraryRestoreSummary {
    static func date(_ value: Date, language: String? = nil, timeZone: TimeZone = .current)
        -> String
    {
        let formatter = DateFormatter()
        formatter.locale =
            language.map { Locale(identifier: RestoreText.presentationLanguage($0)) } ?? .current
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: value)
    }
    static func text(_ plan: LibraryRestorePlan, language: String? = nil) -> String {
        var summary = RestoreText.datedSummary.format(
            date(plan.manifest.createdAt, language: language),
            LibraryBackupCompletionSummary.string(
                wallpapers: plan.library.count,
                playlists: plan.playlists.definitions.count, bytes: plan.manifest.totalLogicalSize,
                language: language), language: language)
        let recovery = plan.manifest.recovery.count
        if recovery > 0 {
            summary = RestoreText.additionalLine.format(
                summary,
                RestoreText.recoveryCount.format(Int64(recovery), language: language),
                language: language)
        }
        if plan.incomplete {
            summary = RestoreText.additionalLine.format(
                summary,
                RestoreText.incomplete.localized(language: language), language: language)
        }
        return RestoreText.confirmation.format(summary, language: language)
    }

}

// Also dismiss windows opened through SwiftUI's Window menu after terminal shutdown.
struct RestoreLibraryWindowGate: ViewModifier {
    @ObservedObject var coordinator: LibraryRestoreCoordinator
    @Environment(\.dismissWindow) private var dismissWindow
    func body(content: Content) -> some View {
        Group {
            if !coordinator.blocksLibrary { content }
        }.onReceive(coordinator.$blocksLibrary) { blocked in
            if blocked { dismissWindow(id: "library") }
        }.onAppear {
            if coordinator.blocksLibrary { dismissWindow(id: "library") }
        }
    }
}
