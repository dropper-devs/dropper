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

    private var cropRect: CGRect?

    private enum Drag {
        case creating(UUID)
        case moving(UUID, last: CGPoint)
        case duplicating(MarkupShape, start: CGPoint)
        case resizing(UUID, MarkupHandle, original: MarkupShape)
        case rotating(UUID, original: MarkupShape, pointerOffset: CGFloat,
                      handleUsesBottom: Bool)
        // Crop reuses the area-selection handle so the two share resize math.
        case creatingCrop(start: CGPoint, previous: CGRect)
        case resizingCrop(AreaResizeHandle, original: CGRect)
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
        textEditor?.textColor = MarkupPalette.nsColor(index)
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
        MarkupPrefs.fontPoints * pixelScale
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
    private var textRotationHandleOffset: CGFloat {
        Self.textRotationHandleOffsetPoints / fitScale
    }

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

    // MARK: - Metrics

    // Selection marquee + resize/rotation knobs.
    private static let marqueeStrokeColor = CGColor(gray: 1, alpha: 0.75)
    private static let marqueeDash: [CGFloat] = [4, 3]
    private static let moveMarqueeInset: CGFloat = 4
    private static let handleSize: CGFloat = 8
    private static let rotationHandleSize: CGFloat = 10
    private static let handleFillColor = CGColor(gray: 1, alpha: 1)
    private static let handleStrokeColor = CGColor(gray: 0, alpha: 0.6)
    private static let rotationHandleColor = CGColor(srgbRed: 0.55, green: 0.61,
                                                     blue: 0.98, alpha: 1)

    // Crop overlay.
    private static let cropDimColor = CGColor(gray: 0, alpha: 0.48)
    private static let cropStrokeColor = CGColor(gray: 1, alpha: 0.9)
    private static let cropDash: [CGFloat] = [5, 3]
    private static let cropHandleSize: CGFloat = 8
    private static let cropHandleFillColor = CGColor(gray: 1, alpha: 1)
    private static let cropHandleStrokeColor = CGColor(gray: 0, alpha: 0.75)
    private static let overlayEdgeInset: CGFloat = 4  // keep chrome inside the fit rect
    private static let cropBadgeHeight: CGFloat = 24
    private static let cropBadgeCornerRadius: CGFloat = 12
    private static let cropBadgeFontSize: CGFloat = 12
    private static let cropBadgeLabelInset: CGFloat = 8   // horizontal text padding
    private static let cropBadgeTopOffset: CGFloat = 8    // below the crop box top
    private static let cropBadgeFillColor = CGColor(gray: 0, alpha: 0.68)
    private static let cropBadgeStrokeColor = CGColor(gray: 1, alpha: 0.16)

    // Interaction distances, in the noted space.
    private static let handleHitTolerancePoints: CGFloat = 8   // image points ÷ fitScale
    private static let duplicateDragThresholdPoints: CGFloat = 4  // image points ÷ fitScale
    private static let exportDragThresholdPoints: CGFloat = 4     // view points
    private static let degenerateSpanPoints: CGFloat = 3         // image pixels
    private static let minimumCropSizePoints: CGFloat = 12       // image points ÷ fitScale

    // Text tuning.
    private static let textRotationHandleOffsetPoints: CGFloat = 24
    private static let textMinimumEdgePoints: CGFloat = 8
    private static let textMinimumScaleFloor: CGFloat = 0.05

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
            drawSelection(shape, in: context)
        }

        if let cropRect {
            drawCropOverlay(cropRect, in: context)
        }
    }

    /// The selected shape's marquee and its resize/rotation knobs.
    private func drawSelection(_ shape: MarkupShape, in context: CGContext) {
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
            drawTextMarquee(shape, rotationHandleUsesBottom: rotationHandleUsesBottom,
                            in: context)
        } else if handles.isEmpty {
            drawMoveOnlyMarquee(shape, in: context)
        }
        drawHandleKnobs(handles, in: context)
    }

    /// A dashed box that follows the text's angle, with a short stem out to the
    /// circular rotation knob; corners remain the only proportional handles.
    private func drawTextMarquee(_ shape: MarkupShape,
                                 rotationHandleUsesBottom: Bool?,
                                 in context: CGContext) {
        let corners = shape.rotatedTextCorners.map(viewPoint)
        guard let first = corners.first else { return }
        let marquee = CGMutablePath()
        marquee.move(to: first)
        for corner in corners.dropFirst() { marquee.addLine(to: corner) }
        marquee.closeSubpath()
        context.saveGState()
        dashedSelectionStroke(marquee, in: context)

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

    /// Pen is move-only, so its full bounds get a light dashed marquee.
    private func drawMoveOnlyMarquee(_ shape: MarkupShape, in context: CGContext) {
        let rect = shape.boundingRect
        let origin = viewPoint(from: CGPoint(x: rect.minX, y: rect.minY))
        let corner = viewPoint(from: CGPoint(x: rect.maxX, y: rect.maxY))
        let box = CGRect(x: origin.x, y: origin.y,
                         width: corner.x - origin.x,
                         height: corner.y - origin.y)
            .insetBy(dx: -Self.moveMarqueeInset, dy: -Self.moveMarqueeInset)
        context.saveGState()
        dashedSelectionStroke(CGPath(rect: box, transform: nil), in: context)
        context.restoreGState()
    }

    private func drawHandleKnobs(
        _ handles: [(handle: MarkupHandle, position: CGPoint)],
        in context: CGContext
    ) {
        for (handle, position) in handles {
            let center = viewPoint(from: position)
            let side = handle == .rotation ? Self.rotationHandleSize : Self.handleSize
            let fill = handle == .rotation ? Self.rotationHandleColor : Self.handleFillColor
            drawHandle(at: center, size: side, fill: fill, in: context)
        }
    }

    /// Configures the shared dashed-selection stroke and strokes `path`,
    /// leaving the stroke color and width set for any follow-on drawing.
    private func dashedSelectionStroke(_ path: CGPath, in context: CGContext) {
        context.setStrokeColor(Self.marqueeStrokeColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: Self.marqueeDash)
        context.addPath(path)
        context.strokePath()
    }

    /// Centered square of side `size` for a handle knob.
    private static func handleRect(center: CGPoint, size: CGFloat) -> CGRect {
        CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    }

    /// A filled, hairline-stroked circular knob used for shape handles.
    private func drawHandle(at center: CGPoint, size: CGFloat, fill: CGColor,
                            in context: CGContext) {
        let knob = Self.handleRect(center: center, size: size)
        context.setFillColor(fill)
        context.setStrokeColor(Self.handleStrokeColor)
        context.setLineWidth(1)
        context.fillEllipse(in: knob)
        context.strokeEllipse(in: knob)
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
        context.setFillColor(Self.cropDimColor)
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(Self.cropStrokeColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: Self.cropDash)
        context.stroke(cropBox)
        context.setLineDash(phase: 0, lengths: [])

        for handle in AreaResizeHandle.allCases {
            var center = viewPoint(from: handle.position(in: rect))
            center.x = min(max(center.x, fitRect.minX + Self.overlayEdgeInset),
                           fitRect.maxX - Self.overlayEdgeInset)
            center.y = min(max(center.y, fitRect.minY + Self.overlayEdgeInset),
                           fitRect.maxY - Self.overlayEdgeInset)
            let knob = Self.handleRect(center: center, size: Self.cropHandleSize)
            context.setFillColor(Self.cropHandleFillColor)
            context.setStrokeColor(Self.cropHandleStrokeColor)
            context.fill(knob)
            context.stroke(knob)
        }

        let pixels = cropPixelRect(rect)
        let label = NSAttributedString(
            string: "\(Int(pixels.width)) × \(Int(pixels.height))",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: Self.cropBadgeFontSize,
                                                   weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
        )
        let labelSize = label.size()
        let badgeSize = CGSize(width: labelSize.width + Self.cropBadgeLabelInset * 2,
                               height: Self.cropBadgeHeight)
        let badgeX = min(max(cropBox.midX - badgeSize.width / 2,
                             fitRect.minX + Self.overlayEdgeInset),
                         fitRect.maxX - badgeSize.width - Self.overlayEdgeInset)
        let badgeY = min(max(cropBox.minY + Self.cropBadgeTopOffset,
                             fitRect.minY + Self.overlayEdgeInset),
                         fitRect.maxY - badgeSize.height - Self.overlayEdgeInset)
        let badge = CGRect(origin: CGPoint(x: badgeX, y: badgeY), size: badgeSize)
        context.addPath(CGPath(roundedRect: badge,
                               cornerWidth: Self.cropBadgeCornerRadius,
                               cornerHeight: Self.cropBadgeCornerRadius, transform: nil))
        context.setFillColor(Self.cropBadgeFillColor)
        context.fillPath()
        context.addPath(CGPath(roundedRect: badge,
                               cornerWidth: Self.cropBadgeCornerRadius,
                               cornerHeight: Self.cropBadgeCornerRadius, transform: nil))
        context.setStrokeColor(Self.cropBadgeStrokeColor)
        context.setLineWidth(1)
        context.strokePath()
        label.draw(at: CGPoint(x: badge.minX + Self.cropBadgeLabelInset,
                               y: badge.midY - labelSize.height / 2))
        context.restoreGState()
    }

    override func resetCursorRects() {
        if let cropRect {
            addCursorRect(bounds, cursor: .crosshair)
            let fullImage = CGRect(origin: .zero, size: imageSize)
            if cropRect != fullImage {
                let origin = viewPoint(from: CGPoint(x: cropRect.minX, y: cropRect.minY))
                let corner = viewPoint(from: CGPoint(x: cropRect.maxX, y: cropRect.maxY))
                let cropBox = CGRect(x: origin.x, y: origin.y,
                                     width: corner.x - origin.x,
                                     height: corner.y - origin.y)
                addCursorRect(cropBox, cursor: .openHand)
                for handle in AreaResizeHandle.allCases {
                    let center = viewPoint(from: handle.position(in: cropRect))
                    addCursorRect(
                        Self.handleRect(center: center,
                                        size: Self.cropHandleSize + 2),
                        cursor: .crosshair)
                }
            }
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
        let tolerance = Self.handleHitTolerancePoints / fitScale

        if let cropRect {
            if let handle = cropHandle(at: point, in: cropRect, tolerance: tolerance) {
                drag = .resizingCrop(handle, original: cropRect)
            } else if cropRect != CGRect(origin: .zero, size: imageSize),
                      cropRect.contains(point) {
                drag = .movingCrop(original: cropRect, start: point)
            } else if fitRect.contains(viewPoint) {
                drag = .creatingCrop(
                    start: MarkupGeometry.clamped(point, to: imageSize),
                    previous: cropRect)
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
            guard hypot(point.x - start.x, point.y - start.y)
                >= Self.duplicateDragThresholdPoints / fitScale else { return }
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
        case .creatingCrop(let start, _):
            let end = MarkupGeometry.clamped(point, to: imageSize)
            cropRect = AreaSelectionGeometry.clamped(
                AreaSelectionGeometry.rect(from: start, to: end),
                in: imageSize)
            needsDisplay = true
        case .resizingCrop(let handle, let original):
            let clamped = MarkupGeometry.clamped(point, to: imageSize)
            cropRect = resizedCrop(original, handle: handle, to: clamped,
                                   symmetric: event.modifierFlags.contains(.option))
            needsDisplay = true
        case .movingCrop(let original, let start):
            cropRect = AreaSelectionGeometry.moved(
                original,
                by: CGSize(width: point.x - start.x, height: point.y - start.y),
                in: imageSize)
            needsDisplay = true
        case .exportingImage(let start):
            guard hypot(viewPoint.x - start.x, viewPoint.y - start.y)
                >= Self.exportDragThresholdPoints else { return }
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
            if span < Self.degenerateSpanPoints {
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
        if case .resizing(let id, _, let original) = drag,
           original.tool == .text,
           let shape = shapes.first(where: { $0.id == id }),
           shape.fontSize != original.fontSize {
            MarkupPrefs.fontPoints = shape.fontSize / pixelScale
        }
        if case .creatingCrop(_, let previous) = drag,
           let cropRect {
            let minimum = max(Self.minimumCropSizePoints / fitScale, 1)
            if cropRect.width < minimum || cropRect.height < minimum {
                self.cropRect = previous
                needsDisplay = true
            }
        }
        switch drag {
        case .creatingCrop, .resizingCrop, .movingCrop:
            window?.invalidateCursorRects(for: self)
        default:
            break
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

    private func cropHandle(at point: CGPoint, in rect: CGRect,
                            tolerance: CGFloat) -> AreaResizeHandle? {
        AreaResizeHandle.allCases.first {
            let position = $0.position(in: rect)
            return hypot(position.x - point.x, position.y - point.y) <= tolerance
        }
    }

    /// Resizes the crop. The plain drag reuses the shared area-selection resize
    /// (opposite edge fixed); the option-key symmetric drag grows the crop
    /// about its center and stays unique to cropping. `point` is pre-clamped to
    /// the image, so both paths land pixel-for-pixel on the old behavior.
    private func resizedCrop(_ original: CGRect, handle: AreaResizeHandle,
                             to point: CGPoint, symmetric: Bool) -> CGRect {
        let minimum = max(Self.minimumCropSizePoints / fitScale, 1)

        guard symmetric else {
            let anchor = handle.position(in: original)
            let translation = CGSize(width: point.x - anchor.x,
                                     height: point.y - anchor.y)
            return AreaSelectionGeometry.resized(
                original, handle: handle, by: translation, in: imageSize,
                minimumSize: CGSize(width: minimum, height: minimum))
        }

        var minX = original.minX, maxX = original.maxX
        var minY = original.minY, maxY = original.maxY
        if handle.adjustsLeft || handle.adjustsRight {
            let center = original.midX
            let distance = handle.adjustsLeft ? center - point.x : point.x - center
            var half = max(distance, minimum / 2)
            half = min(half, min(center, imageSize.width - center))
            minX = center - half
            maxX = center + half
        }
        if handle.adjustsTop || handle.adjustsBottom {
            let center = original.midY
            let distance = handle.adjustsTop ? center - point.y : point.y - center
            var half = max(distance, minimum / 2)
            half = min(half, min(center, imageSize.height - center))
            minY = center - half
            maxY = center + half
        }

        minX = min(max(minX, 0), imageSize.width)
        maxX = min(max(maxX, 0), imageSize.width)
        minY = min(max(minY, 0), imageSize.height)
        maxY = min(max(maxY, 0), imageSize.height)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Maps a text marquee corner to its fixed anchor corner, the dragged
    /// corner opposite it, and the sign of the half-extent offset used to
    /// recenter the box after scaling. Indices are into `rotatedTextCorners`.
    private struct TextResizeCorner {
        let anchorIndex: Int
        let oppositeIndex: Int
        let halfSignX: CGFloat
        let halfSignY: CGFloat
    }

    private static func textResizeCorner(for handle: MarkupHandle) -> TextResizeCorner? {
        switch handle {
        case .topLeft:
            TextResizeCorner(anchorIndex: 2, oppositeIndex: 0, halfSignX: 1, halfSignY: 1)
        case .topRight:
            TextResizeCorner(anchorIndex: 3, oppositeIndex: 1, halfSignX: -1, halfSignY: 1)
        case .bottomLeft:
            TextResizeCorner(anchorIndex: 1, oppositeIndex: 3, halfSignX: 1, halfSignY: -1)
        case .bottomRight:
            TextResizeCorner(anchorIndex: 0, oppositeIndex: 2, halfSignX: -1, halfSignY: -1)
        case .start, .end, .curve, .rotation:
            nil
        }
    }

    /// Largest proportional scale that keeps every rotated corner inside the
    /// image. Each corner is `anchor + scale * vector`, so each edge a corner
    /// would cross contributes a single upper bound.
    private func maximumTextScale(anchor: CGPoint, corners: [CGPoint]) -> CGFloat {
        let epsilon: CGFloat = 0.0001
        var maximumScale = CGFloat.greatestFiniteMagnitude
        for corner in corners {
            let vector = CGVector(dx: corner.x - anchor.x, dy: corner.y - anchor.y)
            if vector.dx > epsilon {
                maximumScale = min(maximumScale, (imageSize.width - anchor.x) / vector.dx)
            } else if vector.dx < -epsilon {
                maximumScale = min(maximumScale, (0 - anchor.x) / vector.dx)
            }
            if vector.dy > epsilon {
                maximumScale = min(maximumScale, (imageSize.height - anchor.y) / vector.dy)
            } else if vector.dy < -epsilon {
                maximumScale = min(maximumScale, (0 - anchor.y) / vector.dy)
            }
        }
        return maximumScale
    }

    /// Scales text from a corner without changing its aspect ratio. The
    /// opposite displayed corner remains fixed even after rotation, matching
    /// image-editor marquee behavior.
    private func resizeText(_ id: UUID, original: MarkupShape,
                            handle: MarkupHandle, to point: CGPoint) {
        let rect = original.unrotatedTextRect
        guard rect.width > 0, rect.height > 0, original.fontSize > 0 else { return }
        let corners = original.rotatedTextCorners
        guard corners.count == 4,
              let mapping = Self.textResizeCorner(for: handle) else { return }
        let anchor = corners[mapping.anchorIndex]
        let originalCorner = corners[mapping.oppositeIndex]

        let base = CGVector(dx: originalCorner.x - anchor.x,
                            dy: originalCorner.y - anchor.y)
        let current = CGVector(dx: point.x - anchor.x, dy: point.y - anchor.y)
        let baseLengthSquared = base.dx * base.dx + base.dy * base.dy
        guard baseLengthSquared > 0 else { return }

        var scale = (current.dx * base.dx + current.dy * base.dy) / baseLengthSquared
        let minimumScale = max(Self.textMinimumEdgePoints * pixelScale / original.fontSize,
                               Self.textMinimumScaleFloor)

        let upperScale = max(0, maximumTextScale(anchor: anchor, corners: corners))
        guard upperScale > 0 else { return }
        let lowerScale = min(minimumScale, upperScale)
        scale = min(max(scale, lowerScale), upperScale)

        update(id) { shape in
            shape.fontSize = original.fontSize * scale
            shape.rotationRadians = original.rotationRadians
            let size = MarkupRender.textMetrics(for: shape).size
            let half = CGVector(dx: size.width / 2, dy: size.height / 2)
            let anchorOffset = CGVector(dx: mapping.halfSignX * half.dx,
                                        dy: mapping.halfSignY * half.dy)
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
        field.textColor = MarkupPalette.nsColor(shape.colorIndex)
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
