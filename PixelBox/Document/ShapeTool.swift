import AppKit

nonisolated enum ShapeKind: String, CaseIterable, Codable, Sendable {
    case rectangle = "Rectangle"
    case ellipse = "Ellipse"
    case triangle = "Triangle"
    case polygon = "Polygon"
    case star = "Star"
    case line = "Line"
    case custom = "Custom Shape"

    /// The kinds a project could hold before version 16.
    var predatesVersion16: Bool { self == .rectangle || self == .ellipse || self == .line }
    /// Polygons and stars take a number of sides (a star's points).
    var takesSides: Bool { self == .polygon || self == .star }
    /// Kinds with straight corners that a radius rounds.
    var takesCornerRadius: Bool { self == .rectangle || self == .triangle || self == .polygon || self == .star }
    var symbol: String {
        switch self {
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .triangle: "triangle"
        case .polygon: "hexagon"
        case .star: "star"
        case .line: "line.diagonal"
        case .custom: "pawprint"
        }
    }
    /// The name in the tool rail's flyout.
    var toolName: String { self == .custom ? "Custom Shape Tool" : "\(rawValue) Tool" }

    /// The shape filling `rect`. Corners round by `cornerRadius`, at most what each corner has room for (so a large
    /// radius makes a pill); ellipses ignore it. Polygons and stars have `sides` points, starting at the top, stretched
    /// to fill the box. A custom shape draws `outline`. A line runs corner to corner and is stroked, not filled
    /// (see `linePath`).
    func path(in rect: CGRect, cornerRadius: CGFloat = 0, smoothing: Bool = false, sides: Int = 5,
              outline: ShapeOutline? = nil) -> CGPath {
        switch self {
        case .ellipse: return CGPath(ellipseIn: rect, transform: nil)
        case .triangle:
            return Self.roundedPolygon([CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
                                        CGPoint(x: rect.minX, y: rect.maxY)], radius: cornerRadius)
        case .polygon, .star:
            let count = min(ShapeLimits.sides.upperBound, max(ShapeLimits.sides.lowerBound, sides))
            let corners = self == .star ? count * 2 : count
            let unit = (0..<corners).map { index in
                let angle = -CGFloat.pi / 2 + CGFloat(index) * 2 * .pi / CGFloat(corners)
                let reach: CGFloat = self == .star && index % 2 == 1 ? ShapeLimits.starInnerRadius : 1
                return CGPoint(x: cos(angle) * reach, y: sin(angle) * reach)
            }
            return Self.roundedPolygon(Self.fitted(unit, in: rect), radius: cornerRadius)
        case .custom:
            return outline?.path(in: rect) ?? CGMutablePath()
        case .rectangle, .line:
            let radius = min(max(0, cornerRadius), rect.width / 2, rect.height / 2)
            guard radius > 0 else { return CGPath(rect: rect, transform: nil) }
            if self == .rectangle, smoothing {
                return smoothedRectangle(in: rect, radius: radius)
            }
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
    }

    /// `points` stretched so their box is `rect`.
    private static func fitted(_ points: [CGPoint], in rect: CGRect) -> [CGPoint] {
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        let width = max((xs.max() ?? 1) - minX, .ulpOfOne), height = max((ys.max() ?? 1) - minY, .ulpOfOne)
        return points.map { CGPoint(x: rect.minX + ($0.x - minX) / width * rect.width,
                                    y: rect.minY + ($0.y - minY) / height * rect.height) }
    }

    /// A closed outline through `points`, each corner rounded by `radius` or as much as its two sides leave room for.
    private static func roundedPolygon(_ points: [CGPoint], radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard radius > 0, points.count >= 3 else {
            path.addLines(between: points)
            path.closeSubpath()
            return path
        }
        let count = points.count
        func middle(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: middle(points[count - 1], points[0]))
        for index in 0..<count {
            let corner = points[index], before = points[(index + count - 1) % count], after = points[(index + 1) % count]
            let toBefore = hypot(before.x - corner.x, before.y - corner.y), toAfter = hypot(after.x - corner.x, after.y - corner.y)
            guard toBefore > 0, toAfter > 0 else { path.addLine(to: corner); continue }
            let cosine = ((before.x - corner.x) * (after.x - corner.x) + (before.y - corner.y) * (after.y - corner.y)) / (toBefore * toAfter)
            let half = acos(min(1, max(-1, cosine))) / 2
            // The arc meets each side this far from the corner; it may use at most half of the shorter side.
            let room = min(toBefore, toAfter) / 2 * tan(half)
            let fitted = min(radius, room)
            if fitted > 0.01 { path.addArc(tangent1End: corner, tangent2End: after, radius: fitted) }
            else { path.addLine(to: corner) }
        }
        path.closeSubpath()
        return path
    }

    /// Figma's cubic–arc–cubic corner construction at 60% smoothing (the iOS squircle match).
    /// https://www.figma.com/blog/desperately-seeking-squircles/
    /// Back off smoothing when the corners run out of room, keeping the requested radius.
    private func smoothedRectangle(in rect: CGRect, radius: CGFloat) -> CGPath {
        let smoothing = min(CGFloat(0.6), max(0, min(rect.width, rect.height) / (2 * radius) - 1))
        guard smoothing > 0 else {
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        let reach = (1 + smoothing) * radius
        let angle = smoothing * .pi / 4
        let tangent = radius * tan(angle / 2)
        let c = tangent * cos(angle)
        let d = tangent * sin(angle)
        let arcLength = radius * sqrt(2) * sin((1 - smoothing) * .pi / 4)
        let b = (reach - arcLength - c - d) / 3
        let a = 2 * b
        let path = CGMutablePath()
        let corners = [CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY)]
        for (index, corner) in corners.enumerated() {
            let rotation = CGFloat(index) * .pi / 2
            let transform = CGAffineTransform(translationX: corner.x, y: corner.y).rotated(by: rotation)
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(transform) }
            let start = point(-reach, 0)
            if index == 0 { path.move(to: start) } else { path.addLine(to: start) }
            path.addCurve(to: point(-reach + a + b + c, d),
                          control1: point(-reach + a, 0), control2: point(-reach + a + b, 0))
            path.addArc(center: CGPoint(x: -radius, y: radius), radius: radius,
                        startAngle: -.pi / 2 + angle, endAngle: -angle, clockwise: false, transform: transform)
            path.addCurve(to: point(0, reach), control1: point(0, reach - a - b), control2: point(0, reach - a))
        }
        path.closeSubpath()
        return path
    }
}

