import AppKit
import CaptureKit
import SwiftUI

/// Callbacks the SwiftUI popover content uses to reach the controller.
struct PopoverActions {
    var dropped: ([URL]) -> Void
    var droppedSeparately: ([URL]) -> Void    // every file becomes its own share
    var droppedInto: ([URL], String) -> Void  // files + explicit parent share id
    var navigate: (String) -> Void     // browse to a folder prefix ("" = root)
    var createFolder: (String) -> Void
    var copy: (String) -> Void
    var open: (String) -> Void
    var close: () -> Void
    var openSettings: () -> Void
    var cancelUpload: () -> Void
    var setDropTargeted: (String, Bool) -> Void
    var dropCommitted: () -> Void
}

/// Borderless key-capable panel — NSPopover proved unreliable for a
/// persistent dropdown (size drift, off-screen spawns), so the dropdown is a
/// floating panel positioned and clamped by hand.
private final class DropdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Pure screen geometry for the menu-bar dropdown. Keeping this separate from
/// the window operation makes every edge (including the top edge) testable.
enum DropdownPlacement {
    static let screenMargin: CGFloat = 8
    static let anchorGap: CGFloat = 2

    static func frame(anchor: NSRect, requestedSize: NSSize,
                      visibleFrame: NSRect) -> NSRect {
        // Preserve the normal two-point menu-bar attachment at the top while
        // retaining breathing room at the other three desktop edges.
        let safeFrame = NSRect(
            x: visibleFrame.minX + screenMargin,
            y: visibleFrame.minY + screenMargin,
            width: max(0, visibleFrame.width - screenMargin * 2),
            height: max(0, visibleFrame.height - screenMargin))
        let width = min(requestedSize.width, max(0, safeFrame.width))
        let height = min(requestedSize.height, max(0, safeFrame.height))
        let size = NSSize(width: width, height: height)

        let preferredX = anchor.midX - width / 2
        let preferredY = anchor.minY - height - anchorGap
        let x = clamp(preferredX, lower: safeFrame.minX,
                      upper: safeFrame.maxX - width)
        let y = clamp(preferredY, lower: safeFrame.minY,
                      upper: safeFrame.maxY - height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat,
                              upper: CGFloat) -> CGFloat {
        // A requested size is reduced to the safe frame first, so this range
        // is always valid—even on a very small display.
        min(max(value, lower), upper)
    }
}

/// Tracks every live destination in one drag session. Tokens prevent an exit
/// from row A from clearing row B when AppKit delivers enter/exit out of order.
struct ActiveDropTargets {
    private(set) var ids = Set<String>()

    var isEmpty: Bool { ids.isEmpty }

    mutating func set(_ id: String, active: Bool) {
        if active {
            ids.insert(id)
        } else {
            ids.remove(id)
        }
    }

    mutating func removeAll() {
        ids.removeAll()
    }
}

@MainActor
final class StatusItemController: NSObject {
    static let dropdownSize = NSSize(width: 380, height: 575 + DropdownShape.beakHeight)

