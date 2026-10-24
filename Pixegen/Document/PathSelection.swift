import AppKit

/// The Path Selection tool's two modes, as Photoshop's black and white arrows: Path Selection picks a shape's whole
/// path and moves it; Direct Selection picks its anchor points and their handles and reshapes it.
nonisolated enum PathSelectionMode: String, CaseIterable, Sendable {
    case path = "Path Selection"
    case direct = "Direct Selection"
    var toolName: String { "\(rawValue) Tool" }
}

/// One knot of a shape layer's path: which subpath, and which knot along it.
nonisolated struct PathKnot: Hashable, Sendable {
    var subpath: Int
    var knot: Int
}

/// What a click on a shape's path landed on.
nonisolated enum PathHit: Equatable, Sendable {
    case anchor(PathKnot)
    /// One of an anchor's two direction handles: its incoming control point, or its outgoing one.
    case handle(PathKnot, outgoing: Bool)
    /// The shape itself, away from its points.
    case shape(UUID)
}

/// A path being dragged with the Path Selection tool. Every step starts again from the layer as it was when the drag
/// began, so nothing drifts.
struct PathDrag {
    let layerID: UUID
    let hit: PathHit
    let start: CGPoint
    let style: LayerShapeStyle
    let transform: LayerTransform
    /// The path when the drag began, in the layer's unit square.
    let knots: [ShapeOutline.Subpath]
    /// The anchors that move with an anchor drag.
    let moving: Set<PathKnot>
    var moved = false
}

extension EditorSession {
    /// The active layer when it's still a shape whose path can be edited.
    var pathLayer: ImageLayer? {
        guard let layer = activeLayer, layer.liveShape != nil, !layer.isGroup else { return nil }
        return layer
    }

    /// The active shape's path in document pixels, for drawing; nil when the active layer isn't a shape.
    var pathKnotsInDocument: [ShapeOutline.Subpath]? {
        guard let layer = pathLayer, let shape = layer.liveShape,
              let knots = Self.pathKnots(style: shape.style, transform: layer.transform, image: shape.image) else { return nil }
        let map = layer.transform.unitToDocument
        return knots.map { subpath in
            ShapeOutline.Subpath(closed: subpath.closed, knots: subpath.knots.map {
                ShapeOutline.Knot(anchor: $0.anchor.applying(map), incoming: $0.incoming.applying(map), outgoing: $0.outgoing.applying(map))
            })
        }
    }

    /// Path Selection selects every point; Direct Selection, only those clicked.
    var shownPathKnots: Set<PathKnot> {
        guard pathSelectionMode == .path, let knots = pathKnotsInDocument else { return selectedPathKnots }
        return Set(knots.enumerated().flatMap { subpath, value in value.knots.indices.map { PathKnot(subpath: subpath, knot: $0) } })
    }