nonisolated enum ShapeLimits {
    static let sides = 3...100
    static let strokeWidth: ClosedRange<CGFloat> = 0...1000
    /// A star's inner points sit at half the reach of its outer ones, Photoshop's default indent.
    static let starInnerRadius: CGFloat = 0.5
    /// How far a mitered corner may reach out, in stroke widths, before it is beveled instead.
    static let miterLimit: CGFloat = 4
}

/// What the Shape tool makes: a shape layer, a work path to make a selection from, or pixels on the active layer.
nonisolated enum ShapeMode: String, CaseIterable, Sendable {
    case shape = "Shape"
    case path = "Path"
    case pixels = "Pixels"
}

nonisolated enum ShapeDash: String, CaseIterable, Codable, Sendable {
    case solid = "Solid"
    case dashed = "Dashed"
    case wideDashed = "Wide Dashed"
    case dots = "Short Dots"
    /// Dash and gap lengths, in stroke widths.
    var lengths: [CGFloat] {
        switch self {
        case .solid: []
        case .dashed: [4, 2]
        case .wideDashed: [8, 4]
        // A dash too short to see, which a round cap makes a dot.
        case .dots: [0.01, 2]
        }
    }
}

nonisolated enum ShapeCap: String, CaseIterable, Codable, Sendable {
    case butt = "Butt", round = "Round", square = "Square"
    var lineCap: CGLineCap { self == .butt ? .butt : self == .round ? .round : .square }
}

