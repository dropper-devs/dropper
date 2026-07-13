import Foundation

/// Compiled-in defaults, used until the user configures the app in Settings.
enum Config {
    /// R2 account (ea8c… is the Temecula DSP account).
    static let defaultAccountID = "ea8c81be662d84ad86683f6a4daa4da0"
    static let bucket = "dropper-page"
    static let keyPrefix = "share"

    /// The configured `share` prefix makes public links land under /share/*;
    /// the site Worker reads that same namespaced key from the R2 bucket.
    static let publicBase = "https://dropper.page"
}
