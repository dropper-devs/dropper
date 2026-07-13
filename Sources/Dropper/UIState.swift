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

/// Shared UI state between the controller, the upload coordinator, and the
/// popover views: what the strip shows and which row is highlighted.
@MainActor
final class UIState: ObservableObject {
    @Published var strip: StripState = .idle
    @Published var highlightedID: String?   // share id or child key
    @Published var beakOffset: CGFloat = 190  // beak tip x within the panel
}
