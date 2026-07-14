import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MarkupRenderError: Error {
    case writeFailed
}

public enum MarkupRender {
    public static func path(for shape: MarkupShape, strokeWidth: CGFloat) -> CGPath {
        let path = CGMutablePath()
        switch shape.tool {
        case .line:
            path.move(to: shape.start)
            path.addLine(to: shape.end)
        case .arrow:
            addSketchArrow(shape, strokeWidth: strokeWidth, to: path)
        case .ellipse:
            addSketchEllipse(in: shape.boundingRect, to: path)
        case .rect:
            addSketchRectangle(in: shape.boundingRect,
                               strokeWidth: strokeWidth, to: path)
        case .pen:
            if let first = shape.points.first {
                path.move(to: first)
                // A bare click still leaves a dot (round cap on a zero-length
                // segment).
                path.addLine(to: shape.points.count > 1 ? shape.points[1] : first)
                for point in shape.points.dropFirst(2) {
                    path.addLine(to: point)
                }
            }
        case .text:
            break  // drawn with CoreText, not a stroke path
        }
        return path
    }

    // MARK: - Clean sketch geometry

    /// A clean open-headed arrow. New arrows are straight; the editor stores
    /// an explicit signed bend only after the user drags the middle handle.
    private static func addSketchArrow(
        _ shape: MarkupShape, strokeWidth: CGFloat,
        to path: CGMutablePath
    ) {
        let start = shape.start
        let end = shape.end
        let delta = CGVector(dx: end.x - start.x, dy: end.y - start.y)
        let length = hypot(delta.dx, delta.dy)
        guard length > 0.001 else {
            path.move(to: start)
            path.addLine(to: end)
            return
        }

        let control = shape.arrowControlPoint

        path.move(to: start)
        if abs(shape.arrowBend) < 0.001 {
            path.addLine(to: end)
        } else {
            path.addQuadCurve(to: end, control: control)
        }

        // Aim the open head along the curve's end tangent rather than the
        // straight start/end vector, which keeps the gesture feeling fluid.
        let tangent = CGVector(dx: end.x - control.x, dy: end.y - control.y)
        let tangentLength = max(hypot(tangent.dx, tangent.dy), 0.001)
        let backwards = CGVector(dx: -tangent.dx / tangentLength,
                                 dy: -tangent.dy / tangentLength)
        let side = CGVector(dx: -backwards.dy, dy: backwards.dx)
        let headLengthFraction: CGFloat = 0.34  // head length vs. shaft length
        let headWidthRatio: CGFloat = 0.56      // barb spread vs. head length
        let headLength = min(max(strokeWidth * 5, 12), max(1, length * headLengthFraction))
        let headWidth = headLength * headWidthRatio
        let firstBarb = CGPoint(
            x: end.x + backwards.dx * headLength - side.dx * headWidth,
            y: end.y + backwards.dy * headLength - side.dy * headWidth
        )
        let secondBarb = CGPoint(
            x: end.x + backwards.dx * headLength + side.dx * headWidth,
            y: end.y + backwards.dy * headLength + side.dy * headWidth
        )
        path.move(to: firstBarb)
        path.addLine(to: end)
        path.addLine(to: secondBarb)
    }

    /// A nearly elliptical four-curve contour with tiny asymmetries. It reads
    /// as hand drawn at annotation sizes without looking wobbly or unfinished.
    private static func addSketchEllipse(in rect: CGRect, to path: CGMutablePath) {
        guard rect.width > 0.001, rect.height > 0.001 else {
            path.addRect(rect)
            return
        }

        // Fractional nudges that give the contour its hand-drawn asymmetry;
        // the per-curve control multipliers below stay near 1 on purpose.
        let wobbleXFraction: CGFloat = 0.012
        let wobbleYFraction: CGFloat = 0.014
        let handleFraction: CGFloat = 0.276  // Bézier handle length vs. axis
        let xWobble = rect.width * wobbleXFraction
        let yWobble = rect.height * wobbleYFraction
        let top = CGPoint(x: rect.midX + xWobble, y: rect.minY)
        let right = CGPoint(x: rect.maxX, y: rect.midY - yWobble)
        let bottom = CGPoint(x: rect.midX - xWobble * 0.8, y: rect.maxY)
        let left = CGPoint(x: rect.minX, y: rect.midY + yWobble * 0.7)
        let hx = rect.width * handleFraction
        let hy = rect.height * handleFraction

        path.move(to: top)
        path.addCurve(to: right,
                      control1: CGPoint(x: top.x + hx * 1.02, y: top.y),
                      control2: CGPoint(x: right.x, y: right.y - hy * 0.98))
        path.addCurve(to: bottom,
                      control1: CGPoint(x: right.x, y: right.y + hy * 1.03),
                      control2: CGPoint(x: bottom.x + hx * 1.01, y: bottom.y))
        path.addCurve(to: left,
                      control1: CGPoint(x: bottom.x - hx * 0.99, y: bottom.y),
                      control2: CGPoint(x: left.x, y: left.y + hy * 0.97))
        path.addCurve(to: top,
                      control1: CGPoint(x: left.x, y: left.y - hy * 1.02),
                      control2: CGPoint(x: top.x - hx, y: top.y))
        path.closeSubpath()
    }

