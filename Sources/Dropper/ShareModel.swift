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
    static let currentVersion = 2

    var version = Manifest.currentVersion
    var items: [ManifestItem]

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
    var poster: String? = nil  // relative high-resolution video poster path
}

/// One prepared file of a drop: possibly a converted temp copy of the source.
struct UploadFile {
    let sourceURL: URL
    var fileName: String
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
    /// Share folder name: first file's stem (readable in bucket browsers)
    /// plus 128 bits of system-generated randomness. The suffix makes links
    /// impractical to discover accidentally and avoids collisions, but these
    /// are unlisted public links — not private or access-controlled content.
    static func shareID(firstFile fileName: String) -> String {
        let safeName = sanitize(fileName)
        let stem = (safeName as NSString).deletingPathExtension
        let capped = String(stem.prefix(24))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let suffix = randomHex(byteCount: 16)
        return capped.isEmpty ? suffix : "\(capped)-\(suffix)"
    }

    /// Keep object keys and URLs clean: ASCII letters/digits/dot/dash only.
    /// Both the stem and extension are sanitized; an extension is input, not
    /// a trusted MIME label, and may contain any character legal in a filename.
    static func sanitize(_ name: String) -> String {
        let rawExtension = (name as NSString).pathExtension
        let rawStem = (name as NSString).deletingPathExtension
        var stem = sanitizePart(rawStem)
        let ext = sanitizePart(rawExtension)
        if stem.isEmpty { stem = "file" }
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    private static func sanitizePart(_ value: String) -> String {
        value.lowercased().map { ch -> Character in
            ch.isASCII && (ch.isLetter || ch.isNumber) ? ch : "-"
        }.reduce(into: "") { acc, ch in
            if ch == "-" && acc.hasSuffix("-") { return }
            acc.append(ch)
        }.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Lowercase hex from the system CSPRNG. Also used for the share page's
    /// CSP nonce, so ID suffixes and nonces share one audited generator.
    static func randomHex(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<byteCount)
            .map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            .hexEncoded
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
    func media(_ fileName: String) -> String { config.key("\(id)/\(fileName)") }
    func thumb(_ fileName: String) -> String { config.key("\(id)/.thumb.\(fileName).jpg") }
    func posterName(_ fileName: String) -> String { ".poster.\(fileName).jpg" }
    func poster(_ fileName: String) -> String {
        config.key("\(id)/\(posterName(fileName))")
    }

    // Public URLs
    var pageURL: String { "\(config.publicBase)/\(page)" }
    func mediaURL(_ fileName: String) -> String { "\(config.publicBase)/\(media(fileName))" }
}
