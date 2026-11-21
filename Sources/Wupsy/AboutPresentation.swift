import AppKit
import Combine
import SwiftUI

enum AboutText: String, CaseIterable {
    case title, version, description, sourceLicense, branding, logo, documentFailed
    case emailLabel, websiteLabel
    func text(language: String? = nil) -> String {
        Localization.string(key: "about." + rawValue, language: language)
    }
    func format(_ values: CVarArg..., language: String? = nil) -> String {
        String(format: text(language: language), arguments: values)
    }
}

struct AboutContent {
    static let email = URL(string: "mailto:kontakt@wirdschonsoftware.com")!
    static let website = URL(string: "https://wirdschonsoftware.com")!
    let version: String
    let build: String
    let resources: URL?
    init(bundle: Bundle = .main, resources: URL? = nil) {
        version =
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        self.resources = resources ?? bundle.resourceURL
    }
    func versionText(language: String? = nil) -> String {
        AboutText.version.format(version, build, language: language)
    }
    func document(_ kind: AboutDocument, language: String? = nil) -> URL? {
        resources?.appendingPathComponent(kind.filename(language: language))
    }
    var logo: NSImage? {
        resources.flatMap { NSImage(contentsOf: $0.appendingPathComponent("WSS_Logo.png")) }
    }
}

enum AboutDocument: CaseIterable {
    case license, branding
    func filename(language: String? = nil) -> String {
        switch self {
        case .license: return "LICENSE"
        case .branding:
            let language = language ?? (Localization.bundle.preferredLocalizations.first ?? "en")
            return language == "de" ? "BRANDING.md" : "BRANDING.en.md"
        }
    }
}

// Both entry points share this owner. Closing keeps the same window reusable;
// showing it never opens an editor or changes activation policy/runtime state.
@MainActor final class AboutPresentation {
    static let shared = AboutPresentation()
    private(set) var window: NSWindow?
    private var documents: [URL: NSWindow] = [:]
    private let content: AboutContent
    init(content: AboutContent = AboutContent()) { self.content = content }

    func show() {
        if window == nil {
            window = Self.makeWindow(content: content) { [weak self] in self?.showDocument($0) }
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func makeWindow(
        content: AboutContent, language: String? = nil,
        document: @escaping (AboutDocument) -> Void
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = AboutText.title.text(language: language)
        window.isReleasedWhenClosed = false
        let view = WupsyPanelHostingView(
            appearance: .shared,
            root: AboutView(content: content, language: language, document: document))
        window.contentView = view
        window.setContentSize(view.fittingSize)
        window.center()
        return window
    }

    func showDocument(_ kind: AboutDocument) {
        do {
            guard let url = content.document(kind) else { throw CocoaError(.fileNoSuchFile) }
            if let existing = documents[url] {
                existing.makeKeyAndOrderFront(nil)
                return
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            let document = Self.makeDocumentWindow(text: text, title: url.lastPathComponent)
            documents[url] = document
            document.makeKeyAndOrderFront(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = AboutText.documentFailed.text()
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    static func makeDocumentWindow(text: String, title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        let scroll = AboutDocumentScrollView(appearance: .shared)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 680, height: 520))
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textColor = .textColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 20, height: 20)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.string = text
        scroll.documentView = view
        scroll.applyScale(WupsyAppearance.shared.scale)
        window.contentView = scroll
        window.center()
        return window
    }
}

@MainActor private final class AboutDocumentScrollView: NSScrollView {
    private var observation: AnyCancellable?

    init(appearance: WupsyAppearance) {
        super.init(frame: .zero)
        observation = appearance.$scale.sink { [weak self] scale in self?.applyScale(scale) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func applyScale(_ scale: WupsyInterfaceScale) {
        guard let text = documentView as? NSTextView else { return }
        let metrics = WupsyMetrics(scale: scale)
        text.font = .systemFont(ofSize: metrics.points(NSFont.systemFontSize))
        let inset = metrics.spacing(20)
        text.textContainerInset = NSSize(width: inset, height: inset)
    }
}

private struct AboutView: View {
    let content: AboutContent
    let language: String?
    let document: (AboutDocument) -> Void
    var body: some View {
        VStack(spacing: 14) {
            if let logo = content.logo {
                Image(nsImage: logo).resizable().scaledToFit()
                    .frame(width: 280, height: 280)
                    .accessibilityLabel(AboutText.logo.text(language: language))
            }
            VStack(spacing: 5) {
                Text(verbatim: ProductIdentity.name).wupsyFont(size: 17, weight: .semibold)
                Text(content.versionText(language: language)).foregroundStyle(.secondary)
            }
            Text(AboutText.description.text(language: language))
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text(AboutText.emailLabel.text(language: language))
                        .gridColumnAlignment(.trailing)
                    Link("kontakt@wirdschonsoftware.com", destination: AboutContent.email)
                }
                GridRow {
                    Text(AboutText.websiteLabel.text(language: language))
                    Link("wirdschonsoftware.com", destination: AboutContent.website)
                }
            }
            VStack(spacing: 6) {
                Text(verbatim: "© 2026 WirdSchonSoftware").foregroundStyle(.secondary)
                Button(AboutText.sourceLicense.text(language: language)) { document(.license) }
                Button(AboutText.branding.text(language: language)) { document(.branding) }
            }.buttonStyle(.link)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .wupsyPadding(.all, 28).wupsyControlFrame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
