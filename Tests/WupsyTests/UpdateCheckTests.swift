import AppKit
import Combine
import XCTest

@testable import Wupsy

private actor UpdateFakeClient: ReleaseChecking {
    var calls = 0
    var held = false
    var result: Result<GitHubRelease?, Error> = .success(nil)
    var continuation: CheckedContinuation<GitHubRelease?, Error>?
    func configure(_ result: Result<GitHubRelease?, Error>, hold: Bool = false) {
        self.result = result
        held = hold
    }
    func latest() async throws -> GitHubRelease? {
        calls += 1
        if held { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return try result.get()
    }
    func finish() {
        continuation?.resume(with: result)
        continuation = nil
    }
}

@MainActor private final class UpdateTestClock: UpdateScheduling {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var alarms: [UUID: (Date, @MainActor () -> Void)] = [:]
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void)
        -> AnyCancellable
    {
        let id = UUID()
        alarms[id] = (now.addingTimeInterval(seconds), action)
        return AnyCancellable { [weak self] in self?.alarms[id] = nil }
    }
    func advance(_ seconds: TimeInterval) {
        now.addTimeInterval(seconds)
        let ready = alarms.filter { $0.value.0 <= now }
        for (id, _) in ready {
            let action = alarms.removeValue(forKey: id)?.1
            action?()
        }
    }
}

@MainActor private final class UpdateTestPresenter: UpdatePresenting {
    var canPresent = true
    var messages: [(UpdateCheckResult, Bool)] = []
    var completion: ((UpdateCheckAction) -> Void)?
    var dismissals = 0
    func present(
        _ result: UpdateCheckResult, manual: Bool, completion: @escaping (UpdateCheckAction) -> Void
    ) {
        messages.append((result, manual))
        self.completion = completion
    }
    func dismiss() {
        dismissals += 1
        completion = nil
    }
}

@MainActor final class UpdateCheckTests: XCTestCase {
    private var domain: String!
    private var defaults: UserDefaults!
    private var clock: UpdateTestClock!
    private var presenter: UpdateTestPresenter!
    private var client: UpdateFakeClient!
    private var coordinator: UpdateCheckCoordinator!
    private var allowed = true
    private var opened: [URL] = []

