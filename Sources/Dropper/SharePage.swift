import Foundation

// MARK: - Share page template

private let docIconSVG = """
<svg class="cardicon" viewBox="0 0 24 24" aria-hidden="true"><path d="M6 2h9l5 5v15H6z" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/><path d="M15 2v5h5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/></svg>
"""

private let zipIconSVG = """
<svg class="cardicon" viewBox="0 0 24 24" aria-hidden="true"><path d="M6 2h9l5 5v15H6z" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/><path d="M15 2v5h5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/><path d="M10 4v2M10 8v2M10 12v2M10 16v2" stroke="currentColor" stroke-width="1.6"/></svg>
"""

private let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "7z", "rar", "bz2", "xz"]

private func downloadCard(_ item: ManifestItem) -> String {
    let ext = (item.file as NSString).pathExtension.lowercased()
    let icon = archiveExtensions.contains(ext) ? zipIconSVG : docIconSVG
    let sizeText = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
    let fileURL = escapeHTML(encodedRelativeObjectPath(item.file))
    return """
    <div class="card">
    \(icon)
    <div class="cardinfo">
    <div class="cardname">\(escapeHTML(item.name))</div>
    <div class="cardsize">\(escapeHTML(sizeText))</div>
    </div>
    <a class="dl" href="\(fileURL)" download>Download</a>
    </div>
    """
}

private func renderImageGallery(_ items: [ManifestItem]) -> String {
    let tiles = items.map { item in
        let fileURL = escapeHTML(encodedRelativeObjectPath(item.file))
        return """
        <a class="gallery-item" href="\(fileURL)" data-name="\(escapeHTML(item.name))" aria-label="\(escapeHTML("View \(item.name)"))">
        <img src="\(fileURL)" alt="" loading="lazy" decoding="async">
        </a>
        """
    }.joined(separator: "\n")

    return """
    <section class="image-gallery" aria-label="Image gallery">
    \(tiles)
    </section>
    """
}

private let imageGalleryLightbox = """
<dialog class="lightbox" aria-label="Image preview" aria-modal="true">
<button class="lightbox-close" type="button" aria-label="Close image preview">
<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M4 4l12 12M16 4L4 16"/></svg>
</button>
<button class="lightbox-nav lightbox-prev" type="button" aria-label="Previous image">
<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M12.5 4L6.5 10l6 6"/></svg>
</button>
<figure class="lightbox-stage">
<img class="lightbox-image" alt="">
<figcaption class="lightbox-caption" aria-live="polite">
<span class="lightbox-name"></span>
<span class="lightbox-count"></span>
<a class="lightbox-download" download>Download</a>
</figcaption>
</figure>
<button class="lightbox-nav lightbox-next" type="button" aria-label="Next image">
<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M7.5 4l6 6-6 6"/></svg>
</button>
</dialog>
"""

