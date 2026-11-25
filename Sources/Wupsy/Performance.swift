import CoreGraphics
import Foundation

enum QualityProfile: String, CaseIterable, Identifiable, Codable {
    case eco, balanced, original
    var id: String { rawValue }
    var title: String { displayName() }
    func displayName(language: String? = nil) -> String {
        let resource: ProductText
        switch self {
        case .eco: resource = .qualityEco
        case .balanced: resource = .qualityBalanced
        case .original: resource = .qualityOriginal
        }
        return resource.localized(language: language)
    }
    var maxDimension: Int {
        switch self {
        case .eco: return 1280
        case .balanced: return 2560
        case .original: return 8192
        }
    }
    var fps: Int32 {
        switch self {
        case .eco: return 24
        case .balanced: return 30
        case .original: return 60
        }
    }
    var detail: String {
        switch self {
        case .eco: return ProductText.qualityEcoDetail.text
        case .balanced: return ProductText.qualityBalancedDetail.text
        case .original: return ProductText.qualityOriginalDetail.text
        }
    }
    func targetSize(_ source: CGSize) -> CGSize {
        let scale = min(1, CGFloat(maxDimension) / max(source.width, source.height))
        return CGSize(
            width: max(2, floor(source.width * scale / 2) * 2),
            height: max(2, floor(source.height * scale / 2) * 2))
    }
}
enum PauseReason: String, CaseIterable {
    case manual = "Paused by you"
    case sleep = "Display asleep"
    case session = "Session inactive"
    case memory = "Paused · critical memory pressure"
    case thermal = "Cooling down"
    case lowPower = "Low Power Mode"
    case battery = "On battery"

    var title: String { displayName() }
    func displayName(language: String? = nil) -> String {
        let resource: ProductText
        switch self {
        case .manual: resource = .pausedManual
        case .sleep: resource = .pausedSleep
        case .session: resource = .pausedSession
        case .battery: resource = .pausedBattery
        case .lowPower: resource = .pausedLowPower
        case .thermal: resource = .pausedThermal
        case .memory: resource = .pausedMemory
        }
        return resource.localized(language: language)
    }

}
struct PlaybackConditions {
    var manual = false
    var sleeping = false
    var systemSleeping = false
    var inactive = false
    var onBattery = false
    var lowPower = false
    var hot = false
    var memoryPressure = false
    var surfaceUnavailable: Bool { sleeping || systemSleeping || inactive }

    func reasons(conserve: Bool, pauseOnBattery: Bool) -> Set<PauseReason> {
        var result: Set<PauseReason> = []
        if manual { result.insert(.manual) }
        if sleeping || systemSleeping { result.insert(.sleep) }
        if inactive { result.insert(.session) }
        if memoryPressure { result.insert(.memory) }
        if conserve && hot { result.insert(.thermal) }
        if conserve && lowPower { result.insert(.lowPower) }
        if pauseOnBattery && onBattery { result.insert(.battery) }
        return result
    }
    func reason(conserve: Bool, pauseOnBattery: Bool) -> PauseReason? {
        let active = reasons(conserve: conserve, pauseOnBattery: pauseOnBattery)
        return PauseReason.allCases.first(where: active.contains)
    }
    func systemReason(conserve: Bool, pauseOnBattery: Bool) -> PauseReason? {
        let active = reasons(conserve: conserve, pauseOnBattery: pauseOnBattery)
        return PauseReason.allCases.first { $0 != .manual && active.contains($0) }
    }
}
