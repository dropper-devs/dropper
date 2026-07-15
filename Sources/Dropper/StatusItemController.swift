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

/// Counts advertised file items without asking the drag source to materialize
/// their URLs. The actual URLs are resolved once, only after a drop commits.
@MainActor
func advertisedFileCount(on pasteboard: NSPasteboard) -> Int {
    guard let items = pasteboard.pasteboardItems else {
        return pasteboard.availableType(from: [.fileURL]) == nil ? 0 : 1
    }
    return items.reduce(into: 0) { count, item in
        if item.types.contains(.fileURL) { count += 1 }
    }
}

@MainActor
private func advertisedFileCount(in sender: NSDraggingInfo) -> Int {
    advertisedFileCount(on: sender.draggingPasteboard)
}

/// Borderless key-capable panel — NSPopover proved unreliable for a
/// persistent dropdown (size drift, off-screen spawns), so the dropdown is a
/// floating panel positioned and clamped by hand.
private final class DropdownPanel: NSPanel {
    var onFileDragCount: (Int) -> Void = { _ in }
    var onFileDragEnded: () -> Void = {}

    override var canBecomeKey: Bool { true }

    // NSWindow's drag-destination hooks are imported as informal protocol
    // methods, so these intentionally do not use `override`. Registered
    // SwiftUI row/strip views remain the concrete destinations; the panel is
    // the non-consuming fallback over the rest of the window.
    @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onFileDragCount(advertisedFileCount(in: sender))
        return []
    }

    @objc func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onFileDragCount(advertisedFileCount(in: sender))
        return []
    }

    @objc func draggingExited(_ sender: NSDraggingInfo?) {
        onFileDragCount(0)
    }

    @objc func draggingEnded(_ sender: NSDraggingInfo) {
        onFileDragCount(0)
        onFileDragEnded()
    }
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

/// Drop-target callbacks are not physical pointer truth: SwiftUI can remove a
/// row destination during a refresh, and bare panel areas may reject a drag.
/// A drag-opened panel must nevertheless stay visible while the user is still
/// holding a mouse button with the pointer inside the panel.
func shouldDeferDragClose(pressedMouseButtons: Int,
                          pointerInsidePanel: Bool) -> Bool {
    pressedMouseButtons != 0 && pointerInsidePanel
}

