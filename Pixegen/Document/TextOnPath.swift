import AppKit

/// Text set along a path rather than in lines, as Photoshop's Type on a Path: its letters stand on the path, one
/// after another, from where it was clicked. Version 21.
nonisolated struct TextPath: Codable, Equatable, Sendable {
    /// The path, in the text layer's own pixels (y down), the corner of its box at the origin.
    var subpath: ShapeOutline.Subpath
    /// Where the text starts (or, centered or right-aligned, where its middle or end is), as a distance along the
    /// path from its first point, in layer pixels.
    var start: CGFloat
    /// The letters on the path's other side, running the other way. Nil is not flipped.
    var flipped: Bool? = nil

    var isFlipped: Bool { flipped == true }
    var isValid: Bool {
        let points = subpath.knots.flatMap { [$0.anchor, $0.incoming, $0.outgoing] }
        return (2...ShapeOutline.maxKnots).contains(subpath.knots.count) && start.isFinite && abs(start) <= 10_000_000
            && points.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 }
    }
    var cgPath: CGPath { ShapeOutline.path(of: [subpath]) }
    /// The path's box, control points left out.
    var bounds: CGRect { cgPath.boundingBoxOfPath }
}

/// A path flattened into short straight pieces, for measuring along it.
nonisolated struct PathRuler {
    let points: [CGPoint]
    /// How far along the path each point is.
    let distances: [CGFloat]
    let closed: Bool
    var length: CGFloat { distances.last ?? 0 }

    init(_ path: CGPath, closed: Bool) {
        var points: [CGPoint] = []
        var current = CGPoint.zero
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                // Only the first subpath: text runs along one.
                guard points.isEmpty else { return }
                current = element.points[0]
                points.append(current)
            case .addLineToPoint:
                current = element.points[0]
                points.append(current)
            case .addQuadCurveToPoint:
                let control = element.points[0], end = element.points[1], from = current
                let steps = Self.steps(from, control, end)
                for step in 1...steps {
                    let t = CGFloat(step) / CGFloat(steps), u = 1 - t
                    points.append(CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * end.x,
                                          y: u * u * from.y + 2 * u * t * control.y + t * t * end.y))
                }
                current = end
            case .addCurveToPoint:
                let a = element.points[0], b = element.points[1], end = element.points[2], from = current
                let steps = Self.steps(from, a, b, end)
                for step in 1...steps {
                    let t = CGFloat(step) / CGFloat(steps), u = 1 - t
                    let w0 = u * u * u, w1 = 3 * u * u * t, w2 = 3 * u * t * t, w3 = t * t * t
                    points.append(CGPoint(x: w0 * from.x + w1 * a.x + w2 * b.x + w3 * end.x,
                                          y: w0 * from.y + w1 * a.y + w2 * b.y + w3 * end.y))
                }
                current = end
            case .closeSubpath:
                if let first = points.first, first != current { points.append(first) }
            @unknown default: break
            }
        }
        if closed, let first = points.first, let last = points.last, first != last { points.append(first) }
        var distances: [CGFloat] = []
        var total: CGFloat = 0
        for (index, point) in points.enumerated() {
            if index > 0 { total += hypot(point.x - points[index - 1].x, point.y - points[index - 1].y) }
            distances.append(total)
        }
        self.points = points
        self.distances = distances
        self.closed = closed
    }

    private init(points: [CGPoint], distances: [CGFloat], closed: Bool) {
        self.points = points; self.distances = distances; self.closed = closed
    }

    /// The same path walked the other way.
    var reversed: PathRuler {
        PathRuler(points: points.reversed(), distances: distances.reversed().map { length - $0 }, closed: closed)
    }

    /// Pieces about two pixels long along a curve, at least four.
    private static func steps(_ points: CGPoint...) -> Int {
        let hull = zip(points, points.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        return min(400, max(4, Int(hull / 2)))
    }

    /// The point `distance` along, and the direction the path runs there, in radians. A closed path goes round again;
    /// an open one is held to its ends.
    func place(at distance: CGFloat) -> (point: CGPoint, angle: CGFloat)? {
        guard points.count >= 2, length > 0 else { return nil }
        var d = distance
        if closed { d = d.truncatingRemainder(dividingBy: length); if d < 0 { d += length } }
        d = min(max(d, 0), length)
        // The piece holding `d`: the first whose end is at or past it.
        var low = 1, high = distances.count - 1
        while low < high {
            let middle = (low + high) / 2
            if distances[middle] < d { low = middle + 1 } else { high = middle }
        }
        let a = points[low - 1], b = points[low]
        let span = distances[low] - distances[low - 1]
        let t = span > 0 ? (d - distances[low - 1]) / span : 0
        return (CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), atan2(b.y - a.y, b.x - a.x))
    }

    /// The nearest point of the path to `point`: how far it is from it, and how far along the path it lies.
    func nearest(to point: CGPoint) -> (gap: CGFloat, distance: CGFloat)? {
        guard points.count >= 2 else { return nil }
        var best: (gap: CGFloat, distance: CGFloat)?
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            let dx = b.x - a.x, dy = b.y - a.y
            let squared = dx * dx + dy * dy
            let t = squared > 0 ? min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / squared)) : 0
            let gap = hypot(a.x + dx * t - point.x, a.y + dy * t - point.y)
            if gap < best?.gap ?? .infinity { best = (gap, distances[index - 1] + (distances[index] - distances[index - 1]) * t) }
        }
        return best
    }

    /// The stretch of path from one distance to another, for drawing a selection along it.
    func stretch(from start: CGFloat, to end: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard end > start else { return path }
        let step = max(1, (end - start) / 200)
        var d = start
        while d < end {
            if let placed = place(at: d) { path.isEmpty ? path.move(to: placed.point) : path.addLine(to: placed.point) }
            d += step
        }
        if let placed = place(at: end) { path.isEmpty ? path.move(to: placed.point) : path.addLine(to: placed.point) }
        return path
    }
}

