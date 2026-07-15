import AppKit

/// Bundled UI sound effects (in Resources), each loaded once and reused.
enum Sounds {
    static let drop = load("drop")
    static let delete = load("delete")

    private static func load(_ name: String) -> NSSound? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "mp3")
        else { return nil }
        return NSSound(contentsOf: url, byReference: true)
    }
}