nonisolated enum ShapeJoin: String, CaseIterable, Codable, Sendable {
    case miter = "Miter", round = "Round", bevel = "Bevel"
    var lineJoin: CGLineJoin { self == .miter ? .miter : self == .round ? .round : .bevel }
}

/// How a stroke or a line is drawn along its path.
nonisolated struct ShapeStrokeOptions: Codable, Equatable, Sendable {
    var dash = ShapeDash.solid
    var cap = ShapeCap.butt
    var join = ShapeJoin.miter
    /// Dots need round ends to be dots at all.
    var drawnCap: ShapeCap { dash == .dots ? .round : cap }

    func apply(width: CGFloat, to context: CGContext) {
        context.setLineWidth(width)
        context.setLineCap(drawnCap.lineCap)
        context.setLineJoin(join.lineJoin)
        context.setMiterLimit(ShapeLimits.miterLimit)
        if dash != .solid { context.setLineDash(phase: 0, lengths: dash.lengths.map { $0 * width }) }
    }
}

/// A stroke centered on a shape's outline.
nonisolated struct ShapeStroke: Codable, Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    /// Document pixels, whatever size the shape is scaled to.
    var width: CGFloat
    var options = ShapeStrokeOptions()
    var color: PaletteColor { PaletteColor(red: red, green: green, blue: blue) }
    init(color: PaletteColor, width: CGFloat, options: ShapeStrokeOptions = ShapeStrokeOptions()) {
        red = color.red; green = color.green; blue = color.blue
        self.width = width; self.options = options
    }
}

/// What a shape layer draws, kept so the shape can be drawn again at a new size.
nonisolated struct LayerShapeStyle: Codable, Equatable, Sendable {
    var kind: ShapeKind
    /// The fill, or a line's color.
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    /// Document pixels, whatever size the shape is scaled to.
    var cornerRadius: CGFloat
    /// Nil in older projects means ordinary circular corners. True uses 60% smoothing.
    var smoothing: Bool? = nil
    /// A line's thickness, and its two ends as fractions of the layer's box (0–1), so the line lands on exactly the
    /// points it was dragged between and still redraws correctly at another size. Nil on other shapes.
    var lineWidth: CGFloat? = nil
    var start: CGPoint? = nil
    var end: CGPoint? = nil
    // Version 16 and later.
    /// False when the shape has no fill, only a stroke. Nil is filled.
    var filled: Bool? = nil
    var stroke: ShapeStroke? = nil
    /// A line's dashes and ends. Nil, as lines were before, is solid with round ends.
    var lineOptions: ShapeStrokeOptions? = nil
    /// A polygon's sides, or a star's points.
    var sides: Int? = nil
    /// A custom shape's outline, and the name it had in the shape library.
    var outline: ShapeOutline? = nil
    var customName: String? = nil

    var color: PaletteColor { PaletteColor(red: red, green: green, blue: blue) }
    var isFilled: Bool { filled != false }
    /// The fields version 16 added.
    var needsVersion16: Bool {
        !kind.predatesVersion16 || filled != nil || stroke != nil || lineOptions != nil || sides != nil || outline != nil || customName != nil
    }
    var isValid: Bool {
        func unit(_ value: CGFloat) -> Bool { value.isFinite && (0...1).contains(value) }
        guard unit(red), unit(green), unit(blue), cornerRadius.isFinite, cornerRadius >= 0 else { return false }
        if let stroke {
            guard unit(stroke.red), unit(stroke.green), unit(stroke.blue), stroke.width.isFinite,
                  ShapeLimits.strokeWidth.contains(stroke.width) else { return false }
        }
        if let sides, !ShapeLimits.sides.contains(sides) { return false }
        if let outline, !outline.isValid { return false }
        if kind == .custom, outline == nil { return false }
        if let customName, customName.count > 256 { return false }
        return true
    }

    /// The outline filling `rect`, the shape's own box inside the layer.
    func outline(in rect: CGRect) -> CGPath {
        kind.path(in: rect, cornerRadius: cornerRadius, smoothing: smoothing == true, sides: sides ?? 5, outline: outline)
    }

    /// Custom shapes are drawn as Photoshop made them, with holes where their parts overlap.
    var fillRule: CGPathFillRule { kind == .custom ? .evenOdd : .winding }

    /// How far the shape's stroke, or a line's ends, reach past its outline: the room the layer leaves around it.
    var reach: CGFloat {
        if kind == .line {
            let options = lineOptions ?? ShapeStrokeOptions(cap: .round)
            return (lineWidth ?? 0) / 2 * (options.drawnCap == .square ? sqrt(2) : 1)
        }
        guard let stroke, stroke.width > 0 else { return 0 }
        let half = stroke.width / 2
        guard stroke.options.join == .miter, kind != .ellipse, !(kind == .rectangle && cornerRadius > 0) else {
            return ceil(half * (stroke.options.drawnCap == .square ? sqrt(2) : 1))
        }
        // A rectangle's square corners reach out along their diagonal; sharper ones as far as the miter limit allows.
        return ceil(half * (kind == .rectangle ? sqrt(2) : ShapeLimits.miterLimit))
    }

    /// Fills, then strokes, the shape filling `rect`, in whatever coordinates `context` is set up for.
    func draw(in rect: CGRect, context: CGContext) {
        let path = outline(in: rect)
        context.saveGState()
        if isFilled {
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
            context.addPath(path)
            context.fillPath(using: fillRule)
        }
        if let stroke, stroke.width > 0 {
            context.setStrokeColor(CGColor(srgbRed: stroke.red, green: stroke.green, blue: stroke.blue, alpha: 1))
            stroke.options.apply(width: stroke.width, to: context)
            context.addPath(path)
            context.strokePath()
        }
        context.restoreGState()
    }

    /// Draws a line between two points, in whatever coordinates `context` is set up for.
    func drawLine(from start: CGPoint, to end: CGPoint, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        (lineOptions ?? ShapeStrokeOptions(cap: .round)).apply(width: max(1, lineWidth ?? 1), to: context)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.restoreGState()
    }
}

