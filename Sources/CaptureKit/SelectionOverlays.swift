import AppKit
import CoreGraphics
import SwiftUI

// Full-screen pick-a-target overlays, one per display: whole-display capture
// confirms in place; area capture adds a drag-out, movable, resizable
// selection rectangle. Each overlay has exactly one confirm action.

@MainActor
final class DisplaySelectionOverlay {
    struct Target: Identifiable {
        let id: CGDirectDisplayID
        let screen: NSScreen
        let title: String
        let subtitle: String
        let captureTitle: String
    }

    private var windows: [SelectionOverlayWindow] = []
    private var onCancel: (() -> Void)?

    func show(
        targets: [Target],
        onSelect: @escaping (Target) -> Void,
        onCancel: @escaping () -> Void
    ) {
        dismiss()

        self.onCancel = onCancel
        for target in targets {
            let window = makeSelectionOverlayWindow(
                for: target,
                cancelHandler: { [weak self] in self?.cancel() },
                rootView: DisplaySelectionOverlayView(
                    target: target,
                    onCapture: { [weak self] in
                        self?.select(target, onSelect: onSelect)
                    },
                    onCancel: { [weak self] in
                        self?.cancel()
                    }
                )
            )

            window.orderFrontRegardless()
            windows.append(window)
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        windows.last?.makeKey()
    }

    func dismiss() {
        dismissSelectionOverlayWindows(&windows, onCancel: &onCancel)
    }

    private func select(_ target: Target, onSelect: (Target) -> Void) {
        dismiss()
        onSelect(target)
    }

    private func cancel() {
        let cancel = onCancel
        dismiss()
        cancel?()
    }
}

@MainActor
final class AreaSelectionOverlay {
    struct Selection {
        let target: DisplaySelectionOverlay.Target
        let sourceRect: CGRect
        let captureFrame: CGRect
    }

    private var windows: [SelectionOverlayWindow] = []
    private var onCancel: (() -> Void)?

    func show(
        targets: [DisplaySelectionOverlay.Target],
        onSelect: @escaping (Selection) -> Void,
        onCancel: @escaping () -> Void
    ) {
        dismiss()

        self.onCancel = onCancel
        for target in targets {
            let window = makeSelectionOverlayWindow(
                for: target,
                cancelHandler: { [weak self] in self?.cancel() },
                rootView: AreaSelectionOverlayView(
                    target: target,
                    onCapture: { [weak self] rect in
                        self?.select(rect, target: target, onSelect: onSelect)
                    },
                    onCancel: { [weak self] in
                        self?.cancel()
                    }
                )
            )

            window.orderFrontRegardless()
            windows.append(window)
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        windows.last?.makeKey()
    }

    func dismiss() {
        dismissSelectionOverlayWindows(&windows, onCancel: &onCancel)
    }

    private func select(
        _ localRect: CGRect,
        target: DisplaySelectionOverlay.Target,
        onSelect: (Selection) -> Void
    ) {
        let rect = AreaSelectionGeometry.standardizedIntegral(localRect)
        let selection = Selection(
            target: target,
            sourceRect: rect,
            captureFrame: AreaSelectionGeometry.captureFrame(
                forLocalRect: rect, screenFrame: target.screen.frame)
        )
        dismiss()
        onSelect(selection)
    }

    private func cancel() {
        let cancel = onCancel
        dismiss()
        cancel?()
    }
}

private final class SelectionOverlayWindow: NSWindow {
    var cancelHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == KeyCode.escape {
            cancelHandler?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private func makeSelectionOverlayWindow<Content: View>(
    for target: DisplaySelectionOverlay.Target,
    cancelHandler: @escaping () -> Void,
    rootView: Content
) -> SelectionOverlayWindow {
    let window = SelectionOverlayWindow(
        contentRect: target.screen.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.isOpaque = false
    window.backgroundColor = .clear
    window.level = .screenSaver
    window.ignoresMouseEvents = false
    window.hasShadow = false
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    window.isReleasedWhenClosed = false
    window.cancelHandler = cancelHandler

    let hostingView = FirstMouseHostingView(rootView: rootView)
    hostingView.frame = window.contentView?.bounds ?? .zero
    hostingView.autoresizingMask = [.width, .height]
    window.contentView = hostingView

    window.setFrame(target.screen.frame, display: true)
    return window
}

private func dismissSelectionOverlayWindows(
    _ windows: inout [SelectionOverlayWindow],
    onCancel: inout (() -> Void)?
) {
    for window in windows {
        window.orderOut(nil)
        window.contentViewController = nil
        window.contentView = nil
    }
    windows.removeAll()
    onCancel = nil
}

// MARK: - Display overlay view

private struct DisplaySelectionOverlayView: View {
    let target: DisplaySelectionOverlay.Target
    let onCapture: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.40)

            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(Color.white.opacity(0.72), lineWidth: 3)
                .padding(10)

            VStack(spacing: 0) {
                SelectionOverlayHeader(title: target.title, subtitle: target.subtitle, onCancel: onCancel)

                Spacer()

                VStack(spacing: 8) {
                    SelectionOverlayConfirmButton(
                        systemImage: "camera.fill",
                        title: "Capture This Display",
                        action: onCapture
                    )
                    SelectionOverlayCancelLink(action: onCancel)
                }

                Spacer()
            }
        }
    }
}

// MARK: - Shared chrome

private struct SelectionOverlayHeader: View {
    let title: String
    let subtitle: String
    let onCancel: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.68))
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .background(Color.black.opacity(0.42), in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Cancel")
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
    }
}

