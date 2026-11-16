import AppKit
import Darwin

// The same signed executable, in a minimal mode before any runtime or preferences exist.
// No shell, bundle-ID lookup, installed-app substitution, or fixed disk path is involved.
enum LibraryRestoreRestart {
    static let argument = "--restore-relaunch-helper"

    static func bundleURL(_ bundle: Bundle) throws -> URL {
        let url = bundle.bundleURL
        guard url.pathExtension == "app", let executable = bundle.executableURL,
            FileManager.default.isExecutableFile(atPath: executable.path)
        else { throw LibraryBackupError("The current application bundle is unavailable.") }
        return url
    }

    @MainActor static func initiate(
        outcome: LibraryRestoreCoordinator.Outcome?,
        launch: () throws -> Void = launchHelper,
        terminate: @MainActor () -> Void = { NSApp.terminate(nil) }
    ) throws {
        guard outcome == .committed else { throw MaintenanceError.invalidTransition }
        try launch()
        terminate()
    }

    static func launchHelper() throws {
        _ = try bundleURL(.main)
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = [argument, String(getpid())]
        let ready = Pipe()
        let permission = Pipe()
        process.standardOutput = ready
        process.standardInput = permission
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? ready.fileHandleForReading.close()
            try? permission.fileHandleForWriting.close()
        }
        do {
            try awaitReadiness(fd: ready.fileHandleForReading.fileDescriptor)
            guard process.isRunning else {
                throw LibraryBackupError("The restart helper exited before handoff.")
            }
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
        do { try authorize(permission.fileHandleForWriting) } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    static func authorize(_ handle: FileHandle) throws {
        // A helper dying after readiness must produce an error, never SIGPIPE the app.
        guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw LibraryBackupError("The restart handoff could not be protected.")
        }
        try handle.write(contentsOf: Data([71]))
    }

    // Bounded readiness handshake: a spawned process alone is not success.
    static func awaitReadiness(
        fd: Int32, timeoutMilliseconds: Int32 = 5000, expectedByte: UInt8 = 82
    ) throws {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var byte: UInt8 = 0
        guard poll(&descriptor, 1, timeoutMilliseconds) > 0,
            read(fd, &byte, 1) == 1, byte == expectedByte
        else { throw LibraryBackupError("The restart helper did not become ready.") }
    }

    @MainActor static func runHelper(arguments: [String]) {
        guard arguments.count == 3, let parent = Int32(arguments[2]), parent > 1,
            parent == getppid(), let url = try? bundleURL(.main)
        else { exit(1) }
        // Register before acknowledging readiness, avoiding an exit/registration race.
        let timeout = DispatchSource.makeTimerSource(queue: .main)
        timeout.schedule(deadline: .now() + 60)
        timeout.setEventHandler {
            showFailure(LibraryBackupError("The previous Wupsy process did not exit in time."))
            exit(1)
        }
        let source = DispatchSource.makeProcessSource(
            identifier: parent, eventMask: .exit, queue: .main)
        source.setEventHandler {
            source.cancel()
            timeout.cancel()
            Task { @MainActor in
                do {
                    let configuration = configuration()
                    _ = try await NSWorkspace.shared.openApplication(
                        at: url, configuration: configuration)
                    exit(0)
                } catch {
                    showFailure(error)
                    exit(1)
                }
            }
        }
        source.setRegistrationHandler {
            // Acknowledge only after the kernel process observer is registered.
            guard write(STDOUT_FILENO, [UInt8(82)], 1) == 1 else { exit(1) }
            do { try awaitReadiness(fd: STDIN_FILENO, expectedByte: 71) } catch { exit(1) }
        }
        source.resume()
        // If orderly termination is refused or hangs, never leave a permanent helper.
        timeout.resume()
        withExtendedLifetime((source, timeout)) { RunLoop.main.run() }
    }

    static func configuration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.allowsRunningApplicationSubstitution = false
        configuration.createsNewApplicationInstance = true
        return configuration
    }

    @MainActor static func showFailure(_ error: Error) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = RestoreText.restartFailed.text
        alert.informativeText =
            RestoreText.restartFailedDetail.text + "\n\n" + error.localizedDescription
        alert.runModal()
    }
}

// Preserve AppKit's compact alert and left-aligned text; move only its existing icon.
final class RestoreCompletionAlert: NSAlert {
    override func layout() {
        super.layout()
        guard let content = window.contentView else { return }
        func centerIcon(in view: NSView) {
            for child in view.subviews {
                if let image = child as? NSImageView, image.image == icon {
                    let center = view.convert(NSPoint(x: content.bounds.midX, y: 0), from: content)
                    image.setFrameOrigin(
                        NSPoint(x: center.x - image.frame.width / 2, y: image.frame.minY))
                } else {
                    centerIcon(in: child)
                }
            }
        }
        centerIcon(in: content)
    }
}
