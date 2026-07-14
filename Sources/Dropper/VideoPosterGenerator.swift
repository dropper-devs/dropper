import AppKit
import AVFoundation
import CoreGraphics
import Foundation

/// Creates a web-sized poster from a local video while it is available during
/// upload. The preferred track transform is applied, so portrait and rotated
/// videos keep their displayed orientation and original aspect ratio.
enum VideoPosterGenerator {
    static let maximumDimension: CGFloat = 1_600
    static let maximumByteCount = 750 * 1_024

    /// Returns a JPEG poster no larger than `maximumByteCount`, or nil when the
    /// video has no readable frame. The first candidate is near the beginning
    /// without using a commonly-black opening frame; later frames are tried
    /// when that candidate is effectively black.
    static func jpegPoster(of url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let durationSeconds = duration.seconds
        guard durationSeconds.isFinite, durationSeconds > 0 else { return nil }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumDimension,
                                       height: maximumDimension)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var brightestDarkFrame: (image: CGImage, luminance: Double)?
        for seconds in candidateTimes(duration: durationSeconds) {
            if Task.isCancelled {
                generator.cancelAllCGImageGeneration()
                return nil
            }

            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let result = try? await generator.image(at: time) else {
                continue
            }
            let image = result.image
            let luminance = averageLuminance(of: image)
            if !isNearBlack(luminance) {
                return jpegWithinLimit(image)
            }
            if luminance > (brightestDarkFrame?.luminance ?? -.infinity) {
                brightestDarkFrame = (image, luminance)
            }
        }

        // A genuinely dark video still deserves a poster; use the most
        // legible frame found rather than discarding it altogether.
        return brightestDarkFrame.flatMap { jpegWithinLimit($0.image) }
    }

    // MARK: - Frame selection

    private static func candidateTimes(duration: Double) -> [Double] {
        let endInset = min(0.1, duration * 0.02)
        let latest = max(duration - endInset, 0)
        let primary: Double
        if duration <= 2 {
            primary = duration * 0.5
        } else {
            primary = min(max(duration * 0.1, 1), 5)
        }

        // Later candidates are only decoded when the preceding frame is
        // nearly black. Fractions work for both brief clips and long videos.
        let retryDelay = min(1, max(duration * 0.1, 0.1))
        let raw = [
            min(primary, latest),
            max(primary + retryDelay, duration * 0.25),
            max(primary + retryDelay * 2, duration * 0.5),
            max(primary + retryDelay * 3, duration * 0.75),
        ]

        var result: [Double] = []
        for value in raw {
            let clipped = min(max(value, 0), latest)
            guard result.allSatisfy({ abs($0 - clipped) > 0.05 }) else {
                continue
            }
            result.append(clipped)
        }
        return result
    }

    /// Samples a tiny rendering; its only job is to reject empty/black intro
    /// frames, so decoding the full image pixel-by-pixel is unnecessary.
    private static func averageLuminance(of image: CGImage) -> Double {
        let side = 32
        let bytesPerRow = side * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * side)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return 1
        }

        let created = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: side,
                    height: side,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0,
                                           width: side, height: side))
            return true
        }
        guard created else { return 1 }

        var total = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[offset]) / 255
            let green = Double(pixels[offset + 1]) / 255
            let blue = Double(pixels[offset + 2]) / 255
            total += red * 0.2126 + green * 0.7152 + blue * 0.0722
        }
        return total / Double(side * side)
    }

    private static func isNearBlack(_ luminance: Double) -> Bool {
        luminance < 0.045
    }

    // MARK: - Encoding

    private static func jpegWithinLimit(_ source: CGImage) -> Data? {
        var image = scaled(source, longestEdgeAtMost: maximumDimension) ?? source

        // Most frames fit on the first pass. If not, find the highest quality
        // that fits before reducing dimensions; quality below 0.60 generally
        // looks worse than a modest proportional downscale.
        for _ in 0..<4 {
            guard let fullQuality = jpeg(image, quality: 0.82) else { return nil }
            if fullQuality.count <= maximumByteCount { return fullQuality }

            guard let qualityFloor = jpeg(image, quality: 0.60) else { return nil }
            if qualityFloor.count <= maximumByteCount {
                var lower: CGFloat = 0.60
                var upper: CGFloat = 0.82
                var best = qualityFloor
                for _ in 0..<6 {
                    let quality = (lower + upper) / 2
                    guard let candidate = jpeg(image, quality: quality) else {
                        break
                    }
                    if candidate.count <= maximumByteCount {
                        best = candidate
                        lower = quality
                    } else {
                        upper = quality
                    }
                }
                return best
            }

            let ratio = sqrt(CGFloat(maximumByteCount)
                             / CGFloat(fullQuality.count)) * 0.94
            let scale = min(0.9, max(0.5, ratio))
            let nextLongestEdge = CGFloat(max(image.width, image.height)) * scale
            guard let smaller = scaled(image,
                                       longestEdgeAtMost: nextLongestEdge),
                  smaller.width < image.width || smaller.height < image.height
            else { return nil }
            image = smaller
        }

        // The loop normally returns well before this point. Retain the hard
        // transfer-size guarantee if an unusually noisy frame reaches it.
        guard let fallback = jpeg(image, quality: 0.55),
              fallback.count <= maximumByteCount else { return nil }
        return fallback
    }

    private static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg,
            properties: [.compressionFactor: quality]
        )
    }

    private static func scaled(_ image: CGImage,
                               longestEdgeAtMost limit: CGFloat) -> CGImage? {
        let longestEdge = CGFloat(max(image.width, image.height))
        guard longestEdge > limit else { return image }

        let ratio = limit / longestEdge
        let width = max(1, Int((CGFloat(image.width) * ratio).rounded()))
        let height = max(1, Int((CGFloat(image.height) * ratio).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: width, height: height))
        return context.makeImage()
    }
}
