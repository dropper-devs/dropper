import AppKit
import CaptureKit
import SwiftUI
import UniformTypeIdentifiers

/// Stable callbacks the drop pill needs. Unlike `PopoverActions` none of these
/// depend on the store, so the pill is wired once and survives client rebuilds.
struct DropPillActions {
    var dropped: ([URL]) -> Void
    var droppedSeparately: ([URL]) -> Void
    var copy: (String) -> Void
    var open: (String) -> Void
    var cancelUpload: () -> Void
    var capture: (CaptureMode) -> Void
    var isListOpen: () -> Bool   // the popover owns its own links; don't revert those
}

/// An always-visible pill hanging just below the menu bar: drop files onto it
/// to upload, watch progress, then copy the link. A floating companion to the
/// menu-bar icon's own drop target, driven by the same shared `UIState`.
@MainActor
final class DropPillController: NSObject {
    // Fixed so the drop target never moves mid-drag — every state swaps its
    // content inside these bounds. Generous enough that the pill's shadow has
    // clear room on every side and never clips against the window's edge.
    static let size = NSSize(width: 380, height: 132)
    private static let originKey = "DropPillOrigin"
    private let panel: NSPanel
    private var lastMoveTime: TimeInterval = 0

    /// True right after the pill was dragged, so a click that lands at the end
    /// of a drag-to-move doesn't get treated as a capture-button press.
    var wasJustDragged: Bool {
        ProcessInfo.processInfo.systemUptime - lastMoveTime < 0.3
    }

    init(state: UIState, actions: DropPillActions) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false               // the pill draws its own shadow
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true  // drag it anywhere on the desktop
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // A hosting *controller* (not a raw NSHostingView) is what reliably
        // drives SwiftUI animations for a window's content — same as the
        // popover. sizingOptions [] leaves the fixed panel to own its size.
        let host = NSHostingController(
            rootView: DropPillView(state: state, actions: actions))
        host.sizingOptions = []
        panel.contentViewController = host

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowMoved),
                           name: NSWindow.didMoveNotification, object: panel)
        center.addObserver(self, selector: #selector(screensChanged),
                           name: NSApplication.didChangeScreenParametersNotification,
                           object: nil)
    }

    func show() {
        placeInitially()
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    /// Restores the user's chosen spot, or defaults to just below the menu bar.
    private func placeInitially() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let origin = Self.savedOrigin() ?? NSPoint(
            x: screen.frame.midX - Self.size.width / 2,
            y: visible.maxY - Self.size.height)
        panel.setFrame(Self.clamp(NSRect(origin: origin, size: Self.size), to: visible),
                       display: true)
    }

    /// Keeps the pill on-screen when the display arrangement changes — without
    /// yanking it back to center, since its position is the user's to choose.
    @objc private func screensChanged() {
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        panel.setFrame(Self.clamp(panel.frame, to: visible), display: true)
    }

    @objc private func windowMoved() {
        lastMoveTime = ProcessInfo.processInfo.systemUptime
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin),
                                  forKey: Self.originKey)
    }

    private static func savedOrigin() -> NSPoint? {
        guard let string = UserDefaults.standard.string(forKey: originKey) else { return nil }
        return NSPointFromString(string)
    }

    private static func clamp(_ frame: NSRect, to visible: NSRect) -> NSRect {
        var f = frame
        f.origin.x = min(max(f.origin.x, visible.minX),
                         max(visible.minX, visible.maxX - f.width))
        f.origin.y = min(max(f.origin.y, visible.minY),
                         max(visible.minY, visible.maxY - f.height))
        return f
    }
}

/// The pill's face. Mirrors the bottom strip's states — idle, drop target,
/// collection/items split, upload progress, and finished links — in a compact
/// floating capsule.
struct DropPillView: View {
    @ObservedObject var state: UIState
    let actions: DropPillActions

    @State private var dragCount = 0        // files hovering the pill
    @State private var separateSide = false // pointer over the right half
    @State private var pillWidth: CGFloat = DropPillController.size.width
    @State private var cancelHover = false
    @State private var hovering = false      // pointer resting over the pill
    @State private var hoveredSegment: Int?  // which capture segment the pointer is over
    @State private var revertWork: DispatchWorkItem?