    override func setUpWithError() throws {
        domain = "wupsy-update-tests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        clock = UpdateTestClock()
        presenter = UpdateTestPresenter()
        client = UpdateFakeClient()
        coordinator = makeCoordinator()
    }
    private func makeCoordinator() -> UpdateCheckCoordinator {
        UpdateCheckCoordinator(
            defaults: defaults, client: client,
            version: { try ReleaseVersion("0.5.0") }, now: { self.clock.now }, scheduler: clock,
            presenter: presenter, canOperate: { self.allowed }, openURL: { self.opened.append($0) })
    }
    override func tearDownWithError() throws {
        coordinator.shutdown()
        defaults.removePersistentDomain(forName: domain)
        coordinator = nil
    }
    private func expectCalls(_ expected: Int) async {
        let actual = await client.calls
        XCTAssertEqual(actual, expected)
    }
    private func settle() async {
        for _ in 0..<2_000 {
            if !coordinator.checking { return }
            await Task.yield()
        }
        XCTFail("Update request did not settle")
    }
    private func release(_ version: String = "v0.5.1") throws -> GitHubRelease {
        GitHubRelease(
            version: try ReleaseVersion(version),
            url: try GitHubRelease.validatedURL(
                "https://github.com/Minischatten/Wupsy/releases/tag/" + version, tag: version))
    }
    func testNumericVersionsAndInvalidInput() throws {
        XCTAssertEqual(try ReleaseVersion("v00.05.001").description, "0.5.1")
        XCTAssertEqual(try ReleaseVersion("v0.5.0"), try ReleaseVersion("0.5.0"))
        for newer in ["0.5.1", "0.6.0", "1.0.0", "0.10.0"] {
            XCTAssertGreaterThan(try ReleaseVersion(newer), try ReleaseVersion("0.5.0"))
        }
        XCTAssertGreaterThan(try ReleaseVersion("0.10.0"), try ReleaseVersion("0.9.0"))
        for bad in [
            "", "0.5", "0.5.0.1", "0..0", "-1.0.0", "+1.0.0", "0.5.0-beta", "0.5.0+1", " 0.5.0",
            "0.５.0", "18446744073709551616.0.0",
        ] {
            XCTAssertThrowsError(try ReleaseVersion(bad))
        }
        XCTAssertThrowsError(try ReleaseVersion.installed(in: Bundle(for: Self.self)))
    }
    func testInstalledVersionUsesShortVersionAndIgnoresBuild() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let info: [String: String] = [
            "CFBundleIdentifier": "wupsy.update.version.test",
            "CFBundleShortVersionString": "0.5.0", "CFBundleVersion": "999999",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: folder.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: folder))
        XCTAssertEqual(try ReleaseVersion.installed(in: bundle).description, "0.5.0")
    }
    func testManualFailuresAndCancelledChecksAreReportedWithoutOpeningBrowser() async {
        coordinator.start()
        for failure in [
            UpdateCheckFailure.unavailable, .invalidVersion, .invalidResponse, .network,
            .server(500), .cancelled,
        ] {
            await client.configure(.failure(failure))
            coordinator.checkNow()
            await settle()
            XCTAssertEqual(presenter.messages.last?.0, .failed(failure))
            XCTAssertTrue(presenter.messages.last?.1 == true)
        }
        XCTAssertTrue(opened.isEmpty)
    }
    func testQueuedAutomaticResultRechecksSkipBeforePresentation() async throws {
        await client.configure(.success(try release()))
        presenter.canPresent = false
        coordinator.start()
        coordinator.setAutomatic(true)
        await settle()
        defaults.set("0.5.1", forKey: UpdateCheckCoordinator.Key.skipped)
        presenter.canPresent = true
        coordinator.flushPresentation()
        XCTAssertTrue(presenter.messages.isEmpty)
    }
    func testDefaultOffManualStillWorksAndRecordsAttemptBeforeRequest() async throws {
        await client.configure(.success(try release()), hold: true)
        coordinator.start()
        XCTAssertFalse(coordinator.automaticEnabled)
        await expectCalls(0)
        coordinator.checkNow()
        XCTAssertEqual(
            defaults.object(forKey: UpdateCheckCoordinator.Key.attempt) as? Date, clock.now)
        for _ in 0..<100 {
            if await client.calls == 1 { break }
            await Task.yield()
        }
        await client.finish()
        await settle()
        XCTAssertEqual(presenter.messages.count, 1)
        XCTAssertTrue(presenter.messages[0].1)
        XCTAssertTrue(opened.isEmpty)
        presenter.completion?(.open)
        XCTAssertEqual(opened, [try release().url])
    }
    func testDailyThrottleFailuresPersistAcrossRestartAndToggles() async {
        await client.configure(.failure(UpdateCheckFailure.network))
        coordinator.start()
        coordinator.setAutomatic(true)
        await settle()
        XCTAssertTrue(presenter.messages.isEmpty)
        await expectCalls(1)
        coordinator.setAutomatic(false)
        coordinator.setAutomatic(true)
        coordinator.shutdown()
        coordinator = makeCoordinator()
        coordinator.start()
        await settle()
        XCTAssertTrue(coordinator.automaticEnabled)
        await expectCalls(1)
        clock.advance(86_399)
        coordinator.resumeIfDue()
        XCTAssertFalse(coordinator.checking)
        clock.advance(1)
        await settle()
        await expectCalls(2)
        XCTAssertEqual(clock.alarms.count, 1)
    }
    func testManualBypassesDailyThrottleAndResetsAutomaticDeadline() async {
        coordinator.start()
        coordinator.setAutomatic(true)
        await settle()
        clock.advance(60)
        coordinator.checkNow()
        await settle()
        await expectCalls(2)
        XCTAssertEqual(
            defaults.object(forKey: UpdateCheckCoordinator.Key.attempt) as? Date, clock.now)
        clock.advance(86_399)
        XCTAssertFalse(coordinator.checking)
        clock.advance(1)
        await settle()
        await expectCalls(3)
    }
    func testBackwardsClockRebasesOnceWithoutRequests() async {
        defaults.set(true, forKey: UpdateCheckCoordinator.Key.automatic)
        defaults.set(
            clock.now.addingTimeInterval(10_000_000), forKey: UpdateCheckCoordinator.Key.attempt)
        coordinator.shutdown()
        coordinator = makeCoordinator()
        coordinator.start()
        let rebased = defaults.object(forKey: UpdateCheckCoordinator.Key.attempt) as? Date
        XCTAssertEqual(rebased, clock.now)
        for _ in 0..<5 { coordinator.resumeIfDue() }
        await expectCalls(0)
        XCTAssertEqual(clock.alarms.count, 1)
        clock.advance(86_400)
        await settle()
        await expectCalls(1)
    }
    func testSimultaneousRequestsJoinAndManualPromotesAutomaticResult() async throws {
        await client.configure(.success(try release()), hold: true)
        coordinator.start()
        coordinator.setAutomatic(true)
        coordinator.checkNow()
        coordinator.checkNow()
        coordinator.resumeIfDue()
        for _ in 0..<100 {
            if await client.calls == 1 { break }
            await Task.yield()
        }
        await client.finish()
        await settle()
        await expectCalls(1)
        XCTAssertEqual(presenter.messages.count, 1)
        XCTAssertTrue(presenter.messages[0].1)
    }
    func testSkipIsExactAndManualExplainsIt() async throws {
        await client.configure(.success(try release()))
        coordinator.start()
        coordinator.setAutomatic(true)
        await settle()
        presenter.completion?(.skip)
        XCTAssertEqual(defaults.string(forKey: UpdateCheckCoordinator.Key.skipped), "0.5.1")
        clock.advance(86_400)
        await settle()
        XCTAssertEqual(presenter.messages.count, 1)
        coordinator.checkNow()
        await settle()
        guard case .available(_, _, true) = presenter.messages.last?.0 else {
            return XCTFail("Skipped version must still be shown manually")
        }
        let message = UpdateCheckMessage(presenter.messages.last!.0, language: "de")
        XCTAssertTrue(message.detail.contains("übersprungen"))
        await client.configure(.success(try release("v0.6.0")))
        clock.advance(86_400)
        await settle()
        guard case .available(_, let latest, false) = presenter.messages.last?.0 else {
            return XCTFail("A later version must be offered")
        }
        XCTAssertEqual(latest.version.description, "0.6.0")
    }
    func testAutomaticCurrentAndIgnoredReleaseAreSilentManualReportsBoth() async throws {
        await client.configure(.success(try release("0.5.0")))
        coordinator.start()
        coordinator.setAutomatic(true)
        await settle()
        XCTAssertTrue(presenter.messages.isEmpty)
        coordinator.checkNow()
        await settle()
        XCTAssertEqual(presenter.messages.last?.0, .current(try ReleaseVersion("0.5.0")))
        await client.configure(.success(nil))
        coordinator.checkNow()
        await settle()
        XCTAssertEqual(presenter.messages.last?.0, .noStableRelease)
    }
    func testRateLimitAlsoBlocksManualRequestsAndSurvivesRestart() async {
        let until = clock.now.addingTimeInterval(90_000)
        await client.configure(.failure(UpdateCheckFailure.rateLimited(until: until)))
        coordinator.start()
        coordinator.setAutomatic(true)
        await settle()
        coordinator.checkNow()
        XCTAssertEqual(presenter.messages.last?.0, .failed(.rateLimited(until: until)))
        await expectCalls(1)
        coordinator.shutdown()
        coordinator = makeCoordinator()
        coordinator.start()
        coordinator.checkNow()
        await expectCalls(1)
        clock.advance(86_400)
        XCTAssertFalse(coordinator.checking)
        clock.advance(3_600)
        await settle()
        await expectCalls(2)
    }
    func testDisabledAndShutdownSuppressLateAutomaticResults() async throws {
        await client.configure(.success(try release()), hold: true)
        coordinator.start()
        coordinator.setAutomatic(true)
        for _ in 0..<100 {
            if await client.calls == 1 { break }
            await Task.yield()
        }
        coordinator.setAutomatic(false)
        await client.finish()
        await settle()
        XCTAssertTrue(presenter.messages.isEmpty)
        coordinator.setAutomatic(true)
        clock.advance(86_400)
        for _ in 0..<100 {
            if await client.calls == 2 { break }
            await Task.yield()
        }
        coordinator.shutdown()
        await client.finish()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(presenter.messages.isEmpty)
    }
    func testPresentationDefersForSheetsMaintenanceAndTermination() async throws {
        await client.configure(.success(try release()))
        presenter.canPresent = false
        coordinator.start()
        coordinator.checkNow()
        await settle()
        XCTAssertTrue(presenter.messages.isEmpty)
        presenter.canPresent = true
        allowed = false
        coordinator.resumeIfDue()
        XCTAssertTrue(presenter.messages.isEmpty)
        allowed = true
        coordinator.suspendForTermination()
        coordinator.flushPresentation()
        XCTAssertTrue(presenter.messages.isEmpty)
        coordinator.cancelTermination()
        coordinator.checkNow()
        await settle()
        XCTAssertEqual(presenter.messages.count, 1)
    }
    func testLocalizationAndSafeReleaseURLs() throws {
        for resource in UpdateText.allCases {
            for language in ["en", "de", "zz"] {
                let text = resource.text(language: language)
                XCTAssertFalse(text.isEmpty)
                XCTAssertNotEqual(text, "Wupsy")
                XCTAssertFalse(text.hasPrefix("updates."))
            }
            XCTAssertEqual(resource.text(language: "zz"), resource.text(language: "en"))
        }
        XCTAssertEqual(UpdateText.automatic.text(language: "de"), "Automatisch nach Updates suchen")
        XCTAssertEqual(UpdateText.checkNow.text(language: "de"), "Jetzt nach Updates suchen …")
        let result = UpdateCheckResult.available(
            installed: try ReleaseVersion("0.5.0"), release: try release(), skipped: false)
        let message = UpdateCheckMessage(result, language: "de")
        XCTAssertTrue(message.detail.contains("0.5.0"))
        XCTAssertTrue(message.detail.contains("0.5.1"))
        for bad in [
            "http://github.com/Minischatten/Wupsy/releases/tag/v0.5.1",
            "https://github.com.evil.test/Minischatten/Wupsy/releases/tag/v0.5.1",
            "https://user@github.com/Minischatten/Wupsy/releases/tag/v0.5.1",
            "https://github.com/Other/Wupsy/releases/tag/v0.5.1",
            "https://github.com/Minischatten/Wupsy/releases/tag/v0.5.1?next=evil",
            "https://github.com/Minischatten/Wupsy/releases/tag/v0.6.0",
        ] {
            XCTAssertThrowsError(try GitHubRelease.validatedURL(bad, tag: "v0.5.1"))
        }
        XCTAssertFalse(
            LibraryRestorePreferences.keys.contains(UpdateCheckCoordinator.Key.automatic))
        XCTAssertFalse(LibraryRestorePreferences.keys.contains(UpdateCheckCoordinator.Key.attempt))
        XCTAssertFalse(LibraryRestorePreferences.keys.contains(UpdateCheckCoordinator.Key.skipped))
    }
}

