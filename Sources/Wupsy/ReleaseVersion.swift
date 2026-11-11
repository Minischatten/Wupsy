import Foundation

struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: UInt64
    let minor: UInt64
    let patch: UInt64

    init(_ text: String) throws {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw UpdateCheckFailure.invalidVersion }
        let numbers = parts.compactMap { part -> UInt64? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }) else {
                return nil
            }
            return UInt64(part)
        }
        guard numbers.count == 3 else { throw UpdateCheckFailure.invalidVersion }
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
    }
    var description: String { "\(major).\(minor).\(patch)" }
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
    static func installed(in bundle: Bundle = .main) throws -> Self {
        guard
            let value = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { throw UpdateCheckFailure.invalidVersion }
        return try Self(value)
    }
}
