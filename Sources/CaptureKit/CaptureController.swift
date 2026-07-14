import AppKit
import ScreenCaptureKit

public enum CaptureMode: Sendable {
    case display
    case window
    case area
}

public enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplays
    case captureFailed

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Screen Recording permission is required. Enable Dropper in "
                + "System Settings > Privacy & Security > Screen Recording, then try again."
        case .noDisplays:
            "No displays are available to capture."
        case .captureFailed:
            "Could not capture the screen."
        }
    }
}

public struct CaptureResult {
    public let image: CGImage
    /// Pixels per point of the captured content; the markup editor scales
    /// stroke widths by it so a 3pt stroke stays 3pt on screen.
    public let scale: CGFloat
    /// Human-readable source name shown by the markup editor.
    public let title: String
}

/// Runs one capture: presents the selector UI for the mode (screencam-style
/// overlays for display/area, the system picker for window) and delivers a
/// still at native scale. Returns nil when the user cancels.
@MainActor
public final class CaptureController: NSObject {
    private let displayOverlay = DisplaySelectionOverlay()
    private let areaOverlay = AreaSelectionOverlay()
    private var pickerContinuation: CheckedContinuation<SCContentFilter?, Never>?

    public func capture(mode: CaptureMode) async throws -> CaptureResult? {
        guard Self.requestScreenRecordingAccessIfNeeded() else {
            throw CaptureError.permissionDenied
        }
        switch mode {
        case .display: return try await captureDisplay()
        case .area: return try await captureArea()
        case .window: return try await captureWindow()
        }
    }

    // MARK: - Display

    private func captureDisplay() async throws -> CaptureResult? {
        let targets = Self.displayTargets()
        guard !targets.isEmpty else { throw CaptureError.noDisplays }

        let selected: DisplaySelectionOverlay.Target? = await withCheckedContinuation { continuation in
            displayOverlay.show(
                targets: targets,
                onSelect: { continuation.resume(returning: $0) },
                onCancel: { continuation.resume(returning: nil) })
        }
        guard let target = selected else { return nil }

        let (display, filter) = try await Self.displayFilter(for: target)
        let scale = max(target.screen.backingScaleFactor, 1)
        let configuration = Self.stillConfiguration()
        configuration.width = max(1, Int((CGFloat(display.width) * scale).rounded(.up)))
        configuration.height = max(1, Int((CGFloat(display.height) * scale).rounded(.up)))

        let image = try await Self.captureImage(filter: filter, configuration: configuration)
        return CaptureResult(image: image, scale: scale, title: target.captureTitle)
    }

    // MARK: - Area

    private func captureArea() async throws -> CaptureResult? {
        let targets = Self.displayTargets()
        guard !targets.isEmpty else { throw CaptureError.noDisplays }

        let selected: AreaSelectionOverlay.Selection? = await withCheckedContinuation { continuation in
            areaOverlay.show(
                targets: targets,
                onSelect: { continuation.resume(returning: $0) },
                onCancel: { continuation.resume(returning: nil) })
        }
        guard let selection = selected else { return nil }

        let rect = selection.sourceRect
        guard rect.width >= 1, rect.height >= 1 else { throw CaptureError.captureFailed }

        let (_, filter) = try await Self.displayFilter(for: selection.target)
        let scale = max(selection.target.screen.backingScaleFactor, 1)
        let pixels = AreaSelectionGeometry.pixelSize(for: rect, scale: scale)
        let configuration = Self.stillConfiguration()
        configuration.sourceRect = rect
        configuration.width = Int(pixels.width)
        configuration.height = Int(pixels.height)

        let image = try await Self.captureImage(filter: filter, configuration: configuration)
        return CaptureResult(image: image, scale: scale, title: "Area")
    }

    // MARK: - Window

