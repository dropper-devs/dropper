import Foundation
import ImageIO
import UniformTypeIdentifiers

/// HEIC/HEIF don't render in most non-Apple browsers, so sharing them raw
/// would produce broken pages. Conversion is on by default (Settings toggle).
enum ImageConverter {
    static func isHEIC(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .heic) || type.conforms(to: .heif)
    }

    /// Converts to a temp JPEG; returns nil on any failure (caller falls back
    /// to uploading the original).
    static func jpegCopy(of url: URL, quality: Double = 0.9) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        guard let dest = CGImageDestinationCreateWithURL(
            destURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            try? FileManager.default.removeItem(at: destURL)
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        // Copy the primary image with metadata (orientation) intact.
        CGImageDestinationAddImageFromSource(dest, source, 0, options)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: destURL)
            return nil
        }
        return destURL
    }
}
