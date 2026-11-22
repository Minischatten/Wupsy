import AppKit
import ServiceManagement
import SwiftUI

struct WupsySettings: View {
    @Environment(\.wupsyMetrics) private var metrics
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject var appearance: WupsyAppearance
    @ObservedObject var library: Library
    let widgets: DesktopWidgets
    let playlist: WallpaperPlaylist
    let editors: WSSEditorCoordinator
    let backup: LibraryBackupCoordinator
    let restore: LibraryRestoreUI
    @ObservedObject var updates: UpdateCheckCoordinator
    @ObservedObject var maintenance: MaintenanceCoordinator
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        TabView {
            general.tabItem {
                Label(ProductText.settingsGeneral.text, systemImage: "gearshape")
            }
            WupsyAppearanceSettings(appearance: appearance)
                .tabItem {
                    Label(WupsyAppearanceText.text("title"), systemImage: "paintbrush")
                }
            libraryActions.tabItem {
                Label(ProductText.settingsLibrary.text, systemImage: "archivebox")
            }
            playback.tabItem {
                Label(ProductText.settingsPlayback.text, systemImage: "play.rectangle")
            }
        }
        .frame(width: metrics.points(440))
        .frame(minHeight: metrics.points(240))
    }

    private var playback: some View {
        Form {
            Section {
                Toggle(ProductText.allDisplays.text, isOn: $library.allDisplays)
                    .help(ProductText.allDisplaysHelp.text)
                Toggle(ProductText.pauseBattery.text, isOn: $library.pauseOnBattery)
                    .help(ProductText.pauseBatteryHelp.text)
                Toggle(ProductText.powerSaving.text, isOn: $library.conserve)
                    .help(ProductText.powerSavingHelp.text)
                Text(ProductText.powerSavingHelp.text)
                    .wupsyFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.disabled(!maintenance.allowsNewOperations)
        }.formStyle(.grouped)
    }

    private var libraryActions: some View {
        Form {
            Section {
                Button(ProductText.menuBackup.text) { backup.start(library: library) }
                Button(ProductText.menuRestore.text) {
                    restore.start(
                        library: library, playlist: playlist, widgets: widgets, editors: editors
                    ) {
                        dismissWindow(id: "library")
                    }
                }
            }.disabled(maintenance.state != .normal)
        }.formStyle(.grouped)
    }

    private var general: some View {
        Form {
            Section {
                Toggle(
                    ProductText.launchLogin.text,
                    isOn: Binding(
                        get: { Self.loginEnabled(loginStatus) }, set: setLoginEnabled))
                if loginStatus == .requiresApproval {
                    Button(ProductText.approveLogin.text) {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
                if let loginError {
                    Text(loginError).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.disabled(!maintenance.allowsNewOperations)
            Section {
                Toggle(
                    UpdateText.automatic.text(),
                    isOn: Binding(
                        get: { updates.automaticEnabled }, set: updates.setAutomatic))
            }.disabled(maintenance.state != .normal)
        }
        .formStyle(.grouped)
        .onAppear { refreshLoginStatus() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) {
            _ in refreshLoginStatus()
        }
    }

    static func loginEnabled(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    private func refreshLoginStatus() {
        loginStatus = SMAppService.mainApp.status
    }

    private func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = ProductText.loginError.text
        }
        refreshLoginStatus()
    }
}
