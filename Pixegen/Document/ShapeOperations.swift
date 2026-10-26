import AppKit

/// Photoshop's path operations, applied to selected shape layers: the active one is the shape the others act on.
nonisolated enum ShapeOperation: String, CaseIterable, Sendable {
    case combine = "Combine Shapes"
    case subtract = "Subtract Front Shape"
    case intersect = "Intersect Shape Areas"
    case exclude = "Exclude Overlapping Shapes"

    /// The button's accessibility label, and the undo step's first word.
    var shortName: String {
        switch self {
        case .combine: "Combine"
        case .subtract: "Subtract"
        case .intersect: "Intersect"
        case .exclude: "Exclude"
        }
    }

    var help: String {
        switch self {
        case .combine: "Combine: add the other selected shapes to the active one"
        case .subtract: "Subtract: cut the other selected shapes out of the active one"
        case .intersect: "Intersect: keep only where all the selected shapes overlap"
        case .exclude: "Exclude: keep where the selected shapes don't overlap"
        }
    }

    /// The area `base` and `others` make together, in whatever coordinates they share. Each path is filled by its own
    /// rule first, so a custom shape's holes stay holes.
    func apply(base: (path: CGPath, rule: CGPathFillRule), others: [(path: CGPath, rule: CGPathFillRule)]) -> CGPath {
        let first = base.path.normalized(using: base.rule)
        let rest = others.map { $0.path.normalized(using: $0.rule) }
        switch self {
        case .combine:
            return rest.reduce(first) { $0.union($1) }
        case .subtract:
            guard let cut = rest.first else { return first }
            return first.subtracting(rest.dropFirst().reduce(cut) { $0.union($1) })
        case .intersect:
            return rest.reduce(first) { $0.intersection($1) }
        case .exclude:
            // Covered an odd number of times: each shape in turn flips what it covers.
            return rest.reduce(first) { $0.symmetricDifference($1) }
        }
    }
}

extension EditorSession {
    /// The selected layers the shape operations work on, bottom to top: visible or not, every one still a shape with
    /// an area (not a line or a folder). Empty unless the active layer is one of them and there are at least two.
    var shapeOperationLayers: [ImageLayer] {
        guard canEditLayers, let document, selectedLayerIDs.count > 1, let active = activeLayerID else { return [] }
        let layers = document.layers.filter {
            selectedLayerIDs.contains($0.id) && !$0.isGroup && $0.liveShape.map { $0.style.kind != .line } == true
        }
        guard layers.count > 1, layers.contains(where: { $0.id == active }) else { return [] }
        return layers
    }

    var canApplyShapeOperation: Bool { !shapeOperationLayers.isEmpty }

    /// A shape's outline on the document: its path through the layer's placement, rotation and flips included.
    nonisolated static func documentOutline(of layer: ImageLayer) -> (path: CGPath, rule: CGPathFillRule)? {
        guard let shape = layer.liveShape,
              let knots = pathKnots(style: shape.style, transform: layer.transform, image: shape.image) else { return nil }
        var map = layer.transform.unitToDocument
        guard let path = ShapeOutline.path(of: knots).copy(using: &map) else { return nil }
        return (path, shape.style.fillRule)
    }

    /// The selected shapes become one: the active layer, its outline replaced by what `operation` makes of all of
    /// them, and the others gone, as one undo step. The active layer keeps its fill, stroke, name, place, opacity,
    /// blend mode, effects and clipping; the result is a custom shape, upright and unflipped, and its mask goes, as in
    /// Photoshop. Layers clipped to a shape that went now clip to the result.
    func applyShapeOperation(_ operation: ShapeOperation) {
        commitTransform()
        let layers = shapeOperationLayers
        guard let document, let base = layers.first(where: { $0.id == activeLayerID }), let shape = base.liveShape,
              let baseOutline = Self.documentOutline(of: base) else { return }
        let others = layers.filter { $0.id != base.id }.compactMap(Self.documentOutline)
        guard others.count == layers.count - 1 else { NSSound.beep(); return }
        let result = operation.apply(base: baseOutline, others: others)
        let bounds = result.boundingBoxOfPath
        guard !result.isEmpty, bounds.width >= 1, bounds.height >= 1, let outline = ShapeOutline(path: result) else {
            brushError = operation == .intersect
                ? "Those shapes don't overlap, so there's nothing left where they all meet."
                : "That would leave nothing of the shape."
            return
        }
        var style = shape.style
        style.kind = .custom
        style.outline = outline
        style.customName = nil
        style.cornerRadius = 0
        style.smoothing = nil
        style.sides = nil
        let box = bounds.insetBy(dx: -style.reach, dy: -style.reach)
        let size = CGSize(width: max(1, box.width.rounded()), height: max(1, box.height.rounded()))
        guard Int(size.width) * Int(size.height) <= Self.maxShapePixels else {
            brushError = "That shape is too large. A shape can cover up to \(DocumentLimits.maxSurfaceMegapixels) megapixels."
            return
        }
        guard let image = try? Self.shapeImage(style, size: size), let thumbnail = try? PixelInvert.thumbnail(of: image),
              let asset = base.asset else { NSSound.beep(); return }
        let removed = Set(layers.map(\.id)).subtracting([base.id])
        var next = document.layers.filter { !removed.contains($0.id) }
        for i in next.indices where next[i].maskSourceID.map(removed.contains) == true {
            next[i].maskSourceID = next[i].id == base.id ? nil : base.id
        }
        guard let index = next.firstIndex(where: { $0.id == base.id }) else { return }
        var placed = base.transform
        placed.origin = box.origin
        placed.size = size
        placed.rotation = 0
        placed.flipX = false
        placed.flipY = false
        next[index].transform = placed
        next[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        next[index].shape = LayerShape(style: style, image: image)
        next[index].mask = nil
        guard (try? LayerHierarchy.validate(next.map(\.hierarchyRecord))) != nil else { NSSound.beep(); return }
        finishOpacityEdit()
        beginEdit("\(operation.shortName) Shapes")
        self.document?.layers = next
        activeLayerID = base.id
        endEdit()
    }
}
