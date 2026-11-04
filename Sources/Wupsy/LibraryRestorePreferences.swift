import CoreFoundation
import Foundation

struct RestorePreferenceValue: Codable, Equatable {
    let plist: Data?
    init(_ value: Any?) throws {
        plist = try value.map {
            try PropertyListSerialization.data(
                fromPropertyList: ["value": $0], format: .binary, options: 0)
        }
    }
    func value() throws -> Any? {
        try plist.map {
            guard
                let envelope = try PropertyListSerialization.propertyList(
                    from: $0, options: [], format: nil) as? [String: Any],
                envelope.count == 1, let value = envelope["value"]
            else { throw LibraryBackupError("Invalid transaction preference value.") }
            return value
        }
    }
}
// Explicit domain only. No controller setters, observers, standard defaults or UI.
struct LibraryRestorePreferences {
    static let keys = [
        "favorites", "profile", "sceneRenderResolution", "sceneFPS", "conserve", "pauseOnBattery",
        "allDisplays",
        "customWidgetPackage", "independentWidgets", "desktopWidgets", "customWidgetEnabled",
        "activeWallpaper", "selectedWallpaper", "selectedPlaylistID", "manuallyPaused",
    ]
    let domain: String
    init(domain: String) throws {
        guard !domain.isEmpty, domain.utf8.count <= 255,
            domain != kCFPreferencesAnyApplication as String
        else {
            throw LibraryBackupError("An explicit preference domain is required.")
        }
        self.domain = domain
    }
    func synchronize() throws {
        guard
            CFPreferencesSynchronize(
                domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        else {
            throw LibraryBackupError("Cannot durably synchronize restore preferences.")
        }
    }
    func snapshot() throws -> [String: RestorePreferenceValue] {
        try synchronize()
        return try Dictionary(
            uniqueKeysWithValues: Self.keys.map { key in
                (
                    key,
                    try RestorePreferenceValue(
                        CFPreferencesCopyValue(
                            key as CFString, domain as CFString, kCFPreferencesCurrentUser,
                            kCFPreferencesAnyHost))
                )
            })
    }
    func write(_ value: RestorePreferenceValue, key: String) throws {
        guard Self.keys.contains(key) else {
            throw LibraryBackupError("Unknown transaction preference.")
        }
        CFPreferencesSetValue(
            key as CFString, try value.value() as CFPropertyList?, domain as CFString,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    func confirm(_ values: [String: RestorePreferenceValue]) throws {
        try synchronize()
        for key in Self.keys {
            let actual = CFPreferencesCopyValue(
                key as CFString, domain as CFString, kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost)
            let expected = try values[key]!.value()
            guard
                (actual == nil && expected == nil)
                    || (actual as? NSObject)?.isEqual(expected) == true
            else {
                throw LibraryBackupError(
                    "Persistent restore preference \(key) does not match the journal.")
            }
        }
    }
    static func projection(
        _ plan: LibraryRestorePlan, preservingLocalState old: [String: RestorePreferenceValue]
    ) throws -> [String: RestorePreferenceValue] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var result = try Dictionary(
            uniqueKeysWithValues: keys.map { ($0, try RestorePreferenceValue(nil)) })
        func set(_ key: String, _ value: Any?) throws {
            result[key] = try RestorePreferenceValue(value)
        }
        try set("favorites", plan.favorites.map(\.uuidString))
        try set("profile", plan.settings.profile.rawValue)
        try set("sceneRenderResolution", plan.settings.sceneRenderResolution)
        try set("sceneFPS", plan.settings.sceneFPS)
        try set("conserve", plan.settings.conserve)
        try set("pauseOnBattery", plan.settings.pauseOnBattery)
        try set("allDisplays", plan.settings.allDisplays)
        try set(
            "customWidgetPackage",
            try plan.widgets.customWidgetPackage.map { try encoder.encode($0) })
        try set("independentWidgets", try encoder.encode(plan.widgets.independentWidgets))
        let localLegacy = try old["desktopWidgets"]?.value() as? Data
        var legacy =
            localLegacy.flatMap {
                try? JSONDecoder().decode(DesktopWidgetSettings.self, from: $0)
            } ?? DesktopWidgetSettings()
        legacy.allDisplays = plan.widgets.allDisplays
        try set("desktopWidgets", try encoder.encode(legacy))
        try set(
            "customWidgetEnabled",
            plan.widgets.independentWidgets[WidgetKind.custom.rawValue]?.enabled ?? false)
        // widgetPositions is target-Mac state and is outside the write allowlist.
        // Only runtime selections are neutralized; no source-local positions enter B.
        try set("manuallyPaused", false)
        return result
    }
}
