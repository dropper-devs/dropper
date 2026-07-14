import AppKit
import XCTest
@testable import Dropper

final class VideoPosterSupportTests: XCTestCase {
    private func videoItem(poster: String? = nil) -> ManifestItem {
        ManifestItem(
            file: "demo.mp4", name: "Demo.mp4", kind: .video,
            size: 42, peaks: nil, width: 1_920, height: 1_080,
            poster: poster)
    }

    func testManifestWithoutHighResolutionPosterDecodes() throws {
        let json = #"{"version":2,"items":[{"file":"demo.mp4","name":"Demo.mp4","kind":"video","size":42,"width":1920,"height":1080}]}"#
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))

        XCTAssertEqual(manifest.version, Manifest.currentVersion)
        XCTAssertNil(manifest.items.first?.poster)
    }

    func testManifestVersionIsNotForcedOrRejected() throws {
        let json = #"{"version":1,"items":[]}"#

        let manifest = try JSONDecoder().decode(
            Manifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.version, 1)
    }

    func testPosterSurvivesManifestRoundTrip() throws {
        let manifest = Manifest(
            items: [videoItem(poster: ".poster.demo.mp4.jpg")])
        let decoded = try JSONDecoder().decode(
            Manifest.self, from: JSONEncoder().encode(manifest))

        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.items.first?.poster, ".poster.demo.mp4.jpg")
    }

    func testSharePageUsesHighResolutionPoster() {
        let html = renderShareHTML(
            title: "Demo",
            items: [videoItem(poster: ".poster.demo.mp4.jpg")])

        XCTAssertTrue(html.contains(#"poster=".poster.demo.mp4.jpg""#))
        XCTAssertTrue(html.contains(#"width="1920" height="1080""#))
        XCTAssertTrue(html.contains("aspect-ratio:1920/1080"))
    }

    func testShareWithoutHighResolutionPosterUsesPerFileThumbnailFallback() {
        let html = renderShareHTML(title: "Demo", items: [videoItem()])

        XCTAssertTrue(html.contains(#"poster=".thumb.demo.mp4.jpg""#))
    }

    func testSharePageUsesResponsiveDesktopSideMargins() {
        let html = renderShareHTML(title: "Demo", items: [videoItem()])

        XCTAssertTrue(html.contains("padding: 96px clamp(24px, 8vw, 128px) 32px"))
    }

    func testSharePageCreditsDropperWebsite() {
        let html = renderShareHTML(title: "Demo", items: [videoItem()])

        XCTAssertTrue(html.contains(
            #"Shared beautifully with <a href="https://dropper.page" target="_blank" rel="noopener">Dropper</a>"#))
    }

    func testCollectionItemsUseTripleSpacing() {
        let html = renderShareHTML(
            title: "Collection", items: [videoItem(), videoItem()])

        XCTAssertTrue(html.contains(#"<main class="share-content">"#))
        XCTAssertTrue(html.contains("gap: 84px; width: 100%"))
    }

    func testPosterNamingAndOwnership() {
        let config = AppConfigSnapshot(
            accountID: "account", bucket: "bucket", prefix: "share",
            publicBase: "https://example.com")
        let keys = ShareKeys(id: "demo-123", config: config)
        let manifest = Manifest(
            items: [videoItem(poster: keys.posterName("demo.mp4"))])

        XCTAssertEqual(keys.posterName("demo.mp4"), ".poster.demo.mp4.jpg")
        XCTAssertEqual(keys.poster("demo.mp4"),
                       "share/demo-123/.poster.demo.mp4.jpg")
        XCTAssertTrue(ShareCatalog.ownedKeys(
            keys: keys, manifest: manifest).contains(keys.poster("demo.mp4")))
    }

    func testPosterTransferLimitsRemainBounded() {
        XCTAssertEqual(VideoPosterGenerator.maximumDimension, 1_600)
        XCTAssertEqual(VideoPosterGenerator.maximumByteCount, 750 * 1_024)
    }

    /// Opt-in integration coverage for a real local video. Keeping the file
    /// outside the repository avoids carrying a binary fixture in the app.
    func testRealVideoPosterWhenFixtureIsProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["DROPPER_POSTER_TEST_VIDEO"]
        else { throw XCTSkip("Set DROPPER_POSTER_TEST_VIDEO for integration coverage") }

        let url = URL(fileURLWithPath: path)
        let generated = await VideoPosterGenerator.jpegPoster(of: url)
        let data = try XCTUnwrap(generated)
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        let sourceDimensions = await VideoConverter.dimensions(of: url)
        let source = try XCTUnwrap(sourceDimensions)
        let posterRatio = Double(image.pixelsWide) / Double(image.pixelsHigh)
        let sourceRatio = Double(source.width) / Double(source.height)

        XCTAssertLessThanOrEqual(data.count,
                                 VideoPosterGenerator.maximumByteCount)
        XCTAssertLessThanOrEqual(max(image.pixelsWide, image.pixelsHigh),
                                 Int(VideoPosterGenerator.maximumDimension))
        XCTAssertEqual(posterRatio, sourceRatio, accuracy: 0.02)
    }
}