/// A shape layer made with the Shape tool. Its pixels are an ordinary raster, so it clips, masks, blends and filters like
/// any layer; `image` is the raster the shape drew. Once anything else changes those pixels (painting, a filter),
/// the layer's image is no longer this one and the layer is plain pixels from then on.
nonisolated struct LayerShape: Equatable, @unchecked Sendable {
    var style: LayerShapeStyle
    let image: CGImage
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.style == rhs.style && lhs.image === rhs.image }
    static func loaded(_ style: LayerShapeStyle?, image: CGImage?) -> LayerShape? {
        guard let style, let image else { return nil }
        return LayerShape(style: style, image: image)
    }
}

extension ImageLayer {
    /// The shape this layer still is: nil once its pixels were edited some other way.
    var liveShape: LayerShape? {
        guard let shape, let image = asset?.image, image === shape.image else { return nil }
        return shape
    }
}

/// A shape being dragged out with the Shape tool, in whole document pixels.
struct ShapeDraft: Equatable {
    /// Everything about the shape but its size, fixed when the drag starts.
    let style: LayerShapeStyle
    let mode: ShapeMode
    let anchor: CGPoint
    var rect: CGRect
    /// Where a line is being dragged to, so its ends stay exactly where they were put.
    var end: CGPoint? = nil
    var kind: ShapeKind { style.kind }
    var cornerRadius: CGFloat { style.cornerRadius }
    var smoothing: Bool { style.smoothing == true }
}

extension EditorSession {
    /// Pixels one shape layer may hold, the same budget as an import.
    nonisolated static let maxShapePixels = DocumentLimits.maxSurfacePixels

