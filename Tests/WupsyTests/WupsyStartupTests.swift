import XCTest

@testable import Wupsy

final class WupsyStartupTests: XCTestCase {
    func testAbsentRootAndNoJournalConstructRuntimeWithoutRecovery() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("startup.tests." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WupsyLaunchContext(
            supportRoot: root, preferenceDomain: "startup.tests." + UUID().uuidString)
        for exists in [false, true] {
            if exists {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            }
            var constructed = false
            try WupsyStartup.run(
                context: context, recover: { _ in XCTFail("No recovery expected") },
                constructRuntime: { constructed = true })
            XCTAssertTrue(constructed)
        }
    }
    func testWrongRootRestoreDirectoryAndJournalTypesFailClosed() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("startup.tests." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WupsyLaunchContext(
            supportRoot: root, preferenceDomain: "startup.tests." + UUID().uuidString)
        try Data().write(to: root)
        XCTAssertThrowsError(try WupsyStartup.needsRecovery(context))
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(
            at: root, withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try WupsyStartup.needsRecovery(context))
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".restore"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".restore/journal.json"),
            withDestinationURL: root.appendingPathComponent("absent"))
        XCTAssertThrowsError(try WupsyStartup.needsRecovery(context))
        var constructed = false
        XCTAssertThrowsError(
            try WupsyStartup.run(
                context: context, probe: { _ in throw CocoaError(.fileReadNoPermission) }
            ) { constructed = true })
        XCTAssertFalse(constructed)
    }
    func testInjectedFailureNeverConstructsRuntimeAndBenchmarkIsIsolated() throws {
        let context = try WupsyLaunchContext.current(arguments: ["Wupsy", "--benchmark"])
        XCTAssertEqual(context.preferenceDomain, "com.wirdschonsoftware.wupsy.benchmark")
        XCTAssertTrue(
            context.supportRoot.path.hasPrefix(
                FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path))
        var constructed = false
        XCTAssertThrowsError(
            try WupsyStartup.run(
                context: context, probe: { _ in true },
                recover: { _ in throw MaintenanceError.drainFailed }
            ) { constructed = true })
        XCTAssertFalse(constructed)
        XCTAssertThrowsError(try WupsyLaunchContext.current(arguments: ["Wupsy"]))
    }
    func testRealPrecommitRecoveryRestoresABeforeRuntime() async throws {
        let fixture = LibraryRestoreTransactionTests()
        try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        try fixture.a()
        let before = try fixture.bytes()
        let prepared = try await fixture.b()
        try fixture.crash(prepared, point: .afterAllNew)
        var constructed = false
        try WupsyStartup.run(
            context: .init(supportRoot: fixture.root, preferenceDomain: fixture.domain)
        ) {
            XCTAssertEqual(try? fixture.bytes(), before)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.root.appendingPathComponent(".restore/journal.json").path))
            constructed = true
        }
        XCTAssertTrue(constructed)
    }
    func testRealCommittedRecoveryFinishesBBeforeRuntime() async throws {
        let fixture = LibraryRestoreTransactionTests()
        try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        try fixture.a()
        let prepared = try await fixture.b()
        try fixture.crash(prepared, point: .afterCommit)
        var constructed = false
        try WupsyStartup.run(
            context: .init(supportRoot: fixture.root, preferenceDomain: fixture.domain)
        ) {
            do { try fixture.assertB(prepared.plan) } catch { XCTFail(error.localizedDescription) }
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.root.appendingPathComponent(".restore/journal.json").path))
            constructed = true
        }
        XCTAssertTrue(constructed)
    }
    func testMalformedPersistedJournalNeverConstructsRuntime() throws {
        let fixture = LibraryRestoreTransactionTests()
        try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        try fixture.file(".restore/journal.json", Data("{}".utf8))
        var constructed = false
        XCTAssertThrowsError(
            try WupsyStartup.run(
                context: .init(supportRoot: fixture.root, preferenceDomain: fixture.domain)
            ) { constructed = true })
        XCTAssertFalse(constructed)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(".restore/journal.json").path))
    }
}
