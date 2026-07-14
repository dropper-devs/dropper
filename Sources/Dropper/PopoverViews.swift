import SwiftUI
import UniformTypeIdentifiers

struct PopoverRootView: View {
    @ObservedObject var state: UIState
    let store: ShareStore?
    let actions: PopoverActions

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: DropdownShape.beakHeight)
            Group {
                if let store {
                    ShareListView(store: store, state: state, actions: actions)
                } else {
                    // No stored token — the wizard (right-click the icon) is
                    // the way in.
                    Text("Not connected — run the Setup Wizard to link your Cloudflare account.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            // The persistent hosting controller/window owns the exact size.
            // Filling its proposal also lets the list compress safely on a
            // display whose visible height is less than the preferred 585 pt.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VisualEffectBackground(material: .hudWindow).ignoresSafeArea())
        // The panel is borderless; the view supplies its own chrome — a
        // rounded panel with a beak pointing at the menu bar icon.
        .clipShape(DropdownShape(beakMidX: state.beakOffset))
        .overlay(
            DropdownShape(beakMidX: state.beakOffset)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

/// The dropdown's outline: rounded rectangle with a popover-style beak on the
/// top edge, its tip at `beakMidX` (slides so it keeps pointing at the icon
/// even when the panel is clamped to the screen edge).
struct DropdownShape: Shape {
    static let beakHeight: CGFloat = 10
    static let beakWidth: CGFloat = 22
    static let cornerRadius: CGFloat = 12

    var beakMidX: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = Self.cornerRadius
        let top = Self.beakHeight
        let half = Self.beakWidth / 2
        let mid = min(max(beakMidX, r + half + 2), rect.width - r - half - 2)

        var path = Path()
        path.move(to: CGPoint(x: r, y: top))
        path.addLine(to: CGPoint(x: mid - half, y: top))
        path.addLine(to: CGPoint(x: mid, y: 0))
        path.addLine(to: CGPoint(x: mid + half, y: top))
        path.addLine(to: CGPoint(x: rect.width - r, y: top))
        path.addArc(center: CGPoint(x: rect.width - r, y: top + r), radius: r,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - r))
        path.addArc(center: CGPoint(x: rect.width - r, y: rect.height - r), radius: r,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: r, y: rect.height))
        path.addArc(center: CGPoint(x: r, y: rect.height - r), radius: r,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: 0, y: top + r))
        path.addArc(center: CGPoint(x: r, y: top + r), radius: r,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Extra-translucent backing for the popover (the built-in popover material
/// is subtler than this).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Drop strip

struct DropStrip: View {
    @ObservedObject var state: UIState
    let actions: PopoverActions
    @State private var stripDragCount = 0  // only while actually over the strip
    @State private var separateSide = false // pointer over the right zone
    @State private var stripWidth: CGFloat = 1
    @State private var cancelHover = false

    /// A single file previews only after it reaches the real drop zone. Two
    /// or more files can preview the split from anywhere in the popover.
    private var dragCount: Int {
        dropStripFileCount(stripCount: stripDragCount,
                           popoverCount: state.draggedFileCount)
    }
    private var targeted: Bool { dragCount > 0 }

    private let dropTargetID = "bottom-upload-strip"

    private static let cardHeight: CGFloat = 95

    /// The dashed drop-target outline shared by the single and split zones.
    private func dashedCard(active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            .foregroundStyle(active ? Color.accentColor : .secondary.opacity(0.5))
    }

    /// The solid card fill shared by the progress and links panels.
    private var filledCard: some View {
        RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08))
    }

    var body: some View {
        Group {
            switch state.strip {
            case .idle:
                idle
            case let .uploading(name, progress):
                uploading(name: name, progress: progress)
            case let .links(name, pageURLs, fileURLs):
                linksContainer(name: name, pageURLs: pageURLs, fileURLs: fileURLs)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.15), value: state.strip)
        // Keeps the auto-opened dropdown alive while a drag is over the strip.
        .onChange(of: targeted) { _, isTargeted in
            actions.setDropTargeted(dropTargetID, isTargeted)
        }
        .onChange(of: state.strip) { _, _ in
            stripDragCount = 0
            state.setDraggedFileCount(0, for: dropTargetID)
        }
        .onDisappear {
            stripDragCount = 0
            state.setDraggedFileCount(0, for: dropTargetID)
            actions.setDropTargeted(dropTargetID, false)
        }
    }

    /// Link actions remain available at rest. A file drag replaces them
    /// with the drop target (or the collection/items split for multi-file
    /// drags).
    private func linksContainer(name: String, pageURLs: [String], fileURLs: [String]) -> some View {
        ZStack {
            if targeted {
                dropTargets
            } else {
                links(name: name, pageURLs: pageURLs, fileURLs: fileURLs)
            }
        }
        .contentShape(Rectangle())
        .modifier(StripDropArea(strip: self))
    }

    private var idle: some View {
        dropTargets
            .contentShape(Rectangle())
            .modifier(StripDropArea(strip: self))
    }

    /// Single-file drags keep the one unambiguous target. Multi-file drags
    /// split in two: everything into ONE share, or one share PER file.
    @ViewBuilder
    private var dropTargets: some View {
        if dragCount > 1 {
            HStack(spacing: 8) {
                splitZone("Upload collection",
                          icon: "rectangle.stack.badge.plus",
                          active: !separateSide)
                splitZone("Upload \(dragCount) new items",
                          icon: "square.on.square",
                          active: separateSide)
            }
            .frame(height: Self.cardHeight)
        } else {
            uploadTarget
        }
    }

    private func splitZone(_ label: String, icon: String, active: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20))
            Text(label)
                .font(.caption)
        }
        .foregroundStyle(active ? Color.accentColor : .secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dashedCard(active: active))
    }

    private var uploadTarget: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
            Text("Upload new item")
                .font(.callout)
        }
        .foregroundStyle(targeted ? Color.accentColor : .secondary)
        .frame(maxWidth: .infinity)
        .frame(height: Self.cardHeight)
        .background(dashedCard(active: targeted))
    }

    /// One delegate handles hover (count + side tracking) and the drop
    /// itself, so the split zones can't flicker between nested targets.
    fileprivate struct StripDropArea: ViewModifier {
        let strip: DropStrip

        func body(content: Content) -> some View {
            content
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { strip.stripWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, width in
                            strip.stripWidth = width
                        }
                })
                .onDrop(of: [.fileURL], delegate: StripDropDelegate(
                    midX: { strip.stripWidth / 2 },
                    update: { count, right in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            strip.stripDragCount = count
                            strip.state.setDraggedFileCount(count,
                                                           for: strip.dropTargetID)
                            strip.separateSide = right
                        }
                    },
                    exit: {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            strip.stripDragCount = 0
                            strip.state.setDraggedFileCount(0,
                                                           for: strip.dropTargetID)
                        }
                    },
                    perform: { separate, providers in
                        strip.performDrop(separate: separate, providers: providers)
                    }))
        }
    }

    fileprivate func performDrop(separate: Bool, providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        stripDragCount = 0
        state.clearDraggedFiles()
        actions.dropCommitted()
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

    private func uploading(name: String, progress: Double) -> some View {
        HStack(spacing: 12) {
            // The ring is the cancel button: hover turns it red with an X.
            Button {
                actions.cancelUpload()
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(cancelHover ? Color.red : Color.accentColor,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(cancelHover ? Color.red : Color.secondary)
                }
                .frame(width: 32, height: 32)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) { cancelHover = hovering }
            }
            .help("Cancel upload")
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: Self.cardHeight)
        .background(filledCard)
    }

    private func links(name: String, pageURLs: [String], fileURLs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if !pageURLs.isEmpty {
                Button {
                    for url in pageURLs { actions.open(url) }
                    actions.close()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "safari")
                        Text(pageURLs.count > 1 ? "Open web pages" : "Open web page")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                // multi-copy: one link per line, in list order
                linkRow(label: pageURLs.count > 1 ? "Copy page links" : "Copy page link",
                        url: pageURLs.joined(separator: "\n"))
            }
            if !fileURLs.isEmpty {
                linkRow(label: fileURLs.count > 1 ? "Copy file links" : "Copy file link",
                        url: fileURLs.joined(separator: "\n"))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(filledCard)
        // File drops while links show are handled by linksContainer.
    }

    private func linkRow(label: String, url: String) -> some View {
        Button {
            actions.copy(url)
            actions.close()  // copied -> they're off to paste it
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc")
                Text(label)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
    }
}

/// Keeps the early-preview rule independent and testable: the popover-wide
/// observation affects the strip only for a genuine multi-file drag.
func dropStripFileCount(stripCount: Int, popoverCount: Int) -> Int {
    max(stripCount, popoverCount > 1 ? popoverCount : 0)
}

/// Tracks how many files are hovering and which half of the strip the
/// pointer is over; performs by side. Right half = one share per file,
/// and only when more than one file is in the drag.
private struct StripDropDelegate: DropDelegate {
    let midX: () -> CGFloat
    let update: (Int, Bool) -> Void
    let exit: () -> Void
    let perform: (Bool, [NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        update(info.itemProviders(for: [.fileURL]).count, info.location.x >= midX())
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info.itemProviders(for: [.fileURL]).count, info.location.x >= midX())
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        exit()
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        let separate = providers.count > 1 && info.location.x >= midX()
        return perform(separate, providers)
    }
}

func loadFileURLs(from providers: [NSItemProvider], into handler: @escaping ([URL]) -> Void) {
    guard !providers.isEmpty else { return }
    let group = DispatchGroup()
    let results = LoadedFileURLs(count: providers.count)

    for (index, provider) in providers.enumerated() {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let u = item as? URL {
                url = u
            }
            results.set(url, at: index)
            group.leave()
        }
    }

    group.notify(queue: .main) {
        let urls = results.values()
        if !urls.isEmpty { handler(urls) }
    }
}

/// NSItemProvider invokes its callbacks on arbitrary queues. Keeping the
/// mutable slots inside one locked Sendable box makes both ordering and the
/// concurrency boundary explicit.
private final class LoadedFileURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL?]

    init(count: Int) {
        storage = [URL?](repeating: nil, count: count)
    }

    func set(_ url: URL?, at index: Int) {
        lock.lock()
        storage[index] = url
        lock.unlock()
    }

    func values() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage.compactMap { $0 }
    }
}
