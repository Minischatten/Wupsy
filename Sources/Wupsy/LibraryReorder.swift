import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let wupsyLibraryEntry = UTType(
        exportedAs: "com.wirdschonsoftware.wupsy.library-entry", conformingTo: .data)
}

/// An ephemeral view capability, never an array index or persisted preference.
struct LibraryReorderItem: Codable, Transferable {
    let contextID: UUID
    let wallpaperID: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .wupsyLibraryEntry)
    }
}

struct LibraryInsertion: Equatable {
    let targetID: UUID
    let placement: LibraryMovePlacement

    static func card(_ id: UUID, x: CGFloat, width: CGFloat) -> Self {
        Self(targetID: id, placement: x < width / 2 ? .before : .after)
    }
}

/// UI admission only; all permutation/persistence work belongs to Library.move.
@MainActor final class LibraryReorderController: ObservableObject {
    @Published private(set) var contextID = UUID()
    @Published private(set) var isMoving = false
    @Published var insertion: LibraryInsertion?

    func indicate(_ target: LibraryInsertion) {
        if insertion != target { insertion = target }
    }

    func invalidate() {
        contextID = UUID()
        insertion = nil
    }

    func accepts(_ item: LibraryReorderItem, at target: LibraryInsertion, visibleIDs: [UUID])
        -> Bool
    {
        !isMoving && item.contextID == contextID && item.wallpaperID != target.targetID
            && Set(visibleIDs).count == visibleIDs.count
            && visibleIDs.contains(item.wallpaperID) && visibleIDs.contains(target.targetID)
    }

    func submit(
        _ item: LibraryReorderItem, at target: LibraryInsertion, visibleIDs: [UUID],
        move: (UUID, UUID, LibraryMovePlacement) async throws -> Void
    ) async throws -> Bool {
        guard accepts(item, at: target, visibleIDs: visibleIDs) else { return false }
        isMoving = true
        invalidate()
        defer { isMoving = false }
        try await move(item.wallpaperID, target.targetID, target.placement)
        return true
    }
}

struct LibraryCardDrop: DropDelegate {
    let controller: LibraryReorderController
    let targetID: UUID
    let width: CGFloat
    var end = false
    let library: Library
    let visibleIDs: () -> [UUID]

    private func target(_ info: DropInfo) -> LibraryInsertion {
        end
            ? LibraryInsertion(targetID: targetID, placement: .after)
            : .card(targetID, x: info.location.x, width: width)
    }
    func validateDrop(info: DropInfo) -> Bool {
        !controller.isMoving && library.maintenance.allowsNewOperations
            && info.hasItemsConforming(to: [.wupsyLibraryEntry])
    }
    func dropEntered(info: DropInfo) {
        if validateDrop(info: info) { controller.indicate(target(info)) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        controller.indicate(target(info))
        // SwiftUI's Transferable source offers copy on macOS. Only the ephemeral
        // UUID payload is transferred; Library.move performs the actual reorder.
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) {
        if controller.insertion?.targetID == targetID { controller.insertion = nil }
    }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        let providers = info.itemProviders(for: [.wupsyLibraryEntry])
        guard providers.count == 1 else { return false }
        let destination = target(info)
        let context = controller.contextID
        controller.insertion = nil
        // The callback can arrive after filters, maintenance or the source have changed.
        _ = providers[0].loadTransferable(type: LibraryReorderItem.self) { result in
            Task { @MainActor in
                guard context == controller.contextID,
                    library.maintenance.allowsNewOperations,
                    case .success(let item) = result
                else { return }
                do {
                    _ = try await controller.submit(item, at: destination, visibleIDs: visibleIDs())
                    {
                        try await library.move(wallpaperID: $0, relativeTo: $1, placement: $2)
                    }
                } catch is CancellationError {
                } catch {
                    library.message = ProductText.libraryMoveError.text
                }
            }
        }
        return true
    }
}

/// Native clip-view scrolling keeps LazyVGrid intact, including partially visible rows.
/// This view never takes mouse/focus events. The timer lives only with the scroll view.
struct LibraryDragScroll: NSViewRepresentable {
    let controller: LibraryReorderController
    func makeNSView(context: Context) -> LibraryDragScrollView {
        let view = LibraryDragScrollView()
        view.controller = controller
        return view
    }
    func updateNSView(_ view: LibraryDragScrollView, context: Context) {
        view.controller = controller
        if controller.insertion != nil && !controller.isMoving { view.start() } else { view.stop() }
    }
    static func dismantleNSView(_ view: LibraryDragScrollView, coordinator: ()) { view.stop() }
}

@MainActor final class LibraryDragScrollView: NSView {
    weak var controller: LibraryReorderController?
    private var timer: Timer?
    private var escapeMonitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func start() {
        guard timer == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                if event.keyCode == 53 {
                    self?.controller?.invalidate()
                    self?.stop()
                }
            }
            return event
        }
        timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        RunLoop.main.add(timer!, forMode: .eventTracking)
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
    private func tick() {
        guard let controller, controller.insertion != nil, !controller.isMoving else { return }
        guard NSEvent.pressedMouseButtons != 0 else {
            controller.insertion = nil
            return
        }
        guard let scroll = enclosingScrollView, let window, let document = scroll.documentView
        else {
            return
        }
        let clip = scroll.contentView
        let point = clip.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let bounds = clip.bounds
        guard bounds.contains(point) else { return }
        let delta = Self.edgeDelta(
            y: clip.isFlipped ? point.y - bounds.minY : bounds.maxY - point.y,
            height: bounds.height)
        guard delta != 0 else { return }
        let direction: CGFloat = document.isFlipped ? 1 : -1
        let maximum = max(0, document.bounds.height - bounds.height)
        let y = min(maximum, max(0, bounds.minY + direction * delta))
        clip.scroll(to: NSPoint(x: bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
    }
    static func edgeDelta(y: CGFloat, height: CGFloat) -> CGFloat {
        guard height > 0, y >= 0, y <= height else { return 0 }
        let edge = min(36, height / 3)
        if y < edge { return -12 }
        if y > height - edge { return 12 }
        return 0
    }
}

struct LibraryThumbnailDrag: ViewModifier {
    let item: LibraryReorderItem?
    @ViewBuilder func body(content: Content) -> some View {
        if let item {
            content.draggable(item).help(ProductText.libraryDragHint.text)
        } else {
            content
        }
    }
}

struct LibraryCardDropModifier: ViewModifier {
    let controller: LibraryReorderController
    let targetID: UUID
    let library: Library
    let visibleIDs: () -> [UUID]
    @State private var width: CGFloat = 178
    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { width = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, value in width = value }
                }
            }
            .overlay(alignment: controller.insertion?.placement == .before ? .leading : .trailing) {
                if controller.insertion?.targetID == targetID {
                    RoundedRectangle(cornerRadius: 2).fill(WupsyTheme.accent)
                        .frame(width: 4).padding(.vertical, 2).allowsHitTesting(false)
                }
            }
            .onDrop(
                of: [.wupsyLibraryEntry],
                delegate:
                    LibraryCardDrop(
                        controller: controller, targetID: targetID, width: width,
                        library: library, visibleIDs: visibleIDs))
    }
}