    /// The shape the tool bar's settings describe, at no size yet. In Pixels mode on a mask it paints in the mask's
    /// black or white.
    var shapeStyle: LayerShapeStyle {
        let color = shapeMode == .pixels ? paletteColor(background: false) : foregroundColor
        var style = LayerShapeStyle(kind: shapeKind, red: color.red, green: color.green, blue: color.blue,
                                    cornerRadius: shapeKind.takesCornerRadius ? CGFloat(shapeCornerRadius) : 0,
                                    smoothing: shapeKind == .rectangle && shapeSmoothing ? true : nil)
        switch shapeKind {
        case .line:
            style.lineWidth = CGFloat(shapeLineWidth)
            style.lineOptions = shapeStrokeOptions
        case .polygon, .star: style.sides = shapeSides
        case .custom:
            style.outline = customShape?.outline
            style.customName = customShape?.name
        default: break
        }
        if shapeKind != .line {
            if !shapeFilled { style.filled = false }
            if shapeStrokeEnabled, shapeStrokeWidth > 0 {
                style.stroke = ShapeStroke(color: shapeStrokeColor, width: CGFloat(shapeStrokeWidth), options: shapeStrokeOptions)
            }
        }
        return style
    }

    func beginShape(at point: CGPoint) {
        guard tool == .shape, canEditLayers, point.x.isFinite, point.y.isFinite else { return }
        if shapeKind == .custom, customShape == nil {
            brushError = "Choose a custom shape in the tool bar first."
            return
        }
        let anchor = CGPoint(x: point.x.rounded(), y: point.y.rounded())
        shapeDraft = ShapeDraft(style: shapeStyle, mode: shapeMode, anchor: anchor, rect: CGRect(origin: anchor, size: .zero))
    }

    /// The line being dragged, from where it began to where the pointer is, in document pixels.
    var shapeLineEnds: (start: CGPoint, end: CGPoint)? {
        guard let draft = shapeDraft, draft.kind == .line, let end = draft.end else { return nil }
        return (draft.anchor, end)
    }

    /// Shift makes a square or circle (a custom shape keeps its own proportions); Option grows the shape from its
    /// center, as in Photoshop.
    func dragShape(to point: CGPoint, square: Bool, fromCenter: Bool) {
        guard var draft = shapeDraft, point.x.isFinite, point.y.isFinite else { return }
        // Shift on a line snaps its angle to eighths of a turn — flat, upright, or 45° — rather than squaring a box.
        if draft.kind == .line, square {
            let dx = point.x - draft.anchor.x, dy = point.y - draft.anchor.y
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            let snapped = CGPoint(x: draft.anchor.x + cos(angle) * length, y: draft.anchor.y + sin(angle) * length)
            draft.end = snapped
            draft.rect = DragBox.rect(from: draft.anchor, to: snapped, square: false, fromCenter: fromCenter)
            shapeDraft = draft
            return
        }
        if draft.kind == .line { draft.end = point }
        if square, let aspect = draft.style.outline?.aspect, draft.kind == .custom {
            draft.rect = DragBox.rect(from: draft.anchor, to: point, aspect: aspect, fromCenter: fromCenter)
        } else {
            draft.rect = DragBox.rect(from: draft.anchor, to: point, square: square, fromCenter: fromCenter)
        }
        shapeDraft = draft
    }

    func cancelShape() {
        if shapeDraft != nil { shapeDraft = nil }
    }

    /// Shift-U (and Tab): the Shape tool steps through its shapes, in the order of the tool rail's flyout.
    func toggleShapeKind() {
        cancelShape()
        let kinds = ShapeKind.allCases
        shapeKind = kinds[((kinds.firstIndex(of: shapeKind) ?? 0) + 1) % kinds.count]
    }

