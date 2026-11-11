import AppKit
import SwiftUI

enum UpdateText: String, CaseIterable {
    case automatic, checkNow, available, availableDetail, skippedDetail, current, currentDetail
    case failed, unavailable, invalidResponse, invalidVersion, network, cancelled, server,
        rateLimited
    case download, skip, close

    func text(language: String? = nil) -> String {
        Localization.string(key: "updates." + rawValue, language: language)
    }
    func format(_ values: CVarArg..., language: String? = nil) -> String {
        String(
            format: text(language: language),
            locale: language.map(Locale.init(identifier:)) ?? .current,
            arguments: values)
    }
}

struct UpdateCheckMessage {
    let title: String
    let detail: String
    let offersUpdate: Bool
    init(_ result: UpdateCheckResult, language: String? = nil) {
        offersUpdate = {
            if case .available = result { return true }
            return false
        }()
        switch result {
        case .available(let installed, let release, let skipped):
            title = UpdateText.available.text(language: language)
            detail =
                UpdateText.availableDetail.format(
                    installed.description, release.version.description, language: language)
                + (skipped ? "\n\n" + UpdateText.skippedDetail.text(language: language) : "")
        case .current(let version):
            title = UpdateText.current.text(language: language)
            detail = UpdateText.currentDetail.format(version.description, language: language)
        case .noStableRelease:
            title = UpdateText.failed.text(language: language)
            detail = UpdateText.unavailable.text(language: language)
        case .failed(let failure):
            title = UpdateText.failed.text(language: language)
            switch failure {
            case .unavailable: detail = UpdateText.unavailable.text(language: language)
            case .invalidResponse: detail = UpdateText.invalidResponse.text(language: language)
            case .invalidVersion: detail = UpdateText.invalidVersion.text(language: language)
            case .network: detail = UpdateText.network.text(language: language)
            case .cancelled: detail = UpdateText.cancelled.text(language: language)
            case .server(let status):
                detail = UpdateText.server.format(Int64(status), language: language)
            case .rateLimited:
                detail = UpdateText.rateLimited.text(language: language)
            }
        }
    }
}

// An owned nonmodal panel keeps playback and editor interaction running. No app
// activation-policy changes, nested modal loops, downloads or background URL opens.
@MainActor final class UpdateCheckPresentation: NSObject, UpdatePresenting, NSWindowDelegate {
    private var panel: NSPanel?
    private var completion: ((UpdateCheckAction) -> Void)?
    var canPresent: Bool {
        panel == nil && NSApp.modalWindow == nil
            && !NSApp.windows.contains { $0.attachedSheet != nil || $0.sheetParent != nil }
            && RunLoop.current.currentMode != .eventTracking
    }
    func present(
        _ result: UpdateCheckResult, manual: Bool, completion: @escaping (UpdateCheckAction) -> Void
    ) {
        guard canPresent else { return }
        self.completion = completion
        let message = UpdateCheckMessage(result)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 260),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Wupsy"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: UpdateCheckDialog(message: message) { [weak self] in self?.finish($0) })
        self.panel = panel
        panel.center()
        if manual { NSApp.activate(ignoringOtherApps: true) }
        panel.makeKeyAndOrderFront(nil)
    }
    private func finish(_ action: UpdateCheckAction) {
        let callback = completion
        completion = nil
        let previous = panel
        panel = nil
        previous?.delegate = nil
        previous?.close()
        callback?(action)
    }
    func windowWillClose(_ notification: Notification) { finish(.close) }
    func dismiss() {
        completion = nil
        let previous = panel
        panel = nil
        previous?.delegate = nil
        previous?.close()
    }
}

private struct UpdateCheckDialog: View {
    let message: UpdateCheckMessage
    let action: (UpdateCheckAction) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(message.title).font(.headline)
            Text(message.detail).fixedSize(horizontal: false, vertical: true).textSelection(
                .enabled)
            Spacer(minLength: 4)
            HStack {
                Button(UpdateText.close.text()) { action(.close) }.keyboardShortcut(.cancelAction)
                Spacer()
                if message.offersUpdate {
                    Button(UpdateText.skip.text()) { action(.skip) }
                    Button(UpdateText.download.text()) { action(.open) }.keyboardShortcut(
                        .defaultAction)
                }
            }
        }.padding(22).frame(width: 540, height: 260)
    }
}
