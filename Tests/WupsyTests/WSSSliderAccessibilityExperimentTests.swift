import AppKit
import ApplicationServices
import SwiftUI
import XCTest

@testable import Wupsy

@MainActor private final class SliderExperimentValues: ObservableObject {
    @Published var diameter = 100.0
    @Published var opacity = 1.0
}

@MainActor private struct SliderExperimentView: View {
    @ObservedObject var values: SliderExperimentValues
    @ViewBuilder private func slider(
        _ binding: Binding<Double>, range: ClosedRange<Double>, label: String,
        identifier: String, hidden: Bool
    ) -> some View {
        if hidden {
            Slider(value: binding, in: range) { Text(label) }
                .labelsHidden().accessibilityIdentifier(identifier)
        } else {
            Slider(value: binding, in: range) { Text(label) }
                .accessibilityIdentifier(identifier)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            ForEach([true, false], id: \.self) { hidden in
                slider(
                    Binding(
                        get: { log2(values.diameter) }, set: { values.diameter = pow(2, $0) }),
                    range: 0...log2(128), label: EditorText.maskDiameter.text,
                    identifier: "ax-experiment.diameter.\(hidden ? "hidden" : "visible")",
                    hidden: hidden
                ).frame(height: 80)
            }
            ForEach([true, false], id: \.self) { hidden in
                slider(
                    $values.opacity, range: 0...1, label: EditorText.maskOpacityAX.text,
                    identifier: "ax-experiment.opacity.\(hidden ? "hidden" : "visible")",
                    hidden: hidden
                ).frame(height: 80)
            }
        }.padding(16)
    }
}

@MainActor final class WSSSliderAccessibilityExperimentTests: XCTestCase {
    private static let clientEnvironment = "WUPSY_AX_EXPERIMENT_TARGET_PID"
    private static let windowTitle = "Wupsy AX slider comparison"
    private static let method =
        "WupsyTests.WSSSliderAccessibilityExperimentTests/testFourVariantsAndExternalClient"
    private static let getters = [
        "accessibilityRole", "accessibilitySubrole", "accessibilityIdentifier",
        "accessibilityLabel", "accessibilityTitle", "accessibilityHelp", "accessibilityValue",
        "accessibilityActionNames", "accessibilityAttributeNames",
    ]