func renderShareHTML(
    title: String, items: [ManifestItem], galleryEnabled: Bool = false
) -> String {
    let nonce = securePageNonce()
    let escapedNonce = escapeHTML(nonce)
    let usesGallery = galleryEnabled && items.count > 1
        && items.allSatisfy { $0.kind == .image }
    // A nonce is the only way scripts may run. Attribute handlers are denied
    // explicitly, so a malformed manifest cannot turn a filename into
    // executable markup even if an escaping regression slips in later.
    let contentSecurityPolicy = [
        "default-src 'none'",
        "base-uri 'none'",
        "connect-src 'self'",
        "font-src 'none'",
        "form-action 'none'",
        // Same-origin only: browsers render an embedded PDF (<object
        // type="application/pdf">) inside an internal viewer frame, which is
        // governed here. 'none' would silently fall back to the download card.
        "frame-src 'self'",
        "img-src 'self' data: https:",
        "media-src 'self'",
        "object-src 'self'",
        "script-src 'nonce-\(nonce)'",
        "script-src-attr 'none'",
        // The generated template and sanitized Markdown may contain inline
        // presentation styles; scripts remain nonce-locked independently.
        "style-src 'unsafe-inline'",
        "worker-src 'none'",
    ].joined(separator: "; ")

    let blocks = usesGallery ? renderImageGallery(items) : items.map { item -> String in
        let fileURL = escapeHTML(encodedRelativeObjectPath(item.file))
        let media: String
        switch item.kind {
        case .image:
            media = #"<img src="\#(fileURL)" alt="\#(escapeHTML(item.name))">"#
        case .video:
            // Intrinsic sizing from the manifest: the layout is final before
            // any video metadata loads, so the page never reflows.
            var containerStyle = ""
            // Prefer the full-resolution poster. The current per-file
            // thumbnail remains the fallback when poster generation or upload
            // is unavailable.
            let poster = item.poster ?? ".thumb.\(item.file).jpg"
            let posterURL = escapeHTML(encodedRelativeObjectPath(poster))
            var videoAttrs = " poster=\"\(posterURL)\""
            if let w = item.width, let h = item.height, w > 0, h > 0 {
                let ratio = String(format: "%.4f", Double(w) / Double(h))
                // Allow up to 2x natural width so small clips still present
                // large; the page ceiling and viewport height cap both hold.
                containerStyle = " style=\"max-width:min(1400px, \(w * 2)px, calc(80vh * \(ratio)))\""
                videoAttrs += " width=\"\(w)\" height=\"\(h)\" style=\"aspect-ratio:\(w)/\(h)\""
            }
            media = """
            <div class="vplayer"\(containerStyle)>
            <video playsinline preload="metadata"\(videoAttrs) src="\(fileURL)"></video>
            <div class="vbar">
            <button type="button" aria-label="Play" aria-pressed="false">
            <svg class="icon-play" viewBox="0 0 16 16" aria-hidden="true"><path d="M4 2.5v11l9-5.5z"/></svg>
            <svg class="icon-pause" viewBox="0 0 16 16" aria-hidden="true"><path d="M4 2h3v12H4zM9 2h3v12H9z"/></svg>
            </button>
            <input class="seek" type="range" min="0" max="1000" value="0" aria-label="Seek video">
            <span class="time">0:00</span>
            </div>
            </div>
            """
        case .audio:
            if let peaks = item.peaks {
                let json = "[" + peaks.map(String.init).joined(separator: ",") + "]"
                media = """
                <div class="player" data-src="\(fileURL)" data-peaks="\(escapeHTML(json))">
                <button type="button" aria-label="Play" aria-pressed="false">
                <svg class="icon-play" viewBox="0 0 16 16" aria-hidden="true"><path d="M4 2.5v11l9-5.5z"/></svg>
                <svg class="icon-pause" viewBox="0 0 16 16" aria-hidden="true"><path d="M4 2h3v12H4zM9 2h3v12H9z"/></svg>
                </button>
                <div class="wave">
                <canvas aria-hidden="true"></canvas>
                <input class="wave-seek" type="range" min="0" max="1000" value="0" aria-label="Seek audio">
                </div>
                <span class="time">0:00</span>
                </div>
                """
            } else {
                media = #"<audio controls src="\#(fileURL)"></audio>"#
            }
        case .markdown:
            media = item.size < 2_000_000
                ? #"<article class="md" data-src="\#(fileURL)">Loading…</article>"#
                : downloadCard(item)
        case .text:
            media = item.size < 1_000_000
                ? #"<pre class="txt" data-src="\#(fileURL)">Loading…</pre>"#
                : downloadCard(item)
        case .file:
            if (item.file as NSString).pathExtension.lowercased() == "pdf" {
                media = """
                <object class="pdfview" data="\(fileURL)" type="application/pdf">
                \(downloadCard(item))
                </object>
                """
            } else {
                media = downloadCard(item)
            }
        }
        // The download card already names the file; a caption would repeat
        // it. PDFs are the exception: they render in the inline viewer, so
        // they still need the download link underneath.
        let isPDF = (item.file as NSString).pathExtension.lowercased() == "pdf"
        let caption = item.kind == .file && !isPDF ? "" : """

        <figcaption><a href="\(fileURL)" download>\(escapeHTML(item.name))</a></figcaption>
        """
        return """
        <figure id="\(escapeHTML(item.file))">
        \(media)\(caption)
        </figure>
        """
    }.joined(separator: "\n")
    let contentClass = usesGallery ? "share-content gallery-content" : "share-content"
    let lightbox = usesGallery ? "\n\(imageGalleryLightbox)" : ""

    let needsMarkdown = items.contains { $0.kind == .markdown && $0.size < 2_000_000 }
    let cdnScripts = needsMarkdown ? """

    <!-- Exact immutable builds with SRI. Reimplementing a Markdown parser or
         HTML sanitizer here would create a larger security surface. -->
    <script nonce="\(escapedNonce)" src="https://cdn.jsdelivr.net/npm/marked@12.0.2/marked.min.js" integrity="sha384-/TQbtLCAerC3jgaim+N78RZSDYV7ryeoBCVqTuzRrFec2akfBkHS7ACQ3PQhvMVi" crossorigin="anonymous" referrerpolicy="no-referrer"></script>
    <script nonce="\(escapedNonce)" src="https://cdn.jsdelivr.net/npm/dompurify@3.2.6/dist/purify.min.js" integrity="sha384-JEyTNhjM6R1ElGoJns4U2Ln4ofPcqzSsynQkmEc/KGy6336qAZl70tDLufbkla+3" crossorigin="anonymous" referrerpolicy="no-referrer"></script>
    """ : ""

    return """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="\(escapeHTML(contentSecurityPolicy))">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>\(escapeHTML(title))</title>
    <style>
    \(sharePageStyles)
    </style>\(cdnScripts)
    </head>
    <body>
    <button class="closer" aria-label="Close">
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M3 3l10 10M13 3 3 13"/></svg>
    </button>
    <main class="\(contentClass)">
    \(blocks)
    </main>\(lightbox)
    <footer class="dropper-credit">Shared beautifully with <a href="https://dropper.page" target="_blank" rel="noopener">Dropper</a></footer>
    <script nonce="\(escapedNonce)">
    \(sharePagePlayerScript)
    </script>
    </body>
    </html>
    """
}

