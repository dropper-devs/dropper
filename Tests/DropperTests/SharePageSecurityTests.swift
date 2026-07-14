import Foundation
import XCTest
@testable import Dropper

final class SharePageSecurityTests: XCTestCase {
    private let hostileName = "report.x\"\ttabindex=\"0\"\tautofocus\tonfocus=\"alert(1)"

    func testSanitizeCleansTheExtensionAsStrictlyAsTheStem() {
        XCTAssertEqual(
            ShareNaming.sanitize(hostileName),
            "report.x-tabindex-0-autofocus-onfocus-alert-1")
        XCTAssertEqual(ShareNaming.sanitize("Résumé.图像#?.PNG"),
                       "r-sum.png")
        XCTAssertEqual(ShareNaming.sanitize("..."), "file")

        let result = ShareNaming.sanitize(hostileName)
        XCTAssertNotNil(result.range(
            of: #"^[a-z0-9]+(?:-[a-z0-9]+)*(?:\.[a-z0-9]+(?:-[a-z0-9]+)*)?$"#,
            options: .regularExpression))
    }

    func testShareIDSuffixContainsAtLeast128BitsOfRandomness() {
        let first = ShareNaming.shareID(firstFile: "Demo.mov")
        let second = ShareNaming.shareID(firstFile: "Demo.mov")

        XCTAssertNotNil(first.range(of: #"^demo-[0-9a-f]{32}$"#,
                                    options: .regularExpression))
        XCTAssertNotEqual(first, second)
    }

    func testRelativeObjectNamesAreEncodedAsOnePathSegment() {
        XCTAssertEqual(encodedRelativeObjectPath("clip #1?.mp4"),
                       "clip%20%231%3F.mp4")
        XCTAssertEqual(encodedRelativeObjectPath("../outside"), "..%2Foutside")
        XCTAssertEqual(encodedRelativeObjectPath(".."), "%2E%2E")
    }

    func testHostileManifestFilenameCannotInjectMarkup() {
        let item = ManifestItem(
            file: hostileName,
            name: #"Bad <name> & "caption""#,
            kind: .image,
            size: 42,
            peaks: nil,
            width: nil,
            height: nil)
        let html = renderShareHTML(
            title: #"</title><script>alert(1)</script>"#,
            items: [item])
        let encoded = "report.x%22%09tabindex%3D%220%22%09autofocus%09onfocus%3D%22alert%281%29"

        XCTAssertTrue(html.contains(#"src="\#(encoded)""#))
        XCTAssertTrue(html.contains(
            #"id="report.x&quot;&#9;tabindex=&quot;0&quot;&#9;autofocus&#9;onfocus=&quot;alert(1)""#))
        XCTAssertTrue(html.contains(
            #"<title>&lt;/title&gt;&lt;script&gt;alert(1)&lt;/script&gt;</title>"#))
        XCTAssertTrue(html.contains(#"alt="Bad &lt;name&gt; &amp; &quot;caption&quot;""#))
        XCTAssertFalse(html.contains("\ttabindex"))
        XCTAssertFalse(html.contains(#"onfocus="alert(1)"#))
        XCTAssertFalse(html.contains(#"<script>alert(1)</script>"#))
    }

    func testMarkdownDependenciesAreImmutableAndCSPNonceLocked() throws {
        let markdown = ManifestItem(
            file: "notes.md", name: "Notes.md", kind: .markdown,
            size: 100, peaks: nil, width: nil, height: nil)
        let html = renderShareHTML(title: "Notes", items: [markdown])
        let regex = try NSRegularExpression(pattern: #"<script nonce="([0-9a-f]{32})""#)
        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: range)

        XCTAssertEqual(matches.count, 3) // Marked, DOMPurify, and Dropper's script.
        let nonceRange = try XCTUnwrap(Range(matches[0].range(at: 1), in: html))
        let nonce = String(html[nonceRange])
        XCTAssertTrue(html.contains("script-src &#39;nonce-\(nonce)&#39;"))
        XCTAssertTrue(html.contains("script-src-attr &#39;none&#39;"))
        XCTAssertTrue(html.contains("default-src &#39;none&#39;"))
        XCTAssertFalse(html.contains("script-src &#39;unsafe-inline&#39;"))

        XCTAssertTrue(html.contains(
            "https://cdn.jsdelivr.net/npm/marked@12.0.2/marked.min.js"))
        XCTAssertTrue(html.contains(
            "https://cdn.jsdelivr.net/npm/dompurify@3.2.6/dist/purify.min.js"))
        XCTAssertTrue(html.contains(
            "sha384-/TQbtLCAerC3jgaim+N78RZSDYV7ryeoBCVqTuzRrFec2akfBkHS7ACQ3PQhvMVi"))
        XCTAssertTrue(html.contains(
            "sha384-JEyTNhjM6R1ElGoJns4U2Ln4ofPcqzSsynQkmEc/KGy6336qAZl70tDLufbkla+3"))
        XCTAssertFalse(html.contains("marked@12/"))
        XCTAssertFalse(html.contains("dompurify@3/"))
    }

    func testGeneratedPlayersExposeTruthfulAccessibleControls() {
        let video = ManifestItem(
            file: "movie.mp4", name: "Movie.mp4", kind: .video,
            size: 100, peaks: nil, width: 1_920, height: 1_080)
        let audio = ManifestItem(
            file: "song.wav", name: "Song.wav", kind: .audio,
            size: 100, peaks: [10, 50, 100], width: nil, height: nil)
        let html = renderShareHTML(title: "Media", items: [video, audio])

        XCTAssertTrue(html.contains(#"aria-label="Play" aria-pressed="false""#))
        XCTAssertTrue(html.contains(
            "button.setAttribute('aria-label', playing ? 'Pause' : 'Play')"))
        XCTAssertTrue(html.contains(#"class="wave-seek""#))
        XCTAssertTrue(html.contains(#"aria-label="Seek audio""#))
        XCTAssertTrue(html.contains(".wave:focus-within"))
        XCTAssertTrue(html.contains(".seek:focus-visible"))
        XCTAssertFalse(html.contains("wave.addEventListener('click'"))
    }

    func testHTMLEscapingCoversQuotedAttributesAndControls() {
        XCTAssertEqual(escapeHTML("<&>\"'\t\n"),
                       "&lt;&amp;&gt;&quot;&#39;&#9;&#10;")
    }
}
