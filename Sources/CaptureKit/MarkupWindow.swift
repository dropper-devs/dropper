import AppKit

/// How the markup session ended.
public enum MarkupExit {
    case cancelled
    case upload(CGImage)
    case saveToDesktop(CGImage)
}

/// One window: toolbar (tools, colors, Cancel/Upload) over an editable canvas.
/// Shapes stay vector until an exit action flattens them to a CGImage.
@MainActor
public final class MarkupWindowController: NSWindowController, NSWindowDelegate {
    private let canvas: MarkupCanvasView
    private let imageSize: CGSize
    private var toolButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private var cropApplyButton: NSButton?
    private var uploadButton: NSButton?
    private var onFinish: ((MarkupExit) -> Void)?
    private let captureTitle: String
    private let titleLabel = PassthroughTitleLabel(labelWithString: "")
    private enum ColorTarget { case stroke, fill }
    private var colorTarget: ColorTarget = .stroke
    private var noFillButton: NSButton?
    private var strokeColorIndex = 0
    private var chosenFillColorIndex: Int?

    /// One slot in the tool rail. `pointer` and `crop` are the non-drawing
    /// modes; `shape` carries the drawing tool it selects.
    private enum ToolItem {
        case pointer
        case crop
        case shape(MarkupTool)

        var tool: MarkupTool? {
            if case let .shape(tool) = self { return tool }
            return nil
        }

        var isPointer: Bool {
            if case .pointer = self { return true }
            return false
        }

        var symbol: String {
            switch self {
            case .pointer: "cursorarrow"
            case .crop: "crop"
            case .shape(let tool):
                switch tool {
                case .arrow: "arrow.up.right"
                case .line: "line.diagonal"
                case .ellipse: "circle"
                case .rect: "rectangle"
                case .pen: "scribble"
                case .text: "textformat"
                }
            }
        }

        var tip: String {
            switch self {
            case .pointer: "Select / drag image"
            case .crop: "Crop"
            case .shape(let tool):
                switch tool {
                case .arrow: "Arrow"
                case .line: "Line"
                case .ellipse: "Ellipse"
                case .rect: "Rectangle"
                case .pen: "Draw"
                case .text: "Text"
                }
            }
        }
    }

    private static let tools: [ToolItem] = [
        .pointer, .crop, .shape(.arrow), .shape(.line),
        .shape(.ellipse), .shape(.rect), .shape(.pen), .shape(.text),
    ]

    /// Where the pointer sits in `tools` — the crop exit and initial selection
    /// return to it. Derived, so it can't drift from the array above.
    private static let pointerToolIndex = tools.firstIndex { $0.isPointer } ?? 0