/// Text on a path slid along it by a drag, as Photoshop's start marker is: the text moves as far along the path as the
/// pointer does, and crossing to the path's other side flips it over. Points are in the path's own coordinates.
nonisolated struct TextPathSlide {
    /// The path as the drag found it.
    let path: TextPath
    private let ruler: PathRuler
    /// How far along the path the pointer was last, and how far it has gone since the drag began.
    private var along: CGFloat
    private var travelled: CGFloat = 0
    /// Which side of the path the pointer is on: 1 the side unflipped letters stand on, -1 the other.
    private var side: CGFloat
    private var flipped: Bool
    /// How far past the path the pointer goes before it counts as the other side, so a drag along it doesn't flicker.
    static let crossing: CGFloat = 2

    init?(_ path: TextPath, at point: CGPoint) {
        let ruler = PathRuler(path.cgPath, closed: path.subpath.closed)
        guard ruler.length > 0, let near = ruler.nearest(to: point) else { return nil }
        self.path = path
        self.ruler = ruler
        along = near.distance
        flipped = path.isFlipped
        let offset = Self.offset(of: point, at: near.distance, on: ruler)
        // Right on the path, it's the side the letters are on.
        side = abs(offset) < Self.crossing ? (flipped ? -1 : 1) : (offset < 0 ? -1 : 1)
    }

    /// How far `point` is from the path at `distance` along it: positive on the side unflipped letters stand on.
    private static func offset(of point: CGPoint, at distance: CGFloat, on ruler: PathRuler) -> CGFloat {
        guard let placed = ruler.place(at: distance) else { return 0 }
        return (point.x - placed.point.x) * sin(placed.angle) - (point.y - placed.point.y) * cos(placed.angle)
    }

    /// The path with its text moved to follow the pointer at `point`.
    mutating func drag(to point: CGPoint) -> TextPath {
        if let near = ruler.nearest(to: point) {
            var step = near.distance - along
            // Round a closed path the short way: past its first point is a small step, not a whole lap back.
            if ruler.closed { step = remainder(step, ruler.length) }
            along = near.distance
            travelled += step
            let offset = Self.offset(of: point, at: near.distance, on: ruler)
            if offset > Self.crossing, side < 0 { side = 1; flipped.toggle() }
            if offset < -Self.crossing, side > 0 { side = -1; flipped.toggle() }
        }
        var result = path
        var start = path.start + travelled
        if ruler.closed {
            start = start.truncatingRemainder(dividingBy: ruler.length)
            if start < 0 { start += ruler.length }
        } else {
            start = min(max(start, 0), ruler.length)
        }
        result.start = start
        result.flipped = flipped ? true : nil
        return result
    }
}

