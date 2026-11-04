import AppKit
import ServiceManagement
import SwiftUI

@MainActor final class WupsyDelegate: NSObject, NSApplicationDelegate {
    static weak var editorCoordinator: WSSEditorCoordinator?
    static weak var restoreCoordinator: LibraryRestoreCoordinator?
    private var deciding = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if MaintenanceCoordinator.shared.state == .restartRequired { return .terminateNow }
        guard !deciding else { return .terminateLater }
        guard let coordinator = Self.editorCoordinator else { return .terminateNow }
        deciding = true
        Task {
            await Self.restoreCoordinator?.prepareToQuit()
            if MaintenanceCoordinator.shared.state == .restartRequired {
                deciding = false
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            let approved = await coordinator.approveTermination()
            if approved { await coordinator.finishTermination() }
            deciding = false
            sender.reply(toApplicationShouldTerminate: approved)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct WupsyApp: App {
    @NSApplicationDelegateAdaptor(WupsyDelegate.self) private var delegate
    @ObservedObject private var maintenance = MaintenanceCoordinator.shared
    @StateObject private var backup = LibraryBackupCoordinator()
    @StateObject private var restore = LibraryRestoreUI()
    @StateObject private var widgets: DesktopWidgets
    @StateObject private var library: Library
    @StateObject private var playlist: WallpaperPlaylist
    @StateObject private var editors: WSSEditorCoordinator
    init() {
        let benchmark = CommandLine.arguments.contains("--benchmark")
        let library: Library
        let playlistURL: URL
        if benchmark {
            let suite = UserDefaults(suiteName: ProductIdentity.benchmarkDomain)!
            library = Library(
                storage: ProductPaths.current.benchmarkLibrary, defaults: suite,
                restoreOnLaunch: false)
            playlistURL = ProductPaths.current.benchmarkPlaylists
        } else {
            library = Library(restoreOnLaunch: false)
            playlistURL = ProductPaths.current.playlists
        }
        _widgets = StateObject(
            wrappedValue: DesktopWidgets(
                defaults: benchmark
                    ? UserDefaults(suiteName: ProductIdentity.benchmarkDomain)! : .standard))
        _library = StateObject(wrappedValue: library)
        _editors = StateObject(
            wrappedValue: WSSEditorCoordinator(
                lookup: { try library.wallpaperForEditor(id: $0) },
                save: { try await library.saveWSSManifest($0) },
                saveAs: { try await library.saveWSSAs($0) },
                publishDraft: { try await library.publishWSSDraft($0) },
                onTermination: { library.stop(preserveSelection: true) },
                presentation: .live()))
        _playlist = StateObject(
            wrappedValue: WallpaperPlaylist(
                library: library, storage: playlistURL,
                defaults: benchmark
                    ? UserDefaults(suiteName: ProductIdentity.benchmarkDomain)! : .standard,
                restoreOnLaunch: !benchmark || !CommandLine.arguments.contains("--report")))
    }
    private var editorHasFocus: Bool {
        editors.editorHasFocus || editors.activeDocument != nil
    }

    var body: some Scene {
        Window("Wupsy", id: "library") {
            LibraryView().environmentObject(editors).environmentObject(library).environmentObject(
                widgets
            ).environmentObject(
                playlist
            )
            .frame(minWidth: 1040, minHeight: 740).preferredColorScheme(.dark).tint(
                WupsyTheme.accent
            )
            .modifier(RestoreLibraryWindowGate(coordinator: restore.coordinator))
            .task { await Benchmark.runIfRequested(library) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 830)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(ProductText.newWallpaper.text) { Task { await editors.newWallpaper() } }
                    .keyboardShortcut("n").disabled(!editors.canCreateWallpaper)
                Button(ProductText.importWallpaper.text) {
                    guard !editorHasFocus else { return }
                    library.importFiles()
                }.disabled(editorHasFocus || !maintenance.allowsNewOperations).keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button(ProductText.save.text) { editors.activeCommands?.perform(.save) }
                    .keyboardShortcut("s")
                    .disabled(editors.activeCommands?.canPerform(.save) != true)
                Button(EditorText.saveAs.text) { editors.activeCommands?.perform(.saveAs) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(editors.activeCommands?.canPerform(.saveAs) != true)
                Button(EditorText.revert.text) { editors.activeCommands?.perform(.revert) }
                    .disabled(editors.activeCommands?.canPerform(.revert) != true)
            }
            CommandGroup(after: .toolbar) {
                Button(EditorText.zoomIn.text) { editors.activeCommands?.perform(.zoom(.zoomIn)) }
                    .keyboardShortcut("+")
                    .disabled(editors.activeCommands?.canPerform(.zoom(.zoomIn)) != true)
                Button(EditorText.zoomOut.text) { editors.activeCommands?.perform(.zoom(.zoomOut)) }
                    .keyboardShortcut("-")
                    .disabled(editors.activeCommands?.canPerform(.zoom(.zoomOut)) != true)
                Button(EditorText.fit.text) { editors.activeCommands?.perform(.zoom(.fit)) }
                    .keyboardShortcut("0")
                    .disabled(editors.activeCommands?.canPerform(.zoom(.fit)) != true)
                Button(EditorText.actualSize.text) {
                    editors.activeCommands?.perform(.zoom(.actualSize))
                }
                .keyboardShortcut("1")
                .disabled(editors.activeCommands?.canPerform(.zoom(.actualSize)) != true)
            }
            CommandMenu(ProductText.wallpaperMenu.text) {
                Button(ProductText.applySelected.text) {
                    if !editorHasFocus,
                        let item = library.items.first(where: { $0.id == library.selected })
                    {
                        library.apply(item)
                    }
                }.keyboardShortcut(.return, modifiers: .command).disabled(
                    editorHasFocus || library.selected == nil || !maintenance.allowsNewOperations)
                Button(library.manuallyPaused ? ProductText.resume.text : ProductText.pause.text) {
                    if !editorHasFocus { library.manuallyPaused.toggle() }
                }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(
                    editorHasFocus || library.active == nil || !maintenance.allowsNewOperations)
                Button(ProductText.stop.text) { if !editorHasFocus { library.stop() } }.disabled(
                    editorHasFocus || !maintenance.allowsNewOperations)
            }
        }
        MenuBarExtra {
            WupsyMenu().environmentObject(library).environmentObject(widgets).environmentObject(
                playlist
            ).environmentObject(editors).environmentObject(backup).environmentObject(restore)
        } label: {
            Image(nsImage: MenuBarIcon.image).renderingMode(.template)
                .accessibilityLabel("Wupsy")
        }

    }
}

struct WupsyMenu: View {
    @ObservedObject private var maintenance = MaintenanceCoordinator.shared
    @EnvironmentObject private var backup: LibraryBackupCoordinator
    @EnvironmentObject private var restore: LibraryRestoreUI
    @EnvironmentObject private var editors: WSSEditorCoordinator
    @EnvironmentObject private var playlist: WallpaperPlaylist
    @Environment(\.dismissWindow) private var dismissWindow
    @EnvironmentObject private var widgets: DesktopWidgets
    @EnvironmentObject private var library: Library
    @Environment(\.openWindow) private var openWindow
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    var body: some View {
        Text(library.status)
        Button(Localization.string(.libraryOpen)) {
            guard maintenance.allowsNewOperations else { return }
            openWindow(id: "library")
            NSApp.activate(ignoringOtherApps: true)
        }.disabled(!maintenance.allowsNewOperations)
        Divider()
        Button(ProductText.menuBackup.text) { backup.start(library: library) }
            .disabled(maintenance.state != .normal)
        Button(ProductText.menuRestore.text) {
            restore.start(library: library, playlist: playlist, widgets: widgets, editors: editors)
            {
                dismissWindow(id: "library")
            }
        }.disabled(maintenance.state != .normal)
        Divider()
        Group {
            Button(widgets.editing ? ProductText.widgetsFinish.text : ProductText.widgetsEdit.text)
            {
                widgets.setEditing(!widgets.editing)
            }
            Toggle(ProductText.pauseWallpapers.text, isOn: $library.manuallyPaused).disabled(
                library.active == nil)
            Picker(ProductText.quality.text, selection: $library.profile) {
                ForEach(QualityProfile.allCases) { Text($0.title).tag($0) }
            }
            Toggle(ProductText.pauseBatteryMenu.text, isOn: $library.pauseOnBattery).help(
                ProductText.pauseBatteryHelp.text)
            Button(ProductText.stopWallpapers.text) { library.stop() }.disabled(
                library.active == nil)
            Divider()
            Toggle(
                ProductText.launchLogin.text,
                isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: { enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginError = nil
                        } catch { loginError = ProductText.loginError.text }
                        loginStatus = SMAppService.mainApp.status
                    }))
            if loginStatus == .requiresApproval {
                Button(ProductText.approveLogin.text) {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
            if let loginError { Text(loginError) }
        }.disabled(!maintenance.allowsNewOperations)
        Divider()
        Button(ProductText.quit.text) {
            NSApp.terminate(nil)
        }.keyboardShortcut("q")
        Text(
            maintenance.state == .restartRequired
                ? Localization.string(.libraryRestartHint)
                : ProductText.quitHint.text
        )
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }
}
