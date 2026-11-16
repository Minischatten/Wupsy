import AppKit
import XCTest

@testable import Wupsy

@MainActor final class AboutPresentationTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testVersionAndBuildComeFromBundleMetadata() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let metadata = [
            "CFBundleIdentifier": "wupsy.about.tests", "CFBundleShortVersionString": "2.7.13",
            "CFBundleVersion": "42",
        ]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: folder.appendingPathComponent("Info.plist"))
        let content = AboutContent(bundle: try XCTUnwrap(Bundle(url: folder)))
        for language in ["de", "en", "zz"] {
            XCTAssertEqual(content.versionText(language: language), "Version 2.7.13 (42)")
        }
        let absent = AboutContent(bundle: Bundle(for: Self.self))
        XCTAssertEqual(absent.versionText(language: "en"), "Version — (—)")
    }

    func testLocalizationAndOfficialContactTargets() {
        for resource in AboutText.allCases {
            for language in ["de", "en", "zz"] {
                let text = resource.text(language: language)
                XCTAssertFalse(text.isEmpty)
                XCTAssertNotEqual(text, "Wupsy")
                XCTAssertFalse(text.hasPrefix("about."))
            }
            XCTAssertEqual(resource.text(language: "zz"), resource.text(language: "en"))
        }
        XCTAssertEqual(AboutText.emailLabel.text(language: "de"), "E-Mail:")
        XCTAssertEqual(AboutText.websiteLabel.text(language: "de"), "Webseite:")
        XCTAssertEqual(AboutText.emailLabel.text(language: "en"), "Email:")
        XCTAssertEqual(AboutText.websiteLabel.text(language: "en"), "Website:")
        XCTAssertEqual(AboutText.title.text(language: "de"), "Über Wupsy")
        XCTAssertEqual(AboutText.title.text(language: "en"), "About Wupsy")
        XCTAssertEqual(
            AboutText.description.text(language: "de"), "Native Hintergrundbilder für macOS")
        XCTAssertEqual(AboutText.sourceLicense.text(language: "de"), "Quellcode: MIT-Lizenz")
        XCTAssertEqual(AboutContent.email.absoluteString, "mailto:kontakt@wirdschonsoftware.com")
        XCTAssertEqual(AboutContent.website.absoluteString, "https://wirdschonsoftware.com")
    }

    func testOriginalBrandingAndLicenseDocumentsRemainReadableAndUnchanged() throws {
        let content = AboutContent(resources: repository)
        // The packaged logo is an unchanged copy of this original, not an app-icon substitute.
        XCTAssertNotNil(AboutContent(resources: repository.appendingPathComponent("Brand")).logo)
        for language in ["de", "en"] {
            for kind in AboutDocument.allCases {
                let url = try XCTUnwrap(content.document(kind, language: language))
                let bytes = try Data(contentsOf: url)
                let text = try String(contentsOf: url, encoding: .utf8)
                let window = AboutPresentation.makeDocumentWindow(
                    text: text, title: url.lastPathComponent)
                defer { window.close() }
                let scroll = try XCTUnwrap(window.contentView as? NSScrollView)
                let view = try XCTUnwrap(scroll.documentView as? NSTextView)
                XCTAssertFalse(view.isEditable)
                XCTAssertTrue(view.isSelectable)
                XCTAssertEqual(view.string, text)
                XCTAssertEqual(try Data(contentsOf: url), bytes)
                XCTAssertTrue(scroll.hasVerticalScroller)
            }
        }
        XCTAssertEqual(AboutDocument.branding.filename(language: "de"), "BRANDING.md")
        XCTAssertEqual(AboutDocument.branding.filename(language: "en"), "BRANDING.en.md")
        XCTAssertEqual(AboutDocument.branding.filename(language: "zz"), "BRANDING.en.md")
    }

    func testRepeatedOpeningAndClosingReusesWindowWithoutEditorOrPolicyChanges() throws {
        _ = NSApplication.shared
        let presentation = AboutPresentation(
            content: AboutContent(resources: repository.appendingPathComponent("Brand")))
        let policy = NSApp.activationPolicy()
        for editorOpen in [false, true] {
            let editor =
                editorOpen
                ? NSWindow(
                    contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
                : nil
            editor?.isReleasedWhenClosed = false
            defer { editor?.close() }
            presentation.show()
            let first = try XCTUnwrap(presentation.window)
            defer { first.close() }
            let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
            presentation.show()
            XCTAssertTrue(presentation.window === first)
            XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), windows)
            XCTAssertTrue(first.isVisible)
            first.close()
            XCTAssertFalse(first.isVisible)
            presentation.show()
            XCTAssertTrue(presentation.window === first)
            XCTAssertTrue(first.isVisible)
            XCTAssertEqual(NSApp.activationPolicy(), policy)
        }
    }

    func testContentFitsInBothLanguagesAndAppearances() throws {
        _ = NSApplication.shared
        let content = AboutContent(resources: repository.appendingPathComponent("Brand"))
        for language in ["de", "en"] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let window = AboutPresentation.makeWindow(content: content, language: language) {
                    _ in
                    XCTFail("Layout must not open a document")
                }
                defer { window.close() }
                window.appearance = NSAppearance(named: appearance)
                let view = try XCTUnwrap(window.contentView)
                view.layoutSubtreeIfNeeded()
                XCTAssertEqual(view.frame.width, 400, accuracy: 1)
                XCTAssertEqual(view.frame.height, view.fittingSize.height, accuracy: 1)
                XCTAssertGreaterThan(view.frame.height, 450)
                XCTAssertLessThan(view.frame.height, 650)
                if let directory = ProcessInfo.processInfo.environment["WUPSY_ABOUT_PREVIEWS"] {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                    window.displayIfNeeded()
                    let bitmap = try XCTUnwrap(
                        view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(
                        to: URL(fileURLWithPath: directory).appendingPathComponent(
                            "about-\(language)-\(appearance.rawValue).png"))
                }
            }
        }
    }
}
