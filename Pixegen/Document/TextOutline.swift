import AppKit

extension EditorSession {
    /// A text layer's letters as outlines, in the layer's own pixels (y down), laid out exactly as `textImage` draws
    /// them: one path for each color, in the order the colors first come, with the letters that wear it. Letters
    /// without an outline (spaces, emoji) add nothing.
    static func textOutlines(_ style: LayerTextStyle) -> [(color: PaletteColor, letters: String, path: CGPath)] {
        guard style.isValid else { return [] }
        let padding = LayerTextStyle.padding
        let size = textBoxSize(style)
        let storage = NSTextStorage(attributedString: attributedText(style))
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, ceil(size.width) - 2 * padding),
                                                     height: max(1, ceil(size.height) - 2 * padding)))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let content = storage.string as NSString
        var groups: [(color: PaletteColor, letters: String, path: CGMutablePath)] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { line, _, _, glyphs, _ in
            for index in glyphs.location..<NSMaxRange(glyphs) {
                let property = layout.propertyForGlyph(at: index)
                guard !property.contains(.null), !property.contains(.controlCharacter) else { continue }
                let character = layout.characterIndexForGlyph(at: index)
                // The face the layout settled on, a fallback for a letter the chosen one lacks included.
                guard let font = storage.attribute(.font, at: character, effectiveRange: nil) as? NSFont else { continue }
                let at = layout.location(forGlyphAt: index)
                // Font outlines run y up from the baseline; the layer's pixels run y down.
                var place = CGAffineTransform(translationX: padding + line.minX + at.x, y: padding + line.minY + at.y)
                    .scaledBy(x: 1, y: -1)
                guard let glyph = CTFontCreatePathForGlyph(font as CTFont, layout.cgGlyph(at: index), &place),
                      !glyph.isEmpty else { continue }
                let shown = (storage.attribute(.foregroundColor, at: character, effectiveRange: nil) as? NSColor)?
                    .usingColorSpace(.sRGB) ?? .black
                let color = PaletteColor(red: min(1, max(0, shown.redComponent)), green: min(1, max(0, shown.greenComponent)),
                                         blue: min(1, max(0, shown.blueComponent)))
                let letter = content.substring(with: NSRange(location: character, length: 1))
                if let group = groups.firstIndex(where: { $0.color == color }) {
                    groups[group].path.addPath(glyph)
                    groups[group].letters += letter
                } else {
                    let path = CGMutablePath()
                    path.addPath(glyph)
                    groups.append((color, letter, path))
                }
            }
        }
        return groups.map { ($0.color, $0.letters, $0.path) }
    }

    /// The active layer when it's text that Convert to Outline can turn into shapes.
    var outlineTextLayer: ImageLayer? {
        guard canEditLayers, textDraft == nil, let layer = activeLayer, layer.liveText != nil else { return nil }
        return layer
    }

    var canConvertTextToOutline: Bool { outlineTextLayer != nil }

    /// Turns the active text layer into a shape of its letters filled with the text's color, in its place, as one
    /// undo step. Text in several colors becomes a folder of one shape per color. The shapes keep the layer's name,
    /// opacity, blend mode, effects, mask and clipping; turned or flipped text comes out as it looked, as upright
    /// shapes.
    func convertTextToOutline() {
        guard let layer = outlineTextLayer, let text = layer.liveText, let document else { return }
        let width = CGFloat(text.image.width), height = CGFloat(text.image.height)
        var map = CGAffineTransform(scaleX: 1 / width, y: 1 / height).concatenating(layer.transform.unitToDocument)
        let outlines = Self.textOutlines(text.style)
        guard !outlines.isEmpty else {
            brushError = "That text has no letters with outlines to convert."
            return
        }
        var shapes: [ImageLayer] = []
        for outline in outlines {
            guard let placed = outline.path.copy(using: &map)?.normalized(using: .winding),
                  let knots = ShapeOutline(path: placed) else { continue }
            let box = placed.boundingBoxOfPath
            let size = CGSize(width: max(1, box.width.rounded()), height: max(1, box.height.rounded()))
            guard Int(size.width) * Int(size.height) <= Self.maxShapePixels else {
                brushError = "That text is too large to outline. A shape can cover up to \(DocumentLimits.maxSurfaceMegapixels) megapixels."
                return
            }
            var style = LayerShapeStyle(kind: .custom, red: outline.color.red, green: outline.color.green,
                                        blue: outline.color.blue, cornerRadius: 0)
            style.outline = knots
            guard let image = try? Self.shapeImage(style, size: size), let thumbnail = try? PixelInvert.thumbnail(of: image),
                  let asset = layer.asset else { NSSound.beep(); return }
            let pixels = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
            // One shape is the text layer itself, so whatever refers to it still does; several are new layers.
            var shape = layer
            if outlines.count > 1 {
                shape = ImageLayer(asset: pixels, origin: box.origin)
                shape.name = Self.layerName(for: outline.letters)
                shape.blendMode = layer.blendMode
                shape.effects = layer.effects
                shape.mask = layer.mask
            }
            shape.asset = pixels
            shape.shape = LayerShape(style: style, image: image)
            shape.text = nil
            var transform = LayerTransform(origin: box.origin, size: size)
            transform.sampling = layer.transform.sampling
            shape.transform = transform
            // A mask that covered the text's box stays where it was on the document.
            if layer.mask != nil, layer.mask?.placement == nil { shape.mask?.placement = layer.maskTransform }
            shapes.append(shape)
        }
        guard shapes.count == outlines.count, let index = document.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        var next = document.layers
        if shapes.count == 1 {
            next[index] = shapes[0]
        } else {
            // A folder in the text's place, which takes its name, visibility and opacity; the shapes inside it, in
            // the order their colors first come, bottom to top.
            var folder = ImageLayer(name: layer.name, blankSize: document.size)
            folder.isGroup = true
            folder.parentID = layer.parentID
            folder.isVisible = layer.isVisible
            folder.opacity = layer.opacity
            next[index] = folder
            next.insert(contentsOf: shapes.map { shape in
                var child = shape
                child.parentID = folder.id
                return child
            }, at: index + 1)
            for i in next.indices where next[i].maskSourceID == layer.id { next[i].maskSourceID = nil }
            Self.releaseDetachedClipping(in: &next)
        }
        guard (try? LayerHierarchy.validate(next.map(\.hierarchyRecord))) != nil else { NSSound.beep(); return }
        commitTransform()
        finishOpacityEdit()
        beginEdit("Convert to Outline")
        self.document?.layers = next
        activeLayerID = next[index].id
        selectedLayerIDs = [next[index].id]
        endEdit()
    }
}
