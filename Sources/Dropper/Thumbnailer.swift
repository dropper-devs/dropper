import Foundation
import AppKit
import QuickLookThumbnailing

/// Renders a small JPEG preview of a local image/video at upload time — the
/// only moment the file is guaranteed to be local, so the list never has to
/// download originals just to draw a row.
enum Thumbnailer {
    static func jpegThumbnail(of url: URL, kind: MediaKind,
                              side: CGFloat = 128) async -> Data? {
        guard kind == .image || kind == .video else { return nil }

        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side),
            scale: 2, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else { return nil }

        let rep = NSBitmapImageRep(cgImage: representation.cgImage)
        return rep.representation(using: .jpeg,
                                  properties: [.compressionFactor: 0.8])
    }
}