@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
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
        panel.registerForDraggedTypes([.fileURL])
        return panel
    }()
    /// This host must survive folder navigation. Replacing a visible panel's
    /// contentViewController makes AppKit collapse it to 0x0 at its old top
    /// edge, then re-expand upward off-screen.
    private var panelHost: NSHostingController<PopoverRootView>?
    private let state = UIState()
    private let viewCounts = ShareViewCountState()
    private var store: ShareStore?
    private var settingsWindow: NSWindow?
    private var openedByDrag = false
    private var activeDropTargets = ActiveDropTargets()
    private var pendingDragClose: DispatchWorkItem?
    private var pendingClientRebuild = false
    private var dropPill: DropPillController?
    private let panelDropTargetID = "popover-window"
    private let iconDropTargetID = "status-icon"

    var hasCredentials: Bool { client != nil }

    private lazy var uploads: UploadCoordinator = {
        let coordinator = UploadCoordinator(state: state)
        coordinator.setIcon = { [weak self] progress in
            self?.setIcon(progress: progress)
            if progress == nil { self?.applyPendingClientRebuild() }
        }
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
            overlay.onDrop = { [weak self] urls in
                self?.handleDrop(urls: urls) ?? false
            }
            overlay.canAcceptDrop = { [weak self] in
                guard let self else { return false }
                return self.client != nil && !self.uploads.busy
            }
            overlay.onClick = { [weak self] in self?.toggleList() }
            overlay.onRightClick = { [weak self] in self?.showContextMenu() }
            overlay.onDragEntered = { [weak self] count in
                self?.dragEnteredIcon(fileCount: count)
            }
            overlay.onDragExited = { [weak self] in self?.dragExitedIcon() }
            overlay.onDragEnded = { [weak self] in self?.endFileDragPreview() }
            button.addSubview(overlay)
        }

        panel.onFileDragCount = { [weak self] count in
            self?.setPanelFileDragCount(count)
        }
        panel.onFileDragEnded = { [weak self] in
            self?.endFileDragPreview()
        }

        rebuildClient()

        // The floating drop pill: on by default, driven by the same shared
        // state as the popover. Its callbacks never touch the store, so it is
        // wired once here and never rebuilt.
        let pillActions = DropPillActions(
            dropped: { [weak self] urls in
                self?.handleDrop(urls: urls, presentsList: false)
            },
            droppedSeparately: { [weak self] urls in
                self?.handleSeparateDrop(urls: urls, presentsList: false)
            },
            copy: { text in copyToClipboard(text) },
            open: { text in
                if let url = URL(string: text) { NSWorkspace.shared.open(url) }
            },
            cancelUpload: { [weak self] in self?.uploads.cancel() },
            capture: { [weak self] mode in
                guard let self, self.dropPill?.wasJustDragged != true else { return }
                self.beginCapture(mode, presentsList: false)
            },
            isListOpen: { [weak self] in self?.panel.isVisible ?? false })
        dropPill = DropPillController(state: state, actions: pillActions)
        if DropPillController.shouldShow { dropPill?.show() }
    }

    /// (Re)creates the client, store, and popover content from the stored
    /// configuration. Called at startup and after Settings changes.
    func rebuildClient() {
        guard !uploads.busy else {
            pendingClientRebuild = true
            notify(title: "Dropper",
                   body: "Your new settings will take effect when the current upload finishes.")
            return
        }
        pendingClientRebuild = false
        let oldClient = client
        let credentials = ConfigStore.resolveCredentials()
        var config: AppConfigSnapshot?
        do {
            config = try ConfigStore.validatedSnapshot()
        } catch {
            // A user who has connected a token deserves to know exactly why
            // the app suddenly acts unconfigured — validation rules can
            // tighten between releases.
            config = nil
            if credentials != nil {
                notify(title: "Dropper",
                       body: "Your saved settings are invalid — open Settings to fix them. \(error.localizedDescription)")
            }
        }
        viewCounts.reset()
        if let config, let credentials {
            client = R2Client(credentials: credentials, config: config)
        } else {
            client = nil
        }
        store = client.map { ShareStore(client: $0, viewCounts: viewCounts) }
        uploads.client = client
        uploads.store = store
        oldClient?.invalidateAndCancel()

        let actions = PopoverActions(
            dropped: { [weak self] urls in self?.handleDrop(urls: urls) },
            droppedSeparately: { [weak self] urls in
                self?.handleSeparateDrop(urls: urls)
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

    private func applyPendingClientRebuild() {
        guard pendingClientRebuild, !uploads.busy else { return }
        rebuildClient()
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
        state.clearDraggedFiles()
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
    private func dragEnteredIcon(fileCount: Int) {
        pendingDragClose?.cancel()
        pendingDragClose = nil
        state.setDraggedFileCount(fileCount, for: iconDropTargetID)
        setDropTarget(iconDropTargetID, active: fileCount > 0)
        if !panel.isVisible {
            openedByDrag = true
            openList()
        }
    }

    /// If the dropdown auto-opened for this drag and nothing was dropped,
    /// close it again once the drag moves away (the strip cancels this while
    /// it's the drop target).
    private func dragExitedIcon() {
        state.setDraggedFileCount(0, for: iconDropTargetID)
        setDropTarget(iconDropTargetID, active: false)
    }

    private func setPanelFileDragCount(_ count: Int) {
        state.setDraggedFileCount(count, for: panelDropTargetID)
        setDropTarget(panelDropTargetID, active: count > 0)
    }

    /// AppKit sends draggingEnded even when another nested destination wins
    /// or the drag is cancelled, so no stale split preview can remain.
    private func endFileDragPreview() {
        state.clearDraggedFiles()
        activeDropTargets.removeAll()
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

    private func scheduleDragClose(after delay: TimeInterval = 0.9) {
        guard openedByDrag, !uploads.busy, activeDropTargets.isEmpty else { return }
        pendingDragClose?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.openedByDrag, !self.uploads.busy,
                  self.activeDropTargets.isEmpty else { return }

            // A destination can disappear beneath a stationary drag when the
            // list refreshes, and the panel's bare areas are non-consuming.
            // Neither means the user stopped hovering the open dropdown.
            if shouldDeferDragClose(
                pressedMouseButtons: NSEvent.pressedMouseButtons,
                pointerInsidePanel: self.panel.frame.contains(NSEvent.mouseLocation)
            ) {
                self.pendingDragClose = nil
                self.scheduleDragClose(after: 0.25)
                return
            }

            self.openedByDrag = false
            self.closePopover()
        }
        pendingDragClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A destination accepted the drop; provider resolution may still be
    /// asynchronous, but the auto-open timer must not close the panel now.
    private func commitDrop() {
        openedByDrag = false
        pendingDragClose?.cancel()
        pendingDragClose = nil
        activeDropTargets.removeAll()
        state.clearDraggedFiles()
    }

    // MARK: - Upload

    @discardableResult
    func handleDrop(urls: [URL], presentsList: Bool = true) -> Bool {
        guard !urls.isEmpty else { return false }
        guard client != nil else {
            notify(title: "Dropper", body: "Run the Setup Wizard before uploading files.")
            return false
        }
        guard !uploads.busy else {
            notify(title: "Dropper", body: "An upload is already in progress.")
            return false
        }
        commitDrop()
        uploads.upload(urls: urls, into: nil, presentsList: presentsList)
        return true
    }

    private func handleSeparateDrop(urls: [URL], presentsList: Bool = true) {
        guard !urls.isEmpty else { return }
        guard client != nil else {
            notify(title: "Dropper", body: "Run the Setup Wizard before uploading files.")
            return
        }
        guard !uploads.busy else {
            notify(title: "Dropper", body: "An upload is already in progress.")
            return
        }
        commitDrop()
        uploads.uploadSeparately(urls: urls, presentsList: presentsList)
    }

    /// Appends a row drop to that exact share. A stale/missing destination is
    /// rejected rather than silently creating an unrelated new share.
    func handleAddDrop(urls: [URL], to shareID: String) {
        guard !urls.isEmpty else { return }
        guard client != nil else {
            notify(title: "Dropper", body: "Run the Setup Wizard before uploading files.")
            return
        }
        guard !uploads.busy else {
            notify(title: "Dropper", body: "An upload is already in progress.")
            return
        }
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

    // MARK: - Window builders

    /// Builds a titled window hosting a SwiftUI view with the chrome the app's
    /// windows share. Positioning and presentation stay with the caller.
    private func makeHostedWindow(
        title: String, size: NSSize, styleMask: NSWindow.StyleMask,
        minSize: NSSize, content: some View
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask, backing: .buffered, defer: false)
        window.title = title
        window.contentView = NSHostingView(rootView: content)
        window.contentMinSize = minSize
        window.isReleasedWhenClosed = false
        return window
    }

    // MARK: - Onboarding

    private var onboardingWindow: NSWindow?
    private var onboardingModel: OnboardingModel?

    func openOnboarding() {
        guard !uploads.busy else {
            notify(title: "Dropper",
                   body: "Wait for the current upload to finish before running setup.")
            return
        }
        onboardingWindow?.close()
        let model = OnboardingModel()
        onboardingModel = model
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
        let window = makeHostedWindow(
            title: "Set Up Dropper",
            size: NSSize(width: 520, height: contentHeight),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            minSize: NSSize(width: 500, height: 500),
            content: view)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.delegate = self
        window.center()
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === onboardingWindow else { return }
        onboardingModel?.cancel()
        onboardingModel = nil
        onboardingWindow = nil
    }

    // MARK: - Settings

    func openSettings() {
        // Fresh window each time so the fields re-read the stored config.
        settingsWindow?.close()
        let targetScreen = statusItem.button?.window?.screen ?? NSScreen.main
        let availableHeight = max(360, (targetScreen?.visibleFrame.height ?? 680) - 40)
        let contentHeight = min(640, availableHeight)
        let view = SettingsView(
            viewCounts: viewCounts,
            onSave: { [weak self] in self?.rebuildClient() },
            onViewCountsChanged: { [weak self] in
                self?.store?.refreshViewCounts(force: true)
            },
            onClose: { [weak self] in self?.settingsWindow?.close() },
            canSave: { [weak self] in self?.uploads.busy == false })
        let window = makeHostedWindow(
            title: "Dropper Settings",
            size: NSSize(width: 460, height: contentHeight),
            styleMask: [.titled, .closable, .resizable],
            minSize: NSSize(width: 460, height: min(520, contentHeight)),
            content: view)
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

    private lazy var notchMenuItem: NSMenuItem = {
        let item = NSMenuItem(title: "Show Notch",
                              action: #selector(toggleNotchFromMenu), keyEquivalent: "")
        item.target = self
        return item
    }()

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
        menu.addItem(notchMenuItem)
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

    @objc private func toggleNotchFromMenu() {
        guard let dropPill else { return }
        dropPill.setVisible(!dropPill.isVisible)
    }

    @objc private func captureAreaFromMenu() { beginCapture(.area) }
    @objc private func captureWindowFromMenu() { beginCapture(.window) }
    @objc private func captureScreenFromMenu() { beginCapture(.display) }

    private func beginCapture(_ mode: CaptureMode, presentsList: Bool = true) {
        closePopover()
        CaptureFlow.begin(
            mode: mode,
            onComplete: { [weak self] url in
                self?.handleDrop(urls: [url], presentsList: presentsList)
            },
            onFailure: { [weak self] message in
                self?.notify(title: "Capture failed", body: message)
            },
            onLanded: { Sounds.drop?.play() })
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        let notchIsVisible = dropPill?.isVisible == true
        notchMenuItem.title = notchIsVisible ? "Hide Notch" : "Show Notch"
        notchMenuItem.state = notchIsVisible ? .on : .off
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
    var onDrop: ([URL]) -> Bool = { _ in false }
    var canAcceptDrop: () -> Bool = { true }
    var onClick: () -> Void = {}
    var onRightClick: () -> Void = {}
    var onDragEntered: (Int) -> Void = { _ in }
    var onDragExited: () -> Void = {}
    var onDragEnded: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Dropper")
        setAccessibilityHelp("Open Dropper, or drop files here to upload them.")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let count = advertisedFileCount(in: sender)
        guard count > 0, canAcceptDrop() else { return [] }
        onDragEntered(count)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExited()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragEnded()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty, canAcceptDrop() else { return false }
        return onDrop(urls)
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

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}
