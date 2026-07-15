import AppKit
import QuartzCore

/// The capture "eye candy". The choreography tells a little story: a shutter
/// click, the raw capture is picked UP off the desktop (anticipation coil →
/// overshoot lift), the desktop falls into a blurred dark focus a beat behind,
/// the editor frame ASSEMBLES beneath the raised shot, and the shot SETTLES
/// down into the frame with a landing squash. The desktop stays dimmed while
/// you edit and only restores when the editor closes.
///
/// Layering is what makes it work: a scrim window *below* the editor (so the
/// editor stays in focus) and a ghost window *above* it (so the shot floats
/// over the assembling frame). Built on Core Animation for reliably smooth,
/// orchestrated timing.
@MainActor
public enum CaptureIntro {
    /// Returns a `dismiss` closure — call it when the editor closes to restore
    /// the desktop. `screenRect`/`finalFrame` are global AppKit points.
    @discardableResult
    public static func play(
        image: CGImage, screenRect: CGRect, isFullScreen: Bool,
        finalFrame: CGRect, editorWindow: NSWindow, present: @escaping () -> Void
    ) -> () -> Void {
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !union.isNull, screenRect.width > 1, finalFrame.width > 1 else {
            present(); return {}
        }

        // Global AppKit (bottom-left) → flipped local (top-left, y-down).
        func local(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX - union.minX, y: union.maxY - r.maxY,
                   width: r.width, height: r.height)
        }
        func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

        // --- Scrim window: blurred, dark, cool. Sits BELOW the editor. ---
        let scrim = overlayWindow(union, level: .floating)
        let scrimRoot = NSView(frame: CGRect(origin: .zero, size: union.size))
        scrimRoot.autoresizingMask = [.width, .height]
        let blur = NSVisualEffectView(frame: scrimRoot.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        let tint = NSView(frame: scrimRoot.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        // ~#0B0B0F, cool and deep, over the blur — not a flat pure black.
        tint.layer?.backgroundColor = NSColor(red: 0.043, green: 0.043,
                                              blue: 0.062, alpha: 0.62).cgColor
        scrimRoot.addSubview(blur)
        scrimRoot.addSubview(tint)
        scrim.contentView = scrimRoot
        scrim.alphaValue = 0

        // --- Ghost window: the shot + shutter flash. Sits ABOVE the editor. ---
        let ghostWindow = overlayWindow(union, level: .screenSaver)
        let root = FlippedView(frame: CGRect(origin: .zero, size: union.size))
        root.wantsLayer = true
        ghostWindow.contentView = root
        guard let rootLayer = root.layer else { present(); return {} }

        let start = local(screenRect)
        let end = local(finalFrame)
        let lifted = CGRect(x: start.minX, y: start.minY - Timing.liftHeight,
                            width: start.width * Timing.liftScale,
                            height: start.height * Timing.liftScale)

        let ghost = CALayer()
        ghost.contents = image
        ghost.contentsGravity = .resize
        ghost.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ghost.bounds = CGRect(origin: .zero, size: start.size)
        ghost.position = center(start)
        ghost.cornerRadius = isFullScreen ? 0 : 6
        ghost.shadowColor = NSColor.black.cgColor
        ghost.shadowRadius = 8
        ghost.shadowOffset = CGSize(width: 0, height: 6)
        ghost.shadowOpacity = 0
        rootLayer.addSublayer(ghost)

        scrim.orderFrontRegardless()
        ghostWindow.orderFrontRegardless()

        // ---- The lift/settle path (area & window) ----
        // A full-screen shot can't rise, so it just eases down into the frame.
        let overshoot = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)
        let easeOut = CAMediaTimingFunction(name: .easeOut)
        let easeInOut = CAMediaTimingFunction(name: .easeInEaseOut)

        let positions: [CGPoint]
        let sizes: [NSValue]
        let squashes: [NSValue]
        let keyTimes: [NSNumber]
        let timings: [CAMediaTimingFunction]
        let ghostDuration: CFTimeInterval

        if isFullScreen {
            positions = [center(start), center(end)]
            sizes = [NSValue(size: start.size), NSValue(size: end.size)]
            squashes = [squash(1), squash(0.97)]
            keyTimes = [0, 1]
            timings = [easeInOut]
            ghostDuration = 0.5
        } else {
            positions = [center(start), center(start), center(lifted),
                         center(lifted), center(end), center(end)]
            sizes = [NSValue(size: start.size), NSValue(size: start.size),
                     NSValue(size: lifted.size), NSValue(size: lifted.size),
                     NSValue(size: end.size), NSValue(size: end.size)]
            // Anticipation coil, release, then a landing squash on arrival.
            squashes = [squash(1), squash(0.95), squash(1), squash(1),
                        squash(0.94), squash(1)]
            keyTimes = [0, 0.10, 0.50, 0.58, 0.88, 1.0]
            timings = [easeOut, overshoot, easeInOut, easeInOut, easeOut]
            ghostDuration = Timing.ghost
        }

        addKeyframe(ghost, "position", positions.map { NSValue(point: $0) },
                    keyTimes, timings, ghostDuration)
        addKeyframe(ghost, "bounds.size", sizes, keyTimes, timings, ghostDuration)
        addKeyframe(ghost, "transform", squashes, keyTimes, timings, ghostDuration)
        ghost.position = center(end)
        ghost.bounds = CGRect(origin: .zero, size: end.size)

        // ---- Shadow: grows, softens, offsets — and LAGS the lift ~50ms, so the
        // object reads as levitating rather than sliding. ----
        let shadowRadius = isFullScreen ? [8.0, 8.0] : [8.0, 8.0, 40.0, 40.0, 22.0, 18.0]
        let shadowOpacity = isFullScreen ? [0.0, 0.28] : [0.0, 0.0, 0.45, 0.45, 0.34, 0.3]
        let shadowY = isFullScreen ? [6.0, 6.0] : [6.0, 6.0, 34.0, 34.0, 20.0, 16.0]
        addKeyframe(ghost, "shadowRadius", shadowRadius.map { $0 as NSNumber },
                    keyTimes, timings, ghostDuration, lag: 0.05)
        addKeyframe(ghost, "shadowOpacity", shadowOpacity.map { $0 as NSNumber },
                    keyTimes, timings, ghostDuration, lag: 0.05)
        addKeyframe(ghost, "shadowOffset",
                    shadowY.map { NSValue(size: CGSize(width: 0, height: $0)) },
                    keyTimes, timings, ghostDuration, lag: 0.05)
        ghost.shadowRadius = CGFloat(shadowRadius.last ?? 8)
        ghost.shadowOpacity = Float(shadowOpacity.last ?? 0)
        ghost.shadowOffset = CGSize(width: 0, height: shadowY.last ?? 6)

        // ---- The desktop falls into focus a BEAT BEHIND the lift. Deferred one
        // runloop tick so the window is committed at alpha 0 first — otherwise
        // the blur pops in at full for a frame (the flash). ----
        DispatchQueue.main.async {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Timing.scrimRamp
                context.timingFunction = easeOut
                scrim.animator().alphaValue = 1
            }
        }