    public init(image: CGImage, scale: CGFloat, captureTitle: String,
                onFinish: @escaping (MarkupExit) -> Void) {
        self.canvas = MarkupCanvasView(image: image, scale: scale)
        self.imageSize = CGSize(width: image.width, height: image.height)
        self.captureTitle = captureTitle
        self.onFinish = onFinish

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize(for: image, scale: scale)),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "\(captureTitle) — \(image.width) × \(image.height)"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        // No system appearance animation — the intro drives the grow-in itself.
        window.animationBehavior = .none
        // Markup windows intentionally remain available to ScreenCaptureKit so
        // a later capture can include an earlier editor window.
        window.sharingType = .readOnly
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: Self.minimumWindowWidth,
                                height: Self.minimumWindowHeight)
        super.init(window: window)
        window.delegate = self

        buildContent(in: window)
        installCenteredTitle(in: window)
        updateWindowTitle(CGSize(width: image.width, height: image.height))
        canvas.onApplyCrop = { [weak self] in self?.applyCropClicked() }
        canvas.onCancelCrop = { [weak self] in self?.selectTool(at: Self.pointerToolIndex) }
        canvas.onImageSizeChanged = { [weak self] size in self?.updateWindowTitle(size) }
        selectTool(at: Self.pointerToolIndex)
        selectColor(at: 0)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateWindowTitle(_ size: CGSize) {
        let title = "\(captureTitle) — \(Int(size.width)) × \(Int(size.height))"
        window?.title = title
        titleLabel.stringValue = title
    }

    public func present() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Centers the editor *around a point* (the middle of the captured region),
    /// clamped fully within that point's screen — so the frame assembles right
    /// where the shot was taken, on its own monitor.
    public func center(around point: CGPoint) {
        guard let window else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? window.frame
        let frame = window.frame
        var origin = NSPoint(x: point.x - frame.width / 2, y: point.y - frame.height / 2)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - frame.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - frame.height)
        window.setFrameOrigin(origin)
    }

    /// The canvas (the screenshot) in global AppKit points — where the capture
    /// intro should land its ghost so the hand-off is seamless.
    public func canvasScreenFrame() -> CGRect {
        guard let window else { return .zero }
        window.layoutIfNeeded()
        let canvasRect = window.convertToScreen(canvas.convert(canvas.bounds, to: nil))
        // Land the intro's ghost on the IMAGE's rect (aspect-fit inside the
        // canvas), not the canvas view's frame — otherwise it interpolates
        // toward the canvas aspect and squishes on the way down.
        guard imageSize.width > 0, imageSize.height > 0,
              canvasRect.width > 0, canvasRect.height > 0 else { return canvasRect }
        let scale = min(canvasRect.width / imageSize.width,
                        canvasRect.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: canvasRect.midX - size.width / 2,
                      y: canvasRect.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Presents the editor growing in from a slightly smaller frame while it
    /// fades up — the "window forms around the screenshot" beat of the intro.
    public func presentGrowing() {
        guard let window else { return present() }
        // The canvas image stays hidden while the frame assembles — otherwise it
        // sits under the intro's still-animating ghost and reads as a double.
        canvas.alphaValue = 0
        let full = window.frame
        let start = full.insetBy(dx: full.width * 0.05, dy: full.height * 0.05)
        window.setFrame(start, display: false)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3 * captureSlowMo
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(full, display: true)
            window.animator().alphaValue = 1
        }
    }

    /// Reveals the canvas image once the intro's ghost has landed on it. Instant,
    /// NOT a fade: the ghost fades out on top of a now-solid canvas, so the image
    /// is always fully opaque — no cross-fade brightness dip (the flicker) from
    /// two identical half-transparent copies overlapping.
    public func revealCanvas() {
        canvas.alphaValue = 1
    }

    // MARK: - Layout

    private static func windowSize(for image: CGImage, scale: CGFloat) -> NSSize {
        let points = NSSize(width: CGFloat(image.width) / scale,
                            height: CGFloat(image.height) / scale)
        let hPad = toolRailLeading + toolButtonSize + toolRailCanvasGap + canvasInset
        let vPad = titlebarHeight + toolbarHeight + 10 + canvasInset
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let fit = min(1, (available.width * 0.85 - hPad) / points.width,
                      (available.height * 0.85 - vPad) / points.height)
        return NSSize(width: max(minimumWindowWidth, points.width * fit + hPad),
                      height: max(minimumWindowHeight, points.height * fit + vPad))
    }

    private static let titlebarHeight: CGFloat = 40
    private static let toolbarHeight: CGFloat = 56
    private static let toolButtonSize: CGFloat = 40
    private static let toolSymbolSize: CGFloat = 16
    private static let minimumWindowWidth: CGFloat = 760
    private static let minimumWindowHeight: CGFloat = 490
    private static let toolRailLeading: CGFloat = 20
    private static let toolRailCanvasGap: CGFloat = 20

    private func installCenteredTitle(in window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let titlebar = close.superview else { return }

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        // Keep Command-Q local to the active capture editor. The button's
        // window-scoped key equivalent handles it before the app menu can.
        cancel.keyEquivalent = "q"
        cancel.keyEquivalentModifierMask = [.command]
        let save = NSButton(title: "Save to Desktop", target: self,
                            action: #selector(saveToDesktopClicked))
        let upload = NSButton(title: "Upload", target: self, action: #selector(uploadClicked))
        for button in [cancel, save, upload] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        upload.keyEquivalent = "\r"
        uploadButton = upload

        let actions = NSStackView(views: [cancel, save, upload])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.setContentHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)

        titlebar.addSubview(titleLabel)
        titlebar.addSubview(actions)
        NSLayoutConstraint.activate([
            actions.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor, constant: -10),
            titleLabel.centerXAnchor.constraint(equalTo: titlebar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: zoom.trailingAnchor,
                                                constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor,
                                                 constant: -12),
        ])
    }

    private func buildContent(in window: NSWindow) {
        // Glassy chrome, matching the dropdown: the window is a frosted panel
        // and the screenshot floats inside it with visible padding.
        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let toolRail = makeToolRail()

        let applyCrop = NSButton(title: "Apply Crop",
                                 target: self, action: #selector(applyCropClicked))
        applyCrop.bezelStyle = .rounded
        applyCrop.isHidden = true
        applyCrop.heightAnchor.constraint(equalToConstant: 42).isActive = true
        cropApplyButton = applyCrop
        toolbar.addArrangedSubview(applyCrop)
        toolbar.setCustomSpacing(14, after: applyCrop)

        for control in makeColorControls() {
            toolbar.addArrangedSubview(control)
        }
        if let lastSwatch = colorButtons.last {
            toolbar.setCustomSpacing(14, after: lastSwatch)
        }

        for control in makeSizeControls() {
            toolbar.addArrangedSubview(control)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        toolbar.addArrangedSubview(spacer)

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.wantsLayer = true
        canvas.layer?.cornerRadius = 8
        canvas.layer?.masksToBounds = true
        let titlebarSeparator = ToolbarSeparatorView()
        titlebarSeparator.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(titlebarSeparator)
        content.addSubview(toolbar)
        content.addSubview(toolRail)
        content.addSubview(canvas)
        NSLayoutConstraint.activate([
            titlebarSeparator.topAnchor.constraint(
                equalTo: content.topAnchor, constant: Self.titlebarHeight - 1
            ),
            titlebarSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            titlebarSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            titlebarSeparator.heightAnchor.constraint(equalToConstant: 1),
            // Keep the titlebar row clear so the window remains easy to grab.
            toolbar.topAnchor.constraint(equalTo: titlebarSeparator.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            toolbar.heightAnchor.constraint(equalToConstant: Self.toolbarHeight),
            toolRail.topAnchor.constraint(equalTo: canvas.topAnchor),
            toolRail.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                              constant: Self.toolRailLeading),
            toolRail.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor,
                                             constant: -Self.canvasInset),
            // Generous padding so the glass reads around the floating image.
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            canvas.leadingAnchor.constraint(equalTo: toolRail.trailingAnchor,
                                             constant: Self.toolRailCanvasGap),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.canvasInset),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.canvasInset),
        ])
        window.contentView = content
    }

    /// The vertical tool rail down the canvas's left edge; each button's tag
    /// is its index into `tools`.
    private func makeToolRail() -> NSStackView {
        let toolRail = NSStackView()
        toolRail.orientation = .vertical
        toolRail.alignment = .centerX
        toolRail.spacing = 6
        toolRail.translatesAutoresizingMaskIntoConstraints = false

        for (index, entry) in Self.tools.enumerated() {
            guard let symbol = NSImage(systemSymbolName: entry.symbol,
                                       accessibilityDescription: entry.tip)
            else { continue }
            let large = symbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: Self.toolSymbolSize, weight: .regular
                )) ?? symbol
            let button = SquareToolbarButton(
                image: large,
                target: self, action: #selector(toolClicked(_:)))
            button.setButtonType(.pushOnPushOff)
            button.toolTip = entry.tip
            button.tag = index
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: Self.toolButtonSize).isActive = true
            button.heightAnchor.constraint(equalToConstant: Self.toolButtonSize).isActive = true
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentHuggingPriority(.required, for: .vertical)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .vertical)
            toolButtons.append(button)
            toolRail.addArrangedSubview(button)
        }
        return toolRail
    }

    /// Stroke/Fill target selector, the no-fill button, then one swatch per
    /// palette color, in toolbar order. Populates `colorButtons`/`noFillButton`.
    private func makeColorControls() -> [NSView] {
        let target = NSSegmentedControl(labels: ["Stroke", "Fill"],
                                        trackingMode: .selectOne,
                                        target: self,
                                        action: #selector(colorTargetChanged(_:)))
        target.selectedSegment = 0
        target.toolTip = "Choose whether the palette edits the stroke or fill"
        target.widthAnchor.constraint(equalToConstant: 104).isActive = true
        target.heightAnchor.constraint(equalToConstant: 42).isActive = true

        let noFillSymbol = NSImage(systemSymbolName: "nosign",
                                   accessibilityDescription: "No fill") ?? NSImage()
        let noFill = NSButton(image: noFillSymbol,
                              target: self, action: #selector(colorClicked(_:)))
        noFill.bezelStyle = .texturedRounded
        noFill.setButtonType(.pushOnPushOff)
        noFill.toolTip = "No fill"
        noFill.setAccessibilityLabel("No fill")
        noFill.setAccessibilityRole(.radioButton)
        noFill.tag = -1
        noFill.translatesAutoresizingMaskIntoConstraints = false
        noFill.widthAnchor.constraint(equalToConstant: 38).isActive = true
        noFill.heightAnchor.constraint(equalToConstant: 48).isActive = true
        noFillButton = noFill

        var controls: [NSView] = [target, noFill]
        for index in 0..<MarkupPalette.colors.count {
            let button = NSButton(image: Self.swatchImage(colorIndex: index, selected: false),
                                  target: self, action: #selector(colorClicked(_:)))
            button.isBordered = false
            button.setButtonType(.pushOnPushOff)
            button.tag = index
            button.setAccessibilityLabel(MarkupPalette.colors[index].name)
            button.setAccessibilityRole(.radioButton)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 38).isActive = true
            button.heightAnchor.constraint(equalToConstant: 48).isActive = true
            colorButtons.append(button)
            controls.append(button)
        }
        return controls
    }

    /// Stroke-width slider followed by the output-size popup, in toolbar order.
    private func makeSizeControls() -> [NSView] {
        let stroke = NSSlider(value: Double(MarkupPrefs.strokePoints),
                              minValue: 1, maxValue: 12,
                              target: self, action: #selector(strokeChanged(_:)))
        stroke.toolTip = "Stroke width"
        stroke.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let size = NSPopUpButton(frame: .zero, pullsDown: false)
        size.addItems(withTitles: ["Size: 100%", "Size: 75%", "Size: 50%"])
        size.selectItem(at: 0)
        size.target = self
        size.action = #selector(sizeChanged(_:))
        size.toolTip = "Output image size"
        size.widthAnchor.constraint(equalToConstant: 108).isActive = true
        size.heightAnchor.constraint(equalToConstant: 42).isActive = true

        return [stroke, size]
    }

    private static let canvasInset: CGFloat = 22

    private static func swatchImage(colorIndex: Int, selected: Bool) -> NSImage {
        let side: CGFloat = 34
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
            MarkupPalette.nsColor(colorIndex).setFill()
            circle.fill()
            NSColor.tertiaryLabelColor.setStroke()
            circle.lineWidth = 1
            circle.stroke()
            if selected {
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                NSColor.controlAccentColor.setStroke()
                ring.stroke()
            }
            return true
        }
    }

    // MARK: - Actions

    @objc private func toolClicked(_ sender: NSButton) {
        selectTool(at: sender.tag)
    }

    private func selectTool(at index: Int) {
        for button in toolButtons {
            button.state = button.tag == index ? .on : .off
        }
        if case .crop = Self.tools[index] {
            canvas.beginCropping()
            cropApplyButton?.isHidden = false
            cropApplyButton?.keyEquivalent = "\r"
            uploadButton?.keyEquivalent = ""
        } else {
            canvas.cancelCropping()
            canvas.currentTool = Self.tools[index].tool
            cropApplyButton?.isHidden = true
            cropApplyButton?.keyEquivalent = ""
            uploadButton?.keyEquivalent = "\r"
        }
        window?.makeFirstResponder(canvas)
    }

    @objc private func applyCropClicked() {
        guard canvas.applyCrop() else {
            NSSound.beep()
            return
        }
        selectTool(at: Self.pointerToolIndex)
    }

    @objc private func colorClicked(_ sender: NSButton) {
        selectColor(at: sender.tag)
    }

    @objc private func colorTargetChanged(_ sender: NSSegmentedControl) {
        colorTarget = sender.selectedSegment == 0 ? .stroke : .fill
        refreshColorButtons()
        window?.makeFirstResponder(canvas)
    }

    private func selectColor(at index: Int) {
        switch colorTarget {
        case .stroke:
            guard index >= 0 else { return }
            strokeColorIndex = index
            canvas.setColorIndex(index)
        case .fill:
            chosenFillColorIndex = index >= 0 ? index : nil
            canvas.setFillColorIndex(chosenFillColorIndex)
        }
        refreshColorButtons()
        window?.makeFirstResponder(canvas)
    }

    private func refreshColorButtons() {
        let selected = colorTarget == .stroke ? strokeColorIndex : chosenFillColorIndex
        for button in colorButtons {
            let isSelected = button.tag == selected
            let wasSelected = button.state == .on
            button.image = Self.swatchImage(colorIndex: button.tag,
                                            selected: isSelected)
            button.state = isSelected ? .on : .off
            button.setAccessibilityValue(NSNumber(value: isSelected))
            if wasSelected != isSelected {
                NSAccessibility.post(element: button, notification: .valueChanged)
            }
        }
        noFillButton?.isEnabled = colorTarget == .fill
        let noFillSelected = colorTarget == .fill && chosenFillColorIndex == nil
        if let noFillButton {
            let wasSelected = noFillButton.state == .on
            noFillButton.state = noFillSelected ? .on : .off
            noFillButton.setAccessibilityValue(NSNumber(value: noFillSelected))
            if wasSelected != noFillSelected {
                NSAccessibility.post(element: noFillButton, notification: .valueChanged)
            }
        }
    }

    @objc private func strokeChanged(_ sender: NSSlider) {
        let points = CGFloat(sender.doubleValue)
        MarkupPrefs.strokePoints = points  // persisted on every tick
        canvas.setStrokeWidth(points: points)
    }

    @objc private func sizeChanged(_ sender: NSPopUpButton) {
        let scales: [CGFloat] = [1, 0.75, 0.5]
        canvas.setOutputScale(scales[min(max(sender.indexOfSelectedItem, 0), scales.count - 1)])
        window?.makeFirstResponder(canvas)
    }

    @objc private func uploadClicked() {
        guard let flattened = canvas.flattened() else {
            NSSound.beep()
            return
        }
        finish(with: .upload(flattened))
    }

    @objc private func saveToDesktopClicked() {
        guard let flattened = canvas.flattened() else {
            NSSound.beep()
            return
        }
        finish(with: .saveToDesktop(flattened))
    }

    @objc private func cancelClicked() {
        finish(with: .cancelled)
    }

    private func finish(with exit: MarkupExit) {
        let callback = onFinish
        onFinish = nil
        window?.delegate = nil
        window?.close()
        callback?(exit)
    }

    public func windowWillClose(_ notification: Notification) {
        // Title-bar close is a cancel.
        let callback = onFinish
        onFinish = nil
        callback?(.cancelled)
    }
}
