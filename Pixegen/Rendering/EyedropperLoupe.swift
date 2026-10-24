import AppKit

/// The eyedropper's magnifier: the canvas pixels around the pointer, enlarged in a circle, with the one that would be
/// picked outlined in the middle and its color in a ring around them. Display only; clicks pass through.
final class EyedropperLoupe: NSView {
    /// The pixels around the sampled one, `EditorSession.loupeRadius` on each side, as composited on the canvas.
    var patch: CGImage?
    var color: PaletteColor?
    static let diameter: CGFloat = 112
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows the loupe above and to the right of `point` (view points), staying inside `area`.
    func show(at point: CGPoint, in area: CGRect) {
        let size = Self.diameter
        var origin = CGPoint(x: point.x + 18, y: point.y - size - 18)
        if origin.x + size > area.maxX { origin.x = point.x - size - 18 }
        if origin.y < area.minY { origin.y = point.y + 18 }
        frame = CGRect(origin: origin, size: CGSize(width: size, height: size))
        isHidden = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let circle = bounds.insetBy(dx: 4, dy: 4)
        let inner = circle.insetBy(dx: 6, dy: 6)
        // The ring: the sampled color, edged so it reads on any background.
        context.setFillColor(NSColor(white: 0.2, alpha: 1).cgColor)
        context.fillEllipse(in: circle.insetBy(dx: -1, dy: -1))
        context.setFillColor((color?.nsColor ?? .clear).cgColor)
        context.fillEllipse(in: circle)
        context.saveGState()
        context.addEllipse(in: inner)
        context.clip()
        context.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
        context.fill(inner)
        if let patch {
            // Hard-edged pixels, top row at the top: the view is flipped, so the image is drawn upside down into it.
            context.interpolationQuality = .none
            context.saveGState()
            context.translateBy(x: inner.minX, y: inner.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(patch, in: CGRect(origin: .zero, size: inner.size))
            context.restoreGState()
            let cell = inner.width / CGFloat(patch.width)
            let middle = CGRect(x: inner.minX + cell * CGFloat(patch.width / 2), y: inner.minY + cell * CGFloat(patch.height / 2),
                                width: cell, height: cell)
            context.setLineWidth(1)
            context.setStrokeColor(NSColor.black.cgColor)
            context.stroke(middle.insetBy(dx: -1, dy: -1))
            context.setStrokeColor(NSColor.white.cgColor)
            context.stroke(middle)
        }
        context.restoreGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: inner)
    }
}

extension EditorSession {
    /// Pixels the eyedropper's magnifier shows on each side of the one under the pointer.
    static let loupeRadius = 5

    /// The canvas as composited around a document pixel, `loupeRadius` pixels on each side, for the magnifier.
    /// Outside the canvas is transparent.
    func compositePatch(around point: CGPoint) -> CGImage? {
        guard let document, point.x.isFinite, point.y.isFinite, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let radius = Self.loupeRadius, side = radius * 2 + 1
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // The renderer's top-left space, the pointer's pixel in the middle.
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -(point.x.rounded(.down) - CGFloat(radius)), y: -(point.y.rounded(.down) - CGFloat(radius)))
        context.clip(to: CGRect(origin: .zero, size: document.size))
        drawLiveComposite(document, in: context)
        return context.makeImage()
    }
}