/// Encodes text for a quoted HTML attribute. It is intentionally also used for
/// text nodes: the extra quote/control escaping is harmless there and keeps a
/// single, auditable boundary around every value inserted into the template.
func escapeHTML(_ value: String) -> String {
    var escaped = ""
    escaped.reserveCapacity(value.utf8.count)
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x26: escaped += "&amp;"
        case 0x3C: escaped += "&lt;"
        case 0x3E: escaped += "&gt;"
        case 0x22: escaped += "&quot;"
        case 0x27: escaped += "&#39;"
        case 0x00...0x1F, 0x7F: escaped += "&#\(scalar.value);"
        default: escaped.unicodeScalars.append(scalar)
        }
    }
    return escaped
}

/// A manifest path is always a relative object-name value, never a URL. Encode
/// the entire value as one RFC 3986 path segment so `/`, `?`, `#`, quotes, and
/// embedded control characters cannot change URL structure or HTML structure.
func encodedRelativeObjectPath(_ value: String) -> String {
    if value == "." { return "%2E" }
    if value == ".." { return "%2E%2E" }
    var encoded = ""
    encoded.reserveCapacity(value.utf8.count)
    for byte in value.utf8 {
        let unreserved = (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
            || (byte >= 0x30 && byte <= 0x39)
            || byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E
        encoded += unreserved ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
    }
    return encoded
}

private func securePageNonce() -> String {
    ShareNaming.randomHex(byteCount: 16)
}
