import AppKit
import CoreGraphics
import Foundation

public enum MarkupTool: CaseIterable, Sendable {
    case arrow
    case line
    case ellipse
    case rect
    case pen
    case text

    /// Only the closed shapes take a fill; everything else is pure stroke
    /// (or text, which is drawn solid).
    public var supportsFill: Bool {
        self == .rect || self == .ellipse
    }
}

public enum MarkupHandle: Equatable, Sendable {
    case start
    case end
    case curve
    case rotation
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

/// One annotation over the screenshot. Coordinates are image pixels with a
/// top-left origin; `start`/`end` are the drag endpoints (for rect/ellipse
/// they span the bounding box, orientation-free). Pen strokes carry their
/// sampled `points`; text carries its `text`/`fontSize`, with `end` kept in
/// sync with the measured extent so bounds-based geometry keeps working.
public struct MarkupShape: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var tool: MarkupTool
    public var colorIndex: Int
    public var fillColorIndex: Int?  // rect/ellipse only; nil means transparent
    public var start: CGPoint
    public var end: CGPoint
    /// Signed distance from the arrow's straight midpoint, perpendicular to
    /// its shaft. Zero draws a perfectly straight arrow.
    public var arrowBend: CGFloat
    public var lineWidth: CGFloat   // image pixels
    public var points: [CGPoint]    // pen only
    public var text: String         // text only
    public var fontSize: CGFloat    // text only, image pixels
    /// Clockwise visual rotation in the model's top-left, y-down space.
    public var rotationRadians: CGFloat  // text only

    public init(id: UUID = UUID(), tool: MarkupTool, colorIndex: Int,
                fillColorIndex: Int? = nil,
                start: CGPoint, end: CGPoint, arrowBend: CGFloat = 0,
                lineWidth: CGFloat = 3,
                points: [CGPoint] = [], text: String = "", fontSize: CGFloat = 0,
                rotationRadians: CGFloat = 0) {
        self.id = id
        self.tool = tool
        self.colorIndex = colorIndex
        self.fillColorIndex = fillColorIndex
        self.start = start
        self.end = end
        self.arrowBend = arrowBend
        self.lineWidth = lineWidth
        self.points = points
        self.text = text
        self.fontSize = fontSize
        self.rotationRadians = rotationRadians
    }