private struct SelectionOverlayConfirmButton: View {
    let systemImage: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))

                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(
                            colors: [
                                Color(red: 0.66, green: 0.53, blue: 1.00),
                                Color(red: 0.51, green: 0.36, blue: 0.95),
                                Color(red: 0.38, green: 0.25, blue: 0.78),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(red: 0.22, green: 0.13, blue: 0.44), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.50), radius: 2, x: 0, y: 1)
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .keyboardShortcut(.defaultAction)
    }
}

private struct SelectionOverlayCancelLink: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Cancel")
                .font(.system(size: 13, weight: .semibold))
                .underline()
                .foregroundStyle(Color.white.opacity(0.82))
                .frame(height: 22)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Cancel")
    }
}

// MARK: - Area geometry

private enum AreaSelectionInteraction: Equatable {
    case creating
    case moving
    case resizing(AreaResizeHandle)
}

enum AreaResizeHandle: CaseIterable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left

    var adjustsLeft: Bool {
        self == .topLeft || self == .bottomLeft || self == .left
    }

    var adjustsRight: Bool {
        self == .topRight || self == .bottomRight || self == .right
    }

    var adjustsTop: Bool {
        self == .topLeft || self == .topRight || self == .top
    }

    var adjustsBottom: Bool {
        self == .bottomLeft || self == .bottomRight || self == .bottom
    }

    var size: CGSize {
        switch self {
        case .top, .bottom:
            CGSize(width: 34, height: 8)
        case .left, .right:
            CGSize(width: 8, height: 34)
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            CGSize(width: 12, height: 12)
        }
    }

    func position(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:
            CGPoint(x: rect.minX, y: rect.minY)
        case .top:
            CGPoint(x: rect.midX, y: rect.minY)
        case .topRight:
            CGPoint(x: rect.maxX, y: rect.minY)
        case .right:
            CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight:
            CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom:
            CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft:
            CGPoint(x: rect.minX, y: rect.maxY)
        case .left:
            CGPoint(x: rect.minX, y: rect.midY)
        }
    }
}

enum AreaSelectionGeometry {
    static let minimumSelectionSize = CGSize(width: 96, height: 72)
    static let actionStackHeight: CGFloat = 66
    static let actionStackSelectionGap: CGFloat = 23

    static func standardizedIntegral(_ rect: CGRect) -> CGRect {
        rect.standardized.integral
    }

    static func pixelSize(for rect: CGRect, scale: CGFloat) -> CGSize {
        let integral = standardizedIntegral(rect)
        let scale = max(scale, 1)
        return CGSize(
            width: max(1, (integral.width * scale).rounded(.up)),
            height: max(1, (integral.height * scale).rounded(.up))
        )
    }

