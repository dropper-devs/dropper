import AppKit

/// Lets titlebar drags pass straight through the centered title text.
private final class PassthroughTitleLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A toolbar control whose visible bezel fills its actual square bounds.
/// AppKit's textured bezel paints at a fixed control height even when the
/// button frame is square, which made the old controls still look pill-shaped.
private final class SquareToolbarButton: NSButton {
    private var isHovering = false

    /// Make Auto Layout constrain the painted frame itself. NSButton's default
    /// per-image alignment insets otherwise turn a square alignment rectangle
    /// into a visibly taller, symbol-dependent frame.
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    init(image: NSImage, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.image = image
        self.imagePosition = .imageOnly
        self.imageScaling = .scaleProportionallyDown
        self.target = target
        self.action = action
        isBordered = false
        focusRingType = .none
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        guard let layer else { return }

        let fill: NSColor
        if !isEnabled {
            fill = .clear
        } else if state == .on {
            fill = NSColor.controlAccentColor.withAlphaComponent(0.24)
        } else if isHighlighted || isHovering {
            fill = NSColor.labelColor.withAlphaComponent(0.10)
        } else {
            fill = NSColor.labelColor.withAlphaComponent(0.045)
        }

        layer.cornerRadius = 8
        layer.backgroundColor = fill.cgColor
        layer.borderWidth = 1
        layer.borderColor = NSColor.separatorColor.withAlphaComponent(
            state == .on ? 0.65 : 0.42
        ).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }
}

/// An explicit full-width hairline that stays visible over vibrant materials.
private final class ToolbarSeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
    }
}

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
        canvas.onCancelCrop = { [weak self] in self?.selectTool(at: 0) }
        canvas.onImageSizeChanged = { [weak self] size in self?.updateWindowTitle(size) }
        selectTool(at: 0)  // pointer/select
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
        return NSSize(width: max(1400, points.width * fit + hPad),
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
            let symbol = NSImage(systemSymbolName: entry.symbol,
                                 accessibilityDescription: entry.tip)!
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
                                   accessibilityDescription: "No fill")!
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

        toolbar.setCustomSpacing(14, after: colorButtons.last!)

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
        selectTool(at: 0)
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

/// Bitmap + vector shapes. Shapes live in image-pixel space (top-left origin)
/// and are mapped through a scale-to-fit transform for display and mouse math.
final class MarkupCanvasView: NSView, NSTextFieldDelegate, NSDraggingSource {
    private var baseImage: CGImage
    private var displayImage: NSImage
    private var imageSize: CGSize
    private let pixelScale: CGFloat
    private var currentStroke: CGFloat
    private var outputScale: CGFloat = 1
    var onApplyCrop: (() -> Void)?
    var onCancelCrop: (() -> Void)?
    var onImageSizeChanged: ((CGSize) -> Void)?

    var currentTool: MarkupTool? {  // nil: pointer/select mode
        didSet {
            commitTextEditing()
            window?.invalidateCursorRects(for: self)
        }
    }
    private var colorIndex = 0
    private var fillColorIndex: Int?
    private var shapes: [MarkupShape] = []
    private var selectedID: UUID?

    // In-place text entry: a borderless field floats over the canvas while a
    // text shape is being typed; the shape itself is hidden until commit.
    private var editingID: UUID?
    private var textEditor: NSTextField?

    private enum CropHandle: CaseIterable {
        case topLeft, top, topRight, right
        case bottomRight, bottom, bottomLeft, left
    }
    private var cropRect: CGRect?

    private enum Drag {
        case creating(UUID)
        case moving(UUID, last: CGPoint)
        case duplicating(MarkupShape, start: CGPoint)
        case resizing(UUID, MarkupHandle, original: MarkupShape)
        case rotating(UUID, original: MarkupShape, pointerOffset: CGFloat,
                      handleUsesBottom: Bool)
        case resizingCrop(CropHandle, original: CGRect)
        case movingCrop(original: CGRect, start: CGPoint)
        case exportingImage(start: CGPoint)
    }
    private var drag: Drag?