    private var client: R2Client?
    private let statusItem: NSStatusItem
    private let panel: DropdownPanel = {
        let panel = DropdownPanel(
            contentRect: NSRect(origin: .zero, size: StatusItemController.dropdownSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }()
    /// This host must survive folder navigation. Replacing a visible panel's
    /// contentViewController makes AppKit collapse it to 0x0 at its old top
    /// edge, then re-expand upward off-screen.
    private var panelHost: NSHostingController<PopoverRootView>?
    private let state = UIState()
    private var store: ShareStore?
    private var settingsWindow: NSWindow?
    private var openedByDrag = false
    private var activeDropTargets = ActiveDropTargets()
    private var pendingDragClose: DispatchWorkItem?

    var hasCredentials: Bool { client != nil }

    private lazy var uploads: UploadCoordinator = {
        let coordinator = UploadCoordinator(state: state)
        coordinator.setIcon = { [weak self] progress in self?.setIcon(progress: progress) }
        coordinator.presentPopover = { [weak self] in self?.showPopover() }
        coordinator.notify = { [weak self] title, body in
            self?.notify(title: title, body: body)
        }
        return coordinator
    }()

    private static let idleIcon: NSImage = {
        let image = NSImage(systemSymbolName: "drop.fill",
                            accessibilityDescription: "Dropper")!
        image.isTemplate = true
        return image
    }()

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = Self.idleIcon
            let overlay = StatusDropView(frame: button.bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.onDrop = { [weak self] urls in self?.handleDrop(urls: urls) }
            overlay.onClick = { [weak self] in self?.toggleList() }
            overlay.onRightClick = { [weak self] in self?.showContextMenu() }
            overlay.onDragEntered = { [weak self] in self?.dragEnteredIcon() }
            overlay.onDragExited = { [weak self] in self?.dragExitedIcon() }
            button.addSubview(overlay)
        }

        rebuildClient()
    }

    /// (Re)creates the client, store, and popover content from the stored
    /// configuration. Called at startup and after Settings changes.
    func rebuildClient() {
        let config = ConfigStore.snapshot()
        client = ConfigStore.resolveCredentials()
            .map { R2Client(credentials: $0, config: config) }
        store = client.map(ShareStore.init)
        uploads.client = client
        uploads.store = store

        let actions = PopoverActions(
            dropped: { [weak self] urls in self?.handleDrop(urls: urls) },
            droppedSeparately: { [weak self] urls in
                self?.uploads.uploadSeparately(urls: urls)
            },
            droppedInto: { [weak self] urls, shareID in
                self?.handleAddDrop(urls: urls, to: shareID)
            },
            navigate: { [weak self] prefix in self?.navigate(to: prefix) },
            createFolder: { [weak self] name in self?.createFolder(named: name) },
            copy: { text in copyToClipboard(text) },
            open: { text in
                if let url = URL(string: text) { NSWorkspace.shared.open(url) }
            },
            close: { [weak self] in self?.closePopover() },
            openSettings: { [weak self] in self?.openSettings() },
            cancelUpload: { [weak self] in self?.uploads.cancel() },
            setDropTargeted: { [weak self] id, targeted in
                self?.setDropTarget(id, active: targeted)
            },
            dropCommitted: { [weak self] in self?.commitDrop() }
        )
        let root = PopoverRootView(state: state, store: store, actions: actions)
        if let panelHost {
            panelHost.rootView = root
        } else {
            let host = NSHostingController(rootView: root)
            // The panel owns its size; SwiftUI content must never resize it.
            host.sizingOptions = []
            panelHost = host
            panel.contentViewController = host
        }
        state.strip = .idle
        state.highlightedID = nil
        if panel.isVisible {
            positionPanel()
            store?.refresh()
            // Reassert the invariant after SwiftUI has processed rootView.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel.isVisible else { return }
                self.positionPanel()
                self.panel.invalidateShadow()
            }
        }
    }

    // MARK: - Popover

    private func showPopover() {
        guard positionPanel() else { return }
        if !panel.isVisible { panel.orderFrontRegardless() }
        DispatchQueue.main.async { self.panel.invalidateShadow() }
        // Nothing should start out as first responder — kills the blue focus
        // ring AppKit hands to the first focusable control.
        panel.makeFirstResponder(nil)
    }

    /// Restores the intended size and places the panel fully within the
    /// status item's current screen. Safe to call while the panel is visible.
    @discardableResult
    private func positionPanel() -> Bool {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return false }
        // Below the icon, clamped fully inside the screen's visible frame —
        // the dropdown can never spawn off the desktop.
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let anchorPoint = NSPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { NSMouseInRect(anchorPoint, $0.frame, false) }
            ?? buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame
            ?? NSRect(origin: .zero, size: Self.dropdownSize)
        let frame = DropdownPlacement.frame(anchor: anchor,
                                            requestedSize: Self.dropdownSize,
                                            visibleFrame: visible)
        // The beak slides to keep pointing at the icon when clamping moved us.
        state.beakOffset = anchor.midX - frame.minX
        panel.setFrame(frame, display: true)
        return true
    }