    /// Ends the drag. In Shape mode the shape goes on a new layer above the active one; in Pixels mode it is painted
    /// into the active layer; in Path mode it becomes the work path. A click without a drag makes nothing, and the
    /// selection is left alone.
    func finishShape() {
        guard let draft = shapeDraft else { return }
        shapeDraft = nil
        var style = draft.style
        var rect = draft.rect
        // A line keeps the two points it was dragged between; the layer is their box with room for the stroke's own
        // thickness (and its ends) around them.
        var ends: (start: CGPoint, end: CGPoint)?
        if draft.kind == .line {
            let from = draft.anchor, to = draft.end ?? draft.anchor
            rect = CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
            ends = (from, to)
            guard rect.width >= 1 || rect.height >= 1 else { return }
        } else {
            guard rect.width >= 1, rect.height >= 1 else { return }
        }
        guard canEditLayers, document != nil else { return }
        switch draft.mode {
        case .path:
            if let ends {
                let path = CGMutablePath()
                path.move(to: ends.start)
                path.addLine(to: ends.end)
                workPath = path
            } else {
                workPath = style.outline(in: rect)
            }
        case .pixels:
            guard style.isFilled || style.stroke != nil || draft.kind == .line else { return }
            Task { await paintShape(style, in: rect, ends: ends) }
        case .shape:
            guard style.isFilled || style.stroke != nil || draft.kind == .line else {
                brushError = "That shape has no fill and no stroke. Turn one of them on in the tool bar."
                return
            }
            rect = rect.insetBy(dx: -style.reach, dy: -style.reach)
            guard Int(rect.width) * Int(rect.height) <= Self.maxShapePixels else {
                brushError = "That shape is too large. A shape can cover up to \(DocumentLimits.maxSurfaceMegapixels) megapixels."
                return
            }
            // The ends as fractions of the box, so a scaled line still runs between the same two places.
            func unit(_ point: CGPoint) -> CGPoint {
                CGPoint(x: rect.width > 0 ? (point.x - rect.minX) / rect.width : 0.5,
                        y: rect.height > 0 ? (point.y - rect.minY) / rect.height : 0.5)
            }
            style.start = ends.map { unit($0.start) }
            style.end = ends.map { unit($0.end) }
            do {
                let image = try Self.shapeImage(style, size: rect.size)
                let name = style.customName ?? draft.kind.rawValue
                addPixelLayer(image, at: rect.origin, name: nextShapeName(name), editName: name,
                              dropsSelection: false, shape: LayerShape(style: style, image: image))
            } catch { brushError = error.localizedDescription }
        }
    }

    /// Pixels mode: the shape painted into the active layer (or its mask), inside the selection, as one undo step.
    private func paintShape(_ style: LayerShapeStyle, in rect: CGRect, ends: (start: CGPoint, end: CGPoint)?) async {
        guard canEditPixels, let layer = activeLayer else {
            brushError = "Select a pixel layer to draw the shape on, or switch the Shape tool to Shape."
            return
        }
        let area = rect.insetBy(dx: -style.reach - 1, dy: -style.reach - 1)
        await applyPixelEdit(to: layer, name: style.customName ?? style.kind.rawValue) { edit in
            try edit.paint(in: area) { context in
                if let ends { style.drawLine(from: ends.start, to: ends.end, context: context) }
                else { style.draw(in: rect, context: context) }
            }
        }
    }

    /// Opens the app's picker on the stroke color; choosing one turns the stroke on.
    func openStrokeColorPicker() {
        guard canEditPalette, colorPicker == nil else { return }
        colorPicker = ColorPickerState(target: .shapeStroke, original: shapeBarLayer?.liveShape?.style.stroke?.color ?? shapeStrokeColor)
    }

    /// The fill swatch: with a shape layer selected, its own fill color; otherwise the foreground color new shapes use.
    func openFillColorPicker() {
        guard let style = shapeBarLayer?.liveShape?.style else { openColorPicker(background: false); return }
        guard canEditPalette, colorPicker == nil else { return }
        colorPicker = ColorPickerState(target: .shapeFill, original: style.color)
    }

    /// The shape layer the Shape tool's bar edits, as in Photoshop: the selected layer while it's still a shape, with
    /// the Shape or Path Selection tool in hand and nothing being drawn.
    var shapeBarLayer: ImageLayer? {
        guard tool == .shape || tool == .pathSelection, shapeDraft == nil, pathDrag == nil else { return nil }
        return pathLayer
    }

