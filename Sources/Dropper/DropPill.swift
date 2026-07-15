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
    // content inside these bounds, exactly like the popover's bottom strip.
    static let size = NSSize(width: 360, height: 96)
    private let panel: NSPanel

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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: DropPillView(state: state, actions: actions))

        NotificationCenter.default.addObserver(
            self, selector: #selector(reposition),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    /// Top-centered, its top edge tucked right under the menu bar.
    @objc private func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame  // the desktop below the menu bar
        let size = Self.size
        panel.setFrame(
            NSRect(x: screen.frame.midX - size.width / 2,
                   y: visible.maxY - size.height,
                   width: size.width, height: size.height),
            display: true)
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
    @State private var revertWork: DispatchWorkItem?

    private var dragging: Bool { dragCount > 0 }
    private static let cardHeight: CGFloat = 64
    private static let revertDelay: TimeInterval = 3

    var body: some View {
        VStack(spacing: 0) {
            pill
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .contentShape(Rectangle())
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { pillWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, width in pillWidth = width }
        })
        // A background panel never becomes key, so an AppKit .activeAlways
        // tracking area is the reliable way to know the pointer is resting here.
        .background(HoverTracking { inside in
            withAnimation(.easeInOut(duration: 0.16)) { hovering = inside }
        })
        .onDrop(of: [.fileURL], delegate: StripDropDelegate(
            midX: { pillWidth / 2 },
            update: { count, right in
                withAnimation(.easeInOut(duration: 0.14)) {
                    dragCount = count
                    separateSide = right
                }
            },
            exit: {
                withAnimation(.easeInOut(duration: 0.14)) { dragCount = 0 }
            },
            perform: { separate, providers in
                performDrop(separate: separate, providers: providers)
            }))
        .onChange(of: state.strip) { _, _ in
            dragCount = 0
            scheduleRevert()
        }
        .onChange(of: hovering) { _, _ in scheduleRevert() }
        .animation(.easeInOut(duration: 0.16), value: state.strip)
        .animation(.easeInOut(duration: 0.16), value: dragCount)
        .animation(.easeInOut(duration: 0.16), value: hovering)
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
                state.strip = .idle
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

    // MARK: - Capsule chrome

    private var pill: some View {
        content
            .background(VisualEffectBackground(material: .hudWindow))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.32), radius: 12, y: 5)
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
            HStack(spacing: 6) {
                captureButton("Window", icon: "macwindow", mode: .window)
                captureButton("Area", icon: "rectangle.dashed", mode: .area)
                captureButton("Screen", icon: "display", mode: .display)
            }
            .padding(8)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "drop.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                Text("Drop a file to share")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func captureButton(_ label: String, icon: String,
                               mode: CaptureMode) -> some View {
        Button {
            actions.capture(mode)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 15))
                Text(label).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
    }

    /// One unambiguous target for a single file; the collection/items split
    /// once two or more files are in the drag.
    @ViewBuilder private var dropContent: some View {
        if dragCount > 1 {
            HStack(spacing: 8) {
                splitZone("Upload collection",
                          icon: "rectangle.stack.badge.plus", active: !separateSide)
                splitZone("Upload \(dragCount) new items",
                          icon: "square.on.square", active: separateSide)
            }
            .frame(height: Self.cardHeight)
            .frame(maxWidth: .infinity)
            .padding(8)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                Text("Drop to upload").font(.callout)
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(dashedCard(active: true))
            .padding(8)
        }
    }

    private func uploadingContent(name: String, progress: Double) -> some View {
        HStack(spacing: 12) {
            // The ring doubles as the cancel button: hover turns it red.
            Button {
                actions.cancelUpload()
            } label: {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(cancelHover ? Color.red : Color.accentColor,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(cancelHover ? Color.red : Color.secondary)
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
                Text(name).font(.callout).lineLimit(1).truncationMode(.middle)
                Text("\(Int(progress * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
    }

    /// The link is already on the clipboard by the time this shows. At rest
    /// it just confirms that; hovering reveals the open/copy actions.
    @ViewBuilder
    private func doneContent(name: String, pageURLs: [String],
                             fileURLs: [String]) -> some View {
        if hovering {
            VStack(alignment: .leading, spacing: 8) {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    if !pageURLs.isEmpty {
                        Button {
                            for url in pageURLs { actions.open(url) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "safari")
                                Text(pageURLs.count > 1 ? "Open pages" : "Open page")
                            }
                        }
                        .buttonStyle(.borderedProminent)
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
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Link copied").font(.callout)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
    }

    // MARK: - Pieces

    private func linkButton(_ label: String, icon: String, url: String) -> some View {
        Button {
            actions.copy(url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(label)
            }
        }
        .buttonStyle(.bordered)
    }

    private func splitZone(_ label: String, icon: String, active: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 18))
            Text(label).font(.caption)
        }
        .foregroundStyle(active ? Color.accentColor : .secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dashedCard(active: active))
    }

    private func dashedCard(active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            .foregroundStyle(active ? Color.accentColor : .secondary.opacity(0.5))
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
