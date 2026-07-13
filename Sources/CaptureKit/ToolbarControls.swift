import AppKit

/// Lets titlebar drags pass straight through the centered title text.
final class PassthroughTitleLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A toolbar control whose visible bezel fills its actual square bounds.
/// AppKit's textured bezel paints at a fixed control height even when the
/// button frame is square, which made the old controls still look pill-shaped.
final class SquareToolbarButton: NSButton {
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
final class ToolbarSeparatorView: NSView {
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