    /// Changes the selected shape layer's style and draws it again, keeping its outline where it is: a stroke that
    /// reaches further grows the layer around it. Changing the same value again straight away (dragging it, typing it)
    /// adds to the same undo step.
    func restyleShape(_ name: String, _ change: (inout LayerShapeStyle) -> Void) {
        guard canEditLayers, let layer = shapeBarLayer, let shape = layer.liveShape,
              let index = document?.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        var style = shape.style
        change(&style)
        guard style != shape.style, style.isValid,
              let placed = Self.restyled(from: shape.style, to: &style, transform: layer.transform) else { return }
        let size = CGSize(width: max(1, placed.size.width.rounded()), height: max(1, placed.size.height.rounded()))
        guard Int(size.width) * Int(size.height) <= Self.maxShapePixels,
              let image = try? Self.shapeImage(style, size: size), let thumbnail = try? PixelInvert.thumbnail(of: image),
              let asset = layer.asset else { return }
        let continuing = lastShapeRestyle.map { $0.layerID == layer.id && $0.name == name && Date().timeIntervalSince($0.time) < 1.5 } == true
            && history.canAmendLast(name)
        if !continuing { beginEdit(name) }
        if let mask = layer.mask, mask.placement == nil { document?.layers[index].mask?.placement = layer.maskTransform }
        document?.layers[index].transform = placed
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        document?.layers[index].shape = LayerShape(style: style, image: image)
        if continuing { history.amendLast(document: document, selection: activeLayerID) } else { endEdit() }
        lastShapeRestyle = (layer.id, name, Date())
    }

    /// The placement that keeps a shape's outline where it is once its style reaches further, or less far, past it.
    /// A line's ends, fractions of its layer's box, are moved into the new box.
    nonisolated static func restyled(from old: LayerShapeStyle, to new: inout LayerShapeStyle, transform: LayerTransform) -> LayerTransform? {
        let width = transform.size.width, height = transform.size.height
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        // As `shapeImage` insets it: a line runs between its ends, any other shape fills the box less its reach.
        let inset = old.kind == .line ? old.reach : max(0, min(old.reach, (width - 1) / 2, (height - 1) / 2))
        let shapeBox = bounds.insetBy(dx: inset, dy: inset)
        let layerBox = shapeBox.insetBy(dx: -new.reach, dy: -new.reach)
        guard layerBox.width >= 1, layerBox.height >= 1 else { return nil }
        guard layerBox != bounds else { return transform }
        if new.kind == .line {
            func moved(_ point: CGPoint?) -> CGPoint? {
                point.map { CGPoint(x: ($0.x * width - layerBox.minX) / layerBox.width, y: ($0.y * height - layerBox.minY) / layerBox.height) }
            }
            new.start = moved(new.start)
            new.end = moved(new.end)
        }
        let unitBox = CGRect(x: layerBox.minX / width, y: layerBox.minY / height, width: layerBox.width / width, height: layerBox.height / height)
        var placed = transform.placing(CGAffineTransform(a: unitBox.width, b: 0, c: 0, d: unitBox.height, tx: unitBox.minX, ty: unitBox.minY)
            .concatenating(transform.unitToDocument))
        placed.size = layerBox.size
        return placed.isValid ? placed : nil
    }

    /// Path mode: the work path becomes the selection, replacing it.
    func makeSelectionFromWorkPath() {
        guard let workPath, !workPath.boundingBoxOfPath.isEmpty else { return }
        applySelection(workPath, mode: .replace, name: "Make Selection")
    }

    func clearWorkPath() {
        if workPath != nil { workPath = nil }
    }

