import AppKit
import UniformTypeIdentifiers
import UserNotifications

enum UploadPreparationError: LocalizedError {
    case filePreparationFailed(String, String)

    var errorDescription: String? {
        switch self {
        case let .filePreparationFailed(name, reason):
            return "Could not prepare \(name): \(reason)"
        }
    }
}

enum UploadPipelineError: LocalizedError {
    case cleanupFailed([String], String)

    var errorDescription: String? {
        switch self {
        case let .cleanupFailed(keys, reason):
            return "Upload failed and \(keys.count) partial object\(keys.count == 1 ? "" : "s") could not be cleaned up: \(reason)"
        }
    }
}

/// The upload engine: drop preparation (conversions, peaks, thumbnails),
/// sequential PUTs with progress, manifest/page publication, cancellation
/// with cleanup. Owns `busy` — one upload at a time.
@MainActor
final class UploadCoordinator {
    private(set) var busy = false
    private var uploadTask: Task<Void, Never>?
    // The pill drives its own progress and copies the link itself, so its
    // uploads never open the list — they announce with a notification instead.
    private var presentsList = true
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

    func upload(urls: [URL], into existing: ShareItem?, presentsList: Bool = true) {
        run(batches: [urls], into: existing, presentsList: presentsList)
    }

    /// "Upload new items": every dropped file becomes its own share, run
    /// back-to-back through the same pipeline.
    func uploadSeparately(urls: [URL], presentsList: Bool = true) {
        run(batches: urls.map { [$0] }, into: nil, presentsList: presentsList)
    }

    struct ShareResult {
        let shareID: String
        let title: String
        let pageURL: String
        let fileURL: String?
    }