    private func closePopover() {
        if panel.isVisible { panel.orderOut(nil) }
        pendingDragClose?.cancel()
        pendingDragClose = nil
        activeDropTargets.removeAll()
        // Reset transient UI unless an upload is mid-flight.
        if !uploads.busy {
            state.strip = .idle
            state.highlightedID = nil
        }
    }

    func toggleList() {
        openedByDrag = false
        if panel.isVisible {
            closePopover()
        } else {
            openList()
        }
    }

    func openList() {
        store?.refresh()
        showPopover()
    }

    // MARK: - Folder navigation

    /// Browses to a folder: it becomes both the view and the drop target,
    /// persisted as the active folder across restarts.
    func navigate(to prefix: String) {
        guard !uploads.busy else { return }
        UserDefaults.standard.set(prefix, forKey: ConfigStore.keys.prefix)
        rebuildClient()
        store?.refresh()
    }

    func createFolder(named name: String) {
        guard let client else { return }
        let clean = ShareNaming.sanitize(name)
        let path = client.config.key(clean)
        Task {
            do {
                try await client.createFolder(path: path)
                await MainActor.run { self.navigate(to: path) }
            } catch {
                await MainActor.run {
                    self.notify(title: "Dropper",
                                body: "Could not create the folder.")
                }
            }
        }
    }

    // MARK: - Drag over the menu bar icon

    /// A drag hovering the icon opens the dropdown so the file can continue
    /// down into the strip.
    private func dragEnteredIcon() {
        pendingDragClose?.cancel()
        pendingDragClose = nil
        if !panel.isVisible {
            openedByDrag = true
            openList()
        }
    }

    /// If the dropdown auto-opened for this drag and nothing was dropped,
    /// close it again once the drag moves away (the strip cancels this while
    /// it's the drop target).
    private func dragExitedIcon() {
        scheduleDragClose()
    }

    private func setDropTarget(_ id: String, active: Bool) {
        activeDropTargets.set(id, active: active)
        if active {
            pendingDragClose?.cancel()
            pendingDragClose = nil
        } else {
            scheduleDragClose()
        }
    }

    private func scheduleDragClose() {
        guard openedByDrag, !uploads.busy, activeDropTargets.isEmpty else { return }
        pendingDragClose?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.openedByDrag, !self.uploads.busy,
                  self.activeDropTargets.isEmpty else { return }
            self.openedByDrag = false
            self.closePopover()
        }
        pendingDragClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    /// A destination accepted the drop; provider resolution may still be
    /// asynchronous, but the auto-open timer must not close the panel now.
    private func commitDrop() {
        openedByDrag = false
        pendingDragClose?.cancel()
        pendingDragClose = nil
        activeDropTargets.removeAll()
    }

    // MARK: - Upload

    func handleDrop(urls: [URL]) {
        commitDrop()
        uploads.upload(urls: urls, into: nil)
    }

    /// Appends a row drop to that exact share. A stale/missing destination is
    /// rejected rather than silently creating an unrelated new share.
    func handleAddDrop(urls: [URL], to shareID: String) {
        commitDrop()
        guard let store, let target = store.shareForHighlight(shareID),
              !store.deletingIDs.contains(target.id) else {
            notify(title: "Dropper", body: "That collection is no longer available.")
            return
        }
        uploads.upload(urls: urls, into: target)
    }

    // MARK: - Icon

    private func setIcon(progress: Double?) {
        guard let button = statusItem.button else { return }
        guard let progress else {
            button.image = Self.idleIcon
            return
        }
        button.image = Self.ringImage(progress)
    }

