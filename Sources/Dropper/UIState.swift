import SwiftUI

/// Bottom strip of the dropdown: drop target -> progress ring -> link buttons.
enum StripState: Equatable {
    case idle
    case uploading(name: String, progress: Double)
    // One entry per selected row, in list order. Fully selected shares
    // contribute their plain page link; partially selected collections
    // contribute anchored links per chosen file. fileURLs holds only the
    // entries that have a direct file (multi-file share rows have none).
    case links(name: String, pageURLs: [String], fileURLs: [String])
}

/// Counts the files advertised by every destination currently under the
/// pointer. Multiple tokens matter because AppKit can enter a child target
/// before it sends the matching exit for its parent (or vice versa).
struct FileDragTargets {
    private(set) var counts: [String: Int] = [:]

    var fileCount: Int { counts.values.max() ?? 0 }

    mutating func set(_ id: String, count: Int) {
        if count > 0 {
            counts[id] = count
        } else {
            counts.removeValue(forKey: id)
        }
    }

    mutating func removeAll() {
        counts.removeAll()
    }
}

/// Shared UI state between the controller, the upload coordinator, and the
/// popover views: what the strip shows and which row is highlighted.
@MainActor
final class UIState: ObservableObject {
    @Published var strip: StripState = .idle
    @Published var highlightedID: String?   // share id or child key
    @Published var beakOffset: CGFloat = 190  // beak tip x within the panel
    @Published private(set) var draggedFileCount = 0
    private var fileDragTargets = FileDragTargets()
    private var pendingClear: DispatchWorkItem?

    func setDraggedFileCount(_ count: Int, for targetID: String) {
        fileDragTargets.set(targetID, count: count)
        let nextCount = fileDragTargets.fileCount
        if nextCount > 0 {
            // A live target: apply now and cancel any pending clear.
            pendingClear?.cancel()
            pendingClear = nil
            if draggedFileCount != nextCount { draggedFileCount = nextCount }
        } else {
            // No target advertises files. AppKit sends the OLD target's exit
            // before the NEW target's enter, so a bare 0 during a hover
            // transition would flicker the multi-file split preview off then
            // on. Defer the drop to zero; the next enter cancels it.
            scheduleClear()
        }
    }

    func clearDraggedFiles() {
        pendingClear?.cancel()
        pendingClear = nil
        fileDragTargets.removeAll()
        if draggedFileCount != 0 { draggedFileCount = 0 }
    }

    private func scheduleClear() {
        pendingClear?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingClear = nil
            if self.fileDragTargets.fileCount == 0, self.draggedFileCount != 0 {
                self.draggedFileCount = 0
            }
        }
        pendingClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }
}
