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
    private var toolButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private var cropApplyButton: NSButton?
    private var uploadButton: NSButton?
    private var onFinish: ((MarkupExit) -> Void)?
    private let captureTitle: String
    private let titleLabel = PassthroughTitleLabel(labelWithString: "")
    private enum ColorTarget { case stroke, fill }
    private var colorTarget: ColorTarget = .stroke
    private var colorTargetControl: NSSegmentedControl?
    private var noFillButton: NSButton?
    private var strokeColorIndex = 0
    private var chosenFillColorIndex: Int?

    private static let tools: [(tool: MarkupTool?, isCrop: Bool, symbol: String, tip: String)] = [
        (nil, false, "cursorarrow", "Select / drag image"),
        (nil, true, "crop", "Crop"),
        (.arrow, false, "arrow.up.right", "Arrow"),
        (.line, false, "line.diagonal", "Line"),
        (.ellipse, false, "circle", "Ellipse"),
        (.rect, false, "rectangle", "Rectangle"),
        (.pen, false, "scribble", "Draw"),
        (.text, false, "textformat", "Text"),
    ]

    /// Where the pointer sits in `tools` — the entry crop exit and the
    /// initial selection return to. Keep in step with the array above.
    private static let pointerToolIndex = 0

    public init(image: CGImage, scale: CGFloat, captureTitle: String,
                onFinish: @escaping (MarkupExit) -> Void) {
        self.canvas = MarkupCanvasView(image: image, scale: scale)
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

        let applyCrop = NSButton(title: "Apply Crop",
                                 target: self, action: #selector(applyCropClicked))
        applyCrop.bezelStyle = .rounded
        applyCrop.isHidden = true
        applyCrop.heightAnchor.constraint(equalToConstant: 42).isActive = true
        cropApplyButton = applyCrop
        toolbar.addArrangedSubview(applyCrop)

        toolbar.setCustomSpacing(14, after: applyCrop)

        let target = NSSegmentedControl(labels: ["Stroke", "Fill"],
                                        trackingMode: .selectOne,
                                        target: self,
                                        action: #selector(colorTargetChanged(_:)))
        target.selectedSegment = 0
        target.toolTip = "Choose whether the palette edits the stroke or fill"
        target.widthAnchor.constraint(equalToConstant: 104).isActive = true
        target.heightAnchor.constraint(equalToConstant: 42).isActive = true
        colorTargetControl = target
        toolbar.addArrangedSubview(target)

        let noFillSymbol = NSImage(systemSymbolName: "nosign",
                                   accessibilityDescription: "No fill") ?? NSImage()
        let noFill = NSButton(image: noFillSymbol,
                              target: self, action: #selector(colorClicked(_:)))
        noFill.bezelStyle = .texturedRounded
        noFill.setButtonType(.pushOnPushOff)
        noFill.toolTip = "No fill"
        noFill.tag = -1
        noFill.translatesAutoresizingMaskIntoConstraints = false
        noFill.widthAnchor.constraint(equalToConstant: 38).isActive = true
        noFill.heightAnchor.constraint(equalToConstant: 48).isActive = true
        noFillButton = noFill
        toolbar.addArrangedSubview(noFill)

        for index in 0..<MarkupPalette.colors.count {
            let button = NSButton(image: Self.swatchImage(colorIndex: index, selected: false),
                                  target: self, action: #selector(colorClicked(_:)))
            button.isBordered = false
            button.tag = index
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 38).isActive = true
            button.heightAnchor.constraint(equalToConstant: 48).isActive = true
            colorButtons.append(button)
            toolbar.addArrangedSubview(button)
        }

        if let lastSwatch = colorButtons.last {
            toolbar.setCustomSpacing(14, after: lastSwatch)
        }

        let stroke = NSSlider(value: Double(MarkupPrefs.strokePoints),
                              minValue: 1, maxValue: 12,
                              target: self, action: #selector(strokeChanged(_:)))
        stroke.toolTip = "Stroke width"
        stroke.widthAnchor.constraint(equalToConstant: 110).isActive = true
        toolbar.addArrangedSubview(stroke)

        let size = NSPopUpButton(frame: .zero, pullsDown: false)
        size.addItems(withTitles: ["Size: 100%", "Size: 75%", "Size: 50%"])
        size.selectItem(at: 0)
        size.target = self
        size.action = #selector(sizeChanged(_:))
        size.toolTip = "Output image size"
        size.widthAnchor.constraint(equalToConstant: 108).isActive = true
        size.heightAnchor.constraint(equalToConstant: 42).isActive = true
        toolbar.addArrangedSubview(size)

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

    private static let canvasInset: CGFloat = 22

    private static func swatchImage(colorIndex: Int, selected: Bool) -> NSImage {
        let side: CGFloat = 34
        let color = MarkupPalette.colors[colorIndex]
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
            NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1).setFill()
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
        let entry = Self.tools[index]
        if entry.isCrop {
            canvas.beginCropping()
            cropApplyButton?.isHidden = false
            cropApplyButton?.keyEquivalent = "\r"
            uploadButton?.keyEquivalent = ""
        } else {
            canvas.cancelCropping()
            canvas.currentTool = entry.tool
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
            button.image = Self.swatchImage(colorIndex: button.tag,
                                            selected: button.tag == selected)
        }
        noFillButton?.isEnabled = colorTarget == .fill
        noFillButton?.state = colorTarget == .fill && chosenFillColorIndex == nil ? .on : .off
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
