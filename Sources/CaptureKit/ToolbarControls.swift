import AppKit

/// Lets titlebar drags pass straight through the centered title text.
final class PassthroughTitleLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A circular toolbar control with a reliable 36-point hit target.
final class SquareToolbarButton: NSButton {
    private var isHovering = false
    private var pointerTrackingArea: NSTrackingArea?

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
            fill = NSColor.controlAccentColor.withAlphaComponent(0.22)
        } else if isHighlighted || isHovering {
            fill = NSColor.labelColor.withAlphaComponent(0.10)
        } else {
            fill = .clear
        }

        layer.cornerRadius = min(bounds.width, bounds.height) / 2
        layer.masksToBounds = true
        layer.backgroundColor = fill.cgColor
        layer.borderWidth = 1
        layer.borderColor = NSColor.white.withAlphaComponent(
            state == .on ? 0.20 : 0.11).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard pointerTrackingArea == nil else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
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

/// Keeps the output-size menu visually consistent with the circular tool
/// buttons while retaining normal NSPopUpButton menu behavior.
final class CircularToolbarPopUpButton: NSPopUpButton {
    private var isHovering = false
    private var pointerTrackingArea: NSTrackingArea?

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        isBordered = false
        focusRingType = .none
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        guard let layer else { return }
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
        layer.masksToBounds = true
        layer.backgroundColor = (isHighlighted || isHovering)
            ? NSColor.labelColor.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
        layer.borderWidth = 1
        layer.borderColor = NSColor.white.withAlphaComponent(0.11).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard pointerTrackingArea == nil else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
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

/// A black capsule with the same hairline used by Dropper's menu-bar pill.
final class FloatingToolbarBackgroundView: NSView {
    var onDragBegan: ((NSEvent) -> Void)?
    var onDragChanged: ((NSEvent) -> Void)?
    var onDragEnded: ((NSEvent) -> Void)?
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(rect.width, rect.height) / 2
        let capsule = NSBezierPath(
            roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.black.setFill()
        capsule.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        onDragBegan?(event)
    }

    override func mouseDragged(with event: NSEvent) { onDragChanged?(event) }
    override func mouseUp(with event: NSEvent) { onDragEnded?(event) }
}

/// Lets drags that begin in the gaps between toolbar controls move the panel.
/// Buttons remain normal hit targets and continue receiving clicks.
final class MovableToolbarStackView: NSStackView {
    var onDragBegan: ((NSEvent) -> Void)?
    var onDragChanged: ((NSEvent) -> Void)?
    var onDragEnded: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onDragBegan?(event)
    }

    override func mouseDragged(with event: NSEvent) { onDragChanged?(event) }
    override func mouseUp(with event: NSEvent) { onDragEnded?(event) }
}

/// An explicit full-width hairline that stays visible over vibrant materials.
final class ToolbarSeparatorView: NSView {
    var axis: NSLayoutConstraint.Orientation = .vertical {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize {
        axis == .vertical
            ? NSSize(width: 1, height: 24)
            : NSSize(width: 24, height: 1)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
    }
}
