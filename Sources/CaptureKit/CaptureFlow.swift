import AppKit

/// Orchestrates capture → markup → PNG, holding the live sessions so the host
/// app only wires two callbacks. Selection is serialized, but any number of
/// completed captures may remain open in independent editors.
@MainActor
public enum CaptureFlow {
    private static var controller: CaptureController?
    private static var editors: [UUID: MarkupWindowController] = [:]

    /// On Upload, delivers the flattened PNG's file URL. The PNG lives in a
    /// Dropper-owned temp folder; stale files (>1 day old) are removed at the
    /// start of the next capture — never mid-flow — so an in-flight upload
    /// can't lose its source file.
    public static func begin(
        mode: CaptureMode,
        onComplete: @escaping (URL) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        guard controller == nil else { return }
        CaptureTempStore.removeStaleFiles()

        let capture = CaptureController()
        controller = capture
        Task { @MainActor in
            defer { controller = nil }
            do {
                guard let result = try await capture.capture(mode: mode) else { return }
                presentMarkup(result, onComplete: onComplete, onFailure: onFailure)
            } catch {
                onFailure(error.localizedDescription)
            }
        }
    }

    private static func presentMarkup(
        _ result: CaptureResult,
        onComplete: @escaping (URL) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        let editorID = UUID()
        var dismissIntro: (() -> Void)?
        let editor = MarkupWindowController(
            image: result.image, scale: result.scale, captureTitle: result.title
        ) { exit in
            dismissIntro?()
            dismissIntro = nil
            editors.removeValue(forKey: editorID)
            switch exit {
            case .cancelled:
                break
            case .upload(let flattened):
                do {
                    onComplete(try CaptureTempStore.writePNG(flattened))
                } catch {
                    onFailure("Could not save the screenshot.")
                }
            case .saveToDesktop(let flattened):
                let desktop = FileManager.default.urls(
                    for: .desktopDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Desktop")
                do {
                    _ = try CaptureTempStore.writePNG(flattened, into: desktop)
                } catch {
                    onFailure("Could not save to the Desktop.")
                }
            }
        }
        editors[editorID] = editor
        // Assemble the editor right where the shot was taken (its own monitor),
        // so the frame builds beneath the lifted capture.
        let captureCenter = CGPoint(x: result.screenRect.midX, y: result.screenRect.midY)
        editor.center(around: captureCenter)
        guard let editorWindow = editor.window else { editor.present(); return }
        dismissIntro = CaptureIntro.play(
            image: result.image, screenRect: result.screenRect,
            isFullScreen: result.isFullScreen,
            finalFrame: editor.canvasScreenFrame(),
            editorWindow: editorWindow
        ) {
            editor.presentGrowing()
        }
    }
}

enum CaptureTempStore {
    static var directory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DropperCaptures", isDirectory: true)
    }

    static func removeStaleFiles() {
        let cutoff = Date().addingTimeInterval(-86_400)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in contents {
            let modified = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Writes "Screenshot <stamp>.png" into `destination` (the capture temp
    /// dir by default; also used for Save to Desktop), dodging collisions.
    static func writePNG(_ image: CGImage, into destination: URL? = nil) throws -> URL {
        let directory = destination ?? self.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: Date())
        var url = directory.appendingPathComponent("Screenshot \(stamp).png")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("Screenshot \(stamp) (\(counter)).png")
            counter += 1
        }
        try MarkupRender.writePNG(image, to: url)
        return url
    }
}