    /// A shape's path in its layer's unit square (0–1 over the layer's box, before rotation and flips). Rectangles,
    /// stars and the rest give the knots of the outline they draw; a line, its two ends.
    nonisolated static func pathKnots(style: LayerShapeStyle, transform: LayerTransform, image: CGImage) -> [ShapeOutline.Subpath]? {
        if style.kind == .line {
            let inset = CGPoint(x: min(0.5, (style.lineWidth ?? 1) / 2 / max(1, transform.size.width)),
                                y: min(0.5, (style.lineWidth ?? 1) / 2 / max(1, transform.size.height)))
            let start = style.start ?? inset, end = style.end ?? CGPoint(x: 1 - inset.x, y: 1 - inset.y)
            return [ShapeOutline.Subpath(closed: false, knots: [ShapeOutline.Knot(anchor: start), ShapeOutline.Knot(anchor: end)])]
        }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width > 0, height > 0 else { return nil }
        let reach = min(style.reach, (width - 1) / 2, (height - 1) / 2)
        let rect = CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: max(0, reach), dy: max(0, reach))
        let pixels = ShapeOutline.subpaths(of: style.outline(in: rect))
        func unit(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x / width, y: point.y / height) }
        let knots = pixels.map { subpath in
            ShapeOutline.Subpath(closed: subpath.closed, knots: subpath.knots.map {
                ShapeOutline.Knot(anchor: unit($0.anchor), incoming: unit($0.incoming), outgoing: unit($0.outgoing))
            })
        }.filter { !$0.knots.isEmpty }
        return knots.isEmpty ? nil : knots
    }

    /// The shape with its path replaced by `knots` (in `transform`'s unit square): a custom shape fitted to them, and the
    /// transform that keeps every point where it is on the document. A line keeps being a line through its two ends.
    /// Nil when the points no longer enclose anything, or would make a layer too large.
    nonisolated static func reshaped(style: LayerShapeStyle, transform: LayerTransform,
                                     knots: [ShapeOutline.Subpath]) -> (style: LayerShapeStyle, transform: LayerTransform)? {
        let width = transform.size.width, height = transform.size.height
        func pixel(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * width, y: point.y * height) }
        let pixels = knots.map { subpath in
            ShapeOutline.Subpath(closed: subpath.closed, knots: subpath.knots.map {
                ShapeOutline.Knot(anchor: pixel($0.anchor), incoming: pixel($0.incoming), outgoing: pixel($0.outgoing))
            })
        }
        var result = style
        let box: CGRect
        if style.kind == .line {
            guard let ends = pixels.first?.knots, ends.count == 2 else { return nil }
            let from = ends[0].anchor, to = ends[1].anchor
            box = CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
            guard box.width >= 1 || box.height >= 1 else { return nil }
        } else {
            guard let outline = ShapeOutline.normalized(pixels) else { return nil }
            box = ShapeOutline.path(of: pixels).boundingBoxOfPath
            // Its own path now, as in Photoshop: a rectangle whose corner is moved is no longer a rectangle.
            result.kind = .custom
            result.outline = outline
            result.cornerRadius = 0
            result.smoothing = nil
            result.sides = nil
        }
        let layerBox = box.insetBy(dx: -result.reach, dy: -result.reach)
        guard layerBox.width >= 1, layerBox.height >= 1, layerBox.width * layerBox.height <= CGFloat(maxShapePixels) else { return nil }
        if style.kind == .line, let ends = pixels.first?.knots {
            func unit(_ point: CGPoint) -> CGPoint { CGPoint(x: (point.x - layerBox.minX) / layerBox.width, y: (point.y - layerBox.minY) / layerBox.height) }
            result.start = unit(ends[0].anchor)
            result.end = unit(ends[1].anchor)
        }
        // The new box, in the old one's unit square, placed on the document as the old one was.
        let unitBox = CGRect(x: layerBox.minX / width, y: layerBox.minY / height, width: layerBox.width / width, height: layerBox.height / height)
        let map = CGAffineTransform(a: unitBox.width, b: 0, c: 0, d: unitBox.height, tx: unitBox.minX, ty: unitBox.minY)
            .concatenating(transform.unitToDocument)
        var placed = transform.placing(map)
        placed.size = CGSize(width: layerBox.width, height: layerBox.height)
        return placed.isValid ? (result, placed) : nil
    }

    /// What's under `point` (document pixels): one of the active shape's points or handles, with Direct Selection;
    /// otherwise the topmost visible shape there. `tolerance` is how near, in document pixels, counts.
    func pathHit(at point: CGPoint, tolerance: CGFloat) -> PathHit? {
        if pathSelectionMode == .direct, let knots = pathKnotsInDocument {
            func near(_ other: CGPoint) -> Bool { hypot(other.x - point.x, other.y - point.y) <= tolerance }
            // The handles shown are those of the selected points.
            for knot in selectedPathKnots {
                guard knots.indices.contains(knot.subpath), knots[knot.subpath].knots.indices.contains(knot.knot) else { continue }
                let value = knots[knot.subpath].knots[knot.knot]
                if value.outgoing != value.anchor, near(value.outgoing) { return .handle(knot, outgoing: true) }
                if value.incoming != value.anchor, near(value.incoming) { return .handle(knot, outgoing: false) }
            }
            for (index, subpath) in knots.enumerated() {
                if let found = subpath.knots.firstIndex(where: { near($0.anchor) }) { return .anchor(PathKnot(subpath: index, knot: found)) }
            }
        }
        guard let document else { return nil }
        let visible = document.effectiveVisibleIDs
        // Topmost first: the last layer is drawn last.
        for layer in document.layers.reversed() where visible.contains(layer.id) {
            guard let shape = layer.liveShape,
                  let knots = Self.pathKnots(style: shape.style, transform: layer.transform, image: shape.image) else { continue }
            var map = layer.transform.unitToDocument
            guard let path = ShapeOutline.path(of: knots).copy(using: &map) else { continue }
            let open = shape.style.kind == .line || !shape.style.isFilled
            let hitsFill = !open && path.contains(point, using: shape.style.fillRule)
            let edge = path.copy(strokingWithWidth: tolerance * 2 + (shape.style.kind == .line ? shape.style.lineWidth ?? 0 : shape.style.stroke?.width ?? 0),
                                 lineCap: .round, lineJoin: .round, miterLimit: 1)
            if hitsFill || edge.contains(point) { return .shape(layer.id) }
        }
        return nil
    }

    /// A press with the Path Selection tool. Shift adds a point to the ones selected (or takes it away).
    func beginPathDrag(at point: CGPoint, tolerance: CGFloat, extend: Bool) {
        guard tool == .pathSelection, canEditLayers, point.x.isFinite, point.y.isFinite else { return }
        guard let hit = pathHit(at: point, tolerance: tolerance) else {
            if !extend { selectedPathKnots = [] }
            return
        }
        if case .shape(let id) = hit, id != activeLayerID {
            selectLayer(id)
            selectedPathKnots = []
        }
        switch hit {
        case .anchor(let knot):
            if extend {
                if selectedPathKnots.contains(knot) { selectedPathKnots.remove(knot); return }
                selectedPathKnots.insert(knot)
            } else if !selectedPathKnots.contains(knot) {
                selectedPathKnots = [knot]
            }
        case .shape:
            if pathSelectionMode == .direct, !extend { selectedPathKnots = [] }
        case .handle: break
        }
        guard let layer = pathLayer, let shape = layer.liveShape,
              let knots = Self.pathKnots(style: shape.style, transform: layer.transform, image: shape.image) else { return }
        let moving: Set<PathKnot>
        if case .anchor = hit { moving = selectedPathKnots } else { moving = [] }
        pathDrag = PathDrag(layerID: layer.id, hit: hit, start: point, style: shape.style, transform: layer.transform,
                            knots: knots, moving: moving)
        beginEdit(pathSelectionMode == .path || hit == .shape(layer.id) ? "Move Path" : "Edit Path")
    }

    /// Path Selection (or a drag on the shape itself) moves the whole shape; Direct Selection moves the points
    /// selected, or one handle. A handle of a smooth point turns its partner with it, unless `breaksHandle` (Option).
    func dragPath(to point: CGPoint, breaksHandle: Bool) {
        guard var drag = pathDrag, point.x.isFinite, point.y.isFinite,
              let index = document?.layers.firstIndex(where: { $0.id == drag.layerID }) else { return }
        let dx = point.x - drag.start.x, dy = point.y - drag.start.y
        drag.moved = drag.moved || dx != 0 || dy != 0
        pathDrag = drag
        if case .shape = drag.hit {
            var moved = drag.transform
            moved.origin = CGPoint(x: moved.origin.x + dx.rounded(), y: moved.origin.y + dy.rounded())
            document?.layers[index].transform = moved
            return
        }
        // The drag in the layer's unit square: undo the rotation, flips and size that place it on the document.
        let inverse = drag.transform.unitToDocument.inverted()
        let delta = CGPoint(x: dx * inverse.a + dy * inverse.c, y: dx * inverse.b + dy * inverse.d)
        func shifted(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + delta.x, y: point.y + delta.y) }
        var knots = drag.knots
        switch drag.hit {
        case .anchor:
            for knot in drag.moving where knots.indices.contains(knot.subpath) && knots[knot.subpath].knots.indices.contains(knot.knot) {
                var value = knots[knot.subpath].knots[knot.knot]
                value = ShapeOutline.Knot(anchor: shifted(value.anchor), incoming: shifted(value.incoming), outgoing: shifted(value.outgoing))
                knots[knot.subpath].knots[knot.knot] = value
            }
        case .handle(let knot, let outgoing):
            guard knots.indices.contains(knot.subpath), knots[knot.subpath].knots.indices.contains(knot.knot) else { return }
            var value = knots[knot.subpath].knots[knot.knot]
            let smooth = !breaksHandle && Self.isSmooth(value)
            if outgoing { value.outgoing = shifted(value.outgoing) } else { value.incoming = shifted(value.incoming) }
            if smooth {
                // The other handle keeps its length and turns to stay in line.
                let moved = outgoing ? value.outgoing : value.incoming
                let other = outgoing ? value.incoming : value.outgoing
                let length = hypot(other.x - value.anchor.x, other.y - value.anchor.y)
                let reach = hypot(moved.x - value.anchor.x, moved.y - value.anchor.y)
                if reach > 0 {
                    let opposite = CGPoint(x: value.anchor.x - (moved.x - value.anchor.x) / reach * length,
                                           y: value.anchor.y - (moved.y - value.anchor.y) / reach * length)
                    if outgoing { value.incoming = opposite } else { value.outgoing = opposite }
                }
            }
            knots[knot.subpath].knots[knot.knot] = value
        case .shape:
            return
        }
        applyPath(knots, from: drag, at: index)
    }

    func endPathDrag() {
        guard pathDrag != nil else { return }
        pathDrag = nil
        endEdit()
    }

    /// Delete with Direct Selection: removes the selected points, and any subpath left with too few to draw. Removing
    /// them all deletes the layer.
    func deleteSelectedPathKnots() {
        guard pathSelectionMode == .direct, !selectedPathKnots.isEmpty, canEditLayers, let layer = pathLayer, let shape = layer.liveShape,
              let index = document?.layers.firstIndex(where: { $0.id == layer.id }),
              var knots = Self.pathKnots(style: shape.style, transform: layer.transform, image: shape.image) else { return }
        guard shape.style.kind != .line else { NSSound.beep(); return }
        for knot in selectedPathKnots.sorted(by: { ($0.subpath, $0.knot) > ($1.subpath, $1.knot) })
            where knots.indices.contains(knot.subpath) && knots[knot.subpath].knots.indices.contains(knot.knot) {
            knots[knot.subpath].knots.remove(at: knot.knot)
        }
        knots.removeAll { $0.knots.count < ($0.closed ? 3 : 2) }
        selectedPathKnots = []
        guard !knots.isEmpty else { deleteLayerOrMask(); return }
        let drag = PathDrag(layerID: layer.id, hit: .shape(layer.id), start: .zero, style: shape.style, transform: layer.transform,
                            knots: knots, moving: [])
        beginEdit("Delete Anchor Points")
        applyPath(knots, from: drag, at: index)
        endEdit()
    }

    /// Redraws the layer at `index` as `knots`, starting from the shape and placement the drag began with.
    private func applyPath(_ knots: [ShapeOutline.Subpath], from drag: PathDrag, at index: Int) {
        guard let reshaped = Self.reshaped(style: drag.style, transform: drag.transform, knots: knots),
              let layer = document?.layers[index], let asset = layer.asset else { return }
        let size = CGSize(width: max(1, reshaped.transform.size.width.rounded()), height: max(1, reshaped.transform.size.height.rounded()))
        guard let image = try? Self.shapeImage(reshaped.style, size: size),
              let thumbnail = try? PixelInvert.thumbnail(of: image) else { return }
        // A mask that follows the layer's pixel grid stays where it is while that grid changes.
        if let mask = layer.mask, mask.placement == nil { document?.layers[index].mask?.placement = layer.maskTransform }
        document?.layers[index].transform = reshaped.transform
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        document?.layers[index].shape = LayerShape(style: reshaped.style, image: image)
    }

    /// Whether an anchor's handles run in one line through it, as at a smooth point.
    nonisolated static func isSmooth(_ knot: ShapeOutline.Knot) -> Bool {
        let a = CGPoint(x: knot.incoming.x - knot.anchor.x, y: knot.incoming.y - knot.anchor.y)
        let b = CGPoint(x: knot.outgoing.x - knot.anchor.x, y: knot.outgoing.y - knot.anchor.y)
        let lengths = hypot(a.x, a.y) * hypot(b.x, b.y)
        guard lengths > 0 else { return false }
        return abs(a.x * b.y - a.y * b.x) / lengths < 0.02 && a.x * b.x + a.y * b.y < 0
    }

    /// Shift-A: Path Selection and Direct Selection.
    func togglePathSelectionMode() {
        pathSelectionMode = pathSelectionMode == .path ? .direct : .path
        if pathSelectionMode == .path { selectedPathKnots = [] }
    }
}