extension ShapeOutline.Subpath {
    /// The subpath with every point, handles included, mapped by `transform`.
    nonisolated func applying(_ transform: CGAffineTransform) -> ShapeOutline.Subpath {
        ShapeOutline.Subpath(closed: closed, knots: knots.map {
            ShapeOutline.Knot(anchor: $0.anchor.applying(transform), incoming: $0.incoming.applying(transform),
                              outgoing: $0.outgoing.applying(transform))
        })
    }
}

/// One letter set on a path: the glyph, and where it goes.
nonisolated struct PathGlyph: @unchecked Sendable {
    let font: CTFont
    let glyph: CGGlyph
    /// From the glyph's own space (y up, origin on its baseline) to the text layer's pixels.
    let transform: CGAffineTransform
    let color: PaletteColor
    /// Which letter of the content it is, in UTF-16 units.
    let character: Int
}

/// Text laid out along its path.
nonisolated struct PathTextLayout {
    var glyphs: [PathGlyph] = []
    /// Where along the (possibly reversed) path each letter starts, by UTF-16 offset, and where the last one ends: for
    /// the caret. Letters that don't fit have none.
    var caretDistances: [Int: CGFloat] = [:]
    /// Some letters didn't fit on the path and aren't shown.
    var overflows = false
    /// The path as the letters walk it: reversed when flipped.
    var ruler: PathRuler?
}

extension LayerTextStyle {
    /// Room around the path for letters standing on either side of it.
    var pathMargin: CGFloat { Self.padding + (fontSize * 1.6).rounded(.up) }

    /// The point of the text's own pixels that stays where it is on the document as the text changes size: the top
    /// left corner for ordinary text, and for text on a path, the corner of the path's box.
    var anchor: CGPoint {
        guard let path else { return .zero }
        let box = path.bounds
        return CGPoint(x: pathMargin - box.minX, y: pathMargin - box.minY)
    }
}

extension EditorSession {
    /// The size of a text-on-path layer's pixels: its path's box with room all round.
    static func pathTextSize(_ style: LayerTextStyle) -> CGSize {
        guard let path = style.path else { return .zero }
        let box = path.bounds, margin = style.pathMargin
        return CGSize(width: max(16, ceil(box.width + margin * 2)), height: max(16, ceil(box.height + margin * 2)))
    }

