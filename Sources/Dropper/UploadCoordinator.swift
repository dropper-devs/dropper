import AppKit
import UniformTypeIdentifiers
import UserNotifications

/// The upload engine: drop preparation (conversions, peaks, thumbnails),
/// sequential PUTs with progress, manifest/page publication, cancellation
/// with cleanup. Owns `busy` — one upload at a time.
@MainActor
final class UploadCoordinator {
    private(set) var busy = false
    private var uploadTask: Task<Void, Never>?
    private let state: UIState

    // Bound by StatusItemController at startup and on settings changes.
    var client: R2Client?
    var store: ShareStore?
    var setIcon: (Double?) -> Void = { _ in }
    var presentPopover: () -> Void = {}
    var notify: (String, String) -> Void = { _, _ in }

    init(state: UIState) {
        self.state = state
    }

    func upload(urls: [URL], into existing: ShareItem?) {
        run(batches: [urls], into: existing)
    }

    /// "Upload new items": every dropped file becomes its own share, run
    /// back-to-back through the same pipeline.
    func uploadSeparately(urls: [URL]) {
        run(batches: urls.map { [$0] }, into: nil)
    }

    struct ShareResult {
        let shareID: String
        let title: String
        let pageURL: String
        let fileURL: String?
    }

    private func run(batches: [[URL]], into existing: ShareItem?) {
        guard !busy, let client, !batches.isEmpty else { return }

        busy = true
        // Existing-share drops keep their collection selected while the
        // bottom strip switches to upload progress. New shares have no row yet.
        state.highlightedID = existing?.id
        state.strip = .uploading(name: "Preparing…", progress: 0)
        presentPopover()
        setIcon(0.001)

        let existingNames = existing.map { Set($0.children.map(\.name)) } ?? []
        uploadTask = Task {
            var completed: [ShareResult] = []
            do {
                for (index, batch) in batches.enumerated() {
                    let prefix = batches.count > 1
                        ? "(\(index + 1)/\(batches.count)) " : ""
                    if let result = try await processShare(
                        client: client, urls: batch, existing: existing,
                        existingNames: existingNames, labelPrefix: prefix,
                        windowBase: Double(index) / Double(batches.count),
                        windowSpan: 1 / Double(batches.count)) {
                        completed.append(result)
                    }
                }
                if completed.isEmpty {
                    await MainActor.run {
                        self.busy = false
                        self.uploadTask = nil
                        self.state.strip = .idle
                        self.setIcon(nil)
                        self.notify("Dropper", "No supported files in that drop.")
                    }
                    return
                }
                let results = completed
                await MainActor.run { self.finish(results: results) }
            } catch {
                let wasCancelled = error.isCancellation
                await MainActor.run {
                    if wasCancelled { self.cancelled() } else { self.fail(error) }
                }
            }
        }
    }