    static func dimensionText(for rect: CGRect, scale: CGFloat) -> String {
        let size = pixelSize(for: rect, scale: scale)
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    static func captureFrame(forLocalRect localRect: CGRect, screenFrame: CGRect) -> CGRect {
        let rect = standardizedIntegral(localRect)
        return CGRect(
            x: screenFrame.minX + rect.minX,
            y: screenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func rect(from first: CGPoint, to second: CGPoint) -> CGRect {
        CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(first.x - second.x),
            height: abs(first.y - second.y)
        )
    }

    static func clamped(_ rect: CGRect, in size: CGSize) -> CGRect {
        let normalized = rect.standardized
        let minX = min(max(0, normalized.minX), size.width)
        let minY = min(max(0, normalized.minY), size.height)
        let maxX = min(max(0, normalized.maxX), size.width)
        let maxY = min(max(0, normalized.maxY), size.height)

        return CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: abs(maxX - minX),
            height: abs(maxY - minY)
        )
    }

    static func moved(_ rect: CGRect, by translation: CGSize, in size: CGSize) -> CGRect {
        let x = min(max(0, rect.minX + translation.width), max(0, size.width - rect.width))
        let y = min(max(0, rect.minY + translation.height), max(0, size.height - rect.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: rect.size)
    }

    static func resized(
        _ rect: CGRect,
        handle: AreaResizeHandle,
        by translation: CGSize,
        in size: CGSize
    ) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        if handle.adjustsLeft {
            minX += translation.width
        }
        if handle.adjustsRight {
            maxX += translation.width
        }
        if handle.adjustsTop {
            minY += translation.height
        }
        if handle.adjustsBottom {
            maxY += translation.height
        }

        minX = min(max(0, minX), size.width)
        maxX = min(max(0, maxX), size.width)
        minY = min(max(0, minY), size.height)
        maxY = min(max(0, maxY), size.height)

        if maxX - minX < minimumSelectionSize.width {
            if handle.adjustsLeft {
                minX = max(0, maxX - minimumSelectionSize.width)
            } else {
                maxX = min(size.width, minX + minimumSelectionSize.width)
            }
        }

        if maxY - minY < minimumSelectionSize.height {
            if handle.adjustsTop {
                minY = max(0, maxY - minimumSelectionSize.height)
            } else {
                maxY = min(size.height, minY + minimumSelectionSize.height)
            }
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func isValidSelection(_ rect: CGRect) -> Bool {
        rect.width >= minimumSelectionSize.width && rect.height >= minimumSelectionSize.height
    }

    static func actionStackPosition(for rect: CGRect, in size: CGSize) -> CGPoint {
        let halfHeight = actionStackHeight / 2
        let preferredY = rect.maxY + actionStackSelectionGap + halfHeight
        let fallbackY = rect.minY - actionStackSelectionGap - halfHeight
        let y = preferredY <= size.height - halfHeight - 12
            ? preferredY
            : max(halfHeight + 12, fallbackY)
        return CGPoint(
            x: min(max(rect.midX, 95), size.width - 95),
            y: y
        )
    }
}

// MARK: - Area overlay view

private struct AreaSelectionOverlayView: View {
    let target: DisplaySelectionOverlay.Target
    let onCapture: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var selectionRect: CGRect?
    @State private var interaction: AreaSelectionInteraction?
    @State private var dragStart: CGPoint?
    @State private var interactionStartRect: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let canvasSize = proxy.size

            ZStack {
                Color.black.opacity(0.38)
                    .gesture(createGesture(in: canvasSize))

                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Color.white.opacity(0.54), lineWidth: 2)
                    .padding(10)

                if let selectionRect {
                    selectionView(selectionRect, canvasSize: canvasSize)
                } else {
                    instructionView
                        .allowsHitTesting(false)
                }

                VStack(spacing: 0) {
                    SelectionOverlayHeader(title: "Select Area", subtitle: target.title, onCancel: onCancel)
                    Spacer()
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
        }
    }

    private var instructionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 28, weight: .semibold))
            Text("Drag to Select an Area")
                .font(.system(size: 20, weight: .bold))
            Text("Resize using the edges or corner handles, then capture the selected area.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.70))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(Color.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
    }

    private func selectionView(_ rect: CGRect, canvasSize: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.clear)
                .frame(width: rect.width, height: rect.height)
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                }
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .position(x: rect.midX, y: rect.midY)
                .gesture(moveGesture(in: canvasSize))

            ForEach(AreaResizeHandle.allCases, id: \.self) { handle in
                handleView(handle)
                    .position(handle.position(in: rect))
                    .gesture(resizeGesture(handle, in: canvasSize))
            }

            Text(AreaSelectionGeometry.dimensionText(
                for: rect, scale: target.screen.backingScaleFactor
            ))
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color.black.opacity(0.68), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            }
            .position(
                x: min(max(rect.midX, 64), canvasSize.width - 64),
                y: min(rect.maxY - 14, rect.minY + 18)
            )
            .allowsHitTesting(false)

            VStack(spacing: 6) {
                SelectionOverlayConfirmButton(
                    systemImage: "camera.fill",
                    title: "Capture This Area"
                ) { onCapture(rect) }
                SelectionOverlayCancelLink(action: onCancel)
            }
            .position(AreaSelectionGeometry.actionStackPosition(for: rect, in: canvasSize))
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    private func handleView(_ handle: AreaResizeHandle) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.white)
            .frame(width: handle.size.width, height: handle.size.height)
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.24), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.26), radius: 4, x: 0, y: 1)
    }

    private func createGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if interaction == nil {
                    if selectionRect?.insetBy(dx: -10, dy: -10).contains(value.startLocation) == true {
                        return
                    }
                    interaction = .creating
                    dragStart = value.startLocation
                }

                guard interaction == .creating, let dragStart else { return }
                selectionRect = AreaSelectionGeometry.clamped(
                    AreaSelectionGeometry.rect(from: dragStart, to: value.location),
                    in: size
                )
            }
            .onEnded { _ in
                if let rect = selectionRect,
                   !AreaSelectionGeometry.isValidSelection(rect) {
                    selectionRect = nil
                }
                resetInteraction()
            }
    }

    private func moveGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if interaction == nil {
                    interaction = .moving
                    interactionStartRect = selectionRect
                }

                guard interaction == .moving, let startRect = interactionStartRect else { return }
                selectionRect = AreaSelectionGeometry.moved(startRect, by: value.translation, in: size)
            }
            .onEnded { _ in
                resetInteraction()
            }
    }

    private func resizeGesture(_ handle: AreaResizeHandle, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if interaction == nil {
                    interaction = .resizing(handle)
                    interactionStartRect = selectionRect
                }

                guard interaction == .resizing(handle),
                      let startRect = interactionStartRect else { return }
                selectionRect = AreaSelectionGeometry.resized(
                    startRect,
                    handle: handle,
                    by: value.translation,
                    in: size
                )
            }
            .onEnded { _ in
                resetInteraction()
            }
    }

    private func resetInteraction() {
        interaction = nil
        dragStart = nil
        interactionStartRect = nil
    }
}