    private func captureWindow() async throws -> CaptureResult? {
        let picked: SCContentFilter? = await withCheckedContinuation { continuation in
            pickerContinuation = continuation
            let picker = SCContentSharingPicker.shared
            var configuration = SCContentSharingPickerConfiguration()
            configuration.allowedPickerModes = [.singleWindow]
            configuration.allowsChangingSelectedContent = false
            configuration.excludedBundleIDs = ["com.crowdcafe.windowmagnet"]
            picker.defaultConfiguration = configuration
            picker.maximumStreamCount = 1
            picker.isActive = true
            picker.add(self)
            picker.present(using: .window)
        }
        guard let filter = picked else { return nil }

        let info = SCShareableContent.info(for: filter)
        let rect = info.contentRect.isEmpty ? filter.contentRect : info.contentRect
        guard rect.width >= 1, rect.height >= 1 else { throw CaptureError.captureFailed }
        let scale: CGFloat = if info.pointPixelScale > 0 {
            CGFloat(info.pointPixelScale)
        } else if filter.pointPixelScale > 0 {
            CGFloat(filter.pointPixelScale)
        } else {
            NSScreen.main?.backingScaleFactor ?? 2
        }

        let configuration = Self.stillConfiguration()
        configuration.width = max(1, Int((rect.width * scale).rounded(.up)))
        configuration.height = max(1, Int((rect.height * scale).rounded(.up)))

        let title = await Self.capturedWindowTitle(filter: filter, contentRect: rect)
        let image = try await Self.captureImage(filter: filter, configuration: configuration)
        return CaptureResult(image: image, scale: scale, title: title)
    }

    private static func capturedWindowTitle(
        filter: SCContentFilter, contentRect: CGRect
    ) async -> String {
        if #available(macOS 15.2, *) {
            let windowTitle = filter.includedWindows.first?.title?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let windowTitle, !windowTitle.isEmpty { return windowTitle }
            let applicationName = filter.includedApplications.first?.applicationName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let applicationName, !applicationName.isEmpty { return applicationName }
        }

        // macOS 14's picker filter does not expose the selected SCWindow.
        // Match its content rect back to the current shareable-window list.
        if let content = try? await SCShareableContent.current,
           let window = content.windows.min(by: {
               windowMatchScore($0.frame, contentRect) < windowMatchScore($1.frame, contentRect)
           }), windowMatchScore(window.frame, contentRect) <= 24 {
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let title, !title.isEmpty { return title }
            let applicationName = window.owningApplication?.applicationName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let applicationName, !applicationName.isEmpty { return applicationName }
        }
        return "Window"
    }

    private static func windowMatchScore(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }

    private func resolvePicker(with filter: SCContentFilter?) {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
        pickerContinuation?.resume(returning: filter)
        pickerContinuation = nil
    }

    // MARK: - ScreenCaptureKit

    private static func displayTargets() -> [DisplaySelectionOverlay.Target] {
        let screens = NSScreen.screens
        return screens.enumerated().compactMap { index, screen in
            guard let number = screen.deviceDescription[
                      NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  !screen.frame.isEmpty else { return nil }
            let captureTitle = screens.count == 1 ? "Desktop" : "Desktop \(index + 1)"
            return DisplaySelectionOverlay.Target(
                id: CGDirectDisplayID(number.uint32Value),
                screen: screen,
                title: screen.localizedName,
                subtitle: captureTitle,
                captureTitle: captureTitle
            )
        }
    }

    private static func displayFilter(
        for target: DisplaySelectionOverlay.Target
    ) async throws -> (SCDisplay, SCContentFilter) {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == target.id }) else {
            throw CaptureError.captureFailed
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        if #available(macOS 14.2, *) {
            filter.includeMenuBar = true
        }
        return (display, filter)
    }

    private static func stillConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        if #available(macOS 15.0, *) {
            configuration.captureDynamicRange = .SDR
        }
        return configuration
    }

    private static func captureImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let image else {
                    continuation.resume(throwing: CaptureError.captureFailed)
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    private static func requestScreenRecordingAccessIfNeeded() -> Bool {
        guard !CGPreflightScreenCaptureAccess() else { return true }
        return CGRequestScreenCaptureAccess()
    }
}

extension CaptureController: SCContentSharingPickerObserver {
    nonisolated public func contentSharingPicker(
        _ picker: SCContentSharingPicker, didCancelFor stream: SCStream?
    ) {
        Task { @MainActor in self.resolvePicker(with: nil) }
    }

    nonisolated public func contentSharingPicker(
        _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor in self.resolvePicker(with: filter) }
    }

    nonisolated public func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in self.resolvePicker(with: nil) }
    }
}