    private static func ringImage(_ progress: Double) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let inset = rect.insetBy(dx: 2, dy: 2)
            let track = NSBezierPath(ovalIn: inset)
            track.lineWidth = 2
            NSColor.black.withAlphaComponent(0.25).setStroke()
            track.stroke()

            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY),
                          radius: inset.width / 2, startAngle: 90,
                          endAngle: 90 - 360 * progress, clockwise: true)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Settings

    // MARK: - Onboarding

    private var onboardingWindow: NSWindow?

    func openOnboarding() {
        onboardingWindow?.close()
        let model = OnboardingModel()
        let view = OnboardingView(
            model: model,
            onConfigured: { [weak self] in
                self?.rebuildClient()
            },
            onFinished: { [weak self] in
                self?.onboardingWindow?.close()
                if self?.hasCredentials == true { self?.openList() }
            })
        let availableHeight = (NSScreen.main?.visibleFrame.height ?? 740) - 40
        let contentHeight = min(700, max(500, availableHeight))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: contentHeight),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Set Up Dropper"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: view)
        window.contentMinSize = NSSize(width: 500, height: 500)
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openSettings() {
        // Fresh window each time so the fields re-read the stored config.
        settingsWindow?.close()
        let targetScreen = statusItem.button?.window?.screen ?? NSScreen.main
        let availableHeight = max(360, (targetScreen?.visibleFrame.height ?? 680) - 40)
        let contentHeight = min(640, availableHeight)
        let view = SettingsView(
            onSave: { [weak self] in self?.rebuildClient() },
            onClose: { [weak self] in self?.settingsWindow?.close() })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: contentHeight),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Dropper Settings"
        window.contentView = NSHostingView(rootView: view)
        window.contentMinSize = NSSize(width: 460, height: min(520, contentHeight))
        window.isReleasedWhenClosed = false
        if let visible = targetScreen?.visibleFrame {
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                                          y: visible.midY - frame.height / 2))
        } else {
            window.center()
        }
        settingsWindow = window
        closePopover()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Context menu

    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu()
        let captures: [(String, Selector)] = [
            ("Capture Window", #selector(captureWindowFromMenu)),
            ("Capture Area", #selector(captureAreaFromMenu)),
            ("Capture Screen", #selector(captureScreenFromMenu)),
        ]
        for (title, action) in captures {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(settingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let setup = NSMenuItem(title: "Setup Wizard…",
                               action: #selector(onboardingFromMenu), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Dropper",
                              action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }()

    @objc private func onboardingFromMenu() {
        openOnboarding()
    }

    @objc private func settingsFromMenu() {
        openSettings()
    }

    @objc private func captureAreaFromMenu() { beginCapture(.area) }
    @objc private func captureWindowFromMenu() { beginCapture(.window) }
    @objc private func captureScreenFromMenu() { beginCapture(.display) }

    private func beginCapture(_ mode: CaptureMode) {
        closePopover()
        CaptureFlow.begin(
            mode: mode,
            onComplete: { [weak self] url in self?.handleDrop(urls: [url]) },
            onFailure: { [weak self] message in
                self?.notify(title: "Capture failed", body: message)
            })
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        contextMenu.popUp(positioning: nil,
                          at: NSPoint(x: 0, y: button.bounds.height + 6), in: button)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Notifications

    func notify(title: String, body: String) {
        postNotification(title: title, body: body)
    }
}

/// Transparent overlay on the status item button: accepts file drops directly
/// on the icon and forwards plain clicks to the controller.
final class StatusDropView: NSView {
    var onDrop: ([URL]) -> Void = { _ in }
    var onClick: () -> Void = {}
    var onRightClick: () -> Void = {}
    var onDragEntered: () -> Void = {}
    var onDragExited: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEntered()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExited()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        // Ctrl-click is a right click by macOS convention.
        if event.modifierFlags.contains(.control) {
            onRightClick()
        } else {
            onClick()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick()
    }
}
