import AppKit
import XCTest
@testable import Dropper

final class DropdownPlacementTests: XCTestCase {
    private let size = NSSize(width: 380, height: 585)

    func testNormalMenuBarAnchorPlacesDropdownBelowIcon() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let anchor = NSRect(x: 1000, y: 875, width: 24, height: 24)
        let frame = DropdownPlacement.frame(anchor: anchor, requestedSize: size,
                                            visibleFrame: visible)

        XCTAssertEqual(frame.midX, anchor.midX, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, anchor.minY - 2, accuracy: 0.001)
        XCTAssertTrue(visible.contains(frame))
    }

    func testEveryEdgeIsClampedInsideVisibleFrame() {
        let visible = NSRect(x: -1440, y: 50, width: 1440, height: 850)
        let anchors = [
            NSRect(x: -1500, y: 900, width: 20, height: 20),
            NSRect(x: 20, y: 900, width: 20, height: 20),
            NSRect(x: -720, y: 20, width: 20, height: 20),
            NSRect(x: -720, y: 1200, width: 20, height: 20),
        ]
        for anchor in anchors {
            let frame = DropdownPlacement.frame(anchor: anchor,
                                                requestedSize: size,
                                                visibleFrame: visible)
            XCTAssertTrue(visible.contains(frame), "Off-screen frame: \(frame)")
            XCTAssertGreaterThanOrEqual(frame.minX, visible.minX + 8)
            XCTAssertLessThanOrEqual(frame.maxX, visible.maxX - 8)
            XCTAssertGreaterThanOrEqual(frame.minY, visible.minY + 8)
        }
    }

    func testOversizedDropdownShrinksToSafeVisibleFrame() {
        let visible = NSRect(x: 100, y: 200, width: 320, height: 400)
        let anchor = NSRect(x: 250, y: 590, width: 20, height: 20)
        let frame = DropdownPlacement.frame(anchor: anchor, requestedSize: size,
                                            visibleFrame: visible)

        XCTAssertEqual(frame, NSRect(x: 108, y: 208, width: 304, height: 392))
    }
}

private final class LazyFileURLProvider: NSObject, NSPasteboardItemDataProvider {
    private(set) var requestCount = 0

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        requestCount += 1
        item.setString("file:///tmp/dropper-drag-test.txt", forType: type)
    }
}

final class AdvertisedFileCountTests: XCTestCase {
    func testCountsFileItemsWithoutMaterializingTheirURLs() {
        let pasteboard = NSPasteboard(
            name: .init("page.dropper.tests.\(UUID().uuidString)"))
        defer { pasteboard.clearContents() }

        let providers = (0..<3).map { _ in LazyFileURLProvider() }
        let items = providers.map { provider -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.fileURL])
            return item
        }
        XCTAssertTrue(pasteboard.writeObjects(items))
        let requestsBeforeCounting = providers.map(\.requestCount)

        XCTAssertEqual(advertisedFileCount(on: pasteboard), 3)
        XCTAssertEqual(providers.map(\.requestCount), requestsBeforeCounting)
    }
}

final class ActiveDropTargetsTests: XCTestCase {
    func testOutOfOrderExitDoesNotClearNewTarget() {
        var targets = ActiveDropTargets()
        targets.set("row-a", active: true)
        targets.set("row-b", active: true)
        targets.set("row-a", active: false)

        XCTAssertFalse(targets.isEmpty)
        XCTAssertEqual(targets.ids, ["row-b"])
    }

    func testAllTargetsMustExitBeforeTrackerIsEmpty() {
        var targets = ActiveDropTargets()
        targets.set("strip", active: true)
        targets.set("row", active: true)
        targets.set("strip", active: false)
        XCTAssertFalse(targets.isEmpty)

        targets.set("row", active: false)
        XCTAssertTrue(targets.isEmpty)
    }

    func testRemoveAllEndsCommittedDragSession() {
        var targets = ActiveDropTargets()
        targets.set("row", active: true)
        targets.removeAll()
        XCTAssertTrue(targets.isEmpty)
    }

    func testPanelFallbackKeepsDragAliveAfterLeavingIcon() {
        var targets = ActiveDropTargets()
        targets.set("status-icon", active: true)
        targets.set("popover-window", active: true)
        targets.set("status-icon", active: false)

        XCTAssertFalse(targets.isEmpty)
        XCTAssertEqual(targets.ids, ["popover-window"])
    }
}

final class FileDragTargetsTests: XCTestCase {
    func testNestedExitKeepsTheAdvertisedFileCount() {
        var targets = FileDragTargets()
        targets.set("popover", count: 4)
        targets.set("row", count: 4)
        targets.set("popover", count: 0)

        XCTAssertEqual(targets.fileCount, 4)
    }

    func testLargestLiveProviderCountWins() {
        var targets = FileDragTargets()
        targets.set("popover", count: 3)
        targets.set("strip", count: 2)

        XCTAssertEqual(targets.fileCount, 3)
    }

    func testRemovingEveryTargetEndsThePreflight() {
        var targets = FileDragTargets()
        targets.set("popover", count: 2)
        targets.set("popover", count: 0)

        XCTAssertEqual(targets.fileCount, 0)
        XCTAssertTrue(targets.counts.isEmpty)
    }

    func testSingleFileDoesNotPreviewBeforeTheStrip() {
        XCTAssertEqual(dropStripFileCount(stripCount: 0, popoverCount: 1), 0)
        XCTAssertEqual(dropStripFileCount(stripCount: 1, popoverCount: 1), 1)
    }

    func testMultipleFilesPreviewAcrossThePopover() {
        XCTAssertEqual(dropStripFileCount(stripCount: 0, popoverCount: 4), 4)
    }
}