    private func run(batches: [[URL]], into existing: ShareItem?,
                     presentsList: Bool = true) {
        guard !busy, client != nil, let store, !batches.isEmpty else { return }

        busy = true
        self.presentsList = presentsList
        // Existing-share drops keep their collection selected while the
        // bottom strip switches to upload progress. New shares have no row yet.
        state.highlightedID = existing?.id
        state.strip = .uploading(name: "Preparing…", progress: 0)
        if presentsList { presentPopover() }
        setIcon(0.001)

        uploadTask = Task {
            var completed: [ShareResult] = []
            do {
                for (index, batch) in batches.enumerated() {
                    let prefix = batches.count > 1
                        ? "(\(index + 1)/\(batches.count)) " : ""
                    if let result = try await processShare(
                        store: store, urls: batch, existing: existing,
                        labelPrefix: prefix,
                        windowBase: Double(index) / Double(batches.count),
                        windowSpan: 1 / Double(batches.count)) {
                        completed.append(result)
                    }
                }
                if completed.isEmpty {
                    self.resetToIdle()
                    self.notify("Dropper", "No supported files in that drop.")
                    return
                }
                self.finish(results: completed)
            } catch {
                let wasCancelled = error.isCancellation
                if wasCancelled { self.cancelled() } else { self.fail(error) }
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
        store: ShareStore, urls: [URL], existing: ShareItem?, labelPrefix: String,
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
        let progress: @Sendable (String, Double) -> Void = { name, fraction in
            show(labelPrefix + name, fraction * 0.3)
        }

        // Conversion and waveform work run OUTSIDE the share's mutation gate:
        // a long transcode must never block refreshes or other mutations on
        // the target share. Names are re-deduplicated against the manifest
        // inside the gate, where they become final.
        let prepared = try await Self.prepareFiles(
            urls: urls, conversionProgress: progress)
        guard let first = prepared.files.first else { return nil }
        defer { Self.removeTemporaryFiles(prepared.files) }

        if let existing {
            return try await store.withShareMutation(id: existing.id) { client, keys in
                let manifest = try await ShareCatalog.currentManifest(
                    client: client, keys: keys)
                let files = Self.deduplicated(
                    prepared.files, existing: Set(manifest.items.map(\.file)))
                return try await Self.uploadPrepared(
                    (files, prepared.convertedVideo), manifest: manifest,
                    shareID: existing.id, keys: keys, client: client,
                    labelPrefix: labelPrefix, show: show)
            }
        }

        let shareID = ShareNaming.shareID(firstFile: first.fileName)
        let gallery = ConfigStore.imageGallery()
        return try await store.withShareMutation(id: shareID) { client, keys in
            try await Self.uploadPrepared(
                prepared, manifest: Manifest(items: [], gallery: gallery),
                shareID: shareID,
                keys: keys, client: client, labelPrefix: labelPrefix,
                show: show)
        }
    }

    /// Re-deduplicates prepared filenames against an existing share's
    /// manifest. `sanitizeAll` is idempotent on already-sanitized names, so
    /// only genuine collisions pick up a numeric suffix.
    private nonisolated static func deduplicated(
        _ files: [UploadFile], existing: Set<String>
    ) -> [UploadFile] {
        let names = ShareNaming.sanitizeAll(
            files.map(\.fileName),
            existing: existing.union(ShareCatalog.reservedMediaFileNames))
        return zip(files, names).map { file, name in
            var copy = file
            copy.fileName = name
            return copy
        }
    }

    private nonisolated static func uploadPrepared(
        _ prepared: (files: [UploadFile], convertedVideo: Bool),
        manifest baseManifest: Manifest, shareID: String, keys: ShareKeys,
        client: R2Client, labelPrefix: String,
        show: @escaping @Sendable (String, Double) -> Void
    ) async throws -> ShareResult {
        let files = prepared.files
        let totalBytes = max(files.reduce(Int64(0)) { $0 + $1.size }, 1)
        let uploadBase = prepared.convertedVideo ? 0.3 : 0.0
        var sentBytes: Int64 = 0
        var uploadedKeys = Set<String>()
        var publishStarted = false

        do {
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                let label = files.count == 1 ? file.displayName
                    : "\(file.displayName) (\(index + 1)/\(files.count))"
                let base = sentBytes
                let mediaKey = keys.media(file.fileName)
                // Track before PUT: a lost response can still mean R2 stored it.
                uploadedKeys.insert(mediaKey)
                try await client.put(
                    fileURL: file.sourceURL, key: mediaKey,
                    contentType: file.contentType,
                    cacheControl: "public, max-age=31536000, immutable"
                ) { fraction in
                    let overall = (Double(base) + fraction * Double(file.size))
                        / Double(totalBytes)
                    show(labelPrefix + label,
                         uploadBase + overall * (0.95 - uploadBase))
                }
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
                    let thumbKey = keys.thumb(file.fileName)
                    uploadedKeys.insert(thumbKey)
                    try await client.put(
                        data: jpeg, key: thumbKey,
                        contentType: "image/jpeg",
                        cacheControl: "public, max-age=31536000, immutable")
                }

                guard file.kind == .video else { continue }
                let poster = await VideoPosterGenerator.jpegPoster(of: file.sourceURL)
                try Task.checkCancellation()
                guard let poster else { continue }
                let posterKey = keys.poster(file.fileName)
                uploadedKeys.insert(posterKey)
                do {
                    try await client.put(
                        data: poster, key: posterKey,
                        contentType: "image/jpeg",
                        cacheControl: "public, max-age=31536000, immutable")
                    posters[file.fileName] = keys.posterName(file.fileName)
                } catch {
                    // A cosmetic preview must never sink an otherwise
                    // successful video share. Cancellation still stops the
                    // upload; other failures fall back to the small thumb.
                    if error.isCancellation { throw error }
                    try? await client.delete(key: posterKey)
                    uploadedKeys.remove(posterKey)
                    NSLog("Dropper poster upload failed for \(file.fileName): \(error)")
                }
            }
            var manifest = baseManifest
            manifest.items += files.map {
                ManifestItem(file: $0.fileName, name: $0.displayName,
                             kind: $0.kind, size: $0.size, peaks: $0.peaks,
                             width: $0.dimensions?.width,
                             height: $0.dimensions?.height,
                             poster: posters[$0.fileName])
            }
            try Task.checkCancellation()
            publishStarted = true
            try await ShareCatalog.publish(manifest, keys: keys, client: client)
            let fileURL = manifest.items.count == 1 && files.count == 1
                ? keys.mediaURL(files[0].fileName) : nil
            return ShareResult(shareID: shareID, title: manifest.title,
                               pageURL: keys.pageURL, fileURL: fileURL)
        } catch {
            // Before publication starts, every key whose PUT may have reached
            // R2 is removed — the manifest never saw them, so the share stays
            // consistent. Once publication has started, an EXISTING share's
            // manifest may already reference the new media; deleting it would
            // tear the live share, so the objects stay for the next publish.
            // A brand-new share has no prior state to protect: everything it
            // created, including a half-published page or manifest, goes.
            let isNewShare = baseManifest.items.isEmpty
            if publishStarted && !isNewShare { throw error }
            var keysToDelete = uploadedKeys.sorted()
            if publishStarted {
                keysToDelete.append(keys.page)
                keysToDelete.append(keys.manifest)
            }
            // Cleanup itself is shielded from cancellation.
            let failedCleanup = await Task.detached {
                var failed: [String] = []
                for key in keysToDelete {
                    do { try await client.delete(key: key) }
                    catch { failed.append(key) }
                }
                return failed
            }.value
            if !failedCleanup.isEmpty {
                throw UploadPipelineError.cleanupFailed(
                    failedCleanup, error.localizedDescription)
            }
            throw error
        }
    }

