import Foundation
import AVFoundation

/// HEVC/ProRes don't decode in Chrome/Firefox and .mov containers are shaky
/// there too; H.264 in .mp4 plays everywhere. A web-safe codec in a .mov is
/// remuxed (passthrough, lossless); anything else is re-encoded to H.264.
/// Conversion is on by default (Settings toggle).
enum VideoConverter {
    enum Plan { case remux, reencode }

    /// Codecs Chrome and Firefox decode natively.
    private static let webSafeCodecs: Set<FourCharCode> = [
        kCMVideoCodecType_H264,   // 'avc1'
        kCMVideoCodecType_AV1,    // 'av01'
        kCMVideoCodecType_VP9,    // 'vp09'
    ]

    /// nil means upload as-is: a web-safe codec already in an MP4 container,
    /// or no readable video track (audio-only movies stay untouched).
    static func conversionPlan(for url: URL) async -> Plan? {
        guard let codec = await videoCodec(of: url) else { return nil }
        guard webSafeCodecs.contains(codec) else { return .reencode }
        return ["mp4", "m4v"].contains(url.pathExtension.lowercased()) ? nil : .remux
    }

    /// Converts to a temp MP4, reporting 0...1 progress; Task cancellation
    /// maps to cancelExport(). Returns nil on failure (caller falls back to
    /// uploading the original). A failed remux retries as a re-encode — e.g.
    /// PCM audio the MP4 container can't carry passthrough.
    static func mp4Copy(of url: URL, plan: Plan,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> URL? {
        if plan == .remux {
            if let output = try await export(url: url, preset: AVAssetExportPresetPassthrough,
                                             progress: progress) {
                return output
            }
            try Task.checkCancellation()
        }
        return try await export(url: url, preset: AVAssetExportPresetHighestQuality,
                                progress: progress)
    }

    /// Display dimensions (rotation applied), stored in the manifest so the
    /// share page can lay the player out before any metadata loads.
    static func dimensions(of url: URL) async -> (width: Int, height: Int)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let transformed = size.applying(transform)
        let width = Int(abs(transformed.width).rounded())
        let height = Int(abs(transformed.height).rounded())
        return width > 0 && height > 0 ? (width, height) : nil
    }

    // MARK: - Internals

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                     UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08x", code)
    }

    private static func videoCodec(of url: URL) async -> FourCharCode? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let desc = try? await track.load(.formatDescriptions).first
        else { return nil }
        return CMFormatDescriptionGetMediaSubType(desc)
    }

    /// Runs one export session; throws CancellationError on cancellation,
    /// returns nil on any other failure. Partial output is always removed.
    private static func export(url: URL, preset: String,
                               progress: @escaping @Sendable (Double) -> Void) async throws -> URL? {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset)
        else { return nil }
        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")
        session.outputURL = destURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true  // moov atom up front

        let box = ExportSessionBox(session)
        // AVAssetExportSession only exposes progress as a pollable property.
        let poller = Task {
            while !Task.isCancelled {
                progress(box.progress)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { poller.cancel() }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    session.exportAsynchronously {
                        switch box.status {
                        case .completed: cont.resume()
                        case .cancelled: cont.resume(throwing: CancellationError())
                        default: cont.resume(throwing: box.error ?? CocoaError(.fileWriteUnknown))
                        }
                    }
                    box.markStarted()
                }
            } onCancel: {
                box.cancel()
            }
        } catch {
            try? FileManager.default.removeItem(at: destURL)
            if error is CancellationError { throw error }
            NSLog("Dropper video conversion failed (\(preset)): \(error)")
            return nil
        }
        progress(1)
        return destURL
    }
}

/// Bridges Swift Task cancellation to the export session, safe against the
/// cancel racing the export's start (same pattern as R2Client's task box).
/// Also the Sendable wrapper the @Sendable closures read the session through.
private final class ExportSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private let session: AVAssetExportSession
    private var started = false
    private var cancelled = false

    init(_ session: AVAssetExportSession) { self.session = session }

    var status: AVAssetExportSession.Status { session.status }
    var error: Error? { session.error }
    var progress: Double { Double(session.progress) }

    func markStarted() {
        lock.lock()
        started = true
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { session.cancelExport() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let hasStarted = started
        lock.unlock()
        if hasStarted { session.cancelExport() }
    }
}