    init(image: CGImage, scale: CGFloat) {
        self.baseImage = image
        self.displayImage = NSImage(cgImage: image,
                                    size: NSSize(width: image.width, height: image.height))
        self.imageSize = CGSize(width: image.width, height: image.height)
        self.pixelScale = max(scale, 1)
        self.currentStroke = MarkupPrefs.strokePoints * max(scale, 1)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func setColorIndex(_ index: Int) {
        colorIndex = index
        if let selectedID, let position = shapes.firstIndex(where: { $0.id == selectedID }) {
            shapes[position].colorIndex = index
            needsDisplay = true
        }
        textEditor?.textColor = Self.nsColor(index)
    }

    func setFillColorIndex(_ index: Int?) {
        fillColorIndex = index
        if let selectedID, let position = shapes.firstIndex(where: { $0.id == selectedID }),
           (shapes[position].tool == .rect || shapes[position].tool == .ellipse) {
            shapes[position].fillColorIndex = index
            needsDisplay = true
        }
    }

    /// Screen-point stroke width for new shapes; restyles a selected stroked
    /// shape too. Text is resized only with its marquee corner handles.
    func setStrokeWidth(points: CGFloat) {
        currentStroke = points * pixelScale
        if let selectedID, let position = shapes.firstIndex(where: { $0.id == selectedID }) {
            if shapes[position].tool != .text {
                shapes[position].lineWidth = currentStroke
            }
            needsDisplay = true
        }
    }

    private var currentFontSize: CGFloat {
        24 * pixelScale
    }

    private static func nsColor(_ index: Int) -> NSColor {
        let color = MarkupPalette.colors[min(max(index, 0), MarkupPalette.colors.count - 1)]
        return NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    func flattened() -> CGImage? {
        commitTextEditing()  // typing in progress counts
        guard let fullSize = MarkupRender.flatten(image: baseImage, shapes: shapes) else {
            return nil
        }
        return MarkupRender.scaled(fullSize, by: outputScale)
    }

    func setOutputScale(_ scale: CGFloat) {
        outputScale = min(max(scale, 0.1), 1)
        if let editingID, let field = textEditor,
           let shape = shapes.first(where: { $0.id == editingID }) {
            field.font = editorFont(for: shape)
            positionTextEditor(field, for: shape)
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func beginCropping() {
        commitTextEditing()
        currentTool = nil
        selectedID = nil
        drag = nil
        cropRect = CGRect(origin: .zero, size: imageSize)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func cancelCropping() {
        guard cropRect != nil else { return }
        cropRect = nil
        drag = nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func cropPixelRect(_ rect: CGRect) -> CGRect {
        let minX = max(0, floor(rect.minX))
        let minY = max(0, floor(rect.minY))
        let maxX = min(imageSize.width, ceil(rect.maxX))
        let maxY = min(imageSize.height, ceil(rect.maxY))
        return CGRect(x: minX, y: minY,
                      width: maxX - minX, height: maxY - minY)
    }

    /// Commits a destructive crop. Existing annotations are baked in first so
    /// partially cropped strokes, arrowheads, and text remain visually exact.
    @discardableResult
    func applyCrop() -> Bool {
        commitTextEditing()
        guard let cropRect else { return false }
        let pixels = cropPixelRect(cropRect)
        if pixels == CGRect(origin: .zero, size: imageSize) {
            self.cropRect = nil
            drag = nil
            needsDisplay = true
            return true
        }
        guard pixels.width >= 1, pixels.height >= 1,
              let composited = MarkupRender.flatten(image: baseImage, shapes: shapes),
              let cropped = composited.cropping(to: pixels)
        else { return false }

        shapes.removeAll()
        baseImage = cropped
        displayImage = NSImage(cgImage: cropped,
                               size: NSSize(width: cropped.width, height: cropped.height))
        imageSize = CGSize(width: cropped.width, height: cropped.height)
        onImageSizeChanged?(imageSize)
        selectedID = nil
        self.cropRect = nil
        drag = nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        return true
    }

    // MARK: - Transform

    private var fitScale: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let scaleToFit = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        return scaleToFit * outputScale
    }

    private var fitRect: CGRect {
        let scale = fitScale
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2,
                      y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Kept in view points so the rotation knob feels identical at every
    /// screenshot resolution and output zoom.
    private var textRotationHandleOffset: CGFloat { 24 / fitScale }

    private func imagePoint(from viewPoint: CGPoint) -> CGPoint {
        let rect = fitRect
        return CGPoint(x: (viewPoint.x - rect.minX) / fitScale,
                       y: (viewPoint.y - rect.minY) / fitScale)
    }

    private func viewPoint(from imagePoint: CGPoint) -> CGPoint {
        let rect = fitRect
        return CGPoint(x: rect.minX + imagePoint.x * fitScale,
                       y: rect.minY + imagePoint.y * fitScale)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        displayImage.draw(in: fitRect)

        context.saveGState()
        context.clip(to: fitRect)
        context.translateBy(x: fitRect.minX, y: fitRect.minY)
        context.scaleBy(x: fitScale, y: fitScale)
        // The shape being typed is represented by the floating field.
        MarkupRender.draw(shapes.filter { $0.id != editingID }, in: context)
        context.restoreGState()

        if let shape = shapes.first(where: { $0.id == selectedID }), shape.id != editingID {
            let rotationHandleUsesBottom: Bool?
            if case let .rotating(id, _, _, usesBottom) = drag, id == shape.id {
                rotationHandleUsesBottom = usesBottom
            } else {
                rotationHandleUsesBottom = nil
            }
            let handles = MarkupGeometry.handles(
                for: shape, rotationHandleOffset: textRotationHandleOffset,
                within: imageSize,
                rotationHandleUsesBottom: rotationHandleUsesBottom)
            if shape.tool == .text {
                // The marquee follows the text's actual angle. A short stem
                // leads to the circular rotation knob; corners remain the
                // only proportional-resize handles.
                let corners = shape.rotatedTextCorners.map(viewPoint)
                if let first = corners.first {
                    let marquee = CGMutablePath()
                    marquee.move(to: first)
                    for corner in corners.dropFirst() { marquee.addLine(to: corner) }
                    marquee.closeSubpath()
                    context.saveGState()
                    context.setStrokeColor(CGColor(gray: 1, alpha: 0.75))
                    context.setLineWidth(1)
                    context.setLineDash(phase: 0, lengths: [4, 3])
                    context.addPath(marquee)
                    context.strokePath()

                    let rotation = MarkupGeometry.rotationHandle(
                        for: shape, offset: textRotationHandleOffset,
                        within: imageSize,
                        useBottom: rotationHandleUsesBottom)
                    context.setLineDash(phase: 0, lengths: [])
                    context.move(to: viewPoint(from: rotation.anchor))
                    context.addLine(to: viewPoint(from: rotation.position))
                    context.strokePath()
                    context.restoreGState()
                }
            } else if handles.isEmpty {
                // Pen is move-only, so its full bounds get a light marquee.
                let rect = shape.boundingRect
                let origin = viewPoint(from: CGPoint(x: rect.minX, y: rect.minY))
                let corner = viewPoint(from: CGPoint(x: rect.maxX, y: rect.maxY))
                let box = CGRect(x: origin.x, y: origin.y,
                                 width: corner.x - origin.x,
                                 height: corner.y - origin.y)
                    .insetBy(dx: -4, dy: -4)
                context.saveGState()
                context.setStrokeColor(CGColor(gray: 1, alpha: 0.75))
                context.setLineWidth(1)
                context.setLineDash(phase: 0, lengths: [4, 3])
                context.stroke(box)
                context.restoreGState()
            }
            for (handle, position) in handles {
                let center = viewPoint(from: position)
                let side: CGFloat = handle == .rotation ? 10 : 8
                let knob = CGRect(x: center.x - side / 2, y: center.y - side / 2,
                                  width: side, height: side)
                context.setFillColor(handle == .rotation
                    ? CGColor(srgbRed: 0.55, green: 0.61, blue: 0.98, alpha: 1)
                    : CGColor(gray: 1, alpha: 1))
                context.setStrokeColor(CGColor(gray: 0, alpha: 0.6))
                context.setLineWidth(1)
                context.fillEllipse(in: knob)
                context.strokeEllipse(in: knob)
            }
        }

        if let cropRect {
            drawCropOverlay(cropRect, in: context)
        }
    }

    private func drawCropOverlay(_ rect: CGRect, in context: CGContext) {
        let origin = viewPoint(from: CGPoint(x: rect.minX, y: rect.minY))
        let corner = viewPoint(from: CGPoint(x: rect.maxX, y: rect.maxY))
        let cropBox = CGRect(x: origin.x, y: origin.y,
                             width: corner.x - origin.x,
                             height: corner.y - origin.y)

        context.saveGState()
        context.addRect(fitRect)
        context.addRect(cropBox)
        context.setFillColor(CGColor(gray: 0, alpha: 0.48))
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [5, 3])
        context.stroke(cropBox)
        context.setLineDash(phase: 0, lengths: [])

        for (_, position) in cropHandles(for: rect) {
            var center = viewPoint(from: position)
            center.x = min(max(center.x, fitRect.minX + 4), fitRect.maxX - 4)
            center.y = min(max(center.y, fitRect.minY + 4), fitRect.maxY - 4)
            let handle = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.75))
            context.fill(handle)
            context.stroke(handle)
        }

        let pixels = cropPixelRect(rect)
        let label = NSAttributedString(
            string: "\(Int(pixels.width)) × \(Int(pixels.height))",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
        )
        let labelSize = label.size()
        let badgeSize = CGSize(width: labelSize.width + 16, height: 24)
        let badgeX = min(max(cropBox.midX - badgeSize.width / 2, fitRect.minX + 4),
                         fitRect.maxX - badgeSize.width - 4)
        let badgeY = min(max(cropBox.minY + 8, fitRect.minY + 4),
                         fitRect.maxY - badgeSize.height - 4)
        let badge = CGRect(origin: CGPoint(x: badgeX, y: badgeY), size: badgeSize)
        context.addPath(CGPath(roundedRect: badge, cornerWidth: 12, cornerHeight: 12,
                               transform: nil))
        context.setFillColor(CGColor(gray: 0, alpha: 0.68))
        context.fillPath()
        context.addPath(CGPath(roundedRect: badge, cornerWidth: 12, cornerHeight: 12,
                               transform: nil))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
        context.setLineWidth(1)
        context.strokePath()
        label.draw(at: CGPoint(x: badge.minX + 8,
                               y: badge.midY - labelSize.height / 2))
        context.restoreGState()
    }

    override func resetCursorRects() {
        if cropRect != nil {
            addCursorRect(bounds, cursor: .crosshair)
            return
        }
        switch currentTool {
        case nil:
            addCursorRect(bounds, cursor: .arrow)
            addCursorRect(fitRect, cursor: .openHand)
        case .text:
            addCursorRect(bounds, cursor: .iBeam)
        default:
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        // Taking first-responder ends any in-progress text edit (committed
        // via controlTextDidEndEditing) before the click is interpreted.
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = imagePoint(from: viewPoint)
        let tolerance = 8 / fitScale

        if let cropRect {
            if let handle = cropHandle(at: point, in: cropRect, tolerance: tolerance) {
                drag = .resizingCrop(handle, original: cropRect)
            } else if cropRect.contains(point) {
                drag = .movingCrop(original: cropRect, start: point)
            } else {
                drag = nil
            }
            return
        }

        // Double-click a text shape (any tool) to edit it in place.
        if event.clickCount == 2,
           let hit = MarkupGeometry.hitShape(in: shapes, at: point, tolerance: tolerance),
           hit.tool == .text {
            beginTextEditing(hit.id)
            return
        }

        let optionDrag = event.modifierFlags.contains(.option)
        if !optionDrag,
           let shape = shapes.first(where: { $0.id == selectedID }),
           let handle = MarkupGeometry.handleHit(
               shape, at: point, tolerance: tolerance,
               rotationHandleOffset: textRotationHandleOffset,
               within: imageSize) {
            if handle == .rotation {
                let center = shape.textCenter
                let pointerAngle = atan2(point.y - center.y, point.x - center.x)
                let offset = MarkupGeometry.normalizedAngle(
                    shape.rotationRadians - pointerAngle)
                let rotationHandle = MarkupGeometry.rotationHandle(
                    for: shape, offset: textRotationHandleOffset,
                    within: imageSize)
                drag = .rotating(shape.id, original: shape, pointerOffset: offset,
                                 handleUsesBottom: rotationHandle.usesBottom)
            } else {
                drag = .resizing(shape.id, handle, original: shape)
            }
            return
        }

        // The pen ignores shape hits: freehand strokes routinely start on top
        // of existing ink. Move pen strokes with the Select tool.
        if currentTool != .pen,
           let hit = MarkupGeometry.hitShape(in: shapes, at: point,
                                             tolerance: tolerance + currentStroke / 2) {
            if optionDrag {
                selectedID = hit.id
                drag = .duplicating(hit, start: point)
            } else {
                selectedID = hit.id
                drag = .moving(hit.id, last: point)
            }
            needsDisplay = true
            return
        }

        // Pointer mode: an empty-space drag exports the flattened image through
        // the native macOS drag system. Shape hits above retain move/resize
        // priority, and letterboxed canvas space never starts an export.
        guard let tool = currentTool else {
            selectedID = nil
            drag = fitRect.contains(viewPoint) ? .exportingImage(start: viewPoint) : nil
            needsDisplay = true
            return
        }

        let start = MarkupGeometry.clamped(point, to: imageSize)

        if tool == .text {
            // Click places the cursor; typing happens in the floating field.
            let shape = MarkupShape(tool: .text, colorIndex: colorIndex,
                                    start: start, end: start,
                                    fontSize: currentFontSize)
            shapes.append(shape)
            beginTextEditing(shape.id)
            return
        }

        let shape = MarkupShape(tool: tool, colorIndex: colorIndex,
                                fillColorIndex: (tool == .rect || tool == .ellipse)
                                    ? fillColorIndex : nil,
                                start: start, end: start, lineWidth: currentStroke,
                                points: tool == .pen ? [start] : [])
        shapes.append(shape)
        selectedID = shape.id
        drag = .creating(shape.id)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = imagePoint(from: viewPoint)

        switch drag {
        case .creating(let id):
            let clamped = MarkupGeometry.clamped(point, to: imageSize)
            update(id) { shape in
                if shape.tool == .pen {
                    shape.points.append(clamped)
                } else {
                    shape.end = clamped
                }
            }
        case .moving(let id, let last):
            let translation = CGSize(width: point.x - last.x, height: point.y - last.y)
            update(id) { $0 = MarkupGeometry.moved($0, by: translation, within: self.imageSize) }
            self.drag = .moving(id, last: point)
        case .duplicating(let source, let start):
            guard hypot(point.x - start.x, point.y - start.y) >= 4 / fitScale else { return }
            let copy = duplicate(source)
            shapes.append(copy)
            selectedID = copy.id
            let translation = CGSize(width: point.x - start.x, height: point.y - start.y)
            update(copy.id) {
                $0 = MarkupGeometry.moved($0, by: translation, within: self.imageSize)
            }
            self.drag = .moving(copy.id, last: point)
        case .resizing(let id, let handle, let original):
            let clamped = MarkupGeometry.clamped(point, to: imageSize)
            if original.tool == .text {
                resizeText(id, original: original, handle: handle, to: clamped)
            } else {
                update(id) { $0 = MarkupGeometry.resized(original, handle: handle, to: clamped) }
            }
        case .rotating(let id, let original, let pointerOffset, _):
            let center = original.textCenter
            let pointerAngle = atan2(point.y - center.y, point.x - center.x)
            var angle = MarkupGeometry.normalizedAngle(pointerAngle + pointerOffset)
            if event.modifierFlags.contains(.shift) {
                let increment = CGFloat.pi / 12  // 15°
                angle = (angle / increment).rounded() * increment
            }
            update(id) { $0.rotationRadians = MarkupGeometry.normalizedAngle(angle) }
        case .resizingCrop(let handle, let original):
            let clamped = MarkupGeometry.clamped(point, to: imageSize)
            cropRect = resizedCrop(original, handle: handle, to: clamped,
                                   symmetric: event.modifierFlags.contains(.option))
            needsDisplay = true
        case .movingCrop(let original, let start):
            cropRect = movedCrop(original, by: CGSize(width: point.x - start.x,
                                                       height: point.y - start.y))
            needsDisplay = true
        case .exportingImage(let start):
            guard hypot(viewPoint.x - start.x, viewPoint.y - start.y) >= 4 else { return }
            self.drag = nil
            beginImageExportDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .creating(let id) = drag,
           let position = shapes.firstIndex(where: { $0.id == id }) {
            let shape = shapes[position]
            // A click without a real drag leaves a degenerate shape — drop it.
            let span = shape.tool == .pen
                ? max(shape.boundingRect.width, shape.boundingRect.height)
                : hypot(shape.end.x - shape.start.x, shape.end.y - shape.start.y)
            if span < 3 {
                shapes.remove(at: position)
                selectedID = nil
                needsDisplay = true
            }
        }
        if case .rotating(let id, _, _, _) = drag {
            // Keep the rotated text itself reachable; the rotation knob may
            // still flip to the opposite side near a canvas edge.
            update(id) {
                $0 = MarkupGeometry.moved($0, by: .zero, within: self.imageSize)
            }
        }
        drag = nil
    }

    private func duplicate(_ shape: MarkupShape) -> MarkupShape {
        MarkupShape(tool: shape.tool, colorIndex: shape.colorIndex,
                    fillColorIndex: shape.fillColorIndex,
                    start: shape.start, end: shape.end, arrowBend: shape.arrowBend,
                    lineWidth: shape.lineWidth, points: shape.points,
                    text: shape.text, fontSize: shape.fontSize,
                    rotationRadians: shape.rotationRadians)
    }

    private func cropHandles(for rect: CGRect) -> [(CropHandle, CGPoint)] {
        [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.top, CGPoint(x: rect.midX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.right, CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottom, CGPoint(x: rect.midX, y: rect.maxY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.left, CGPoint(x: rect.minX, y: rect.midY)),
        ]
    }

    private func cropHandle(at point: CGPoint, in rect: CGRect,
                            tolerance: CGFloat) -> CropHandle? {
        cropHandles(for: rect).first {
            hypot($0.1.x - point.x, $0.1.y - point.y) <= tolerance
        }?.0
    }

    private func resizedCrop(_ original: CGRect, handle: CropHandle,
                             to point: CGPoint, symmetric: Bool) -> CGRect {
        let minimum = max(12 / fitScale, 1)
        var minX = original.minX, maxX = original.maxX
        var minY = original.minY, maxY = original.maxY
        let changesLeft = handle == .topLeft || handle == .left || handle == .bottomLeft
        let changesRight = handle == .topRight || handle == .right || handle == .bottomRight
        let changesTop = handle == .topLeft || handle == .top || handle == .topRight
        let changesBottom = handle == .bottomLeft || handle == .bottom || handle == .bottomRight

        if symmetric {
            if changesLeft || changesRight {
                let center = original.midX
                let distance = changesLeft ? center - point.x : point.x - center
                var half = max(distance, minimum / 2)
                half = min(half, min(center, imageSize.width - center))
                minX = center - half
                maxX = center + half
            }
            if changesTop || changesBottom {
                let center = original.midY
                let distance = changesTop ? center - point.y : point.y - center
                var half = max(distance, minimum / 2)
                half = min(half, min(center, imageSize.height - center))
                minY = center - half
                maxY = center + half
            }
        } else {
            if changesLeft { minX = min(point.x, maxX - minimum) }
            if changesRight { maxX = max(point.x, minX + minimum) }
            if changesTop { minY = min(point.y, maxY - minimum) }
            if changesBottom { maxY = max(point.y, minY + minimum) }
        }

        minX = min(max(minX, 0), imageSize.width)
        maxX = min(max(maxX, 0), imageSize.width)
        minY = min(max(minY, 0), imageSize.height)
        maxY = min(max(maxY, 0), imageSize.height)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func movedCrop(_ original: CGRect, by translation: CGSize) -> CGRect {
        let dx = min(max(translation.width, -original.minX),
                     imageSize.width - original.maxX)
        let dy = min(max(translation.height, -original.minY),
                     imageSize.height - original.maxY)
        return original.offsetBy(dx: dx, dy: dy)
    }

    /// Scales text from a corner without changing its aspect ratio. The
    /// opposite displayed corner remains fixed even after rotation, matching
    /// image-editor marquee behavior.
    private func resizeText(_ id: UUID, original: MarkupShape,
                            handle: MarkupHandle, to point: CGPoint) {
        let rect = original.unrotatedTextRect
        guard rect.width > 0, rect.height > 0, original.fontSize > 0 else { return }
        let corners = original.rotatedTextCorners
        guard corners.count == 4 else { return }

        let anchor: CGPoint
        let originalCorner: CGPoint
        switch handle {
        case .topLeft:
            anchor = corners[2]
            originalCorner = corners[0]
        case .topRight:
            anchor = corners[3]
            originalCorner = corners[1]
        case .bottomLeft:
            anchor = corners[1]
            originalCorner = corners[3]
        case .bottomRight:
            anchor = corners[0]
            originalCorner = corners[2]
        case .start, .end, .curve, .rotation:
            return
        }

        let base = CGVector(dx: originalCorner.x - anchor.x,
                            dy: originalCorner.y - anchor.y)
        let current = CGVector(dx: point.x - anchor.x, dy: point.y - anchor.y)
        let baseLengthSquared = base.dx * base.dx + base.dy * base.dy
        guard baseLengthSquared > 0 else { return }

        var scale = (current.dx * base.dx + current.dy * base.dy) / baseLengthSquared
        let minimumScale = max(8 * pixelScale / original.fontSize, 0.05)

        // Every rotated corner is `anchor + scale * vector`, so each image
        // edge contributes a simple upper bound for proportional scaling.
        var maximumScale = CGFloat.greatestFiniteMagnitude
        for corner in corners {
            let vector = CGVector(dx: corner.x - anchor.x, dy: corner.y - anchor.y)
            if vector.dx > 0.0001 {
                maximumScale = min(maximumScale,
                                   (imageSize.width - anchor.x) / vector.dx)
            } else if vector.dx < -0.0001 {
                maximumScale = min(maximumScale, (0 - anchor.x) / vector.dx)
            }
            if vector.dy > 0.0001 {
                maximumScale = min(maximumScale,
                                   (imageSize.height - anchor.y) / vector.dy)
            } else if vector.dy < -0.0001 {
                maximumScale = min(maximumScale, (0 - anchor.y) / vector.dy)
            }
        }
        let upperScale = max(0, maximumScale)
        guard upperScale > 0 else { return }
        let lowerScale = min(minimumScale, upperScale)
        scale = min(max(scale, lowerScale), upperScale)

        update(id) { shape in
            shape.fontSize = original.fontSize * scale
            shape.rotationRadians = original.rotationRadians
            let size = MarkupRender.textMetrics(for: shape).size
            let half = CGVector(dx: size.width / 2, dy: size.height / 2)
            let anchorOffset: CGVector
            switch handle {
            case .topLeft:
                anchorOffset = CGVector(dx: half.dx, dy: half.dy)
            case .topRight:
                anchorOffset = CGVector(dx: -half.dx, dy: half.dy)
            case .bottomLeft:
                anchorOffset = CGVector(dx: half.dx, dy: -half.dy)
            case .bottomRight:
                anchorOffset = CGVector(dx: -half.dx, dy: -half.dy)
            case .start, .end, .curve, .rotation:
                return
            }
            let displayedOffset = MarkupGeometry.rotated(
                anchorOffset, by: original.rotationRadians)
            let center = CGPoint(x: anchor.x - displayedOffset.dx,
                                 y: anchor.y - displayedOffset.dy)
            shape.start = CGPoint(x: center.x - half.dx, y: center.y - half.dy)
            shape.end = CGPoint(x: shape.start.x + size.width,
                                y: shape.start.y + size.height)
        }
    }

    private func beginImageExportDrag(with event: NSEvent) {
        guard let image = flattened(),
              let url = try? CaptureTempStore.writePNG(image)
        else {
            NSSound.beep()
            return
        }

        let preview = NSImage(cgImage: image, size: fitRect.size)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(fitRect, contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    private func update(_ id: UUID, _ mutate: (inout MarkupShape) -> Void) {
        guard let position = shapes.firstIndex(where: { $0.id == id }) else { return }
        mutate(&shapes[position])
        needsDisplay = true
    }

    // MARK: - Text entry

    private func editorFont(for shape: MarkupShape) -> NSFont {
        // Display size tracks the zoom-to-fit scale so what you type is
        // exactly what flattens into the image.
        let size = shape.fontSize * fitScale
        if let name = MarkupRender.resolvedTextFontName,
           let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size)
    }

    private func positionTextEditor(_ field: NSTextField, for shape: MarkupShape) {
        let origin = viewPoint(from: shape.start)
        let metrics = MarkupRender.textMetrics(for: shape).size
        let lineHeight = field.font.map { NSLayoutManager().defaultLineHeight(for: $0) } ?? 20
        let width = max(shape.text.isEmpty ? 60 : 16, metrics.width * fitScale + 4)
        let height = max(lineHeight + 4, metrics.height * fitScale + 4)
        let center = metrics == .zero
            ? CGPoint(x: origin.x + width / 2 - 2, y: origin.y + height / 2 - 1)
            : viewPoint(from: shape.textCenter)
        // AppKit's `frame` is ambiguous while a view is rotated. Lay the
        // editor out horizontally first, then restore its center rotation.
        field.frameCenterRotation = 0
        field.frame = NSRect(x: center.x - width / 2, y: center.y - height / 2,
                             width: width, height: height)
        field.frameCenterRotation = shape.rotationRadians * 180 / .pi
    }

    private func beginTextEditing(_ id: UUID) {
        commitTextEditing()
        guard let shape = shapes.first(where: { $0.id == id }) else { return }
        editingID = id
        selectedID = id

        let field = NSTextField(string: shape.text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        field.font = editorFont(for: shape)
        field.textColor = Self.nsColor(shape.colorIndex)
        field.delegate = self
        positionTextEditor(field, for: shape)
        addSubview(field)
        textEditor = field
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    /// Ends the floating edit: non-empty text lands in the shape (with its
    /// measured extent), empty text discards it. Safe to call when idle.
    private func commitTextEditing() {
        guard let id = editingID, let field = textEditor else { return }
        // Clear state first: tearing the field down re-enters via
        // controlTextDidEndEditing.
        editingID = nil
        textEditor = nil
        let text = field.stringValue
        field.removeFromSuperview()

        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            shapes.removeAll { $0.id == id }
            if selectedID == id { selectedID = nil }
        } else {
            update(id) { $0.text = text }
            remeasureText(id)
        }
        needsDisplay = true
    }

    /// Keeps `end` equal to the measured text extent so bounding-box hit
    /// tests, moves, and the selection box stay truthful.
    private func remeasureText(_ id: UUID?) {
        guard let id else { return }
        update(id) { shape in
            guard shape.tool == .text else { return }
            let metrics = MarkupRender.textMetrics(for: shape)
            shape.end = CGPoint(x: shape.start.x + metrics.size.width,
                                y: shape.start.y + metrics.size.height)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitTextEditing()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let id = editingID, let field = textEditor else { return }
        update(id) { $0.text = field.stringValue }
        remeasureText(id)
        if let shape = shapes.first(where: { $0.id == id }) {
            positionTextEditor(field, for: shape)
        }
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        // Enter and Esc both end the edit (Esc keeps the text — basic tool,
        // no separate cancel path).
        if commandSelector == #selector(NSResponder.insertNewline(_:))
            || commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            commitTextEditing()
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    override func layout() {
        super.layout()
        // Window resize rescales the fit transform; keep the field glued on.
        if let editingID, let field = textEditor,
           let shape = shapes.first(where: { $0.id == editingID }) {
            field.font = editorFont(for: shape)
            positionTextEditor(field, for: shape)
        }
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        if cropRect != nil {
            switch event.keyCode {
            case 36, 76:  // return, keypad enter
                onApplyCrop?()
            case 53:  // esc
                onCancelCrop?()
            default:
                super.keyDown(with: event)
            }
            return
        }

        switch event.keyCode {
        case 51, 117:  // delete, forward delete
            if let selectedID {
                shapes.removeAll { $0.id == selectedID }
                self.selectedID = nil
                needsDisplay = true
            }
        case 53:  // esc
            selectedID = nil
            needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }
}