    func cancel() {
        uploadTask?.cancel()
    }

    /// Clears in-flight upload state back to idle chrome. Callers add their
    /// own sound/notification.
    private func resetToIdle() {
        busy = false
        uploadTask = nil
        state.strip = .idle
        setIcon(nil)
    }

    private func cancelled() {
        resetToIdle()
    }

    /// Filters a drop to supported media files (no folders), converting HEIC,
    /// AIFF, and non-web-safe video when enabled. Runs off the main thread;
    /// video conversion is the slow one and drives `conversionProgress`
    /// (label, 0...1 per file). Conversions are best-effort: when one fails,
    /// the original file uploads as-is — a drop never dies over a conversion.
    /// Only cancellation stops the pipeline.
    nonisolated static func prepareFiles(
        urls: [URL],
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
                if kind == .image, convertHEIC, ImageConverter.isHEIC(url) {
                    if let converted = ImageConverter.jpegCopy(of: url) {
                        sources.append((converted, stem + ".jpg", .image, true))
                    } else {
                        NSLog("Dropper HEIC conversion failed for \(url.lastPathComponent); uploading the original")
                        sources.append((url, url.lastPathComponent, kind, false))
                    }
                } else if kind == .audio, convertAIFF, AudioConverter.isAIFF(url) {
                    do {
                        let converted = try AudioConverter.wavCopy(of: url)
                        sources.append((converted, stem + ".wav", .audio, true))
                    } catch {
                        if error.isCancellation { throw error }
                        NSLog("Dropper AIFF conversion failed for \(url.lastPathComponent); uploading the original: \(error)")
                        sources.append((url, url.lastPathComponent, kind, false))
                    }
                } else if kind == .video, convertMOV,
                          let plan = await VideoConverter.conversionPlan(for: url) {
                    convertedVideo = true
                    let label = "Converting \(url.lastPathComponent)…"
                    do {
                        if let converted = try await VideoConverter.mp4Copy(
                            of: url, plan: plan,
                            progress: { conversionProgress(label, $0) }) {
                            sources.append((converted, stem + ".mp4", .video, true))
                        } else {
                            NSLog("Dropper video conversion produced no file for \(url.lastPathComponent); uploading the original")
                            sources.append((url, url.lastPathComponent, kind, false))
                        }
                    } catch {
                        if error.isCancellation { throw error }
                        NSLog("Dropper video conversion failed for \(url.lastPathComponent); uploading the original: \(error)")
                        sources.append((url, url.lastPathComponent, kind, false))
                    }
                } else {
                    sources.append((url, url.lastPathComponent, kind, false))
                }
            }

            let fileNames = ShareNaming.sanitizeAll(
                sources.map(\.name),
                existing: ShareCatalog.reservedMediaFileNames)
            var files: [UploadFile] = []
            for (source, fileName) in zip(sources, fileNames) {
                let attrs = try FileManager.default.attributesOfItem(
                    atPath: source.url.path)
                guard let size = (attrs[.size] as? NSNumber)?.int64Value else {
                    throw UploadPreparationError.filePreparationFailed(
                        source.name, "could not determine its size")
                }
                let contentType = UTType(filenameExtension: source.url.pathExtension)?
                    .preferredMIMEType ?? "application/octet-stream"
                files.append(UploadFile(
                    sourceURL: source.url, fileName: fileName,
                    displayName: source.name, kind: source.kind,
                    contentType: contentType, size: size,
                    isTemporary: source.temp,
                    peaks: source.kind == .audio
                        ? try AudioConverter.peaks(of: source.url) : nil,
                    dimensions: source.kind == .video
                        ? await VideoConverter.dimensions(of: source.url) : nil))
            }
            return (files, convertedVideo)
        } catch {
            // This covers conversion and the later metadata phase (including
            // waveform cancellation), before the caller owns a cleanup defer.
            for source in sources where source.temp {
                try? FileManager.default.removeItem(at: source.url)
            }
            throw error
        }
    }

    private nonisolated static func removeTemporaryFiles(_ files: [UploadFile]) {
        for file in files where file.isTemporary {
            try? FileManager.default.removeItem(at: file.sourceURL)
        }
    }

    private func finish(results: [ShareResult]) {
        let pages = results.map(\.pageURL)
        copyToClipboard(pages.joined(separator: "\n"))
        Sounds.drop?.play()
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
        if presentsList {
            presentPopover()
        } else {
            // The pill never opens the list, so the notification is how the
            // user learns the link is already on their clipboard.
            notify("Link copied", name)
        }
    }

    private func fail(_ error: Error) {
        resetToIdle()
        NSSound(named: "Basso")?.play()
        notify("Upload failed", error.localizedDescription)
        NSLog("Dropper upload failed: \(error)")
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
