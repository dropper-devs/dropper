import SwiftUI

/// Dropper's brand palette — the single Swift-side source for these colors.
/// The generated share page repeats the same values as CSS hex in its own
/// template; the two are kept in sync by eye (different languages).
enum Brand {
    static let indigo = Color(red: 0.545, green: 0.612, blue: 0.976)   // #8b9cf9
    static let violet = Color(red: 0.478, green: 0.408, blue: 0.905)
    static let coral = Color(red: 0.949, green: 0.647, blue: 0.647)

    /// Dark surfaces behind the onboarding art. `backdrop` is #14151a — the
    /// same background the share page uses.
    static let backdropTop = Color(red: 0.11, green: 0.115, blue: 0.15)
    static let backdrop = Color(red: 0.078, green: 0.082, blue: 0.102)  // #14151a
}
