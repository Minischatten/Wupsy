import AppKit
import SwiftUI
import XCTest

@testable import Wupsy

@MainActor final class WSSRipplePaintToolbarTests: XCTestCase {
    var helper: WSSMaskManagementTests!
    var doc: WSSEditorDocument { helper.doc }
    var session: WSSMaskCanvasSession { doc.maskCanvas }
    override func setUp() async throws {
        _ = NSApplication.shared
        helper = WSSMaskManagementTests()
        try await helper.setUp()
        try await helper.unmask()
        session.setDiameter(100)
    }
    override func tearDown() async throws {
        await session.waitForFinish()
        try await helper.tearDown()
        helper = nil
    }
    func hosted(document value: WSSEditorDocument? = nil, width: CGFloat = 1000) -> NSHostingView<
        AnyView
    > {
        let value = value ?? doc
        let host = NSHostingView(
            rootView: AnyView(
                VStack(alignment: .leading, spacing: 8) { WSSMaskCanvasTools(document: value) }
                    .environment(\.accessibilityEnabled, true)))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: 150), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: width, height: 150)
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        addTeardownBlock { @MainActor in window.close() }
        return host
    }
    struct AXNode: Equatable {
        let role: String
        let label: String
        let identifier: String
        let value: String
        let numericValue: Double?
        let actions: [String]
    }
    func nodes(_ root: NSObject) -> [AXNode] {
        var visited = Set<ObjectIdentifier>()
        func get(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        func walk(_ object: NSObject) -> [AXNode] {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            let rawValue = get(object, "accessibilityValue")
            let own = AXNode(
                role: get(object, "accessibilityRole") as? String ?? "",
                label: get(object, "accessibilityLabel") as? String ?? "",
                identifier: get(object, "accessibilityIdentifier") as? String ?? "",
                value: String(describing: rawValue ?? ""),
                numericValue: (rawValue as? NSNumber)?.doubleValue,
                actions: get(object, "accessibilityActionNames") as? [String] ?? [])
            let children =
                ((get(object, "accessibilityChildren") as? [Any]) ?? [])
                + ((get(object, "accessibilityChildrenInNavigationOrder") as? [Any]) ?? [])
            return [own] + children.compactMap { $0 as? NSObject }.flatMap(walk)
        }
        return walk(root)
    }
    // Diagnostic only: title/help/description do not establish an accessible slider name.
    private func sliderAXDetails(_ root: NSObject) -> String {
        func value(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        func attribute(_ object: NSObject, _ name: String) -> String {
            guard object.responds(to: NSSelectorFromString(name)) else {
                return "<unavailable: selector unsupported>"
            }
            guard let result = value(object, name) else { return "<unavailable: nil>" }
            return String(reflecting: result)
        }
        func descriptionAttribute(_ object: NSObject) -> String {
            // AXDescription is the legacy public attribute corresponding to
            // accessibilityLabel (NSAccessibilityProtocols.h). Query separately
            // only when the element advertises support for that public API.
            let selector = NSSelectorFromString("accessibilityAttributeValue:")
            let name = NSAccessibility.Attribute.description.rawValue
            guard object.responds(to: selector),
                let names = value(object, "accessibilityAttributeNames") as? [String],
                names.contains(name)
            else { return "<unavailable: legacy AXDescription not advertised>" }
            guard let result = object.perform(selector, with: name)?.takeUnretainedValue() else {
                return "<unavailable: nil>"
            }
            return String(reflecting: result)
        }
        func summary(_ object: NSObject) -> String {
            "class=\(String(reflecting: type(of: object))) "
                + "role=\(attribute(object, "accessibilityRole")) "
                + "subrole=\(attribute(object, "accessibilitySubrole")) "
                + "label=\(attribute(object, "accessibilityLabel")) "
                + "title=\(attribute(object, "accessibilityTitle")) "
                + "AXDescription=\(descriptionAttribute(object)) "
                + "help=\(attribute(object, "accessibilityHelp")) "
                + "value=\(attribute(object, "accessibilityValue")) "
                + "actions=\(attribute(object, "accessibilityActionNames"))"
        }
        func relation(_ object: NSObject, _ name: String) -> String {
            guard object.responds(to: NSSelectorFromString(name)) else {
                return "<unavailable: selector unsupported>"
            }
            guard let result = value(object, name) else { return "<unavailable: nil>" }
            if let children = result as? [NSObject] {
                return children.map(summary).joined(separator: "\n    ")
            }
            guard let element = result as? NSObject else { return "<unavailable: not an element>" }
            return summary(element)
        }
        var visited = Set<ObjectIdentifier>()
        func walk(_ object: NSObject) -> [String] {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            let details =
                summary(object)
                + "\n  parent: \(relation(object, "accessibilityParent"))"
                + "\n  titleUIElement: \(relation(object, "accessibilityTitleUIElement"))"
                + "\n  children: \(relation(object, "accessibilityChildren"))"
                + "\n  navigationChildren: \(relation(object, "accessibilityChildrenInNavigationOrder"))"
            let children =
                ((value(object, "accessibilityChildren") as? [NSObject]) ?? [])
                + ((value(object, "accessibilityChildrenInNavigationOrder") as? [NSObject]) ?? [])
            return [details] + children.flatMap(walk)
        }
        return "SLIDER_AX_DETAILS\n" + walk(root).joined(separator: "\n")
    }
    func signature(
        _ host: NSHostingView<AnyView>, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String] {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        host.display()
        let all = nodes(host)
        func diagnostic(_ requirement: String) -> String {
            "Toolbar AX requirement: \(requirement)\n"
                + "host=\(host.frame) window=\(String(describing: host.window?.frame)) "
                + "active=\(NSApp.isActive) key=\(host.window?.isKeyWindow == true)\n"
                + all.enumerated().map { index, node in
                    "[\(index)] role=\(node.role) label=\(String(reflecting: node.label)) "
                        + "identifier=\(String(reflecting: node.identifier)) "
                        + "value=\(String(reflecting: node.value)) actions=\(node.actions)"
                }.joined(separator: "\n")
        }
        let brush = try XCTUnwrap(
            all.first { $0.identifier == "wss.mask.brush-title" },
            diagnostic("brush title identifier wss.mask.brush-title must exist"),
            file: file, line: line)
        XCTAssertEqual(
            brush.role, NSAccessibility.Role.staticText.rawValue,
            diagnostic("brush title must have AXStaticText role"), file: file, line: line)
        XCTAssertFalse(
            brush.actions.contains(NSAccessibility.Action.press.rawValue),
            diagnostic("brush title must not expose AXPress"), file: file, line: line)
        XCTAssertFalse(
            all.contains {
                ($0.label == EditorText.brush.text || $0.value == EditorText.brush.text)
                    && ($0.role == NSAccessibility.Role.button.rawValue
                        || $0.role == NSAccessibility.Role.checkBox.rawValue)
            }, diagnostic("brush title must not be a button or checkbox"), file: file, line: line)
        // Internal structure only: this reader cannot prove slider identity or VoiceOver names.
        // The regular app passed Accessibility Inspector and VoiceOver checks on macOS 26.
        // Automated external AX regression coverage is not implemented.
        // nodes() deduplicates by ObjectIdentifier, so these are distinct internal objects.
        let sliders = all.filter { $0.role == NSAccessibility.Role.slider.rawValue }
        XCTAssertEqual(
            sliders.count, 2, diagnostic("exactly two distinct internal AXSlider objects must exist")
                + "\n" + sliderAXDetails(host),
            file: file, line: line)
        for slider in sliders {
            XCTAssertEqual(
                slider.role, NSAccessibility.Role.slider.rawValue,
                diagnostic("internal slider must have AXSlider role"), file: file, line: line)
            XCTAssertTrue(
                slider.numericValue?.isFinite == true,
                diagnostic("internal slider must expose a numeric, finite AX value: \(slider.value)"),
                file: file, line: line)
            for action in [NSAccessibility.Action.increment, .decrement] {
                XCTAssertTrue(
                    slider.actions.contains(action.rawValue),
                    diagnostic("internal slider must support \(action.rawValue)"),
                    file: file, line: line)
            }
        }
        XCTAssertTrue(
            all.contains {
                $0.value == EditorText.optionErase.text || $0.label == EditorText.optionErase.text
            },
            diagnostic(
                "Option erase hint \(EditorText.optionErase.text) must exist as label or value"),
            file: file, line: line)
        XCTAssertFalse(
            all.contains {
                $0.value == EditorText.maskBlackHint.text
                    || $0.label == EditorText.maskBlackHint.text
            }, diagnostic("obsolete black mask hint must not exist"), file: file, line: line)
        let roles: [NSAccessibility.Role] = [
            .staticText, .slider, .textField, .menuButton, .popUpButton,
        ]
        return all.filter { roles.map(\.rawValue).contains($0.role) }
            .map {
                "\($0.role)|\($0.label)|\($0.identifier)|\($0.role == NSAccessibility.Role.staticText.rawValue ? $0.value : "")"
            }
    }
    func testMasklessSelectionHasFullAccessibleToolbarWithoutMutationOrUndo() throws {
        let model = doc.state.workingModel
        let revision = doc.state.workingRevision
        let assets = doc.state.sessionAssets.count
        let host = hosted()
        _ = try signature(host)
        XCTAssertTrue(session.brushEnabled)
        XCTAssertNil(doc.selectedMaskTarget)
        XCTAssertNil(session.loaded)
        XCTAssertEqual(session.diameter, 100)
        XCTAssertEqual(session.opacity, 1)
        XCTAssertEqual(session.maximumDiameter, 128)
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertEqual(doc.state.workingRevision, revision)
        XCTAssertEqual(doc.state.sessionAssets.count, assets)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
    func testFirstStrokeUsesEarlySettingsAndDoesNotChangeToolbarStructure() async throws {
        let host = hosted()
        let before = try signature(host)
        session.setDiameter(12)
        session.setOpacity(0.45)
        XCTAssertEqual(session.diameter, 12)
        XCTAssertFalse(doc.isDirty)
        let model = doc.state.workingModel
        XCTAssertTrue(session.begin(SIMD2(16, 32), erase: false))
        session.append(SIMD2(32, 32))
        session.finish(SIMD2(48, 32))
        await session.waitForFinish()
        await session.waitForLoad()
        XCTAssertNil(session.error)
        XCTAssertTrue(try XCTUnwrap(session.pixels).contains { $0 > 0 })
        XCTAssertEqual(session.diameter, 12)
        XCTAssertEqual(session.opacity, 0.45)
        XCTAssertEqual(try signature(host), before)
        let painted = doc.state.workingModel
        doc.undoManager.undo()
        await session.waitForLoad()
        XCTAssertTrue(try XCTUnwrap(session.pixels).allSatisfy { $0 == 0 })
        doc.undoManager.undo()
        XCTAssertEqual(doc.state.workingModel, model)
        XCTAssertEqual(try signature(host), before)
        doc.undoManager.redo()
        doc.undoManager.redo()
        await session.waitForLoad()
        XCTAssertEqual(doc.state.workingModel, painted)
        XCTAssertEqual(try signature(host), before)
    }
    func testExistingMaskAndEffectSwitchesUseCorrectFullToolbar() async throws {
        let host = hosted()
        let ripple = try XCTUnwrap(doc.selection)
        let before = try signature(host)
        let layer = doc.identity.layers[1]
        doc.select(.effect(layer.id, layer.effects[0]))
        await session.waitForLoad()
        XCTAssertEqual(session.loaded?.resolved.target.slot, .clouds)
        _ = try signature(host)
        doc.select(ripple)
        XCTAssertEqual(try signature(host), before)
        doc.select(.layer(doc.identity.layers[0].id))
        host.rootView = AnyView(
            VStack(alignment: .leading, spacing: 8) { WSSMaskCanvasTools(document: doc) }
                .environment(\.accessibilityEnabled, true))
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(nodes(host).contains { $0.identifier == "wss.mask.brush-title" })
        try doc.addEffect(.flow)
        XCTAssertTrue(doc.directionCanvas.brushEnabled)
        doc.select(ripple)
        XCTAssertFalse(doc.directionCanvas.brushEnabled)
        XCTAssertEqual(try signature(host), before)
        try await doc.manageMask(.create)
        await session.waitForLoad()
        XCTAssertEqual(session.loaded?.resolved.target.slot, .ripple)
        XCTAssertEqual(try signature(host), before)
    }
    func testNarrowToolbarHasSameControlsAndNonInteractiveTitle() throws {
        let wide = hosted()
        let narrow = hosted(width: 360)
        XCTAssertEqual(try signature(narrow), try signature(wide))
        XCTAssertFalse(doc.isDirty)
        XCTAssertNil(doc.selectedMaskTarget)
    }
    func testPredictedDimensionsEqualExistingBlackMaskRuleWithoutEarlyAllocation() async throws {
        for size: [Float] in [[64, 64], [3840, 1920], [8192, 8192], [0.2, 0.1]] {
            let dimensions = try WSSMaskPreparation.blackMaskDimensions(size: size)
            let bitmap = try await WSSMaskPreparation().blackMask(size: size)
            XCTAssertEqual(dimensions.width, bitmap.width)
            XCTAssertEqual(dimensions.height, bitmap.height)
        }
        XCTAssertNil(doc.selectedMaskTarget)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.undoManager.canUndo)
    }
}
