import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import Wupsy

@MainActor final class LibraryNativeDropTests: XCTestCase {
    func testTransferableProviderOffersAndLoadsLibraryPayload() async throws {
        XCTAssertTrue(UTType.wupsyLibraryEntry.conforms(to: .data))
        XCTAssertFalse(UTType.wupsyLibraryEntry.conforms(to: .fileURL))
        let item = LibraryReorderItem(contextID: UUID(), wallpaperID: UUID())
        let provider = NSItemProvider()
        provider.register(item)
        XCTAssertTrue(
            provider.hasItemConformingToTypeIdentifier(UTType.wupsyLibraryEntry.identifier))
        let decoded: LibraryReorderItem = try await withCheckedThrowingContinuation {
            continuation in
            _ = provider.loadTransferable(type: LibraryReorderItem.self) {
                continuation.resume(with: $0)
            }
        }
        XCTAssertEqual(decoded.contextID, item.contextID)
        XCTAssertEqual(decoded.wallpaperID, item.wallpaperID)
    }

    // Drive the public AppKit destination protocol installed by SwiftUI, including
    // its pasteboard-to-Transferable bridge. Physical mouse acceptance is separate.
    func testHostedCardRegistersAcceptsAndPersistsNativeDrop() async throws {
        let fixture = LibraryBackupTests()
        try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        let items = (0..<3).map {
            Wallpaper(
                title: "Card \($0)", path: "/synthetic/\($0).png", root: "/synthetic", kind: .image)
        }
        try fixture.save(items)
        let library = Library(
            maintenance: MaintenanceCoordinator(), storage: fixture.storage,
            defaults: fixture.defaults, restoreOnLaunch: false)
        let controller = LibraryReorderController()
        let ready = expectation(description: "Card hosted")
        let host = NSHostingView(
            rootView:
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible())]) {
                        WallpaperCard(
                            item: items[1], isSelected: false, isActive: false,
                            isFavorite: false, select: {}, apply: {}, favorite: {}
                        )
                        .modifier(
                            LibraryCardDropModifier(
                                controller: controller, targetID: items[1].id,
                                library: library, visibleIDs: { items.map(\.id) })
                        )
                        .contextMenu { Button("Synthetic action") {} }
                    }
                    .background(LibraryDragScroll(controller: controller))
                }.onAppear { ready.fulfill() })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await fulfillment(of: [ready], timeout: 3)
        host.layoutSubtreeIfNeeded()
        func destinations(_ view: NSView) -> [NSView] {
            (view.registeredDraggedTypes.isEmpty ? [] : [view])
                + view.subviews.flatMap(destinations)
        }
        let destination = try XCTUnwrap(
            destinations(host).first {
                $0.registeredDraggedTypes.contains(
                    NSPasteboard.PasteboardType(UTType.data.identifier))
            }, "SwiftUI must register native drop types; an unrooted custom UTType registers none")
        let point = destination.convert(NSPoint(x: 1, y: destination.bounds.midY), to: nil)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let payload = LibraryReorderItem(contextID: controller.contextID, wallpaperID: items[0].id)
        pasteboard.declareTypes(
            [NSPasteboard.PasteboardType(UTType.wupsyLibraryEntry.identifier)], owner: nil)
        pasteboard.setData(
            try JSONEncoder().encode(payload),
            forType: NSPasteboard.PasteboardType(UTType.wupsyLibraryEntry.identifier))
        let info = NativeLibraryDragInfo(window: window, pasteboard: pasteboard, point: point)
        XCTAssertNotEqual(destination.draggingEntered(info), [])
        let operation = destination.draggingUpdated(info)
        XCTAssertEqual(operation, .copy)
        XCTAssertFalse(
            operation.intersection(info.draggingSourceOperationMask).isEmpty,
            "AppKit rejects proposals outside the source's operation mask")
        XCTAssertEqual(
            controller.insertion, LibraryInsertion(targetID: items[1].id, placement: .before))
        let changed = expectation(description: "Move published after persistence")
        let observation = library.$items.dropFirst().sink { updated in
            if updated.map(\.id) == [items[1], items[0], items[2]].map(\.id) { changed.fulfill() }
        }
        defer { observation.cancel() }
        XCTAssertEqual(destination.prepareForDragOperation(info), true)
        XCTAssertEqual(destination.performDragOperation(info), true)
        await fulfillment(of: [changed], timeout: 3)
        XCTAssertEqual(library.items.map(\.id), [items[1], items[0], items[2]].map(\.id))
        XCTAssertEqual(
            try JSONDecoder().decode([Wallpaper].self, from: Data(contentsOf: fixture.storage)),
            library.items)
    }
}

@MainActor private final class NativeLibraryDragInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingSourceOperationMask: NSDragOperation = .copy
    let draggingSource: Any? = nil
    let draggingSequenceNumber = 1
    let draggedImageLocation = NSPoint.zero
    nonisolated var draggedImage: NSImage? { nil }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none
    init(window: NSWindow, pasteboard: NSPasteboard, point: NSPoint) {
        draggingDestinationWindow = window
        draggingPasteboard = pasteboard
        draggingLocation = point
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL)
        -> [String]?
    { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        for (index, item) in (draggingPasteboard.pasteboardItems ?? []).enumerated() {
            var stop: ObjCBool = false
            block(NSDraggingItem(pasteboardWriter: item), index, &stop)
            if stop.boolValue { break }
        }
    }
}