    private var dragging: Bool { dragCount > 0 }
    private static let revertDelay: TimeInterval = 3
    /// Apple's spring vocabulary (WWDC "Animate with springs"): describe the
    /// motion by duration + bounce, not a raw damping ratio. A snappy spring
    /// with a slight overshoot is exactly the Dynamic Island's morph feel.
    private static let morph = Animation.spring(duration: 0.4, bounce: 0.2)

    /// One id per distinct visual state; changing it drives the blur-morph
    /// between states. Progress ticks keep the same id and update in place.
    private var visualKey: Int {
        switch state.strip {
        case .uploading: return 1
        case .links: return dragging ? (dragCount > 1 ? 3 : 2) : (hovering ? 5 : 4)
        case .idle: return dragging ? (dragCount > 1 ? 3 : 2) : (hovering ? 6 : 0)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            pill
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .contentShape(Rectangle())
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { pillWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, width in pillWidth = width }
        })
        // A background panel never becomes key, so an AppKit .activeAlways
        // tracking area is the reliable way to know the pointer is resting here.
        // Every state change is driven from an AppKit callback (hover tracker,
        // drop delegate) — so each must open its own animation transaction with
        // withAnimation; an implicit .animation modifier alone won't fire here.
        .background(HoverTracking { inside in
            withAnimation(Self.morph) { hovering = inside }
        })
        .onDrop(of: [.fileURL], delegate: StripDropDelegate(
            midX: { pillWidth / 2 },
            update: { count, right in
                withAnimation(Self.morph) {
                    dragCount = count
                    separateSide = right
                }
            },
            exit: { withAnimation(Self.morph) { dragCount = 0 } },
            perform: { separate, providers in
                performDrop(separate: separate, providers: providers)
            }))
        .onChange(of: state.strip) { _, _ in
            dragCount = 0
            scheduleRevert()
        }
        .onChange(of: hovering) { _, isHovering in
            if !isHovering { hoveredSegment = nil }
            scheduleRevert()
        }
        .animation(Self.morph, value: visualKey)
        .animation(.easeOut(duration: 0.15), value: separateSide)
    }

    /// After a quiet pill upload the finished link lingers, then fades back to
    /// idle — held open while the pointer rests on the pill, so hovering to
    /// grab a button never pulls it out from under the user. The list flow's
    /// links are left alone; the popover clears those when it closes.
    private func scheduleRevert() {
        revertWork?.cancel()
        revertWork = nil
        guard case .links = state.strip, !hovering, !actions.isListOpen() else { return }
        let work = DispatchWorkItem {
            if case .links = state.strip, !actions.isListOpen() {
                withAnimation(Self.morph) { state.strip = .idle }
            }
        }
        revertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revertDelay, execute: work)
    }

    private func performDrop(separate: Bool, providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        dragCount = 0
        loadFileURLs(from: providers) { urls in
            guard !urls.isEmpty else { return }
            if separate, urls.count > 1 {
                actions.droppedSeparately(urls)
            } else {
                actions.dropped(urls)
            }
        }
        return true
    }

    // MARK: - Pill chrome

    /// The pill's explicit size per state. SwiftUI reliably animates an
    /// EXPLICIT frame (the way the diagnostic scaleEffect animated); it does
    /// NOT animate an intrinsic layout-size change. So the morph is driven by
    /// interpolating these sizes, with the content crossfading inside.
    private var pillSize: CGSize {
        switch visualKey {
        case 6: return CGSize(width: 320, height: 72)   // capture launcher
        case 2: return CGSize(width: 300, height: 82)   // drop target
        case 3: return CGSize(width: 344, height: 90)   // collection / items split
        case 1: return CGSize(width: 300, height: 64)   // uploading
        case 4: return CGSize(width: 188, height: 46)   // done, at rest
        case 5: return CGSize(width: 340, height: 74)   // done, hovered
        default: return CGSize(width: 58, height: 32)   // idle — small, just the droplet
        }
    }

    private var pill: some View {
        // A capsule at EVERY size: the pill only ever grows into a larger pill,
        // it never becomes a plain rounded rectangle.
        let shape = Capsule()
        // The size frame MUST sit on a stably-identified view (this ZStack), not
        // on `content` — `content` is a switch whose view type changes per state,
        // and SwiftUI won't interpolate a frame across an identity change (it just
        // snaps). On the stable ZStack the frame interpolates, so the capsule
        // itself morphs from one size to the next while the content emerges.
        return ZStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
        .frame(width: pillSize.width, height: pillSize.height)
        .background(pillSurface)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 7)
        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        // The pill is always black, so render its contents dark-mode
        // regardless of the system theme — keeps text legible on black.
        .environment(\.colorScheme, .dark)
    }

    /// Not flat black — a whisper of top-down lift plus a hairline top sheen, so
    /// the pill reads like a physical object the way Apple's HUDs do.
    private var pillSurface: some View {
        ZStack {
            Color.black
            LinearGradient(
                colors: [.white.opacity(0.06), .clear],
                startPoint: .top, endPoint: .center)
        }
    }

    @ViewBuilder private var content: some View {
        switch state.strip {
        case let .uploading(name, progress):
            uploadingContent(name: name, progress: progress)
        case let .links(name, pageURLs, fileURLs):
            if dragging { dropContent }
            else { doneContent(name: name, pageURLs: pageURLs, fileURLs: fileURLs) }
        case .idle:
            if dragging { dropContent } else { idleContent }
        }
    }

    // MARK: - States

    /// At rest, an invitation to drop. Hovering turns the idle pill into a
    /// capture launcher — the same window/area/screen flow as the menu.
    @ViewBuilder private var idleContent: some View {
        if hovering {
            // A segmented capture launcher: the outer segments' outer corners
            // round to ~half the segment height, so they hug the pill's capsule
            // ends; the middle one stays lightly rounded. A single position
            // tracker drives the highlight so it can never get stuck.
            let outer: CGFloat = 30, inner: CGFloat = 6
            HStack(spacing: 4) {
                CaptureSegment(label: "Window", icon: "macwindow",
                               corners: .init(topLeading: outer, bottomLeading: outer,
                                              bottomTrailing: inner, topTrailing: inner),
                               highlighted: hoveredSegment == 0) { actions.capture(.window) }
                CaptureSegment(label: "Area", icon: "rectangle.dashed",
                               corners: .init(topLeading: inner, bottomLeading: inner,
                                              bottomTrailing: inner, topTrailing: inner),
                               highlighted: hoveredSegment == 1) { actions.capture(.area) }
                CaptureSegment(label: "Screen", icon: "display",
                               corners: .init(topLeading: inner, bottomLeading: inner,
                                              bottomTrailing: outer, topTrailing: outer),
                               highlighted: hoveredSegment == 2) { actions.capture(.display) }
            }
            .padding(6)
            .background(SegmentHoverTracker(count: 3) { hoveredSegment = $0 })
        } else {
            // At rest: a very small black pill with just the droplet at its left.
            Image(systemName: "drop.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 15)
        }
    }

    /// One unambiguous target for a single file; the collection/items split
    /// once two or more files are in the drag.
    @ViewBuilder private var dropContent: some View {
        if dragCount > 1 {
            HStack(spacing: 9) {
                splitZone("Upload collection",
                          icon: "rectangle.stack.badge.plus", active: !separateSide)
                splitZone("Upload \(dragCount) new items",
                          icon: "square.on.square", active: separateSide)
            }
            .padding(10)
        } else {
            HStack(spacing: 9) {
                Image(systemName: "arrow.down.doc").font(.system(size: 15))
                Text("Drop to upload").font(.system(size: 13.5, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(dropCard)
            .padding(10)
        }
    }

    private var dropCard: some View {
        let shape = Capsule()
        return shape.fill(Color.accentColor.opacity(0.10))
            .overlay(shape.strokeBorder(
                style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundStyle(Color.accentColor.opacity(0.65)))
    }

    private func uploadingContent(name: String, progress: Double) -> some View {
        HStack(spacing: 13) {
            // The ring doubles as the cancel button: hover turns it red.
            Button {
                actions.cancelUpload()
            } label: {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(cancelHover ? Color.red : Color.accentColor,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.3), value: progress)
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(cancelHover ? Color.red : .white.opacity(0.6))
                }
                .frame(width: 30, height: 30)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) { cancelHover = hovering }
            }
            .help("Cancel upload")
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    /// The link is already on the clipboard by the time this shows. At rest
    /// it just confirms that; hovering reveals the open/copy actions.
    @ViewBuilder
    private func doneContent(name: String, pageURLs: [String],
                             fileURLs: [String]) -> some View {
        if hovering {
            VStack(alignment: .leading, spacing: 9) {
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    if !pageURLs.isEmpty {
                        Button {
                            for url in pageURLs { actions.open(url) }
                        } label: {
                            buttonLabel(pageURLs.count > 1 ? "Open pages" : "Open page",
                                        icon: "safari")
                        }
                        .buttonStyle(PillButtonStyle(accent: true))
                        linkButton(pageURLs.count > 1 ? "Copy links" : "Copy link",
                                   icon: "doc.on.doc",
                                   url: pageURLs.joined(separator: "\n"))
                    }
                    if !fileURLs.isEmpty {
                        linkButton(fileURLs.count > 1 ? "File links" : "File link",
                                   icon: "arrow.down.circle",
                                   url: fileURLs.joined(separator: "\n"))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 9) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.green)
                Text("Link copied")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Pieces

    private func linkButton(_ label: String, icon: String, url: String) -> some View {
        Button {
            actions.copy(url)
        } label: {
            buttonLabel(label, icon: icon)
        }
        .buttonStyle(PillButtonStyle())
    }

    private func buttonLabel(_ label: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(label)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
    }

    private func splitZone(_ label: String, icon: String, active: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 17))
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(active ? Color.accentColor : .white.opacity(0.55))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 6)
        .background(shape.fill(active ? Color.accentColor.opacity(0.12)
                                      : Color.white.opacity(0.05)))
        .overlay(shape.strokeBorder(active ? Color.accentColor.opacity(0.8)
                                           : Color.white.opacity(0.10), lineWidth: 1))
    }
}

/// One segment of the capture launcher. Its outer corners round to the pill's
/// capsule ends so Window/Screen read as part of the pill; the middle segment
/// stays lightly rounded. Hover is tracked with an `.activeAlways` area so it
/// lights up even though the pill is a background, non-key panel.
private struct CaptureSegment: View {
    let label: String
    let icon: String
    let corners: RectangleCornerRadii
    let highlighted: Bool
    let action: () -> Void

    var body: some View {
        let shape = UnevenRoundedRectangle(cornerRadii: corners, style: .continuous)
        return Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 16))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white.opacity(highlighted ? 1 : 0.85))
            .background(shape.fill(Color.white.opacity(highlighted ? 0.16 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.13), value: highlighted)
    }
}

