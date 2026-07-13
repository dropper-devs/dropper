import Foundation
import UniformTypeIdentifiers

enum MediaKind: String, Codable {
    case image, video, audio, markdown, text, file

    /// Every file maps to a kind — `.file` is the catch-all, so anything can
    /// be shared; the page just presents it as a download card.
    static func of(_ url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" { return .markdown }
        guard let type = UTType(filenameExtension: ext) else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .text) { return .text }
        return .file
    }
}

/// Per-share metadata stored as manifest.json alongside the files. Item order
/// is display order; it's what makes leaf deletes and reordering able to
/// regenerate the page.
struct Manifest: Codable, Equatable {
    var version = 1
    var items: [ManifestItem]
    /// Which item's file the legacy share-level .thumb.jpg depicts.
    var thumb: String?

    /// The share's display title, derived from its first item.
    var title: String {
        guard let first = items.first else { return "share" }
        return items.count == 1 ? first.name : "\(first.name) +\(items.count - 1)"
    }
}

struct ManifestItem: Codable, Equatable {
    let file: String    // sanitized object filename
    let name: String    // original display name
    let kind: MediaKind
    let size: Int64
    var peaks: [Int]?   // 0...100 waveform peaks (audio only)
    var width: Int?     // natural display size (video only) — stops the page
    var height: Int?    // from reflowing when metadata loads
}

/// One prepared file of a drop: possibly a converted temp copy of the source.
struct UploadFile {
    let sourceURL: URL
    let fileName: String
    let displayName: String
    let kind: MediaKind
    let contentType: String
    let size: Int64
    let isTemporary: Bool   // delete sourceURL after upload (conversions)
    let peaks: [Int]?       // waveform peaks (audio only)
    let dimensions: (width: Int, height: Int)?  // video only
}

/// ID and filename hygiene for share folders.
enum ShareNaming {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    /// Share folder name: first file's stem (readable in bucket browsers)
    /// plus 6 random characters (the unguessable part that keeps links
    /// private on a public bucket): "mixdown-final-v3-x8d2k1".
    static func shareID(firstFile fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        let capped = String(stem.prefix(24))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let suffix = String((0..<6).map { _ in alphabet.randomElement()! })
        return capped.isEmpty ? suffix : "\(capped)-\(suffix)"
    }

    /// Keep object keys and URLs clean: ASCII letters/digits/dot/dash only.
    static func sanitize(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        let stem = (name as NSString).deletingPathExtension
        var clean = stem.lowercased().map { ch -> Character in
            ch.isLetter && ch.isASCII || ch.isNumber ? ch : "-"
        }.reduce(into: "") { acc, ch in
            if ch == "-" && acc.hasSuffix("-") { return }
            acc.append(ch)
        }.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if clean.isEmpty { clean = "file" }
        return ext.isEmpty ? clean : "\(clean).\(ext)"
    }

    /// Sanitize a batch, deduplicating collisions ("kick.wav", "kick-2.wav").
    /// `existing` seeds the collision set when adding to an existing share.
    static func sanitizeAll(_ names: [String], existing: Set<String> = []) -> [String] {
        var seen = existing
        return names.map { name in
            var candidate = sanitize(name)
            let ext = (candidate as NSString).pathExtension
            let stem = (candidate as NSString).deletingPathExtension
            var counter = 2
            while seen.contains(candidate) {
                candidate = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
                counter += 1
            }
            seen.insert(candidate)
            return candidate
        }
    }
}

/// Object keys and public URLs for one share's folder — the single source of
/// truth for Dropper's bucket layout. Everything that touches a share's
/// objects goes through here.
struct ShareKeys {
    let id: String
    let config: AppConfigSnapshot

    // Keys
    var folderPrefix: String { config.key("\(id)/") }
    var manifest: String { config.key("\(id)/manifest.json") }
    var page: String { config.key("\(id)/index.html") }
    var archivedMarker: String { config.key("\(id)/.archived") }
    var pinnedMarker: String { config.key("\(id)/.pinned") }
    var legacyThumb: String { config.key("\(id)/.thumb.jpg") }
    func media(_ fileName: String) -> String { config.key("\(id)/\(fileName)") }
    func thumb(_ fileName: String) -> String { config.key("\(id)/.thumb.\(fileName).jpg") }

    // Public URLs
    var pageURL: String { "\(config.publicBase)/\(page)" }
    func mediaURL(_ fileName: String) -> String { "\(config.publicBase)/\(media(fileName))" }
}