    /// The letters of `style` laid along its path, in the layer's pixels. Line breaks read as spaces.
    static func pathTextLayout(_ style: LayerTextStyle) -> PathTextLayout {
        var layout = PathTextLayout()
        guard let path = style.path else { return layout }
        let anchor = style.anchor
        var shift = CGAffineTransform(translationX: anchor.x, y: anchor.y)
        guard let placed = path.cgPath.copy(using: &shift) else { return layout }
        let forward = PathRuler(placed, closed: path.subpath.closed)
        let ruler = path.isFlipped ? forward.reversed : forward
        layout.ruler = ruler
        guard ruler.length > 0 else { return layout }
        let string = attributedText(style)
        // One line: breaks become spaces, keeping every offset where it was.
        let content = string.string as NSString
        for index in 0..<content.length where [10, 13, 0x2028, 0x2029].contains(content.character(at: index)) {
            string.replaceCharacters(in: NSRange(location: index, length: 1), with: " ")
        }
        string.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: string.length))
        let line = CTLineCreateWithAttributedString(string)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        // Flipped, the text covers the same stretch of the path as it did, from the other side: walked the other
        // way, its start is where its end was.
        let origin: CGFloat = switch (style.alignment, path.isFlipped) {
        case (.left, false): path.start
        case (.center, false): path.start - width / 2
        case (.right, false): path.start - width
        case (.left, true): ruler.length - path.start - width
        case (.center, true): ruler.length - path.start - width / 2
        case (.right, true): ruler.length - path.start
        }
        /// Where a letter `offset` along the text lands on the path, or nil when it falls off it.
        func along(_ offset: CGFloat, _ advance: CGFloat) -> CGFloat? {
            if ruler.closed {
                // Once round, and no further, so the text never runs over itself.
                guard offset + advance <= ruler.length + 0.01 else { return nil }
                return origin + offset
            }
            let d = origin + offset
            return d >= -0.01 && d + advance <= ruler.length + 0.01 ? d : nil
        }
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetAdvances(run, CFRange(), &advances)
            CTRunGetStringIndices(run, CFRange(), &indices)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let face = attributes[kCTFontAttributeName], CFGetTypeID(face as CFTypeRef) == CTFontGetTypeID() else { continue }
            let font = face as! CTFont
            for i in 0..<count {
                let advance = advances[i].width
                guard let d = along(positions[i].x, advance) else { layout.overflows = true; continue }
                layout.caretDistances[indices[i]] = d
                layout.caretDistances[indices[i] + 1] = d + advance
                guard let middle = ruler.place(at: d + advance / 2) else { continue }
                let shown = (string.attribute(.foregroundColor, at: indices[i], effectiveRange: nil) as? NSColor)?
                    .usingColorSpace(.sRGB) ?? .black
                let color = PaletteColor(red: min(1, max(0, shown.redComponent)), green: min(1, max(0, shown.greenComponent)),
                                         blue: min(1, max(0, shown.blueComponent)))
                // Upright on the path at its middle, its baseline along it; the glyph's y runs up, the layer's down.
                let transform = CGAffineTransform(scaleX: 1, y: -1)
                    .concatenating(CGAffineTransform(translationX: -advance / 2, y: 0))
                    .concatenating(CGAffineTransform(rotationAngle: middle.angle))
                    .concatenating(CGAffineTransform(translationX: middle.point.x, y: middle.point.y))
                layout.glyphs.append(PathGlyph(font: font, glyph: glyphs[i], transform: transform, color: color, character: indices[i]))
            }
        }
        if layout.caretDistances[0] == nil, content.length == 0 { layout.caretDistances[0] = along(0, 0) ?? origin }
        return layout
    }

    /// Text on a path drawn into pixels the size `pathTextSize` gives.
    static func pathTextImage(_ style: LayerTextStyle) throws -> CGImage {
        let size = pathTextSize(style)
        guard size.width <= DocumentLimits.maxSideExtent, size.height <= DocumentLimits.maxSideExtent,
              size.width * size.height <= DocumentLimits.maxSurfaceExtent else { throw ProjectError.tooLarge }
        // Already y down, as the layout is.
        let context = try BrushRaster.context(width: Int(size.width), height: Int(size.height), mask: false)
        context.textMatrix = .identity
        for letter in pathTextLayout(style).glyphs {
            context.saveGState()
            context.concatenate(letter.transform)
            context.setFillColor(CGColor(srgbRed: letter.color.red, green: letter.color.green, blue: letter.color.blue, alpha: 1))
            var glyph = letter.glyph, position = CGPoint.zero
            CTFontDrawGlyphs(letter.font, &glyph, &position, 1, context)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }

    /// The paths text could be set on, in document pixels: each subpath of every visible shape layer, and of the
    /// work path.
    var textPathCandidates: [ShapeOutline.Subpath] {
        guard let document else { return [] }
        var result: [ShapeOutline.Subpath] = []
        if let workPath { result += ShapeOutline.subpaths(of: workPath) }
        let visible = document.effectiveVisibleIDs
        // Topmost first, so the shape on top wins where two meet.
        for layer in document.layers.reversed() where visible.contains(layer.id) {
            guard let shape = layer.liveShape,
                  let knots = Self.pathKnots(style: shape.style, transform: layer.transform, image: shape.image) else { continue }
            let map = layer.transform.unitToDocument
            result += knots.map { subpath in
                ShapeOutline.Subpath(closed: subpath.closed, knots: subpath.knots.map {
                    ShapeOutline.Knot(anchor: $0.anchor.applying(map), incoming: $0.incoming.applying(map), outgoing: $0.outgoing.applying(map))
                })
            }
        }
        return result
    }

    /// The path a click at `point` (document pixels) would set text on, and how far along it the click is: the
    /// nearest within `tolerance` document pixels.
    func textPathTarget(at point: CGPoint, tolerance: CGFloat) -> (subpath: ShapeOutline.Subpath, distance: CGFloat)? {
        var best: (subpath: ShapeOutline.Subpath, distance: CGFloat, gap: CGFloat)?
        for subpath in textPathCandidates where subpath.knots.count >= 2 {
            let path = ShapeOutline.path(of: [subpath])
            // Cheap first: a box this far away can't be near.
            guard path.boundingBox.insetBy(dx: -tolerance, dy: -tolerance).contains(point),
                  let near = PathRuler(path, closed: subpath.closed).nearest(to: point),
                  near.gap <= tolerance, near.gap < best?.gap ?? .infinity else { continue }
            best = (subpath, near.distance, near.gap)
        }
        return best.map { ($0.subpath, $0.distance) }
    }

    /// Starts new text on `subpath` (document pixels), from `distance` along it, in the text settings and the
    /// foreground color, as `beginText` does for point text. The layer gets its own copy of the path.
    func beginTextOnPath(_ subpath: ShapeOutline.Subpath, at distance: CGFloat) {
        guard canEditLayers, textDraft == nil, let document else { return }
        let box = ShapeOutline.path(of: [subpath]).boundingBoxOfPath
        let local = ShapeOutline.Subpath(closed: subpath.closed, knots: subpath.knots.map {
            func shift(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - box.minX, y: point.y - box.minY) }
            return ShapeOutline.Knot(anchor: shift($0.anchor), incoming: shift($0.incoming), outgoing: shift($0.outgoing))
        })
        var style = textDefaults
        style.content = ""
        style.colorRuns = nil
        style.fontRuns = nil
        style.boxSize = nil
        style.path = TextPath(subpath: local, start: distance)
        if !isMaskSelected {
            style.red = foregroundColor.red; style.green = foregroundColor.green; style.blue = foregroundColor.blue
        }
        guard style.isValid else { NSSound.beep(); return }
        tool = .type
        // For text on a path, the draft's origin is where the path's box sits on the document.
        textDraft = TextDraft(documentID: document.id, layerID: nil, origin: box.origin, style: style)
    }

    /// The active layer when it's text on a path, whose text the Path Selection tool slides along it and whose path
    /// Direct Selection reshapes.
    var pathTextLayer: ImageLayer? {
        guard let layer = activeLayer, layer.liveText?.style.path != nil, !layer.isGroup else { return nil }
        return layer
    }

    /// From a text-on-path layer's path, in the path's own coordinates, to the document.
    static func textPathToDocument(_ layer: ImageLayer) -> CGAffineTransform? {
        guard let text = layer.liveText, text.style.path != nil else { return nil }
        let anchor = text.style.anchor
        return CGAffineTransform(translationX: anchor.x, y: anchor.y)
            .concatenating(CGAffineTransform(scaleX: 1 / CGFloat(text.image.width), y: 1 / CGFloat(text.image.height)))
            .concatenating(layer.transform.unitToDocument)
    }

    /// Whether `point` (document pixels) is on a text-on-path layer's own path, so a click there edits it.
    func isOnTextPath(_ layer: ImageLayer, at point: CGPoint, tolerance: CGFloat) -> Bool {
        guard let path = layer.liveText?.style.path, var map = Self.textPathToDocument(layer),
              let placed = path.cgPath.copy(using: &map),
              let near = PathRuler(placed, closed: path.subpath.closed).nearest(to: point) else { return false }
        return near.gap <= tolerance
    }

    /// Text on a path flipped to its other side, or back.
    func flipTextPath() {
        changeTextStyle { style in
            guard var path = style.path else { return }
            path.flipped = path.isFlipped ? nil : true
            style.path = path
        }
    }
}
