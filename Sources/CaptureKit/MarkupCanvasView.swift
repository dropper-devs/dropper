import AppKit

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
           shapes[position].tool.supportsFill {
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
                                fillColorIndex: tool.supportsFill
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
            case KeyCode.returnKey, KeyCode.keypadEnter:
                onApplyCrop?()
            case KeyCode.escape:
                onCancelCrop?()
            default:
                super.keyDown(with: event)
            }
            return
        }

        switch event.keyCode {
        case KeyCode.delete, KeyCode.forwardDelete:
            if let selectedID {
                shapes.removeAll { $0.id == selectedID }
                self.selectedID = nil
                needsDisplay = true
            }
        case KeyCode.escape:
            selectedID = nil
            needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }
}
