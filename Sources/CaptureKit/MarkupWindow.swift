import AppKit

/// How the markup session ended.
public enum MarkupExit {
    case cancelled
    case upload(CGImage)
    case saveToDesktop(CGImage)
}

/// An editable canvas with a compact child-window toolbar. Shapes stay vector
/// until an exit action flattens them to a CGImage.
@MainActor
public final class MarkupWindowController: NSWindowController, NSWindowDelegate {
    private enum ToolbarDock: Int {
        case bottom, top, left, right

        var isHorizontal: Bool { self == .bottom || self == .top }
    }

    private let canvas: MarkupCanvasView
    private let imageSize: CGSize
    private var toolButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private var strokeButtons: [NSButton] = []
    private var cropApplyButton: NSButton?
    private var uploadButton: NSButton?
    private var activeColorButton: NSButton?
    private var colorTargetControl: NSSegmentedControl?
    private var floatingToolbarPanel: NSPanel?
    private var floatingToolbarStack: MovableToolbarStackView?
    private var floatingToolbarSeparators: [ToolbarSeparatorView] = []
    private var floatingToolbarContainmentConstraints: [NSLayoutConstraint] = []
    private var toolbarDock = ToolbarDock(rawValue: MarkupPrefs.toolbarDockIndex) ?? .bottom
    private var toolbarRelativeCenter = MarkupPrefs.toolbarRelativeCenter
    private var toolbarDragStart: NSPoint?
    private var toolbarDragOffset = CGPoint.zero
    private var toolbarDragTargetFrame: NSRect?
    private var toolbarDragDidMove = false
    private var toolbarLatestPointer = NSPoint.zero
    private var toolbarMorphTimer: Timer?
    private var toolbarMorphStartTime: TimeInterval = 0
    private var toolbarMorphFromSize = NSSize.zero
    private var toolbarMorphToSize = NSSize.zero
    private var toolbarMorphFromOffset = CGPoint.zero
    private var toolbarMorphToOffset = CGPoint.zero
    private var toolbarMorphTargetDock: ToolbarDock?
    private let colorPopover = NSPopover()
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
    private static let outputScales: [CGFloat] = [1, 0.75, 0.5]
    private static let strokePresets: [CGFloat] = [1, 3, 8]

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
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
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

        colorTarget = MarkupPrefs.editsFill ? .fill : .stroke
        strokeColorIndex = MarkupPrefs.strokeColorIndex
        chosenFillColorIndex = MarkupPrefs.fillColorIndex
        MarkupPrefs.strokePoints = Self.nearestStrokePreset(to: MarkupPrefs.strokePoints)