private final class UpdateStubProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var status = 200
    static var headers: [String: String] = [:]
    static var body = Data()
    static var error: Error?
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let (status, headers, body, error) = (Self.status, Self.headers, Self.body, Self.error)
        Self.requests.append(request)
        Self.lock.unlock()
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class GitHubReleaseClientTests: XCTestCase {
    private func payload(_ changes: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = [
            "tag_name": "v0.5.1",
            "html_url": "https://github.com/Minischatten/Wupsy/releases/tag/v0.5.1", "draft": false,
            "prerelease": false, "published_at": "2026-11-11T00:00:00Z",
        ]
        value.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }
    func testDecodePublishedReleaseAndRejectMalformedData() throws {
        XCTAssertEqual(try GitHubReleaseClient.decode(payload())?.version.description, "0.5.1")
        XCTAssertNil(try GitHubReleaseClient.decode(payload(["draft": true])))
        XCTAssertNil(try GitHubReleaseClient.decode(payload(["prerelease": true])))
        for changes: [String: Any] in [
            ["tag_name": "v0.5.1-rc1"], ["published_at": NSNull()], ["published_at": "bad"],
            ["html_url": "https://evil.test"], ["draft": "false"],
        ] {
            XCTAssertThrowsError(try GitHubReleaseClient.decode(payload(changes)))
        }
        XCTAssertThrowsError(try GitHubReleaseClient.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try GitHubReleaseClient.decode(Data("not JSON".utf8)))
    }
    func testRateHeadersAndHTTPDate() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        for headers in [
            ["Retry-After": "120"],
            ["Retry-After": formatter.string(from: now.addingTimeInterval(120))],
            [
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": String(now.timeIntervalSince1970 + 120),
            ],
        ] {
            let response = HTTPURLResponse(
                url: GitHubReleaseClient.endpoint, statusCode: 429, httpVersion: nil,
                headerFields: headers)!
            XCTAssertThrowsError(try GitHubReleaseClient.validateStatus(response, now: now)) {
                error in
                XCTAssertEqual(
                    error as? UpdateCheckFailure, .rateLimited(until: now.addingTimeInterval(120)))
            }
        }
    }
    func testMockTransportStatusesTimeoutCancellationAndRequestPrivacy() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateStubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let client = GitHubReleaseClient(session: session, now: { time })
        let valid = try payload()
        for (status, error, expected): (Int, Error?, UpdateCheckFailure?) in [
            (200, nil, nil), (404, nil, .unavailable),
            (403, nil, .rateLimited(until: time.addingTimeInterval(60))),
            (429, nil, .rateLimited(until: time.addingTimeInterval(60))), (503, nil, .server(503)),
            (200, URLError(.timedOut), .network), (200, URLError(.cancelled), .cancelled),
        ] {
            UpdateStubProtocol.lock.withLock {
                UpdateStubProtocol.status = status
                UpdateStubProtocol.error = error
                UpdateStubProtocol.headers = [:]
                UpdateStubProtocol.body = valid
                UpdateStubProtocol.requests = []
            }
            do {
                let release = try await client.latest()
                XCTAssertNil(expected)
                XCTAssertEqual(release?.version.description, "0.5.1")
            } catch { XCTAssertEqual(error as? UpdateCheckFailure, expected) }
            let requests = UpdateStubProtocol.lock.withLock { UpdateStubProtocol.requests }
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests[0].url, GitHubReleaseClient.endpoint)
            XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(requests[0].value(forHTTPHeaderField: "Cookie"))
            XCTAssertNotNil(requests[0].value(forHTTPHeaderField: "User-Agent"))
        }
    }
}
