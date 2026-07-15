import AppKit
import QuartzCore

/// Speed multiplier for the capture intro. 1 = baseline; 0.75 = 25% quicker.
let captureSlowMo: Double = 0.75

/// The focus scrim behind the capture flow — a SPOTLIGHT, not a blanket. It
/// dims everything EXCEPT the captured region (a clear hole), so the subject
/// stays visible the whole time the still is being taken. It comes up the
/// instant a capture is CONFIRMED (before the selection overlay tears down), so
/// the desktop never flashes bright and the subject is never obscured. Once the
/// lifted copy appears over the hole, `closeHole()` fills the gap behind it.
///
/// Built from four opaque panels framing the hole (plain NSView frames, so
/// there's no layer/flip coordinate ambiguity).
@MainActor
public final class CaptureScrim {
    fileprivate let window: NSWindow
    private let root: NSView
    private var panels: [NSView] = []
    private let holeCover: NSView
    // Start at the selection overlay's exact dim so the hand-off is invisible;
    // deepen only as the subject lifts out.
    private static let selectionDim: Float = 0.40
    private static let liftDim: Float = 0.86

    /// `hole` is the captured region in global AppKit points.
    public init(hole: CGRect) {
        // Scope to the screen the capture is ON — not all screens — so on a
        // multi-display setup the dim lands where the shot came from, not on
        // whichever display the pill happens to live on.
        let center = CGPoint(x: hole.midX, y: hole.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? .zero
        window = NSWindow(contentRect: frame, styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.animationBehavior = .none   // no system appearance animation
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        root = NSView(frame: CGRect(origin: .zero, size: frame.size))
        window.contentView = root

        // Window-local (bottom-left) hole, clamped on-screen.
        let bounds = root.bounds
        let holeLocal = CGRect(x: hole.minX - frame.minX, y: hole.minY - frame.minY,
                               width: hole.width, height: hole.height).intersection(bounds)
        let W = bounds.width, H = bounds.height
        for r in [
            CGRect(x: 0, y: 0, width: max(0, holeLocal.minX), height: H),                       // left
            CGRect(x: holeLocal.maxX, y: 0, width: max(0, W - holeLocal.maxX), height: H),       // right
            CGRect(x: holeLocal.minX, y: 0, width: holeLocal.width, height: max(0, holeLocal.minY)),          // below
            CGRect(x: holeLocal.minX, y: holeLocal.maxY, width: holeLocal.width, height: max(0, H - holeLocal.maxY)), // above
        ] {
            panels.append(Self.panel(frame: r, opacity: Self.selectionDim))
        }
        // Fills the hole as the subject lifts out (starts invisible).
        holeCover = Self.panel(frame: holeLocal, opacity: 0)
        panels.forEach(root.addSubview)
        root.addSubview(holeCover)

        window.alphaValue = 1
        window.orderFrontRegardless()
    }

    private static func panel(frame: CGRect, opacity: Float) -> NSView {
        let view = NSView(frame: frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.opacity = opacity
        return view
    }

    /// Deepens the dim and fills the hole as the subject lifts out — the
    /// dramatic darkening happens WITH the lift, not at the hand-off.
    func deepen(duration: CFTimeInterval = 0.5 * captureSlowMo) {
        for panel in panels { Self.animateOpacity(panel, to: Self.liftDim, duration) }
        Self.animateOpacity(holeCover, to: Self.liftDim, duration)
    }

    private static func animateOpacity(_ view: NSView, to value: Float,
                                       _ duration: CFTimeInterval) {
        guard let layer = view.layer else { return }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = layer.opacity
        anim.toValue = value
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        layer.opacity = value
        layer.add(anim, forKey: "deepen")
    }

    /// Puts the editor above the scrim so it stays in focus while the desktop
    /// behind it is dimmed.
    fileprivate func placeEditorAbove(_ editorWindow: NSWindow) {
        editorWindow.level = .floating
        editorWindow.order(.above, relativeTo: window.windowNumber)
    }

    /// Fades the desktop back in.
    public func fadeOut() {
        let window = self.window
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.9 * captureSlowMo
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95 * captureSlowMo) {
            window.orderOut(nil)
        }
    }
}

/// The capture "eye candy". The desktop is already dimmed (the scrim came up at
/// capture-confirm); this adds the story: the raw capture is picked UP off the
/// desktop (anticipation coil → overshoot lift) while the editor frame ASSEMBLES
/// beneath it, then the shot SETTLES down into the frame with a landing squash —
/// and once it lands, the desktop fades back in. Built on Core Animation for
/// reliably smooth, orchestrated timing.
@MainActor
public enum CaptureIntro {
    /// Returns a `dismiss` closure — call it if the editor closes before the
    /// intro finishes. `screenRect`/`finalFrame` are global AppKit points.
    @discardableResult
    public static func play(
        scrim: CaptureScrim, image: CGImage, screenRect: CGRect,
        isFullScreen: Bool, finalFrame: CGRect, editorWindow: NSWindow,
        present: @escaping () -> Void, reveal: @escaping () -> Void,
        onLanded: @escaping () -> Void
    ) -> () -> Void {
        // Scope to the capture's own screen (see CaptureScrim) — desktop-aware.
        let captureCenter = CGPoint(x: screenRect.midX, y: screenRect.midY)
        let region = (NSScreen.screens.first { $0.frame.contains(captureCenter) }
            ?? NSScreen.main ?? NSScreen.screens.first)?.frame ?? .zero
        guard region.width > 1, screenRect.width > 1, finalFrame.width > 1 else {
            present(); return { scrim.fadeOut() }
        }

        // Global AppKit (bottom-left) → flipped local (top-left, y-down).
        func local(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX - region.minX, y: region.maxY - r.maxY,
                   width: r.width, height: r.height)
        }
        func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

        // Ghost window: the shot itself, ABOVE the editor.
        let ghostWindow = overlayWindow(region, level: .screenSaver)
        let root = FlippedView(frame: CGRect(origin: .zero, size: region.size))
        root.wantsLayer = true
        ghostWindow.contentView = root
        guard let rootLayer = root.layer else { present(); return { scrim.fadeOut() } }

        let start = local(screenRect)
        let end = local(finalFrame)
        let lifted = CGRect(x: start.minX, y: start.minY - Timing.liftHeight,
                            width: start.width * Timing.liftScale,
                            height: start.height * Timing.liftScale)

        let ghost = CALayer()
        // Forbid ALL implicit animations: setting the layer's model values (its
        // final position/size, shadow, etc.) must NOT auto-animate, or the copy
        // slides into place instead of appearing pinned over the subject. Only
        // our explicit keyframes drive it.
        ghost.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(),
                         "opacity": NSNull(), "contents": NSNull(), "cornerRadius": NSNull(),
                         "shadowOpacity": NSNull(), "shadowRadius": NSNull(),
                         "shadowOffset": NSNull()]
        ghost.contents = image
        // Aspect-preserving: the start/lifted/end rects all share the image's
        // aspect, so this fills exactly — and never squishes if they're a hair off.
        ghost.contentsGravity = .resizeAspect
        ghost.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ghost.bounds = CGRect(origin: .zero, size: start.size)
        ghost.position = center(start)
        ghost.cornerRadius = isFullScreen ? 0 : 6
        ghost.shadowColor = NSColor.black.cgColor
        ghost.shadowRadius = 8
        ghost.shadowOffset = CGSize(width: 0, height: 6)
        ghost.shadowOpacity = 0
        rootLayer.addSublayer(ghost)

        ghostWindow.orderFrontRegardless()
        // FIRST the dim deepens to black while the copy sits still on top of the
        // original (filling the hole behind it); only once the screen is dark
        // does the copy lift — so the copy and the original are never both seen.
        let deepenDuration = 0.5 * captureSlowMo
        scrim.deepen(duration: deepenDuration)

        let easeOut = CAMediaTimingFunction(name: .easeOut)
        let easeInOut = CAMediaTimingFunction(name: .easeInEaseOut)

        let positions: [CGPoint]
        let sizes: [NSValue]
        let squashes: [NSValue]
        let keyTimes: [NSNumber]
        let timings: [CAMediaTimingFunction]
        let ghostDuration: CFTimeInterval

        if isFullScreen {
            // Shrinks into the frame with a landing squash that RETURNS to 1 —
            // ending on a squash would leave it permanently out of aspect.
            positions = [center(start), center(end), center(end)]
            sizes = [NSValue(size: start.size), NSValue(size: end.size), NSValue(size: end.size)]
            squashes = [squash(1), squash(0.96), squash(1)]
            keyTimes = [0, 0.82, 1]
            timings = [easeInOut, easeOut]
            ghostDuration = 0.6 * captureSlowMo
        } else {
            // Just lifts out — no anticipation coil, no overshoot spring. It
            // eases up and grows a touch, hangs, settles into the frame, and
            // gets a gentle landing squash only at the very end.
            positions = [center(start), center(lifted), center(lifted),
                         center(end), center(end), center(end)]
            sizes = [NSValue(size: start.size), NSValue(size: lifted.size),
                     NSValue(size: lifted.size), NSValue(size: end.size),
                     NSValue(size: end.size), NSValue(size: end.size)]
            // Settles in with a gentle landing squash — compress, then pop back
            // to full height as it lands in the frame.
            squashes = [squash(1), squash(1), squash(1), squash(1),
                        squash(0.95), squash(1)]
            keyTimes = [0, 0.42, 0.50, 0.80, 0.90, 1.0]
            timings = [easeOut, easeInOut, easeInOut, easeInOut, easeOut]
            ghostDuration = Timing.ghost
        }

        addKeyframe(ghost, "position", positions.map { NSValue(point: $0) },
                    keyTimes, timings, ghostDuration, delay: deepenDuration)
        addKeyframe(ghost, "bounds.size", sizes, keyTimes, timings, ghostDuration,
                    delay: deepenDuration)
        addKeyframe(ghost, "transform", squashes, keyTimes, timings, ghostDuration,
                    delay: deepenDuration)
        ghost.position = center(end)
        ghost.bounds = CGRect(origin: .zero, size: end.size)

        // Shadow: grows, softens, offsets — and LAGS the lift ~50ms.
        let shadowRadius = isFullScreen ? [8.0, 34.0, 30.0] : [8.0, 40.0, 40.0, 24.0, 22.0, 18.0]
        let shadowOpacity = isFullScreen ? [0.0, 0.4, 0.34] : [0.0, 0.45, 0.45, 0.35, 0.33, 0.3]
        let shadowY = isFullScreen ? [6.0, 28.0, 24.0] : [6.0, 34.0, 34.0, 22.0, 20.0, 16.0]
        addKeyframe(ghost, "shadowRadius", shadowRadius.map { $0 as NSNumber },
                    keyTimes, timings, ghostDuration, delay: deepenDuration,
                    lag: 0.05 * captureSlowMo)
        addKeyframe(ghost, "shadowOpacity", shadowOpacity.map { $0 as NSNumber },
                    keyTimes, timings, ghostDuration, delay: deepenDuration,
                    lag: 0.05 * captureSlowMo)
        addKeyframe(ghost, "shadowOffset",
                    shadowY.map { NSValue(size: CGSize(width: 0, height: $0)) },
                    keyTimes, timings, ghostDuration, delay: deepenDuration,
                    lag: 0.05 * captureSlowMo)
        ghost.shadowRadius = CGFloat(shadowRadius.last ?? 8)
        ghost.shadowOpacity = Float(shadowOpacity.last ?? 0)
        ghost.shadowOffset = CGSize(width: 0, height: shadowY.last ?? 6)

        // The editor ASSEMBLES beneath the raised shot, mid-lift, above the scrim.
        let editorAt = deepenDuration
            + (isFullScreen ? 0.28 * captureSlowMo : Timing.editorAssemble)
        DispatchQueue.main.asyncAfter(deadline: .now() + editorAt) {
            present()
            scrim.placeEditorAbove(editorWindow)
        }

        // Once settled, the shot fades onto the canvas and the desktop returns.
        var restored = false
        func restoreDesktop() {
            guard !restored else { return }
            restored = true
            scrim.fadeOut()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.95 * captureSlowMo) {
                editorWindow.level = .normal
            }
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + deepenDuration + ghostDuration - 0.02 * captureSlowMo) {
            // The ghost has landed at full size — hand off to the editor's canvas
            // now (never both at once), then fade the ghost onto it.
            reveal()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.2 * captureSlowMo
            fade.timingFunction = easeInOut
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            ghost.opacity = 0
            ghost.add(fade, forKey: "settleFade")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24 * captureSlowMo) {
                ghostWindow.orderOut(nil)
                restoreDesktop()
            }
        }

        // On the LANDING — the instant it touches down in the frame (keyTime
        // ~0.80), after the descent and before the spring-up.
        DispatchQueue.main.asyncAfter(deadline: .now() + deepenDuration + ghostDuration * 0.8) {
            onLanded()
        }

        return {
            restoreDesktop()
            ghostWindow.orderOut(nil)
        }
    }

    private enum Timing {
        static let ghost: CFTimeInterval = 0.95 * captureSlowMo
        static let editorAssemble: CFTimeInterval = 0.46 * captureSlowMo
        static let liftHeight: CGFloat = 56       // spatial — not scaled
        static let liftScale: CGFloat = 1.06      // spatial — not scaled
    }

    private static func squash(_ y: CGFloat) -> NSValue {
        NSValue(caTransform3D: CATransform3DMakeScale(1, y, 1))
    }

    private static func addKeyframe(
        _ layer: CALayer, _ keyPath: String, _ values: [Any],
        _ keyTimes: [NSNumber], _ timings: [CAMediaTimingFunction],
        _ duration: CFTimeInterval, delay: CFTimeInterval = 0, lag: CFTimeInterval = 0
    ) {
        let anim = CAKeyframeAnimation(keyPath: keyPath)
        anim.values = values
        anim.keyTimes = keyTimes
        anim.timingFunctions = timings
        anim.duration = duration
        // .both so it holds the START value during the delay (the shot sits
        // still while the screen darkens) and the END value after.
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        let offset = delay + lag
        if offset > 0 { anim.beginTime = CACurrentMediaTime() + offset }
        layer.add(anim, forKey: keyPath)
    }

    private static func overlayWindow(_ frame: CGRect, level: NSWindow.Level) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = level
        window.ignoresMouseEvents = true
        window.hasShadow = false
        // No system "pop into place" appearance animation — the ghost must appear
        // dead-still, pinned over the subject; only our keyframes move it.
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return window
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