        buildContent(in: window)
        buildFloatingToolbar(for: window)
        installCenteredTitle(in: window)
        updateWindowTitle(CGSize(width: image.width, height: image.height))
        canvas.onApplyCrop = { [weak self] in self?.applyCropClicked() }
        canvas.onCancelCrop = { [weak self] in self?.selectTool(at: Self.pointerToolIndex) }
        canvas.onImageSizeChanged = { [weak self] size in self?.updateWindowTitle(size) }
        canvas.setColorIndex(strokeColorIndex)
        canvas.setFillColorIndex(chosenFillColorIndex)
        canvas.setStrokeWidth(points: MarkupPrefs.strokePoints)
        canvas.setOutputScale(Self.outputScales[MarkupPrefs.outputScaleIndex])
        refreshColorButtons()
        refreshStrokeButtons()
        let savedTool = MarkupPrefs.toolIndex
        selectTool(at: Self.tools.indices.contains(savedTool)
                   ? savedTool : Self.pointerToolIndex)
        window.center()
        positionFloatingToolbar()
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
        showFloatingToolbar()
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
        origin.x = min(max(origin.x, visible.minX),
                       max(visible.minX, visible.maxX - frame.width))
        origin.y = min(max(origin.y, visible.minY),
                       max(visible.minY, visible.maxY - frame.height))
        window.setFrameOrigin(origin)
        positionFloatingToolbar()
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
        if let panel = floatingToolbarPanel, panel.parent == nil {
            panel.alphaValue = 0
            window.addChildWindow(panel, ordered: .above)
            positionFloatingToolbar()
        }
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3 * captureSlowMo
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(full, display: true)
            window.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.showFloatingToolbar(animated: true) }
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
        let hPad = canvasInset * 2
        let vPad = titlebarHeight + canvasTopInset + canvasInset
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let fit = min(1, (available.width * 0.85 - hPad) / points.width,
                      (available.height * 0.85 - vPad) / points.height)
        return NSSize(width: max(minimumWindowWidth, points.width * fit + hPad),
                      height: max(minimumWindowHeight, points.height * fit + vPad))
    }

    private static let titlebarHeight: CGFloat = 32
    private static let canvasTopInset: CGFloat = 0
    private static let floatingToolbarLongSide: CGFloat = 594
    private static let floatingToolbarThickness: CGFloat = 68
    private static let floatingToolbarGap: CGFloat = 12
    private static let toolbarMorphDuration: TimeInterval = 0.12
    private static let screenMargin: CGFloat = 8
    private static let toolButtonSize: CGFloat = 36
    private static let toolSymbolSize: CGFloat = 16
    private static let minimumWindowWidth: CGFloat = 760
    private static let minimumWindowHeight: CGFloat = 490

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
        let applyCrop = NSButton(title: "Apply Crop", target: self,
                                 action: #selector(applyCropClicked))
        applyCrop.isHidden = true
        cropApplyButton = applyCrop
        for button in [applyCrop, cancel, save, upload] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        upload.keyEquivalent = "\r"
        uploadButton = upload

        let actions = NSStackView(views: [applyCrop, cancel, save, upload])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.setContentHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)

        titlebar.addSubview(titleLabel)
        titlebar.addSubview(actions)
        NSLayoutConstraint.activate([
            actions.centerYAnchor.constraint(equalTo: titlebar.centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor, constant: -10),
            titleLabel.centerXAnchor.constraint(equalTo: titlebar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: titlebar.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: zoom.trailingAnchor,
                                                constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor,
                                                 constant: -12),
        ])
    }

    private func buildContent(in window: NSWindow) {
        let content = NSView()

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.wantsLayer = true
        canvas.layer?.cornerRadius = 8
        canvas.layer?.masksToBounds = true
        content.addSubview(canvas)
        NSLayoutConstraint.activate([
            // The titlebar itself is the top frame; no extra gap below it.
            canvas.topAnchor.constraint(equalTo: content.topAnchor,
                                        constant: Self.titlebarHeight + Self.canvasTopInset),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                             constant: Self.canvasInset),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.canvasInset),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.canvasInset),
        ])
        window.contentView = content
    }

    /// Creates the black child panel. A child window follows the editor through
    /// moves, Spaces, ordering, and minimization without becoming an unrelated
    /// always-on-top palette.
    private func buildFloatingToolbar(for window: NSWindow) {
        let size = Self.floatingToolbarSize(for: toolbarDock)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.sharingType = .readOnly
        panel.appearance = NSAppearance(named: .darkAqua)

        let background = FloatingToolbarBackgroundView(
            frame: NSRect(origin: .zero, size: size))
        background.autoresizingMask = [.width, .height]
        background.onDragBegan = { [weak self] event in self?.beginToolbarDrag(event) }
        background.onDragChanged = { [weak self] event in self?.updateToolbarDrag(event) }
        background.onDragEnded = { [weak self] event in self?.endToolbarDrag(event) }

        let controls = MovableToolbarStackView()
        controls.orientation = toolbarDock.isHorizontal ? .horizontal : .vertical
        controls.alignment = toolbarDock.isHorizontal ? .centerY : .centerX
        controls.spacing = 5
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.onDragBegan = { [weak self] event in self?.beginToolbarDrag(event) }
        controls.onDragChanged = { [weak self] event in self?.updateToolbarDrag(event) }
        controls.onDragEnded = { [weak self] event in self?.endToolbarDrag(event) }
        background.addSubview(controls)
        floatingToolbarStack = controls

        for (index, entry) in Self.tools.enumerated() {
            guard let button = makeToolButton(entry, index: index) else { continue }
            controls.addArrangedSubview(button)
            if index == 1 { controls.addArrangedSubview(makeToolbarSeparator()) }
        }
        controls.addArrangedSubview(makeToolbarSeparator())

        let initialColor = NSImage(systemSymbolName: "circle.fill",
                                   accessibilityDescription: "Annotation color") ?? NSImage()
        let color = SquareToolbarButton(
            image: initialColor, target: self, action: #selector(colorPopoverClicked(_:)))
        color.toolTip = "Annotation color"
        color.translatesAutoresizingMaskIntoConstraints = false
        color.widthAnchor.constraint(equalToConstant: Self.toolButtonSize).isActive = true
        color.heightAnchor.constraint(equalToConstant: Self.toolButtonSize).isActive = true
        activeColorButton = color
        controls.addArrangedSubview(color)

        for (index, points) in Self.strokePresets.enumerated() {
            let button = SquareToolbarButton(
                image: Self.strokeImage(points: points, selected: false),
                target: self, action: #selector(strokeClicked(_:)))
            button.setButtonType(.pushOnPushOff)
            button.tag = index
            button.toolTip = "\(["Thin", "Medium", "Thick"][index]) stroke"
            button.setAccessibilityLabel("\(["Thin", "Medium", "Thick"][index]) stroke")
            button.setAccessibilityValue("\(Int(points)) points")
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: Self.toolButtonSize).isActive = true
            button.heightAnchor.constraint(equalToConstant: Self.toolButtonSize).isActive = true
            strokeButtons.append(button)
            controls.addArrangedSubview(button)
        }

        controls.addArrangedSubview(makeToolbarSeparator())

        let outputSize = CircularToolbarPopUpButton(frame: .zero, pullsDown: false)
        outputSize.addItems(withTitles: ["100%", "75%", "50%"])
        let outputSymbol = NSImage(
            systemSymbolName: "aspectratio",
            accessibilityDescription: "Output image size")
        outputSize.itemArray.forEach { $0.image = outputSymbol }
        outputSize.selectItem(at: MarkupPrefs.outputScaleIndex)
        outputSize.target = self
        outputSize.action = #selector(sizeChanged(_:))
        outputSize.toolTip = "Output image size"
        outputSize.setAccessibilityLabel("Output image size")
        outputSize.setAccessibilityValue(outputSize.titleOfSelectedItem ?? "100%")
        outputSize.controlSize = .small
        outputSize.translatesAutoresizingMaskIntoConstraints = false
        outputSize.widthAnchor.constraint(equalToConstant: Self.toolButtonSize).isActive = true
        outputSize.heightAnchor.constraint(equalToConstant: Self.toolButtonSize).isActive = true
        controls.addArrangedSubview(outputSize)

        let containment = [
            controls.leadingAnchor.constraint(greaterThanOrEqualTo: background.leadingAnchor,
                                              constant: 6),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor,
                                               constant: -6),
            controls.topAnchor.constraint(greaterThanOrEqualTo: background.topAnchor,
                                          constant: 6),
            controls.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor,
                                             constant: -6),
        ]
        floatingToolbarContainmentConstraints = containment
        NSLayoutConstraint.activate([
            controls.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            controls.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ] + containment)

        panel.contentView = background
        floatingToolbarPanel = panel
        buildColorPopover()
    }

    private static func floatingToolbarSize(for dock: ToolbarDock) -> NSSize {
        dock.isHorizontal
            ? NSSize(width: floatingToolbarLongSide, height: floatingToolbarThickness)
            : NSSize(width: floatingToolbarThickness, height: floatingToolbarLongSide)
    }

    private func makeToolButton(_ entry: ToolItem, index: Int) -> NSButton? {
        guard let symbol = NSImage(systemSymbolName: entry.symbol,
                                   accessibilityDescription: entry.tip) else { return nil }
        let configured = symbol.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: Self.toolSymbolSize, weight: .regular)
        ) ?? symbol
        let button = SquareToolbarButton(
            image: configured, target: self, action: #selector(toolClicked(_:)))
        button.setButtonType(.pushOnPushOff)
        button.toolTip = entry.tip
        button.setAccessibilityLabel(entry.tip)
        button.tag = index
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: Self.toolButtonSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: Self.toolButtonSize).isActive = true
        toolButtons.append(button)
        return button
    }

    private func makeToolbarSeparator() -> ToolbarSeparatorView {
        let separator = ToolbarSeparatorView()
        separator.axis = toolbarDock.isHorizontal ? .vertical : .horizontal
        separator.translatesAutoresizingMaskIntoConstraints = false
        floatingToolbarSeparators.append(separator)
        return separator
    }

    /// The expanded palette keeps independent stroke/fill state while the pill
    /// itself only needs one active-color chip.
    private func buildColorPopover() {
        let target = NSSegmentedControl(labels: ["Stroke", "Fill"],
                                        trackingMode: .selectOne,
                                        target: self,
                                        action: #selector(colorTargetChanged(_:)))
        target.selectedSegment = colorTarget == .stroke ? 0 : 1
        target.toolTip = "Choose whether the palette edits the stroke or fill"
        target.translatesAutoresizingMaskIntoConstraints = false
        target.widthAnchor.constraint(equalToConstant: 104).isActive = true
        target.heightAnchor.constraint(equalToConstant: 30).isActive = true
        colorTargetControl = target

        let noFillSymbol = NSImage(systemSymbolName: "nosign",
                                   accessibilityDescription: "No fill") ?? NSImage()
        let noFill = SquareToolbarButton(
            image: noFillSymbol, target: self, action: #selector(colorClicked(_:)))
        noFill.setButtonType(.pushOnPushOff)
        noFill.toolTip = "No fill"
        noFill.setAccessibilityLabel("No fill")
        noFill.setAccessibilityRole(.radioButton)
        noFill.tag = -1
        noFill.translatesAutoresizingMaskIntoConstraints = false
        noFill.widthAnchor.constraint(equalToConstant: 34).isActive = true
        noFill.heightAnchor.constraint(equalToConstant: 38).isActive = true
        noFillButton = noFill

        let swatches = NSStackView()
        swatches.orientation = .horizontal
        swatches.alignment = .centerY
        swatches.spacing = 4
        swatches.addArrangedSubview(noFill)
        for index in 0..<MarkupPalette.colors.count {
            let button = NSButton(image: Self.swatchImage(colorIndex: index, selected: false),
                                  target: self, action: #selector(colorClicked(_:)))
            button.isBordered = false
            button.setButtonType(.pushOnPushOff)
            button.tag = index
            button.setAccessibilityLabel(MarkupPalette.colors[index].name)
            button.setAccessibilityRole(.radioButton)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
            colorButtons.append(button)
            swatches.addArrangedSubview(button)
        }

        let content = NSVisualEffectView(
            frame: NSRect(x: 0, y: 0, width: 350, height: 96))
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.appearance = NSAppearance(named: .darkAqua)

        let rows = NSStackView(views: [target, swatches])
        rows.orientation = .vertical
        rows.alignment = .centerX
        rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            rows.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        let controller = NSViewController()
        controller.view = content
        colorPopover.contentViewController = controller
        colorPopover.contentSize = content.frame.size
        colorPopover.behavior = .transient
        colorPopover.animates = true
        colorPopover.appearance = NSAppearance(named: .darkAqua)
    }

    private func showFloatingToolbar(animated: Bool = false) {
        guard let window, window.isVisible, let panel = floatingToolbarPanel else { return }
        if panel.parent == nil {
            panel.alphaValue = animated ? 0 : 1
            window.addChildWindow(panel, ordered: .above)
        }
        positionFloatingToolbar()
        panel.orderFront(nil)
        guard animated else {
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func positionFloatingToolbar() {
        guard let window, let panel = floatingToolbarPanel else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let parent = window.frame
        let size = panel.frame.size
        let center: NSPoint
        if let relative = toolbarRelativeCenter {
            center = NSPoint(
                x: parent.minX + parent.width * relative.x,
                y: parent.minY + parent.height * relative.y)
        } else {
            center = legacyToolbarCenter(parent: parent, visible: visible, size: size)
        }

        var frame = NSRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height)

        // Preserve every normal free placement. Recover only when a restored
        // position no longer touches any connected display at all.
        let isOnConnectedScreen = NSScreen.screens.contains { screen in
            let overlap = screen.frame.intersection(frame)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }
        if !isOnConnectedScreen {
            let lowerX = visible.minX + Self.screenMargin
            let upperX = max(lowerX, visible.maxX - frame.width - Self.screenMargin)
            let lowerY = visible.minY + Self.screenMargin
            let upperY = max(lowerY, visible.maxY - frame.height - Self.screenMargin)
            frame.origin.x = min(max(frame.minX, lowerX), upperX)
            frame.origin.y = min(max(frame.minY, lowerY), upperY)
        }

        panel.setFrameOrigin(frame.origin)
        if toolbarRelativeCenter == nil || !isOnConnectedScreen {
            saveToolbarCenter(NSPoint(x: frame.midX, y: frame.midY))
        }
    }

    /// Keeps the previous edge-based location only as the one-time default for
    /// users who have not yet stored a free two-dimensional toolbar position.
    private func legacyToolbarCenter(parent: NSRect, visible: NSRect,
                                     size: NSSize) -> NSPoint {
        let offset = MarkupPrefs.toolbarDockOffset
        let xAlongEdge = toolbarAxisOrigin(
            parentMin: parent.minX, parentLength: parent.width,
            toolbarLength: size.width, offset: offset,
            visibleMin: visible.minX, visibleMax: visible.maxX)
        let yAlongEdge = toolbarAxisOrigin(
            parentMin: parent.minY, parentLength: parent.height,
            toolbarLength: size.height, offset: offset,
            visibleMin: visible.minY, visibleMax: visible.maxY)

        let origin: NSPoint
        switch toolbarDock {
        case .bottom:
            let outside = parent.minY - Self.floatingToolbarGap - size.height
            let y = outside >= visible.minY + Self.screenMargin
                ? outside : parent.minY + Self.floatingToolbarGap
            origin = NSPoint(x: xAlongEdge, y: y)
        case .top:
            let outside = parent.maxY + Self.floatingToolbarGap
            let y = outside + size.height <= visible.maxY - Self.screenMargin
                ? outside : parent.maxY - Self.floatingToolbarGap - size.height
            origin = NSPoint(x: xAlongEdge, y: y)
        case .left:
            let outside = parent.minX - Self.floatingToolbarGap - size.width
            let x = outside >= visible.minX + Self.screenMargin
                ? outside : parent.minX + Self.floatingToolbarGap
            origin = NSPoint(x: x, y: yAlongEdge)
        case .right:
            let outside = parent.maxX + Self.floatingToolbarGap
            let x = outside + size.width <= visible.maxX - Self.screenMargin
                ? outside : parent.maxX - Self.floatingToolbarGap - size.width
            origin = NSPoint(x: x, y: yAlongEdge)
        }
        return NSPoint(x: origin.x + size.width / 2,
                       y: origin.y + size.height / 2)
    }

    private func toolbarAxisOrigin(parentMin: CGFloat, parentLength: CGFloat,
                                   toolbarLength: CGFloat, offset: CGFloat,
                                   visibleMin: CGFloat, visibleMax: CGFloat) -> CGFloat {
        let desired = parentMin + parentLength * offset - toolbarLength / 2
        let parentUpper = parentMin + parentLength - toolbarLength
        let parentClamped = parentUpper >= parentMin
            ? min(max(desired, parentMin), parentUpper)
            : parentMin + (parentLength - toolbarLength) / 2
        let visibleLower = visibleMin + Self.screenMargin
        let visibleUpper = max(visibleLower,
                               visibleMax - toolbarLength - Self.screenMargin)
        return min(max(parentClamped, visibleLower), visibleUpper)
    }

    private func configureFloatingToolbar(horizontal: Bool, animated: Bool) {
        guard let panel = floatingToolbarPanel, let stack = floatingToolbarStack else { return }
        let changed = (stack.orientation == .horizontal) != horizontal
        if changed && animated {
            stack.wantsLayer = true
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.10
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            stack.layer?.add(transition, forKey: "toolbar-orientation")
        }
        stack.orientation = horizontal ? .horizontal : .vertical
        stack.alignment = horizontal ? .centerY : .centerX
        for separator in floatingToolbarSeparators {
            separator.axis = horizontal ? .vertical : .horizontal
        }
        panel.contentView?.needsLayout = true
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    /// Interpolates the capsule geometry ourselves instead of animating the
    /// NSPanel toward a stale point. Every frame is rebuilt from the latest
    /// pointer, so the morph never loosens the user's grab.
    private func startToolbarMorph(to dock: ToolbarDock, at now: TimeInterval) {
        guard let panel = floatingToolbarPanel else { return }
        colorPopover.performClose(nil)
        toolbarMorphStartTime = now
        toolbarMorphFromSize = panel.frame.size
        toolbarMorphToSize = Self.floatingToolbarSize(for: dock)
        toolbarMorphFromOffset = CGPoint(
            x: toolbarLatestPointer.x - panel.frame.midX,
            y: toolbarLatestPointer.y - panel.frame.midY)
        toolbarMorphToOffset = toolbarDragOffset
        toolbarMorphTargetDock = dock
        NSLayoutConstraint.deactivate(floatingToolbarContainmentConstraints)

        if toolbarMorphTimer == nil {
            let timer = Timer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(toolbarMorphTimerFired(_:)),
                userInfo: nil,
                repeats: true)
            toolbarMorphTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        advanceToolbarMorph(at: now)
    }

    @objc private func toolbarMorphTimerFired(_ timer: Timer) {
        guard timer === toolbarMorphTimer else {
            timer.invalidate()
            return
        }
        advanceToolbarMorph(at: ProcessInfo.processInfo.systemUptime)
    }

    private func advanceToolbarMorph(at now: TimeInterval) {
        guard let panel = floatingToolbarPanel,
              let targetDock = toolbarMorphTargetDock else { return }
        let progress = min(max(
            (now - toolbarMorphStartTime) / Self.toolbarMorphDuration, 0), 1)
        let eased = progress * progress * (3 - 2 * progress)
        let size = NSSize(
            width: toolbarMorphFromSize.width
                + (toolbarMorphToSize.width - toolbarMorphFromSize.width) * eased,
            height: toolbarMorphFromSize.height
                + (toolbarMorphToSize.height - toolbarMorphFromSize.height) * eased)
        let offset = CGPoint(
            x: toolbarMorphFromOffset.x
                + (toolbarMorphToOffset.x - toolbarMorphFromOffset.x) * eased,
            y: toolbarMorphFromOffset.y
                + (toolbarMorphToOffset.y - toolbarMorphFromOffset.y) * eased)

        if progress >= 0.5 {
            configureFloatingToolbar(horizontal: targetDock.isHorizontal, animated: true)
        }

        let center = NSPoint(
            x: toolbarLatestPointer.x - offset.x,
            y: toolbarLatestPointer.y - offset.y)
        panel.setFrame(NSRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height), display: true)

        guard progress >= 1 else { return }
        configureFloatingToolbar(horizontal: targetDock.isHorizontal, animated: true)
        NSLayoutConstraint.activate(floatingToolbarContainmentConstraints)
        panel.contentView?.layoutSubtreeIfNeeded()
        toolbarMorphTimer?.invalidate()
        toolbarMorphTimer = nil
        toolbarMorphTargetDock = nil
    }

    private func completeToolbarMorph() {
        guard toolbarMorphTargetDock != nil else { return }
        advanceToolbarMorph(
            at: toolbarMorphStartTime + Self.toolbarMorphDuration)
    }

    private func beginToolbarDrag(_ event: NSEvent) {
        guard let panel = floatingToolbarPanel,
              panel.frame.width > 0, panel.frame.height > 0 else { return }
        completeToolbarMorph()
        let pointer = NSEvent.mouseLocation
        toolbarLatestPointer = pointer
        toolbarDragStart = pointer
        toolbarDragOffset = CGPoint(
            x: pointer.x - panel.frame.midX,
            y: pointer.y - panel.frame.midY)
        toolbarDragTargetFrame = panel.frame
        toolbarDragDidMove = false
    }

    private func updateToolbarDrag(_ event: NSEvent) {
        guard let start = toolbarDragStart,
              let window, let panel = floatingToolbarPanel else { return }
        let pointer = NSEvent.mouseLocation
        toolbarLatestPointer = pointer
        if !toolbarDragDidMove {
            guard hypot(pointer.x - start.x, pointer.y - start.y) >= 2 else { return }
            toolbarDragDidMove = true
        }

        let now = ProcessInfo.processInfo.systemUptime
        if toolbarMorphTargetDock != nil {
            advanceToolbarMorph(at: now)
        } else {
            // Move the current geometry to the newest pointer before deciding
            // whether that pointer crossed an orientation boundary.
            let center = NSPoint(
                x: pointer.x - toolbarDragOffset.x,
                y: pointer.y - toolbarDragOffset.y)
            panel.setFrame(NSRect(
                x: center.x - panel.frame.width / 2,
                y: center.y - panel.frame.height / 2,
                width: panel.frame.width,
                height: panel.frame.height), display: true)
        }

        let dock = toolbarDock(for: pointer, relativeTo: window.frame)
        let orientationChanged = dock.isHorizontal != toolbarDock.isHorizontal
        if orientationChanged {
            toolbarDragOffset = toolbarDock.isHorizontal
                ? CGPoint(x: toolbarDragOffset.y, y: -toolbarDragOffset.x)
                : CGPoint(x: -toolbarDragOffset.y, y: toolbarDragOffset.x)
        }
        toolbarDock = dock
        MarkupPrefs.toolbarDockIndex = dock.rawValue

        let size = Self.floatingToolbarSize(for: dock)
        let center = NSPoint(
            x: pointer.x - toolbarDragOffset.x,
            y: pointer.y - toolbarDragOffset.y)
        let frame = NSRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height)
        toolbarDragTargetFrame = frame

        if orientationChanged {
            startToolbarMorph(to: dock, at: now)
        } else if toolbarMorphTargetDock != nil {
            toolbarMorphTargetDock = dock
            toolbarMorphToSize = size
            toolbarMorphToOffset = toolbarDragOffset
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func endToolbarDrag(_ event: NSEvent) {
        guard toolbarDragStart != nil else { return }
        updateToolbarDrag(event)
        let didMove = toolbarDragDidMove
        let target = toolbarDragTargetFrame
        toolbarDragStart = nil
        toolbarDragTargetFrame = nil
        toolbarDragDidMove = false
        guard didMove, let target else { return }
        saveToolbarCenter(NSPoint(x: target.midX, y: target.midY))
    }

    private func toolbarDock(for pointer: NSPoint, relativeTo parent: NSRect) -> ToolbarDock {
        let hysteresis: CGFloat = 8

        // Once oriented, require a few pixels of deliberate movement across a
        // boundary before rotating back. This prevents cursor jitter on an
        // editor edge from flashing between horizontal and vertical layouts.
        if toolbarDock.isHorizontal {
            let remainsAcross = pointer.x >= parent.minX - hysteresis
                && pointer.x <= parent.maxX + hysteresis
            if toolbarDock == .top,
               remainsAcross, pointer.y >= parent.maxY - hysteresis { return .top }
            if toolbarDock == .bottom,
               remainsAcross, pointer.y <= parent.minY + hysteresis { return .bottom }
        } else {
            let clearlyAcross = pointer.x >= parent.minX + hysteresis
                && pointer.x <= parent.maxX - hysteresis
            if clearlyAcross, pointer.y >= parent.maxY + hysteresis { return .top }
            if clearlyAcross, pointer.y <= parent.minY - hysteresis { return .bottom }
            return pointer.x < parent.midX ? .left : .right
        }

        let isAbove = pointer.y >= parent.maxY
        let isBelow = pointer.y <= parent.minY
        let isAcrossWindow = pointer.x >= parent.minX && pointer.x <= parent.maxX
        if isAcrossWindow && (isAbove || isBelow) {
            return isAbove ? .top : .bottom
        }
        return pointer.x < parent.midX ? .left : .right
    }

    private func saveToolbarCenter(_ center: NSPoint) {
        guard let window else { return }
        let parent = window.frame
        let relative = CGPoint(
            x: (center.x - parent.minX) / max(parent.width, 1),
            y: (center.y - parent.minY) / max(parent.height, 1))
        toolbarRelativeCenter = relative
        MarkupPrefs.toolbarRelativeCenter = relative
    }

    private func tearDownFloatingToolbar() {
        colorPopover.performClose(nil)
        toolbarMorphTimer?.invalidate()
        toolbarMorphTimer = nil
        toolbarMorphTargetDock = nil
        toolbarDragStart = nil
        toolbarDragTargetFrame = nil
        toolbarDragDidMove = false
        guard let panel = floatingToolbarPanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.close()
        floatingToolbarPanel = nil
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

    private static func strokeImage(points: CGFloat, selected: Bool) -> NSImage {
        let side: CGFloat = 24
        let diameter: CGFloat
        switch points {
        case ..<2: diameter = 4
        case ..<6: diameter = 7
        default: diameter = 13
        }
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: NSRect(
                x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                width: diameter, height: diameter))
            (selected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).setFill()
            dot.fill()
            return true
        }
    }

    private static func nearestStrokePreset(to points: CGFloat) -> CGFloat {
        strokePresets.min { abs($0 - points) < abs($1 - points) } ?? strokePresets[1]
    }

    private func restoreCanvasFocus() {
        guard let window else { return }
        if window.isVisible { window.makeKey() }
        window.makeFirstResponder(canvas)
    }

    // MARK: - Actions

    @objc private func toolClicked(_ sender: NSButton) {
        selectTool(at: sender.tag)
    }

    private func selectTool(at index: Int) {
        guard Self.tools.indices.contains(index) else { return }
        MarkupPrefs.toolIndex = index
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
        restoreCanvasFocus()
    }

    @objc private func applyCropClicked() {
        guard canvas.applyCrop() else {
            NSSound.beep()
            return
        }
        selectTool(at: Self.pointerToolIndex)
    }

    @objc private func colorPopoverClicked(_ sender: NSButton) {
        if colorPopover.isShown {
            colorPopover.performClose(sender)
        } else {
            let edge: NSRectEdge = switch toolbarDock {
            case .bottom: .maxY
            case .top: .minY
            case .left: .maxX
            case .right: .minX
            }
            colorPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: edge)
        }
    }

    @objc private func colorClicked(_ sender: NSButton) {
        selectColor(at: sender.tag)
        colorPopover.performClose(sender)
    }

    @objc private func colorTargetChanged(_ sender: NSSegmentedControl) {
        colorTarget = sender.selectedSegment == 0 ? .stroke : .fill
        MarkupPrefs.editsFill = colorTarget == .fill
        refreshColorButtons()
    }

    private func selectColor(at index: Int) {
        switch colorTarget {
        case .stroke:
            guard MarkupPalette.colors.indices.contains(index) else { return }
            strokeColorIndex = index
            MarkupPrefs.strokeColorIndex = index
            canvas.setColorIndex(index)
        case .fill:
            guard index == -1 || MarkupPalette.colors.indices.contains(index) else { return }
            chosenFillColorIndex = index >= 0 ? index : nil
            MarkupPrefs.fillColorIndex = chosenFillColorIndex
            canvas.setFillColorIndex(chosenFillColorIndex)
        }
        refreshColorButtons()
        restoreCanvasFocus()
    }

    private func refreshColorButtons() {
        colorTargetControl?.selectedSegment = colorTarget == .stroke ? 0 : 1
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

        let name: String
        if colorTarget == .fill && chosenFillColorIndex == nil {
            activeColorButton?.image = NSImage(
                systemSymbolName: "nosign", accessibilityDescription: "No fill")
            name = "Fill color: None"
        } else {
            let index = colorTarget == .stroke
                ? strokeColorIndex : (chosenFillColorIndex ?? strokeColorIndex)
            activeColorButton?.image = Self.swatchImage(colorIndex: index, selected: false)
            name = "\(colorTarget == .stroke ? "Stroke" : "Fill") color: "
                + MarkupPalette.colors[index].name
        }
        activeColorButton?.toolTip = name
        activeColorButton?.setAccessibilityLabel(name)
    }

    @objc private func strokeClicked(_ sender: NSButton) {
        guard Self.strokePresets.indices.contains(sender.tag) else { return }
        let points = Self.strokePresets[sender.tag]
        MarkupPrefs.strokePoints = points
        canvas.setStrokeWidth(points: points)
        refreshStrokeButtons()
        restoreCanvasFocus()
    }

    private func refreshStrokeButtons() {
        let selected = Self.nearestStrokePreset(to: MarkupPrefs.strokePoints)
        for button in strokeButtons {
            guard Self.strokePresets.indices.contains(button.tag) else { continue }
            let points = Self.strokePresets[button.tag]
            let isSelected = points == selected
            button.state = isSelected ? .on : .off
            button.image = Self.strokeImage(points: points, selected: isSelected)
            button.setAccessibilityValue("\(Int(points)) points, "
                                         + (isSelected ? "selected" : "not selected"))
        }
    }

    @objc private func sizeChanged(_ sender: NSPopUpButton) {
        let index = min(max(sender.indexOfSelectedItem, 0), Self.outputScales.count - 1)
        MarkupPrefs.outputScaleIndex = index
        canvas.setOutputScale(Self.outputScales[index])
        let value = sender.titleOfSelectedItem ?? ""
        sender.toolTip = "Output image size: \(value)"
        sender.setAccessibilityValue(value)
        restoreCanvasFocus()
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
        tearDownFloatingToolbar()
        window?.delegate = nil
        window?.close()
        callback?(exit)
    }

    public func windowWillClose(_ notification: Notification) {
        // Title-bar close is a cancel.
        let callback = onFinish
        onFinish = nil
        tearDownFloatingToolbar()
        callback?(.cancelled)
    }

    public func windowDidResize(_ notification: Notification) {
        positionFloatingToolbar()
    }

}
