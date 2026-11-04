import Foundation

// Transient identities only. Technical descriptions remain stable for legacy
// callbacks; the activity view resolves user text when it renders each event.
enum RuntimeDiagnostic: Error, LocalizedError, Equatable {
    case videoResuming, decoderRebuilding, memoryRecovered
    case imageDecode, videoRecoveryFailed, webStopped, wssGPU
    case gifRead, gifFrames
    case sceneUnsupported(String)
    case failure(String)

    var errorDescription: String? { technicalDescription }

    static func capturing(_ error: Error) -> RuntimeDiagnostic {
        (error as? RuntimeDiagnostic) ?? .failure(error.localizedDescription)
    }

    var technicalDescription: String {
        switch self {
        case .videoResuming: return "Video stalled; resuming playback"
        case .decoderRebuilding: return "Recreating video decoder after a stall"
        case .memoryRecovered: return "Memory pressure eased; resuming wallpaper"
        case .imageDecode: return "The image could not be decoded."
        case .videoRecoveryFailed:
            return
                "The video repeatedly failed to recover. Your wallpaper is kept; choose Resume or try another file."
        case .webStopped:
            return "The web wallpaper stopped unexpectedly. Apply it again to restart."
        case .wssGPU: return "The WSS static renderer reported a GPU error."
        case .gifRead: return "Could not read this GIF."
        case .gifFrames:
            return
                "This GIF has no frames or exceeds 20,000 frames. Convert it to MP4 for efficient playback."
        case .sceneUnsupported(let evidence):
            return
                "Dieses Wallpaper kann derzeit nicht in das native WSS-Format übernommen werden. \(evidence)"
        case .failure(let evidence): return evidence
        }
    }
    func localized(language: String? = nil) -> String {
        let resource: RuntimeText
        switch self {
        case .videoResuming: resource = .videoResuming
        case .decoderRebuilding: resource = .decoderRebuilding
        case .memoryRecovered: resource = .memoryRecovered
        case .imageDecode: resource = .imageDecode
        case .videoRecoveryFailed: resource = .videoRecoveryFailed
        case .webStopped: resource = .webStopped
        case .wssGPU: resource = .wssGPU
        case .gifRead: resource = .gifRead
        case .gifFrames: return RuntimeText.gifFrames.format(Int64(20000), language: language)
        case .sceneUnsupported(let evidence):
            return RuntimeText.sceneUnsupported.format(evidence, language: language)
        case .failure(let evidence): return RuntimeText.failure.format(evidence, language: language)
        }
        return resource.localized(language: language)
    }
}

struct PlaybackActivity: Equatable {
    enum Event: Equatable {
        case status(LibraryPlaybackStatus)
        case diagnostic(RuntimeDiagnostic)
    }
    let time: Date
    let event: Event

    func localized(language: String? = nil) -> String {
        let text: String
        switch event {
        case .status(let status): text = status.localizedTitle(language: language)
        case .diagnostic(let diagnostic): text = diagnostic.localized(language: language)
        }
        let locale =
            language.map { Locale(identifier: RuntimeText.presentationLanguage($0)) } ?? .current
        let timestamp = time.formatted(
            Date.FormatStyle(date: .omitted, time: .standard).locale(locale))
        return RuntimeText.activity.format(timestamp, text, language: language)
    }
}

enum RuntimeText: String, CaseIterable {
    case videoResuming = "runtime.videoResuming"
    case decoderRebuilding = "runtime.decoderRebuilding"
    case memoryRecovered = "runtime.memoryRecovered"
    case imageDecode = "runtime.imageDecode"
    case videoRecoveryFailed = "runtime.videoRecoveryFailed"
    case webStopped = "runtime.webStopped"
    case wssGPU = "runtime.wssGPU"
    case failure = "runtime.failure"
    case activity = "runtime.activity"
    case gifRead = "runtime.gifRead"
    case gifFrames = "runtime.gifFrames"
    case sceneUnsupported = "runtime.sceneUnsupported"

    static func presentationLanguage(_ language: String) -> String {
        Localization.bundle.path(forResource: language, ofType: "lproj") == nil ? "en" : language
    }
    func localized(language: String? = nil) -> String {
        Localization.string(key: rawValue, language: language.map(Self.presentationLanguage))
    }
    func format(_ arguments: CVarArg..., language: String? = nil) -> String {
        let language = language.map(Self.presentationLanguage)
        return String(
            format: localized(language: language),
            locale: language.map(Locale.init(identifier:)) ?? .current, arguments: arguments)
    }
}