    private func emit(_ kind: String, _ fields: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        // Avoid buffered print output being interleaved with XCTest's own log.
        FileHandle.standardError.write(Data("\(kind) ".utf8) + data + Data([10]))
    }
    private func get(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
    private func identity(_ object: NSObject) -> String {
        "\(ObjectIdentifier(object)) role=\(get(object, "accessibilityRole") ?? "UNAVAILABLE") "
            + "id=\(get(object, "accessibilityIdentifier") ?? "UNAVAILABLE")"
    }
    private func describe(_ value: Any?) -> String {
        guard let value else { return "UNAVAILABLE: nil" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        if let strings = value as? [String] { return String(reflecting: strings) }
        if let objects = value as? [NSObject] {
            return objects.map(identity).joined(separator: "; ")
        }
        if let object = value as? NSObject { return identity(object) }
        return String(reflecting: value)
    }
    private func dumpInternal(_ root: NSObject) {
        var visited = Set<ObjectIdentifier>()
        func walk(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            var record: [String: Any] = [
                "object": identity(object), "class": String(reflecting: type(of: object)),
                "availablePublicGetters": Self.getters.filter {
                    object.responds(to: NSSelectorFromString($0))
                },
            ]
            for name in Self.getters {
                record[name] =
                    object.responds(to: NSSelectorFromString(name))
                    ? describe(get(object, name)) : "UNAVAILABLE: selector unsupported"
            }
            if let element = object as? NSAccessibilityProtocol {
                record["isAccessibilityElement"] = element.isAccessibilityElement()
            } else if object.responds(to: NSSelectorFromString("isAccessibilityElement")) {
                // Some SwiftUI objects implement the public getter without
                // declaring conformance to the complete AppKit protocol.
                let selector = NSSelectorFromString("isAccessibilityElement")
                typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
                let getter = unsafeBitCast(object.method(for: selector), to: Getter.self)
                record["isAccessibilityElement"] = getter(object, selector)
            } else {
                record["isAccessibilityElement"] =
                    "UNAVAILABLE: no NSAccessibilityProtocol conformance"
            }
            for name in [
                "accessibilityParent", "accessibilityChildren",
                "accessibilityChildrenInNavigationOrder", "accessibilityTitleUIElement",
            ] {
                record[name] =
                    object.responds(to: NSSelectorFromString(name))
                    ? describe(get(object, name)) : "UNAVAILABLE: selector unsupported"
            }
            let children =
                ((get(object, "accessibilityChildren") as? [NSObject]) ?? [])
                + ((get(object, "accessibilityChildrenInNavigationOrder") as? [NSObject]) ?? [])
            record["unignoredAncestor"] = describe(NSAccessibility.unignoredAncestor(of: object))
            record["unignoredDescendant"] = describe(
                NSAccessibility.unignoredDescendant(of: object))
            record["unignoredChildren"] = describe(
                NSAccessibility.unignoredChildren(from: children))
            emit("AX_INTERNAL", record)
            for child in children { walk(child) }
        }
        walk(root)
    }

    private func errorName(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .apiDisabled: return "apiDisabled"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .noValue: return "noValue"
        default: return "AXError(\(error.rawValue))"
        }
    }
    private func externalValue(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error, value)
    }
    private func externalSummary(_ element: AXUIElement) -> String {
        ["AXRole", "AXIdentifier", "AXTitle", "AXDescription"].map { name in
            let (error, value) = externalValue(element, name)
            return
                "\(name)=\(error == .success ? String(describing: value ?? "nil" as CFString) : "UNAVAILABLE: " + errorName(error))"
        }.joined(separator: " ")
    }
    private func externalDescription(_ value: CFTypeRef?) -> String {
        guard let value else { return "UNAVAILABLE: nil" }
        if CFGetTypeID(value) == AXUIElementGetTypeID() {
            return externalSummary(value as! AXUIElement)
        }
        if let elements = value as? [AXUIElement] {
            return elements.map(externalSummary).joined(separator: "; ")
        }
        return String(describing: value)
    }
    private func runExternalClient(_ pid: pid_t) {
        emit("AX_EXTERNAL_CLIENT", ["targetPID": pid, "trusted": AXIsProcessTrusted()])
        guard AXIsProcessTrusted() else {
            emit(
                "AX_EXTERNAL",
                ["status": "UNAVAILABLE", "reason": "client not trusted; no prompt requested"])
            return
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        let (error, value) = externalValue(app, "AXWindows")
        guard error == .success, let windows = value as? [AXUIElement] else {
            emit(
                "AX_EXTERNAL",
                ["status": "UNAVAILABLE", "reason": "AXWindows: " + errorName(error)])
            return
        }
        guard
            let window = windows.first(where: {
                let (_, title) = externalValue($0, "AXTitle")
                return (title as? String) == Self.windowTitle
            })
        else {
            emit(
                "AX_EXTERNAL", ["status": "UNAVAILABLE", "reason": "diagnostic window not exposed"])
            return
        }
        var visited: [AXUIElement] = []
        var identifiers = Set<String>()
        func walk(_ element: AXUIElement) {
            guard visited.count < 128, !visited.contains(where: { CFEqual($0, element) }) else {
                return
            }
            visited.append(element)
            var names: CFArray?
            let namesError = AXUIElementCopyAttributeNames(element, &names)
            var actions: CFArray?
            let actionsError = AXUIElementCopyActionNames(element, &actions)
            var record: [String: Any] = [
                "attributesStatus": errorName(namesError), "attributes": (names as? [String]) ?? [],
                "actionsStatus": errorName(actionsError), "actions": (actions as? [String]) ?? [],
            ]
            for name in [
                "AXRole", "AXSubrole", "AXIdentifier", "AXTitle", "AXDescription", "AXHelp",
                "AXValue", "AXParent", "AXChildren", "AXTitleUIElement",
            ] {
                let (status, value) = externalValue(element, name)
                record[name] =
                    status == .success
                    ? externalDescription(value) : "UNAVAILABLE: " + errorName(status)
                if name == "AXIdentifier", let identifier = value as? String {
                    identifiers.insert(identifier)
                }
            }
            emit("AX_EXTERNAL_ELEMENT", record)
            let (_, children) = externalValue(element, "AXChildren")
            for child in (children as? [AXUIElement]) ?? [] { walk(child) }
        }
        walk(window)
        emit(
            "AX_EXTERNAL_RESULT",
            [
                "status": "queried; not an accessibility pass verdict",
                "identifiers": identifiers.sorted(),
                "visited": visited.count, "limitReached": visited.count == 128,
            ])
    }

    private func launchClient() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", Self.method, Bundle(for: Self.self).bundlePath]
        process.environment = ProcessInfo.processInfo.environment.merging([
            Self.clientEnvironment: String(ProcessInfo.processInfo.processIdentifier)
        ]) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled, process.isRunning {
                emit(
                    "AX_EXTERNAL",
                    ["status": "UNAVAILABLE", "reason": "client exceeded 30 second bound"])
                process.terminate()
            }
        }
        // Reading off the MainActor keeps the target's GUI responsive to AX IPC.
        let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        await Task.detached { process.waitUntilExit() }.value
        watchdog.cancel()
        let text = String(decoding: data, as: UTF8.self)
        FileHandle.standardError.write(
            Data("AX_CLIENT_OUTPUT_BEGIN\n\(text)AX_CLIENT_OUTPUT_END\n".utf8))
        XCTAssertTrue(
            text.contains("AX_EXTERNAL_CLIENT"), "Client must enter its diagnostic branch")
        if process.terminationStatus != 0 {
            emit(
                "AX_EXTERNAL",
                ["status": "UNAVAILABLE", "reason": "client exit \(process.terminationStatus)"])
        }
    }

    func testFourVariantsAndExternalClient() async throws {
        if let target = ProcessInfo.processInfo.environment[Self.clientEnvironment],
            let pid = pid_t(target)
        {
            runExternalClient(pid)
            return
        }
        _ = NSApplication.shared
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let values = SliderExperimentValues()
        let window = NSWindow(
            contentRect: NSRect(
                x: visible.minX, y: visible.minY, width: min(700, visible.width),
                height: min(440, visible.height - 30)),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = Self.windowTitle
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        let host = NSHostingView(
            rootView: SliderExperimentView(values: values).environment(\.accessibilityEnabled, true)
        )
        host.frame = NSRect(x: 0, y: 60, width: root.bounds.width, height: root.bounds.height - 60)
        let control = NSButton(title: "Wupsy AX control", target: nil, action: nil)
        control.setAccessibilityLabel("Wupsy AX control")
        control.setAccessibilityIdentifier("ax-experiment.control")
        let controlCell = try XCTUnwrap(control.cell as? NSButtonCell)
        controlCell.setAccessibilityIdentifier("ax-experiment.control")
        control.frame = NSRect(x: 16, y: 12, width: 240, height: 32)
        root.addSubview(host)
        root.addSubview(control)
        window.orderFront(nil)
        root.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        emit(
            "AX_EXPERIMENT",
            [
                "diameterLabel": EditorText.maskDiameter.text,
                "opacityLabel": EditorText.maskOpacityAX.text,
                "window": NSStringFromRect(window.frame), "host": NSStringFromRect(host.frame),
                "variants": [
                    "diameter.hidden", "diameter.visible", "opacity.hidden", "opacity.visible",
                ],
                "reader": "in-process public AppKit getters; separate AXUIElement client follows",
            ])
        dumpInternal(host)
        dumpInternal(control)
        XCTAssertEqual(control.accessibilityLabel(), "Wupsy AX control")
        XCTAssertEqual(controlCell.accessibilityTitle(), "Wupsy AX control")
        try await launchClient()
        XCTAssertEqual(values.diameter, 100)
        XCTAssertEqual(values.opacity, 1)
    }
}