    /// The full pipeline for ONE share: prepare/convert, upload media and
    /// thumbnails, publish manifest + page. Progress maps into the
    /// [windowBase, windowBase + windowSpan] slice of the ring so a batch
    /// reads as one continuous upload. Returns nil when the batch had no
    /// supported files. On cancellation, removes everything THIS share
    /// uploaded (earlier completed shares in the batch stay) and rethrows.
    private func processShare(
        client: R2Client, urls: [URL], existing: ShareItem?,
        existingNames: Set<String>, labelPrefix: String,
        windowBase: Double, windowSpan: Double
    ) async throws -> ShareResult? {
        let show: @Sendable (String, Double) -> Void = { name, fraction in
            let shown = windowBase + fraction * windowSpan
            Task { @MainActor in
                guard self.busy else { return }  // stale after cancel
                self.state.strip = .uploading(name: name, progress: shown)
                self.setIcon(shown)
            }
        }
        // Ring budget within the window: a video conversion, when one runs,
        // owns 0...0.3 and uploads take 0.3...0.95; conversion-free drops
        // keep the full range. The last 5% covers the manifest/page PUTs.
        let prepared = try await Self.prepareFiles(
            urls: urls, existingNames: existingNames) { name, fraction in
            show(labelPrefix + name, fraction * 0.3)
        }
        let files = prepared.files
        guard !files.isEmpty else { return nil }
        defer {
            for file in files where file.isTemporary {
                try? FileManager.default.removeItem(at: file.sourceURL)
            }
        }

        let shareID = existing?.id ?? ShareNaming.shareID(firstFile: files[0].fileName)
        let keys = ShareKeys(id: shareID, config: client.config)
        let totalBytes = max(files.reduce(Int64(0)) { $0 + $1.size }, 1)
        let uploadBase = prepared.convertedVideo ? 0.3 : 0.0
        var sentBytes: Int64 = 0
        var uploadedKeys: [String] = []

        do {
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                let label = files.count == 1 ? file.displayName
                    : "\(file.displayName) (\(index + 1)/\(files.count))"
                let base = sentBytes
                try await client.put(
                    fileURL: file.sourceURL, key: keys.media(file.fileName),
                    contentType: file.contentType,
                    cacheControl: "public, max-age=31536000, immutable"
                ) { fraction in
                    let overall = (Double(base) + fraction * Double(file.size))
                        / Double(totalBytes)
                    show(labelPrefix + label,
                         uploadBase + overall * (0.95 - uploadBase))
                }
                uploadedKeys.append(keys.media(file.fileName))
                sentBytes += file.size
            }
            try Task.checkCancellation()
            // Per-file thumbnails while the files are still local — the
            // one moment previews are cheap to make.
            var posters: [String: String] = [:]
            for file in files where file.kind == .image || file.kind == .video {
                try Task.checkCancellation()
                if let jpeg = await Thumbnailer.jpegThumbnail(
                    of: file.sourceURL, kind: file.kind) {
                    try await client.put(
                        data: jpeg, key: keys.thumb(file.fileName),
                        contentType: "image/jpeg",
                        cacheControl: "public, max-age=31536000, immutable")
                    uploadedKeys.append(keys.thumb(file.fileName))
                }

                guard file.kind == .video else { continue }
                let poster = await VideoPosterGenerator.jpegPoster(of: file.sourceURL)
                try Task.checkCancellation()
                guard let poster else { continue }
                do {
                    try await client.put(
                        data: poster, key: keys.poster(file.fileName),
                        contentType: "image/jpeg",
                        cacheControl: "public, max-age=31536000, immutable")
                    uploadedKeys.append(keys.poster(file.fileName))
                    posters[file.fileName] = keys.posterName(file.fileName)
                } catch {
                    // A cosmetic preview should never sink an otherwise
                    // successful video share. Cancellation still stops the
                    // upload; other failures fall back to the small thumb.
                    if error.isCancellation { throw error }
                    NSLog("Dropper poster upload failed for \(file.fileName): \(error)")
                }
            }
            // Manifest: fresh copy of the target share's (adds), or new.
            var manifest: Manifest
            if let existing {
                manifest = await ShareStore.currentManifest(
                    client: client, config: client.config, item: existing)
            } else {
                manifest = Manifest(items: [], thumb: nil)
            }
            manifest.items += files.map {
                ManifestItem(file: $0.fileName, name: $0.displayName,
                             kind: $0.kind, size: $0.size, peaks: $0.peaks,
                             width: $0.dimensions?.width,
                             height: $0.dimensions?.height,
                             poster: posters[$0.fileName])
            }
            if !posters.isEmpty { manifest.version = 2 }
            try Task.checkCancellation()
            // Shielded from cancellation: manifest and page must land
            // together, or an existing share's manifest could be torn.
            let finalManifest = manifest
            try await Task.detached {
                try await ShareStore.publish(finalManifest, keys: keys, client: client)
            }.value
            let fileURL = finalManifest.items.count == 1 && files.count == 1
                ? keys.mediaURL(files[0].fileName) : nil
            return ShareResult(shareID: shareID, title: finalManifest.title,
                               pageURL: keys.pageURL, fileURL: fileURL)
        } catch {
            if error.isCancellation {
                // User bailed: remove the partial share so nothing orphans.
                for key in uploadedKeys {
                    try? await client.delete(key: key)
                }
            }
            throw error
        }
    }

    func cancel() {
        uploadTask?.cancel()
    }

    private func cancelled() {
        busy = false
        uploadTask = nil
        state.strip = .idle
        setIcon(nil)
    }

    /// Filters a drop to supported media files (no folders), converting HEIC,
    /// AIFF, and non-web-safe video when enabled. Runs off the main thread;
    /// video conversion is the slow one and drives `conversionProgress`
    /// (label, 0...1 per file). Throws only on cancellation.
    nonisolated private static func prepareFiles(
        urls: [URL],
        existingNames: Set<String> = [],
        conversionProgress: @escaping @Sendable (String, Double) -> Void
    ) async throws -> (files: [UploadFile], convertedVideo: Bool) {
        let convertHEIC = ConfigStore.convertHEIC()
        let convertAIFF = ConfigStore.convertAIFF()
        let convertMOV = ConfigStore.convertMOV()
        var sources: [(url: URL, name: String, kind: MediaKind, temp: Bool)] = []
        var convertedVideo = false

        do {
            for url in urls {
                try Task.checkCancellation()
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path,
                                                     isDirectory: &isDirectory),
                      !isDirectory.boolValue else { continue }
                let kind = MediaKind.of(url)

                let stem = url.deletingPathExtension().lastPathComponent
                if kind == .image, convertHEIC, ImageConverter.isHEIC(url),
                   let converted = ImageConverter.jpegCopy(of: url) {
                    sources.append((converted, stem + ".jpg", .image, true))
                } else if kind == .audio, convertAIFF, AudioConverter.isAIFF(url),
                          let converted = AudioConverter.wavCopy(of: url) {
                    sources.append((converted, stem + ".wav", .audio, true))
                } else if kind == .video, convertMOV,
                          let plan = await VideoConverter.conversionPlan(for: url) {
                    convertedVideo = true
                    let label = "Converting \(url.lastPathComponent)…"
                    if let converted = try await VideoConverter.mp4Copy(
                        of: url, plan: plan,
                        progress: { conversionProgress(label, $0) }) {
                        sources.append((converted, stem + ".mp4", .video, true))
                    } else {
                        sources.append((url, url.lastPathComponent, kind, false))
                    }
                } else {
                    sources.append((url, url.lastPathComponent, kind, false))
                }
            }
        } catch {
            // Cancelled mid-preparation: temps made so far never reach the
            // caller's cleanup defer, so remove them here.
            for source in sources where source.temp {
                try? FileManager.default.removeItem(at: source.url)
            }
            throw error
        }

        let fileNames = ShareNaming.sanitizeAll(sources.map(\.name), existing: existingNames)
        var files: [UploadFile] = []
        for (source, fileName) in zip(sources, fileNames) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: source.url.path)
            let size = (attrs?[.size] as? Int64) ?? 0
            let contentType = UTType(filenameExtension: source.url.pathExtension)?
                .preferredMIMEType ?? "application/octet-stream"
            files.append(UploadFile(
                sourceURL: source.url, fileName: fileName,
                displayName: source.name, kind: source.kind,
                contentType: contentType, size: size,
                isTemporary: source.temp,
                peaks: source.kind == .audio
                    ? AudioConverter.peaks(of: source.url) : nil,
                dimensions: source.kind == .video
                    ? await VideoConverter.dimensions(of: source.url) : nil))
        }
        return (files, convertedVideo)
    }

    private func finish(results: [ShareResult]) {
        let pages = results.map(\.pageURL)
        copyToClipboard(pages.joined(separator: "\n"))
        NSSound(named: "Glass")?.play()
        busy = false
        uploadTask = nil
        let name = results.count == 1
            ? results[0].title : "\(results.count) new shares"
        state.strip = .links(name: name, pageURLs: pages,
                             fileURLs: results.compactMap(\.fileURL))
        state.highlightedID = results.count == 1 ? results[0].shareID : nil
        setIcon(nil)
        store?.showingArchive = false  // new uploads land in the main list
        store?.refresh()
        presentPopover()
    }

    private func fail(_ error: Error) {
        busy = false
        uploadTask = nil
        state.strip = .idle
        setIcon(nil)
        NSSound(named: "Basso")?.play()
        notify("Upload failed", error.localizedDescription)
        NSLog("Dropper upload failed: \(error)")
    }
}

private extension Error {
    /// Cancellation arrives two ways: CancellationError from Task checks, and
    /// URLError.cancelled from a URLSession task torn down mid-flight.
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}

@MainActor
func copyToClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

@MainActor
func postNotification(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    ) { _ in }
}
