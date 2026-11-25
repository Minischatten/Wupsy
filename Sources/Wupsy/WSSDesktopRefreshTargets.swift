import AppKit

// Selection for the existing renderer refresh transaction, not a desktop-assignment model.
@MainActor enum WSSDesktopRefreshTargets {
    struct Display: Equatable {
        let number: UInt32?
        let frame: NSRect
        let scale: CGFloat
    }
    struct Target {
        let index: Int
        let renderer: Renderer
        let screen: NSScreen
    }
    static func matchSlots<ID: Equatable>(current: [ID], target: [ID]) -> [Int?] {
        var available = Array(current.indices)
        return target.map { id in
            guard let match = available.firstIndex(where: { current[$0] == id }) else {
                return nil
            }
            return available.remove(at: match)
        }
    }

    static func number(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }
    static func topology(_ screens: [NSScreen]) -> [Display] {
        screens.map { Display(number: number($0), frame: $0.frame, scale: $0.backingScaleFactor) }
    }
    static func select(id: UUID, renderers: [Renderer], screens: [NSScreen]) throws -> [Target] {
        try renderers.enumerated().compactMap { index, renderer in
            guard renderer.wallpaper.id == id else { return nil }
            guard
                let screen = screens.first(where: {
                    if let a = number($0), let b = number(renderer.screen) { return a == b }
                    return $0 === renderer.screen
                })
            else { throw ImportFailure.message(EditorText.desktopTopologyChanged.text) }
            return Target(index: index, renderer: renderer, screen: screen)
        }
    }
}
