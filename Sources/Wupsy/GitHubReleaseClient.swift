import Foundation

enum UpdateCheckFailure: Error, Equatable, Sendable {
    case unavailable, invalidResponse, invalidVersion, network, cancelled
    case server(Int)
    case rateLimited(until: Date)
}

struct GitHubRelease: Equatable, Sendable {
    let version: ReleaseVersion
    let url: URL

    static func validatedURL(_ text: String, tag: String) throws -> URL {
        guard let components = URLComponents(string: text),
            components.scheme == "https", components.host?.lowercased() == "github.com",
            components.user == nil, components.password == nil, components.port == nil,
            components.query == nil, components.fragment == nil,
            components.path == "/Minischatten/Wupsy/releases/tag/" + tag,
            !tag.contains("/"), let url = components.url
        else { throw UpdateCheckFailure.invalidResponse }
        return url
    }
}

protocol ReleaseChecking: Sendable {
    func latest() async throws -> GitHubRelease?
}

private final class UpdateRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct GitHubReleaseClient: ReleaseChecking {
    static let endpoint = URL(
        string: "https://api.github.com/repos/Minischatten/Wupsy/releases/latest")!
    let session: URLSession
    let now: @Sendable () -> Date

    init(
        session: URLSession = GitHubReleaseClient.makeSession(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.now = now
    }
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(
            configuration: config, delegate: UpdateRedirectPolicy(), delegateQueue: nil)
    }
    static var request: URLRequest {
        var request = URLRequest(
            url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Wupsy-Update-Check", forHTTPHeaderField: "User-Agent")
        return request
    }
    func latest() async throws -> GitHubRelease? {
        do {
            let (bytes, response) = try await session.bytes(for: Self.request)
            guard let http = response as? HTTPURLResponse else {
                throw UpdateCheckFailure.invalidResponse
            }
            try Self.validateStatus(http, now: now())
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 1_048_576 else { throw UpdateCheckFailure.invalidResponse }
                data.append(byte)
            }
            return try Self.decode(data)
        } catch let error as UpdateCheckFailure {
            throw error
        } catch is CancellationError {
            throw UpdateCheckFailure.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw UpdateCheckFailure.cancelled
        } catch {
            throw UpdateCheckFailure.network
        }
    }
    static func validateStatus(_ response: HTTPURLResponse, now: Date) throws {
        switch response.statusCode {
        case 200: return
        case 404: throw UpdateCheckFailure.unavailable
        case 403, 429:
            var deadline = now.addingTimeInterval(60)
            if let raw = response.value(forHTTPHeaderField: "Retry-After") {
                if let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0 {
                    deadline = max(deadline, now.addingTimeInterval(seconds))
                } else {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                    if let date = formatter.date(from: raw) { deadline = max(deadline, date) }
                }
            }
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
                let raw = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
                let seconds = TimeInterval(raw), seconds.isFinite
            {
                deadline = max(deadline, Date(timeIntervalSince1970: seconds))
            }
            throw UpdateCheckFailure.rateLimited(until: deadline)
        default: throw UpdateCheckFailure.server(response.statusCode)
        }
    }
    static func decode(_ data: Data) throws -> GitHubRelease? {
        struct Payload: Decodable {
            let tagName: String
            let htmlURL: String
            let draft: Bool
            let prerelease: Bool
            let publishedAt: String?
            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case htmlURL = "html_url"
                case draft, prerelease
                case publishedAt = "published_at"
            }
        }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) } catch {
            throw UpdateCheckFailure.invalidResponse
        }
        guard !payload.draft, !payload.prerelease else { return nil }
        guard let published = payload.publishedAt,
            ISO8601DateFormatter().date(from: published) != nil
        else { throw UpdateCheckFailure.invalidResponse }
        let version = try ReleaseVersion(payload.tagName)
        return GitHubRelease(
            version: version,
            url: try GitHubRelease.validatedURL(payload.htmlURL, tag: payload.tagName))
    }
}