    /// Soft corners and very shallow edge bows take the mechanical perfection
    /// out of a rectangle while preserving a clean, single-stroke silhouette.
    private static func addSketchRectangle(
        in rect: CGRect, strokeWidth: CGFloat, to path: CGMutablePath
    ) {
        guard rect.width > 0.001, rect.height > 0.001 else {
            path.addRect(rect)
            return
        }

        let cornerFraction: CGFloat = 0.075  // corner radius vs. short side
        let bowFraction: CGFloat = 0.018     // edge bow depth vs. short side
        let shortSide = min(rect.width, rect.height)
        let radius = min(shortSide * cornerFraction, max(strokeWidth * 1.6, 4))
        let bow = min(shortSide * bowFraction, max(strokeWidth * 0.45, 0.75))

        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.minY - bow)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
            control: CGPoint(x: rect.maxX + bow * 0.65, y: rect.midY)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.maxY),
            control: CGPoint(x: rect.midX - bow, y: rect.maxY + bow * 0.8)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + radius),
            control: CGPoint(x: rect.minX - bow * 0.55, y: rect.midY + bow)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
    }

    // MARK: - Text

    /// A legible handwritten face bundled with macOS, with a second core
    /// system face and then the UI font as fallbacks. The editor and exporter
    /// both use this resolved PostScript name so text never shifts on commit.
    public static let resolvedTextFontName: String? = {
        for name in ["Caveat-Regular", "Noteworthy-Bold", "MarkerFelt-Wide"] {
            let font = CTFontCreateWithName(name as CFString, 24, nil)
            if CTFontCopyPostScriptName(font) as String == name { return name }
        }
        return nil
    }()

    public static func annotationFont(size: CGFloat) -> CTFont {
        if let name = resolvedTextFontName {
            return CTFontCreateWithName(name as CFString, size, nil)
        }
        return CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private static func textLine(for shape: MarkupShape) -> CTLine {
        let attributes = [
            kCTFontAttributeName: annotationFont(size: shape.fontSize),
            kCTForegroundColorAttributeName: MarkupPalette.cgColor(shape.colorIndex),
        ] as CFDictionary
        let attributed = CFAttributedStringCreate(nil, shape.text as CFString, attributes)!
        return CTLineCreateWithAttributedString(attributed)
    }

    /// Measured extent and baseline offset of a text shape, in image pixels.
    public static func textMetrics(for shape: MarkupShape) -> (size: CGSize, ascent: CGFloat) {
        guard !shape.text.isEmpty, shape.fontSize > 0 else { return (.zero, 0) }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(textLine(for: shape), &ascent, &descent, &leading)
        return (CGSize(width: CGFloat(width), height: ascent + descent), ascent)
    }

    /// Strokes/draws the shapes into `context`, whose coordinate space must
    /// match the shape model (image pixels, top-left origin, y down).
    public static func draw(_ shapes: [MarkupShape], in context: CGContext) {
        for shape in shapes {
            if shape.tool == .text {
                guard !shape.text.isEmpty else { continue }
                let (_, ascent) = textMetrics(for: shape)
                let center = shape.textCenter
                context.saveGState()
                context.translateBy(x: center.x, y: center.y)
                context.rotate(by: shape.rotationRadians)
                context.translateBy(x: -center.x, y: -center.y)
                // CoreText draws y-up from the baseline; flip locally.
                context.translateBy(x: shape.start.x, y: shape.start.y + ascent)
                context.scaleBy(x: 1, y: -1)
                context.textPosition = .zero
                CTLineDraw(textLine(for: shape), context)
                context.restoreGState()
                continue
            }
            let shapePath = path(for: shape, strokeWidth: shape.lineWidth)
            if shape.tool.supportsFill,
               let fillColorIndex = shape.fillColorIndex {
                context.setFillColor(MarkupPalette.cgColor(fillColorIndex))
                context.addPath(shapePath)
                context.fillPath()
            }
            context.setStrokeColor(MarkupPalette.cgColor(shape.colorIndex))
            context.setLineWidth(shape.lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(shapePath)
            context.strokePath()
        }
    }

    /// Flattens base image + shapes into a new image at the base's pixel size.
    public static func flatten(image: CGImage,
                               shapes: [MarkupShape]) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext is bottom-left origin; the shape model is top-left.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(shapes, in: context)
        return context.makeImage()
    }

    public static func scaled(_ image: CGImage, by scale: CGFloat) -> CGImage? {
        guard scale > 0 else { return nil }
        if abs(scale - 1) < 0.0001 { return image }
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw MarkupRenderError.writeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MarkupRenderError.writeFailed
        }
    }
}