/// Reports which of `count` equal columns the pointer is over (or nil) from a
/// SINGLE `.activeAlways` tracking area. One tracker means a highlight can never
/// get stuck the way separate per-segment trackers do as segments animate in.
private struct SegmentHoverTracker: NSViewRepresentable {
    let count: Int
    let onChange: (Int?) -> Void

    func makeNSView(context: Context) -> NSView { Tracker(count: count, onChange: onChange) }
    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? Tracker else { return }
        view.count = count
        view.onChange = onChange
    }

    final class Tracker: NSView {
        var count: Int
        var onChange: (Int?) -> Void

        init(count: Int, onChange: @escaping (Int?) -> Void) {
            self.count = count
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self))
        }

        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseExited(with event: NSEvent) { onChange(nil) }

        private func report(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.width > 0, bounds.contains(point) else { onChange(nil); return }
            let column = Int(point.x / (bounds.width / CGFloat(count)))
            onChange(min(max(column, 0), count - 1))
        }
    }
}

/// The pill's own button chrome — a rounded fill that brightens on hover
/// (tracked via `.activeAlways`, so it works on the background panel) and
/// presses in on click. `accent` fills with the brand color for primary actions.
private struct PillButtonStyle: ButtonStyle {
    var accent = false

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, accent: accent)
    }

    private struct PillButtonBody: View {
        let configuration: Configuration
        let accent: Bool
        @State private var hover = false

        var body: some View {
            let shape = Capsule()
            return configuration.label
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(accent ? .white : .white.opacity(0.92))
                .background(shape.fill(fill))
                .overlay(accent ? nil : shape.strokeBorder(
                    Color.white.opacity(0.09), lineWidth: 1))
                .clipShape(shape)
                .background(HoverTracking { hover = $0 })
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: hover)
                .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
        }

        private var fill: Color {
            if accent { return Color.accentColor.opacity(hover ? 1 : 0.9) }
            return Color.white.opacity(hover ? 0.15 : 0.07)
        }
    }
}

/// Reports pointer enter/exit via an `.activeAlways` tracking area, which —
/// unlike SwiftUI's `.onHover` — fires even for a background, non-key panel.
private struct HoverTracking: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView { TrackingView(onChange: onChange) }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TrackingView)?.onChange = onChange
    }

    private final class TrackingView: NSView {
        var onChange: (Bool) -> Void

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }
    }
}