    /// Text's measured box before rotation. `start` remains its local
    /// top-left so changing the angle never changes its font metrics.
    public var unrotatedTextRect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    public var textCenter: CGPoint {
        let rect = unrotatedTextRect
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// Converts a point in the unrotated text box to its displayed position.
    public func rotatedTextPoint(_ point: CGPoint) -> CGPoint {
        let center = textCenter
        let dx = point.x - center.x, dy = point.y - center.y
        let cosine = cos(rotationRadians), sine = sin(rotationRadians)
        return CGPoint(x: center.x + dx * cosine - dy * sine,
                       y: center.y + dx * sine + dy * cosine)
    }

    /// Converts a displayed point back into the text box's local orientation.
    public func unrotatedTextPoint(_ point: CGPoint) -> CGPoint {
        let center = textCenter
        let dx = point.x - center.x, dy = point.y - center.y
        let cosine = cos(rotationRadians), sine = sin(rotationRadians)
        return CGPoint(x: center.x + dx * cosine + dy * sine,
                       y: center.y - dx * sine + dy * cosine)
    }

    /// Clockwise from the displayed top-left.
    public var rotatedTextCorners: [CGPoint] {
        let rect = unrotatedTextRect
        return [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ].map(rotatedTextPoint)
    }

    public var boundingRect: CGRect {
        if tool == .pen, let first = points.first {
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        if tool == .arrow {
            let control = arrowControlPoint
            let minX = min(start.x, end.x, control.x)
            let maxX = max(start.x, end.x, control.x)
            let minY = min(start.y, end.y, control.y)
            let maxY = max(start.y, end.y, control.y)
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        if tool == .text, let first = rotatedTextCorners.first {
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for point in rotatedTextCorners.dropFirst() {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                      width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// The draggable point that lies on the arrow at t = 0.5.
    public var arrowCurvePoint: CGPoint {
        let midpoint = CGPoint(x: (start.x + end.x) / 2,
                               y: (start.y + end.y) / 2)
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return midpoint }
        return CGPoint(x: midpoint.x - dy / length * arrowBend,
                       y: midpoint.y + dx / length * arrowBend)
    }

    /// Quadratic control point derived so the curve passes through the
    /// draggable midpoint rather than merely leaning toward it.
    public var arrowControlPoint: CGPoint {
        let midpoint = CGPoint(x: (start.x + end.x) / 2,
                               y: (start.y + end.y) / 2)
        let curve = arrowCurvePoint
        return CGPoint(x: curve.x * 2 - midpoint.x,
                       y: curve.y * 2 - midpoint.y)
    }
}

public enum MarkupPalette {
    /// A named annotation color with sRGB components.
    public struct Color: Sendable {
        public let name: String
        public let red: CGFloat
        public let green: CGFloat
        public let blue: CGFloat
    }

    /// Order: red, orange, yellow, green, blue, white, black.
    public static let colors: [Color] = [
        Color(name: "Red", red: 0.96, green: 0.26, blue: 0.21),
        Color(name: "Orange", red: 1.00, green: 0.58, blue: 0.00),
        Color(name: "Yellow", red: 1.00, green: 0.84, blue: 0.04),
        Color(name: "Green", red: 0.20, green: 0.78, blue: 0.35),
        Color(name: "Blue", red: 0.04, green: 0.52, blue: 1.00),
        Color(name: "White", red: 1.00, green: 1.00, blue: 1.00),
        Color(name: "Black", red: 0.00, green: 0.00, blue: 0.00),
    ]

    public static func cgColor(_ index: Int) -> CGColor {
        let color = colors[clampedIndex(index)]
        return CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    public static func nsColor(_ index: Int) -> NSColor {
        let color = colors[clampedIndex(index)]
        return NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    private static func clampedIndex(_ index: Int) -> Int {
        min(max(index, 0), colors.count - 1)
    }
}

public enum MarkupGeometry {
    public static func handles(
        for shape: MarkupShape,
        rotationHandleOffset: CGFloat = 24,
        within bounds: CGSize? = nil,
        rotationHandleUsesBottom: Bool? = nil
    ) -> [(handle: MarkupHandle, position: CGPoint)] {
        switch shape.tool {
        case .arrow:
            return [(.start, shape.start), (.curve, shape.arrowCurvePoint), (.end, shape.end)]
        case .line:
            return [(.start, shape.start), (.end, shape.end)]
        case .ellipse, .rect:
            let rect = shape.boundingRect
            return [
                (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
                (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
                (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
                (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            ]
        case .text:
            let corners = shape.rotatedTextCorners
            guard corners.count == 4 else { return [] }
            let rotation = rotationHandle(for: shape, offset: rotationHandleOffset,
                                          within: bounds,
                                          useBottom: rotationHandleUsesBottom)
            return [
                (.topLeft, corners[0]),
                (.topRight, corners[1]),
                (.bottomRight, corners[2]),
                (.bottomLeft, corners[3]),
                (.rotation, rotation.position),
            ]
        case .pen:
            // Move-only: pen strokes keep their drawn form.
            return []
        }
    }

    public static func handleHit(_ shape: MarkupShape, at point: CGPoint,
                                 tolerance: CGFloat,
                                 rotationHandleOffset: CGFloat = 24,
                                 within bounds: CGSize? = nil) -> MarkupHandle? {
        handles(for: shape, rotationHandleOffset: rotationHandleOffset,
                within: bounds).first {
            hypot($0.position.x - point.x, $0.position.y - point.y) <= tolerance
        }?.handle
    }

    /// The rotation handle stays a fixed visual distance from the marquee.
    /// Near the top edge it flips below the text so it remains reachable.
    public static func rotationHandle(
        for shape: MarkupShape, offset: CGFloat,
        within bounds: CGSize? = nil,
        useBottom: Bool? = nil
    ) -> (anchor: CGPoint, position: CGPoint, usesBottom: Bool) {
        let rect = shape.unrotatedTextRect
        let top = shape.rotatedTextPoint(CGPoint(x: rect.midX, y: rect.minY))
        let bottom = shape.rotatedTextPoint(CGPoint(x: rect.midX, y: rect.maxY))
        let outward = rotated(CGVector(dx: 0, dy: -offset), by: shape.rotationRadians)
        let inward = rotated(CGVector(dx: 0, dy: offset), by: shape.rotationRadians)
        let topPosition = CGPoint(x: top.x + outward.dx, y: top.y + outward.dy)
        let bottomPosition = CGPoint(x: bottom.x + inward.dx, y: bottom.y + inward.dy)

        if useBottom == true { return (bottom, bottomPosition, true) }
        if useBottom == false { return (top, topPosition, false) }
        if let bounds {
            let canvas = CGRect(origin: .zero, size: bounds)
            if !canvas.contains(topPosition), canvas.contains(bottomPosition) {
                return (bottom, bottomPosition, true)
            }
        }
        return (top, topPosition, false)
    }

    /// True when `point` is on a stroke, inside a filled shape, or inside text.
    public static func strokeHit(_ shape: MarkupShape, at point: CGPoint,
                                 tolerance: CGFloat) -> Bool {
        switch shape.tool {
        case .arrow, .line, .rect, .ellipse:
            return renderedPathHit(shape, at: point, tolerance: tolerance)
        case .pen:
            guard shape.points.count > 1 else {
                guard let only = shape.points.first else { return false }
                return hypot(only.x - point.x, only.y - point.y) <= tolerance
            }
            for index in 0..<(shape.points.count - 1) {
                if distanceToSegment(point, shape.points[index],
                                     shape.points[index + 1]) <= tolerance {
                    return true
                }
            }
            return false
        case .text:
            // Text is solid, not an outline — its whole box is grabbable.
            return shape.unrotatedTextRect
                .insetBy(dx: -tolerance, dy: -tolerance)
                .contains(shape.unrotatedTextPoint(point))
        }
    }

    /// Uses the exact display/export contour so organic arrows and shapes are
    /// selectable everywhere the user can see a stroke.
    private static func renderedPathHit(_ shape: MarkupShape, at point: CGPoint,
                                        tolerance: CGFloat) -> Bool {
        let path = MarkupRender.path(for: shape, strokeWidth: shape.lineWidth)
        if shape.fillColorIndex != nil, path.contains(point) { return true }
        let hitPath = path.copy(
            strokingWithWidth: max(shape.lineWidth, 1) + tolerance * 2,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
        return hitPath.contains(point)
    }

    /// Topmost shape whose stroke is near `point`.
    public static func hitShape(in shapes: [MarkupShape], at point: CGPoint,
                                tolerance: CGFloat) -> MarkupShape? {
        shapes.reversed().first { strokeHit($0, at: point, tolerance: tolerance) }
    }

    /// Translates the shape, clamped so its bounding box stays inside `bounds`.
    public static func moved(_ shape: MarkupShape, by translation: CGSize,
                             within bounds: CGSize) -> MarkupShape {
        let rect = shape.boundingRect
        let dx = clampedTranslation(translation.width, minimum: -rect.minX,
                                    maximum: bounds.width - rect.maxX,
                                    oversizedCentering: bounds.width / 2 - rect.midX)
        let dy = clampedTranslation(translation.height, minimum: -rect.minY,
                                    maximum: bounds.height - rect.maxY,
                                    oversizedCentering: bounds.height / 2 - rect.midY)
        var moved = shape
        moved.start = CGPoint(x: shape.start.x + dx, y: shape.start.y + dy)
        moved.end = CGPoint(x: shape.end.x + dx, y: shape.end.y + dy)
        moved.points = shape.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return moved
    }

    private static func clampedTranslation(_ proposed: CGFloat, minimum: CGFloat,
                                           maximum: CGFloat,
                                           oversizedCentering: CGFloat) -> CGFloat {
        guard minimum <= maximum else { return oversizedCentering }
        return min(max(proposed, minimum), maximum)
    }

    /// Drags one handle to `point`. Corner handles anchor the opposite corner;
    /// endpoint handles move that endpoint.
    public static func resized(_ shape: MarkupShape, handle: MarkupHandle,
                               to point: CGPoint) -> MarkupShape {
        var resized = shape
        switch handle {
        case .start:
            resized.start = point
        case .end:
            resized.end = point
        case .curve:
            let midpoint = CGPoint(x: (shape.start.x + shape.end.x) / 2,
                                   y: (shape.start.y + shape.end.y) / 2)
            let dx = shape.end.x - shape.start.x
            let dy = shape.end.y - shape.start.y
            let length = hypot(dx, dy)
            guard length > 0.001 else { return resized }
            let normal = CGVector(dx: -dy / length, dy: dx / length)
            let offset = (point.x - midpoint.x) * normal.dx
                + (point.y - midpoint.y) * normal.dy
            resized.arrowBend = abs(offset) < 0.5 ? 0 : offset
        case .rotation:
            break  // Text rotation is handled as an angular canvas drag.
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let rect = shape.boundingRect
            let anchor: CGPoint
            switch handle {
            case .topLeft: anchor = CGPoint(x: rect.maxX, y: rect.maxY)
            case .topRight: anchor = CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomLeft: anchor = CGPoint(x: rect.maxX, y: rect.minY)
            default: anchor = CGPoint(x: rect.minX, y: rect.minY)
            }
            resized.start = anchor
            resized.end = point
        }
        return resized
    }

    public static func clamped(_ point: CGPoint, to bounds: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width),
                y: min(max(point.y, 0), bounds.height))
    }

    public static func rotated(_ vector: CGVector, by angle: CGFloat) -> CGVector {
        let cosine = cos(angle), sine = sin(angle)
        return CGVector(dx: vector.dx * cosine - vector.dy * sine,
                        dy: vector.dx * sine + vector.dy * cosine)
    }

    public static func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        var normalized = angle.truncatingRemainder(dividingBy: .pi * 2)
        if normalized > .pi { normalized -= .pi * 2 }
        if normalized < -.pi { normalized += .pi * 2 }
        return normalized
    }

    public static func distanceToSegment(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(max(((point.x - a.x) * abx + (point.y - a.y) * aby) / lengthSquared, 0), 1)
        return hypot(point.x - (a.x + t * abx), point.y - (a.y + t * aby))
    }
}

/// Persisted markup preferences (shared app defaults).
public enum MarkupPrefs {
    private static let strokeKey = "DropperMarkupStrokePoints"

    /// Stroke width in screen points, clamped to 1...12; written on every
    /// slider tick so the choice sticks across sessions.
    public static var strokePoints: CGFloat {
        get {
            let value = UserDefaults.standard.double(forKey: strokeKey)
            return value == 0 ? 3 : CGFloat(min(max(value, 1), 12))
        }
        set {
            UserDefaults.standard.set(Double(min(max(newValue, 1), 12)),
                                      forKey: strokeKey)
        }
    }
}