    /// "Rectangle 1", "Tiger 2", … skipping names already in the document.
    func nextShapeName(_ base: String) -> String {
        let names = Set(document?.layers.map(\.name) ?? [])
        var number = 1
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    func nextShapeName(_ kind: ShapeKind) -> String { nextShapeName(kind.rawValue) }

    /// A shape layer scaled to a new size draws its shape again at that size, so a rounded corner keeps its radius
    /// and a stroke its width instead of stretching. Part of the edit that changed the size.
    func redrawShape(at index: Int) {
        guard let layer = document?.layers[index], let shape = layer.liveShape, let asset = layer.asset else { return }
        let width = max(1, Int(layer.transform.size.width.rounded())), height = max(1, Int(layer.transform.size.height.rounded()))
        guard width != asset.image.width || height != asset.image.height, width * height <= Self.maxShapePixels,
              let image = try? Self.shapeImage(shape.style, size: CGSize(width: width, height: height)),
              let thumbnail = try? PixelInvert.thumbnail(of: image) else { return }
        // A mask that follows the layer's pixel grid stays exactly where it is while that grid changes size.
        if let mask = layer.mask, mask.placement == nil { document?.layers[index].mask?.placement = layer.maskTransform }
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        document?.layers[index].shape = LayerShape(style: shape.style, image: image)
    }

    /// While a shape whose corners or stroke would stretch is being scaled, the shape drawn at the size it's being
    /// dragged to, so they keep their size during the drag rather than only once it's applied. At most 2048 pixels
    /// across (the radius and stroke scale down with it); nil for any other layer, which just stretches until the
    /// redraw at commit.
    func shapeTransformPreview(for layer: ImageLayer, transform: LayerTransform) -> CGImage? {
        guard transformEdit != nil, let shape = layer.liveShape, shape.style.kind != .line,
              shape.style.cornerRadius > 0 || shape.style.stroke != nil else {
            if !shapeTransformPreviewCache.isEmpty, transformEdit == nil { shapeTransformPreviewCache = [:] }
            return nil
        }
        let size = transform.size
        guard size.width >= 1, size.height >= 1,
              abs(size.width - CGFloat(shape.image.width)) >= 0.5 || abs(size.height - CGFloat(shape.image.height)) >= 0.5 else { return nil }
        let factor = min(1, 2048 / max(size.width, size.height))
        let drawn = CGSize(width: max(1, (size.width * factor).rounded()), height: max(1, (size.height * factor).rounded()))
        if let cached = shapeTransformPreviewCache[layer.id], cached.size == drawn { return cached.image }
        var style = shape.style
        style.cornerRadius *= factor
        style.stroke?.width *= factor
        guard let image = try? Self.shapeImage(style, size: drawn) else { return nil }
        shapeTransformPreviewCache[layer.id] = (drawn, image)
        return image
    }

    /// The shape filling its box, anti-aliased where it curves.
    nonisolated static func shapeImage(_ kind: ShapeKind, size: CGSize, color: PaletteColor, cornerRadius: CGFloat = 0, smoothing: Bool = false,
                           lineWidth: CGFloat = 0, start: CGPoint? = nil, end: CGPoint? = nil) throws -> CGImage {
        try shapeImage(LayerShapeStyle(kind: kind, red: color.red, green: color.green, blue: color.blue, cornerRadius: cornerRadius,
                                       smoothing: smoothing ? true : nil, lineWidth: kind == .line ? lineWidth : nil, start: start, end: end),
                       size: size)
    }

    /// The shape drawn into a layer `size` pixels across: its outline inset from the edges by its stroke's reach.
    nonisolated static func shapeImage(_ style: LayerShapeStyle, size: CGSize) throws -> CGImage {
        let context = try BrushRaster.context(width: Int(size.width), height: Int(size.height), mask: false)
        let bounds = CGRect(origin: .zero, size: size)
        if style.kind == .line {
            // The ends sit where they were dragged, as fractions of the box. Older lines (no ends stored) ran corner
            // to corner, inset by half their thickness.
            let thickness = max(1, style.lineWidth ?? 0)
            let inset = bounds.insetBy(dx: min(thickness, size.width) / 2, dy: min(thickness, size.height) / 2)
            let from = style.start.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) } ?? CGPoint(x: inset.minX, y: inset.minY)
            let to = style.end.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) } ?? CGPoint(x: inset.maxX, y: inset.maxY)
            style.drawLine(from: from, to: to, context: context)
        } else {
            let reach = min(style.reach, (size.width - 1) / 2, (size.height - 1) / 2)
            style.draw(in: bounds.insetBy(dx: max(0, reach), dy: max(0, reach)), context: context)
        }
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }
}
