import AppKit

/// Text set inside a closed shape instead of a rectangle, as Photoshop's area type: lines wrap to fit the shape's
/// outline. Version 22.
nonisolated struct TextArea: Codable, Equatable, Sendable {
    /// The outline, in the text layer's own pixels (y down), its box `LayerTextStyle.padding` in from the layer's
    /// top-left corner. Overlaps are already merged, so it fills by the winding rule.
    var subpaths: [ShapeOutline.Subpath]

    var isValid: Bool {
        let knots = subpaths.reduce(0) { $0 + $1.knots.count }
        let points = subpaths.flatMap { $0.knots.flatMap { [$0.anchor, $0.incoming, $0.outgoing] } }
        return !subpaths.isEmpty && subpaths.allSatisfy { $0.closed && $0.knots.count >= 2 } && knots <= ShapeOutline.maxKnots
            && points.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 }
    }
    var cgPath: CGPath { ShapeOutline.path(of: subpaths) }
}

/// A text container that never breaks a word for want of room in a shape: a piece of a line too narrow for the
/// word that would start it is skipped, and the line moves on to the next piece, or down, as Photoshop's area type
/// does. With no shape to wrap to, it's an ordinary container.
final class AreaTextContainer: NSTextContainer {
    override func lineFragmentRect(forProposedRect proposed: NSRect, at characterIndex: Int, writingDirection: NSWritingDirection,
                                   remaining: UnsafeMutablePointer<NSRect>?) -> NSRect {
        guard !exclusionPaths.isEmpty else {
            return super.lineFragmentRect(forProposedRect: proposed, at: characterIndex, writingDirection: writingDirection, remaining: remaining)
        }
        let needed = min(firstWordWidth(at: characterIndex), size.width)
        // Down in steps of a quarter line, so the first line that fits isn't missed by much.
        let step = max(1, proposed.height / 4)
        var rect = proposed
        while rect.maxY <= size.height {
            var rest = NSRect.zero
            let found = super.lineFragmentRect(forProposedRect: rect, at: characterIndex, writingDirection: writingDirection, remaining: &rest)
            if !found.isEmpty, found.width >= needed {
                remaining?.pointee = rest
                return found
            }
            if !rest.isEmpty, rest.minX > rect.minX {
                rect = rest
            } else {
                rect = NSRect(x: proposed.minX, y: rect.minY + step, width: proposed.width, height: proposed.height)
            }
        }
        remaining?.pointee = .zero
        return .zero
    }

    /// How wide the word starting at `index` is set, so a line starting there is placed where it fits.
    private func firstWordWidth(at index: Int) -> CGFloat {
        guard let storage = layoutManager?.textStorage, index < storage.length else { return 0 }
        let text = storage.string as NSString
        var end = index
        while end < text.length, let scalar = UnicodeScalar(text.character(at: end)),
              !CharacterSet.whitespacesAndNewlines.contains(scalar) { end += 1 }
        guard end > index else { return 0 }
        return ceil(storage.attributedSubstring(from: NSRange(location: index, length: end - index)).size().width)
    }
}

extension EditorSession {
    /// The text container `style` lays out in, for a layer `size` pixels: the box less its padding, and, for text in a
    /// shape, everything outside the shape kept clear so lines wrap to its outline.
    static func textContainer(_ style: LayerTextStyle, size: CGSize) -> NSTextContainer {
        let padding = LayerTextStyle.padding
        let container = AreaTextContainer(size: CGSize(width: max(1, ceil(size.width) - 2 * padding),
                                                       height: max(1, ceil(size.height) - 2 * padding)))
        container.lineFragmentPadding = 0
        container.exclusionPaths = areaExclusion(style, size: container.size)
        return container
    }

    /// For text in a shape, the part of a text container `size` across that lies outside the shape, in the
    /// container's coordinates (the layer's less its padding). Nothing for other text.
    static func areaExclusion(_ style: LayerTextStyle, size: CGSize) -> [NSBezierPath] {
        guard let area = style.area else { return [] }
        let padding = LayerTextStyle.padding
        var shift = CGAffineTransform(translationX: -padding, y: -padding)
        guard let shape = area.cgPath.copy(using: &shift) else { return [] }
        // Wider than the container all round, so no sliver of it is left open at an edge.
        let room = CGPath(rect: CGRect(origin: .zero, size: size).insetBy(dx: -padding, dy: -padding), transform: nil)
        let outside = room.subtracting(shape, using: .winding)
        return outside.isEmpty ? [] : [NSBezierPath(cgPath: outside)]
    }

    /// The closed shape a Type tool click at `point` (document pixels) falls inside, its outline in document pixels with
    /// overlaps merged: the topmost visible shape layer that isn't a line. Nil when there's none.
    func textAreaTarget(at point: CGPoint) -> [ShapeOutline.Subpath]? {
        guard let document else { return nil }
        let visible = document.effectiveVisibleIDs
        // Topmost first: the last layer is drawn last.
        for layer in document.layers.reversed() where visible.contains(layer.id) {
            guard let shape = layer.liveShape, shape.style.kind != .line,
                  let knots = Self.pathKnots(style: shape.style, transform: layer.transform, image: shape.image) else { continue }
            let closed = knots.filter(\.closed).map { $0.applying(layer.transform.unitToDocument) }
            guard !closed.isEmpty else { continue }
            let path = ShapeOutline.path(of: closed)
            guard path.contains(point, using: shape.style.fillRule) else { continue }
            let merged = ShapeOutline.subpaths(of: path.normalized(using: shape.style.fillRule)).filter { $0.closed && $0.knots.count >= 2 }
            return merged.isEmpty ? nil : merged
        }
        return nil
    }

    /// Starts new text inside the shape `subpaths` (document pixels), as `beginTextOnPath` does for a path: in the text
    /// settings and the foreground color, wrapping to the shape. The layer gets its own copy of the outline.
    func beginTextInShape(_ subpaths: [ShapeOutline.Subpath]) {
        guard canEditLayers, textDraft == nil, let document else { return }
        let padding = LayerTextStyle.padding
        let box = ShapeOutline.path(of: subpaths).boundingBoxOfPath
        let local = subpaths.map { $0.applying(CGAffineTransform(translationX: padding - box.minX, y: padding - box.minY)) }
        var style = textDefaults
        style.content = ""
        style.colorRuns = nil
        style.fontRuns = nil
        style.path = nil
        style.boxSize = CGSize(width: max(16, ceil(box.width + padding * 2)), height: max(16, ceil(box.height + padding * 2)))
        style.area = TextArea(subpaths: local)
        if !isMaskSelected {
            style.red = foregroundColor.red; style.green = foregroundColor.green; style.blue = foregroundColor.blue
        }
        guard style.isValid else { NSSound.beep(); return }
        tool = .type
        textDraft = TextDraft(documentID: document.id, layerID: nil,
                              origin: CGPoint(x: box.minX - padding, y: box.minY - padding), style: style)
    }
}
