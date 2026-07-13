import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// AIFF doesn't play in Chrome/Firefox; WAV plays everywhere. This is a
/// lossless PCM repack (same samples, same depth), not a re-encode.
enum AudioConverter {
    static func isAIFF(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .aiff)
    }

    /// Downsamples the file to `count` normalized peak values (0...100) for
    /// the share page's waveform. Streams the PCM; never loads it whole.
    static func peaks(of url: URL, count: Int = 200) -> [Int]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let totalFrames = Int(file.length)
        guard totalFrames > 0 else { return nil }
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 131072
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: chunk) else { return nil }

        var maxes = [Float](repeating: 0, count: count)
        var frameIndex = 0
        while file.framePosition < file.length {
            guard (try? file.read(into: buffer, frameCount: chunk)) != nil,
                  buffer.frameLength > 0,
                  let data = buffer.floatChannelData else { break }
            let frames = Int(buffer.frameLength)
            let channels = Int(format.channelCount)
            for f in 0..<frames {
                var m: Float = 0
                for c in 0..<channels {
                    m = max(m, abs(data[c][f]))
                }
                let bucket = min((frameIndex + f) * count / totalFrames, count - 1)
                if m > maxes[bucket] { maxes[bucket] = m }
            }
            frameIndex += frames
        }

        guard let top = maxes.max(), top > 0 else { return nil }
        return maxes.map { Int(($0 / top * 100).rounded()) }
    }

    /// Converts to a temp WAV; returns nil on any failure (caller falls back
    /// to uploading the original).
    static func wavCopy(of url: URL) -> URL? {
        do {
            let input = try AVAudioFile(forReading: url)
            let sourceSettings = input.fileFormat.settings
            let bitDepth = (sourceSettings[AVLinearPCMBitDepthKey] as? Int) ?? 16

            let destURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: input.fileFormat.sampleRate,
                AVNumberOfChannelsKey: input.fileFormat.channelCount,
                AVLinearPCMBitDepthKey: [16, 24, 32].contains(bitDepth) ? bitDepth : 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let output = try AVAudioFile(forWriting: destURL, settings: settings,
                                         commonFormat: .pcmFormatFloat32,
                                         interleaved: false)

            let chunk: AVAudioFrameCount = 65536
            guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                                frameCapacity: chunk) else { return nil }
            while input.framePosition < input.length {
                try input.read(into: buffer, frameCount: chunk)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
            }
            return destURL
        } catch {
            NSLog("Dropper AIFF conversion failed: \(error)")
            return nil
        }
    }
}