        // ---- The editor ASSEMBLES beneath the raised shot, mid-lift. ----
        let editorAt = isFullScreen ? 0.28 : Timing.editorAssemble
        DispatchQueue.main.asyncAfter(deadline: .now() + editorAt) {
            present()
            editorWindow.level = .floating   // above the scrim, below the ghost
        }

        // The desktop fades back in once the capture has landed in the frame.
        // Guarded so it runs once, whether triggered by the settle or an early
        // editor close.
        var restored = false
        func restoreDesktop() {
            guard !restored else { return }
            restored = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.9
                context.timingFunction = easeInOut
                scrim.animator().alphaValue = 0
            }
            // Keep the editor above the still-fading scrim, then settle it back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
                scrim.orderOut(nil)
                editorWindow.level = .normal
            }
        }

        // ---- Once settled, the shot fades onto the editor's canvas, then the
        // desktop fades back in — the capture has landed in the frame. ----
        DispatchQueue.main.asyncAfter(deadline: .now() + ghostDuration - 0.02) {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.2
            fade.timingFunction = easeInOut
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            ghost.opacity = 0
            ghost.add(fade, forKey: "settleFade")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                ghostWindow.orderOut(nil)
                restoreDesktop()
            }
        }

        // Safety: if the editor is dismissed before the intro finishes, restore.
        return {
            restoreDesktop()
            ghostWindow.orderOut(nil)
        }
    }

    private enum Timing {
        static let ghost: CFTimeInterval = 0.95
        static let scrimRamp: CFTimeInterval = 0.32
        static let editorAssemble: CFTimeInterval = 0.46
        static let liftHeight: CGFloat = 56
        static let liftScale: CGFloat = 1.06
    }

    private static func squash(_ y: CGFloat) -> NSValue {
        NSValue(caTransform3D: CATransform3DMakeScale(1, y, 1))
    }

    private static func addKeyframe(
        _ layer: CALayer, _ keyPath: String, _ values: [Any],
        _ keyTimes: [NSNumber], _ timings: [CAMediaTimingFunction],
        _ duration: CFTimeInterval, lag: CFTimeInterval = 0
    ) {
        let anim = CAKeyframeAnimation(keyPath: keyPath)
        anim.values = values
        anim.keyTimes = keyTimes
        anim.timingFunctions = timings
        anim.duration = duration
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        if lag > 0 { anim.beginTime = CACurrentMediaTime() + lag }
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
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return window
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
