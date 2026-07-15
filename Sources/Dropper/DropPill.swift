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

/// An optional pill hanging just below the menu bar: drop files onto it to
/// upload, watch progress, then copy the link. A floating companion to the
/// menu-bar icon's own drop target, driven by the same shared `UIState`.
@MainActor
final class DropPillController: NSObject {
    // Fixed so the drop target never moves mid-drag — every state swaps its
    // content inside these bounds. Generous enough that the pill's shadow has
    // clear room on every side and never clips against the window's edge.
    static let size = NSSize(width: 380, height: 132)
    private static let originKey = "DropPillOrigin"
    private static let visibilityKey = "DropPillVisible"
    private let panel: NSPanel
    private var lastMoveTime: TimeInterval = 0

    /// True right after the pill was dragged, so a click that lands at the end
    /// of a drag-to-move doesn't get treated as a capture-button press.
    var wasJustDragged: Bool {
        ProcessInfo.processInfo.systemUptime - lastMoveTime < 0.3
    }

    static var shouldShow: Bool {
        UserDefaults.standard.object(forKey: visibilityKey) as? Bool ?? true
    }

    var isVisible: Bool { panel.isVisible }

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

    func setVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: Self.visibilityKey)
        if visible { show() } else { hide() }
    }

    /// Restores the user's chosen spot, or defaults to just below the menu bar.
    private func placeInitially() {
        guard let defaultScreen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame: NSRect
        let screen: NSScreen
        if let origin = Self.savedOrigin() {
            frame = NSRect(origin: origin, size: Self.size)
            screen = Self.screen(containing: frame) ?? defaultScreen
        } else {
            let visible = defaultScreen.visibleFrame
            frame = NSRect(
                x: defaultScreen.frame.midX - Self.size.width / 2,
                y: visible.maxY - Self.size.height,
                width: Self.size.width,
                height: Self.size.height)
            screen = defaultScreen
        }
        panel.setFrame(Self.clamp(frame, to: screen.visibleFrame), display: true)
    }

    /// Keeps the pill on-screen when the display arrangement changes — without
    /// yanking it back to center, since its position is the user's to choose.
    @objc private func screensChanged() {
        guard let screen = Self.screen(containing: panel.frame)
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        panel.setFrame(Self.clamp(panel.frame, to: screen.visibleFrame), display: true)
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

    /// Global window coordinates identify the display as long as it is still
    /// connected. Choose that display before clamping the restored position.
    private static func screen(containing frame: NSRect) -> NSScreen? {
        let candidates = NSScreen.screens.map { screen in
            let intersection = screen.frame.intersection(frame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            return (screen: screen, area: area)
        }
        guard let best = candidates.max(by: { $0.area < $1.area }), best.area > 0 else {
            return nil
        }
        return best.screen
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
    @State private var confirmation: String?     // transient "Link copied" toast
    @State private var confirmWork: DispatchWorkItem?
    @State private var autoExpand = false        // offer the link actions without a hover
    @State private var celebrating = false       // running the post-upload sequence
    @State private var seqExpand: DispatchWorkItem?
    @State private var seqCollapse: DispatchWorkItem?

    private var dragging: Bool { dragCount > 0 }
    private static let revertDelay: TimeInterval = 3
    /// Apple's spring vocabulary (WWDC "Animate with springs"): describe the
    /// motion by duration + bounce, not a raw damping ratio. A snappy spring
    /// with a slight overshoot is exactly the Dynamic Island's morph feel.
    private static let morph = Animation.spring(duration: 0.3, bounce: 0.2)

    /// One id per distinct visual state; changing it drives the blur-morph
    /// between states. Progress ticks keep the same id and update in place.
    private var visualKey: Int {
        if confirmation != nil { return 7 }
        switch state.strip {
        case .uploading: return 1
        case .links: return dragging ? (dragCount > 1 ? 3 : 2)
                                     : ((hovering || autoExpand) ? 5 : 4)
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
        .onChange(of: state.strip) { _, newValue in
            dragCount = 0
            // A finished pill upload (links, list closed) runs the celebration:
            // check → auto-offer the actions → idle. Selections stay quiet.
            if case let .links(_, pageURLs, _) = newValue, !actions.isListOpen() {
                startUploadCelebration(
                    message: pageURLs.count > 1 ? "Links copied" : "Link copied")
            } else {
                cancelCelebration()
                confirmWork?.cancel()
                confirmation = nil
                autoExpand = false
            }
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
        guard case .links = state.strip, !hovering, !actions.isListOpen(),
              confirmation == nil, !celebrating else { return }
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
        case 3: return CGSize(width: 300, height: 82)   // drop target, divided in half
        case 1: return CGSize(width: 300, height: 64)   // uploading
        case 4: return CGSize(width: 58, height: 32)    // links, at rest — small
        case 5: return CGSize(width: currentLinkSegmentCount >= 3 ? 300 : 224,
                              height: 70)               // links, hovered
        case 7: return CGSize(width: 210, height: 44)   // copy confirmation

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
        if let confirmation {
            confirmationContent(confirmation)
        } else {
            switch state.strip {
            case let .uploading(name, progress):
                uploadingContent(name: name, progress: progress)
            case let .links(_, pageURLs, fileURLs):
                if dragging { dropContent }
                else { doneContent(pageURLs: pageURLs, fileURLs: fileURLs) }
            case .idle:
                if dragging { dropContent } else { idleContent }
            }
        }
    }

    private func confirmationContent(_ message: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.green)
            Text(message)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Flashes a green-check toast (e.g. "Link copied") for a beat, then — for a
    /// pill upload — settles back to idle. A copy ends any auto-offer.
    private func confirm(_ message: String) {
        cancelCelebration()
        confirmWork?.cancel()
        withAnimation(Self.morph) { confirmation = message }
        let work = DispatchWorkItem {
            withAnimation(Self.morph) { confirmation = nil }
            if case .links = state.strip, !actions.isListOpen(), !hovering {
                withAnimation(Self.morph) { state.strip = .idle }
            }
        }
        confirmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    /// The post-upload sequence: a check-mark success, then the link actions
    /// auto-expand for a couple seconds (no hover needed), then back to idle if
    /// the user never reaches for them.
    private func startUploadCelebration(message: String) {
        cancelCelebration()
        confirmWork?.cancel()
        celebrating = true
        withAnimation(Self.morph) { confirmation = message; autoExpand = false }

        let expand = DispatchWorkItem {
            withAnimation(Self.morph) { confirmation = nil; autoExpand = true }
        }
        let collapse = DispatchWorkItem {
            celebrating = false
            seqExpand = nil
            seqCollapse = nil
            withAnimation(Self.morph) { autoExpand = false }
            if case .links = state.strip, !actions.isListOpen(), !hovering {
                withAnimation(Self.morph) { state.strip = .idle }
            }
        }
        seqExpand = expand
        seqCollapse = collapse
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: expand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.8, execute: collapse)
    }

    private func cancelCelebration() {
        seqExpand?.cancel()
        seqExpand = nil
        seqCollapse?.cancel()
        seqCollapse = nil
        celebrating = false
    }

    // MARK: - States

    /// At rest, an invitation to drop. Hovering turns the idle pill into a
    /// capture launcher — the same window/area/screen flow as the menu.
    @ViewBuilder private var idleContent: some View {
        if hovering {
            // Hovering the idle pill reveals the capture launcher.
            segmentedRow([
                PillSegment(label: "Window", icon: "macwindow") { actions.capture(.window) },
                PillSegment(label: "Area", icon: "rectangle.dashed") { actions.capture(.area) },
                PillSegment(label: "Screen", icon: "display") { actions.capture(.display) },
            ])
        } else {
            // At rest: a very small black pill with just the droplet, centered.
            Image(systemName: "drop.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One unambiguous target for a single file; the collection/items split
    /// once two or more files are in the drag.
    @ViewBuilder private var dropContent: some View {
        if dragCount > 1 {
            let shape = Capsule()
            HStack(spacing: 4) {
                splitZone("Upload collection",
                          icon: "rectangle.stack.badge.plus", active: !separateSide)
                splitZone("Upload \(dragCount) new items",
                          icon: "square.on.square", active: separateSide)
            }
            .background(shape.fill(Color.accentColor.opacity(0.06)))
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                    .foregroundStyle(Color.accentColor.opacity(0.65))
                GeometryReader { geometry in
                    Path { path in
                        let x = geometry.size.width / 2
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                    }
                    .stroke(Color.accentColor.opacity(0.65),
                            style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                }
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
        let finishing = progress >= 0.95
        return HStack(spacing: 13) {
            // The ring doubles as the cancel button: hover turns it red.
            Button {
                actions.cancelUpload()
            } label: {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 3)
                    if finishing {
                        SpinningProgressArc(
                            color: cancelHover ? Color.red : Color.accentColor,
                            lineWidth: 3)
                    } else {
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(cancelHover ? Color.red : Color.accentColor,
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.3), value: progress)
                    }
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
                Text(finishing ? "Finishing…" : "\(Int(progress * 100))%")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    /// Links are available (a finished upload, or a selection in the list). At
    /// rest it's just a small link glyph — never "copied", since selecting
    /// copies nothing. Hovering reveals Open / Copy / File as segmented buttons,
    /// styled exactly like the capture launcher, with no filename.
    @ViewBuilder
    private func doneContent(pageURLs: [String], fileURLs: [String]) -> some View {
        if hovering || autoExpand {
            segmentedRow(linkSegments(pageURLs: pageURLs, fileURLs: fileURLs))
        } else {
            Image(systemName: "link")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Segmented rows

    /// A row of segmented pill buttons, shared by the capture launcher and the
    /// link actions. The outer segments hug the capsule ends; a single position
    /// tracker drives the highlight so it can never stick.
    private func segmentedRow(_ segments: [PillSegment]) -> some View {
        let count = segments.count
        return HStack(spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                CaptureSegment(label: segment.label, icon: segment.icon,
                               corners: segmentCorners(index: index, count: count),
                               highlighted: hoveredSegment == index,
                               action: segment.action)
            }
        }
        .padding(6)
        .background(SegmentHoverTracker(count: count) { hoveredSegment = $0 })
    }

    private func segmentCorners(index: Int, count: Int) -> RectangleCornerRadii {
        let outer: CGFloat = 30, inner: CGFloat = 6
        let first = index == 0, last = index == count - 1
        return .init(topLeading: first ? outer : inner,
                     bottomLeading: first ? outer : inner,
                     bottomTrailing: last ? outer : inner,
                     topTrailing: last ? outer : inner)
    }

    private func linkSegments(pageURLs: [String], fileURLs: [String]) -> [PillSegment] {
        var segments: [PillSegment] = []
        if !pageURLs.isEmpty {
            segments.append(PillSegment(label: "Open", icon: "safari") {
                for url in pageURLs { actions.open(url) }
            })
            segments.append(PillSegment(label: "Copy", icon: "doc.on.doc") {
                actions.copy(pageURLs.joined(separator: "\n"))
                confirm(pageURLs.count > 1 ? "Links copied" : "Link copied")
            })
        }
        if !fileURLs.isEmpty {
            segments.append(PillSegment(label: "File", icon: "arrow.down.circle") {
                actions.copy(fileURLs.joined(separator: "\n"))
                confirm(fileURLs.count > 1 ? "File links copied" : "File link copied")
            })
        }
        return segments
    }

    /// The number of link segments for the current state — sizes the pill.
    private var currentLinkSegmentCount: Int {
        if case let .links(_, pageURLs, fileURLs) = state.strip {
            return (pageURLs.isEmpty ? 0 : 2) + (fileURLs.isEmpty ? 0 : 1)
        }
        return 2
    }

    private func splitZone(_ label: String, icon: String, active: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 17))
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(active ? Color.accentColor : .white.opacity(0.55))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 6)
        .background(active ? Color.accentColor.opacity(0.12) : Color.clear)
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

/// One entry in a `segmentedRow` — a labeled, icon'd button.
private struct PillSegment {
    let label: String
    let icon: String
    let action: () -> Void
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
