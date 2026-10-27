import AppKit
import Testing
@testable import Pixegen

@MainActor
struct TextOnPathTests {
    private func makeSession() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 600, height: 400, emptyLayer: false)
        session.foregroundColor = PaletteColor(red: 0, green: 0, blue: 0)
        return session
    }
    @discardableResult
    private func draw(_ session: EditorSession, _ kind: ShapeKind, _ rect: CGRect) -> UUID {
        session.selectTool(.shape)
        session.shapeKind = kind
        session.beginShape(at: rect.origin)
        session.dragShape(to: CGPoint(x: rect.maxX, y: rect.maxY), square: false, fromCenter: false)
        session.finishShape()
        return session.activeLayerID!
    }
    /// Text typed along the path nearest `point`, committed.
    private func type(_ session: EditorSession, _ content: String, near point: CGPoint, size: CGFloat = 36) throws -> ImageLayer {
        session.selectTool(.type)
        let target = try #require(session.textPathTarget(at: point, tolerance: 8))
        session.beginTextOnPath(target.subpath, at: target.distance)
        var draft = try #require(session.textDraft)
        draft.style.content = content
        draft.style.fontSize = size
        #expect(session.applyText(draft))
        return try #require(session.activeLayer)
    }
    /// Where a letter's middle lands on the document.
    private func centers(_ layer: ImageLayer) throws -> [CGPoint] {
        let text = try #require(layer.liveText)
        let map = CGAffineTransform(scaleX: 1 / CGFloat(text.image.width), y: 1 / CGFloat(text.image.height))
            .concatenating(layer.transform.unitToDocument)
        return EditorSession.pathTextLayout(text.style).glyphs.map { letter in
            let box = CTFontGetBoundingRectsForGlyphs(letter.font, .default, [letter.glyph], nil, 1)
            return CGPoint(x: box.midX, y: box.midY).applying(letter.transform).applying(map)
        }
    }

    @Test func aClickNearAShapeFindsItsPath() {
        let session = makeSession()
        draw(session, .ellipse, CGRect(x: 100, y: 100, width: 200, height: 200))
        #expect(session.textPathTarget(at: CGPoint(x: 200, y: 103), tolerance: 8) != nil, "near the top of the circle")
        #expect(session.textPathTarget(at: CGPoint(x: 200, y: 200), tolerance: 8) == nil, "its middle is no path")
        session.workPath = CGPath(rect: CGRect(x: 400, y: 50, width: 100, height: 20), transform: nil)
        #expect(session.textPathTarget(at: CGPoint(x: 450, y: 52), tolerance: 8) != nil, "the work path too")
    }

    @Test func lettersStandOnTheOutsideOfACircle() throws {
        let session = makeSession()
        draw(session, .ellipse, CGRect(x: 100, y: 100, width: 200, height: 200))
        let layer = try type(session, "Around", near: CGPoint(x: 200, y: 100))
        #expect(layer.liveText?.style.path != nil)
        let middle = CGPoint(x: 200, y: 200)
        let points = try centers(layer)
        #expect(points.count == 6)
        for point in points {
            let distance = hypot(point.x - middle.x, point.y - middle.y)
            #expect(distance > 100 && distance < 100 + 36, "outside the circle, about a letter's height from it")
        }
    }

    @Test func theLettersAreDrawnWhereTheyAreLaidOut() throws {
        let session = makeSession()
        draw(session, .line, CGRect(x: 50, y: 300, width: 500, height: 0))
        let layer = try type(session, "IIII", near: CGPoint(x: 60, y: 300), size: 60)
        let text = try #require(layer.liveText)
        let context = try BrushRaster.copy(text.image)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let layout = EditorSession.pathTextLayout(text.style)
        // Each I's middle, in the layer's pixels, is painted; the same spot mirrored top to bottom is not.
        for letter in layout.glyphs {
            let box = CTFontGetBoundingRectsForGlyphs(letter.font, .default, [letter.glyph], nil, 1)
            let middle = CGPoint(x: box.midX, y: box.midY).applying(letter.transform)
            let x = Int(middle.x), y = Int(middle.y), mirrored = text.image.height - 1 - y
            #expect(bytes[(y * context.bytesPerRow / 4 + x) * 4 + 3] > 128)
            #expect(bytes[(mirrored * context.bytesPerRow / 4 + x) * 4 + 3] < 128)
        }
    }

    @Test func flippingPutsTheLettersOnTheOtherSide() throws {
        let session = makeSession()
        draw(session, .line, CGRect(x: 50, y: 200, width: 500, height: 0))
        let layer = try type(session, "Flip", near: CGPoint(x: 60, y: 200))
        #expect(try centers(layer).allSatisfy { $0.y < 200 }, "a line drawn left to right has its letters above it")
        session.flipTextPath()
        #expect(session.finishText())
        let flipped = try #require(session.activeLayer)
        let points = try centers(flipped)
        #expect(points.count == 4, "the same stretch of the line, so it all still fits")
        #expect(points.allSatisfy { $0.y > 200 })
        #expect(points.first!.x > points.last!.x, "read the other way")
    }

    @Test func textLongerThanItsPathStopsAtTheEnd() throws {
        let session = makeSession()
        draw(session, .line, CGRect(x: 50, y: 200, width: 100, height: 0))
        let layer = try type(session, "Much too long for this line", near: CGPoint(x: 55, y: 200))
        let style = try #require(layer.liveText?.style)
        let layout = EditorSession.pathTextLayout(style)
        #expect(layout.overflows)
        #expect(layout.glyphs.count < "Muchtoolongforthisline".count)
        #expect(try centers(layer).allSatisfy { $0.x >= 50 && $0.x <= 150 })
    }

    @Test func aBiggerFontKeepsThePathInPlace() throws {
        let session = makeSession()
        draw(session, .line, CGRect(x: 50, y: 200, width: 500, height: 0))
        let layer = try type(session, "Grow", near: CGPoint(x: 60, y: 200), size: 24)
        #expect(session.isOnTextPath(layer, at: CGPoint(x: 300, y: 200), tolerance: 1))
        session.editActiveText()
        session.changeTextStyle { $0.fontSize = 96 }
        #expect(session.finishText())
        let grown = try #require(session.activeLayer)
        #expect(grown.transform.size.height > layer.transform.size.height)
        #expect(session.isOnTextPath(grown, at: CGPoint(x: 300, y: 200), tolerance: 1))
    }

    @Test func pathTextConvertsToOutline() throws {
        let session = makeSession()
        draw(session, .ellipse, CGRect(x: 100, y: 100, width: 200, height: 200))
        let layer = try type(session, "Ring", near: CGPoint(x: 200, y: 100))
        session.selectTool(.move)
        session.convertTextToOutline()
        let shape = try #require(session.document?.layers.first { $0.id == layer.id })
        #expect(shape.liveShape != nil)
        // The outline's box sits outside the circle's top, where the letters were.
        #expect(shape.transform.origin.y < 100)
        #expect(shape.transform.origin.y + shape.transform.size.height > 90)
    }

    @Test func draggingTheTextSlidesItAlongItsPath() throws {
        let session = makeSession()
        draw(session, .line, CGRect(x: 50, y: 200, width: 500, height: 0))
        let layer = try type(session, "Slide", near: CGPoint(x: 100, y: 200))
        let before = try #require(layer.liveText?.style.path?.start)
        let first = try #require(try centers(layer).first)
        session.selectTool(.pathSelection)
        let count = session.history.undoCount
        // On the letters, just above the line.
        session.beginPathDrag(at: CGPoint(x: first.x, y: 190), tolerance: 5, extend: false)
        session.dragPath(to: CGPoint(x: first.x + 60, y: 192), breaksHandle: false)
        session.dragPath(to: CGPoint(x: first.x + 120, y: 190), breaksHandle: false)
        session.endPathDrag()
        let slid = try #require(session.activeLayer)
        #expect(abs(try #require(slid.liveText?.style.path?.start) - before - 120) < 1)
        #expect(slid.liveText?.style.path?.isFlipped == false)
        #expect(abs(try #require(try centers(slid).first).x - first.x - 120) < 1)
        #expect(slid.transform == layer.transform, "the layer stays where it was; only its letters move")
        #expect(session.history.undoCount == count + 1)
        session.undo()
        #expect(session.activeLayer?.liveText?.style.path?.start == before)
    }

    @Test func draggingAcrossThePathFlipsTheText() throws {
        let session = makeSession()
        draw(session, .line, CGRect(x: 50, y: 200, width: 500, height: 0))
        let layer = try type(session, "Over", near: CGPoint(x: 100, y: 200))
        let first = try #require(try centers(layer).first)
        session.selectTool(.pathSelection)
        session.beginPathDrag(at: CGPoint(x: first.x, y: 190), tolerance: 5, extend: false)
        session.dragPath(to: CGPoint(x: first.x, y: 199), breaksHandle: false)
        #expect(session.activeLayer?.liveText?.style.path?.isFlipped == false, "on the line isn't across it yet")
        session.dragPath(to: CGPoint(x: first.x, y: 215), breaksHandle: false)
        session.endPathDrag()
        let flipped = try #require(session.activeLayer)
        #expect(flipped.liveText?.style.path?.isFlipped == true)
        #expect(try centers(flipped).allSatisfy { $0.y > 200 })
    }

    @Test func slidingRoundAClosedPathWraps() throws {
        let path = TextPath(subpath: ShapeOutline.Subpath(closed: true, knots: [
            ShapeOutline.Knot(anchor: CGPoint(x: 0, y: 0)), ShapeOutline.Knot(anchor: CGPoint(x: 100, y: 0)),
            ShapeOutline.Knot(anchor: CGPoint(x: 100, y: 100)), ShapeOutline.Knot(anchor: CGPoint(x: 0, y: 100)),
        ]), start: 10)
        var slide = try #require(TextPathSlide(path, at: CGPoint(x: 10, y: -3)))
        // Back past the first point: a short step back, round to the end of the path.
        _ = slide.drag(to: CGPoint(x: 0, y: -3))
        let moved = slide.drag(to: CGPoint(x: -3, y: 20))
        #expect(abs(moved.start - 380) < 0.5)
        #expect(!moved.isFlipped, "outside the square is the letters' side all the way round")
    }

    @Test func directSelectionReshapesTheTextsPath() throws {
        let session = makeSession()
        draw(session, .line, CGRect(x: 50, y: 200, width: 300, height: 0))
        let layer = try type(session, "Bend", near: CGPoint(x: 60, y: 200))
        session.selectTool(.pathSelection)
        session.pathSelectionMode = .direct
        let knots = try #require(session.pathKnotsInDocument?.first?.knots)
        #expect(knots.count == 2)
        let end = knots[1].anchor, other = knots[0].anchor
        let count = session.history.undoCount
        // Select the far end, then drag it down and out.
        session.beginPathDrag(at: end, tolerance: 5, extend: false)
        session.endPathDrag()
        session.beginPathDrag(at: end, tolerance: 5, extend: false)
        session.dragPath(to: CGPoint(x: end.x + 100, y: end.y + 150), breaksHandle: false)
        session.endPathDrag()
        let bent = try #require(session.activeLayer)
        #expect(bent.liveText?.style.path != layer.liveText?.style.path)
        let moved = try #require(session.pathKnotsInDocument?.first?.knots)
        #expect(hypot(moved[1].anchor.x - end.x - 100, moved[1].anchor.y - end.y - 150) < 0.5, "the point follows the pointer")
        #expect(hypot(moved[0].anchor.x - other.x, moved[0].anchor.y - other.y) < 0.5, "the other end stays where it was")
        #expect(bent.transform.size.height > layer.transform.size.height, "the layer grows round the longer path")
        // The letters follow the path down its slope.
        let points = try centers(bent)
        #expect(points.count == 4)
        #expect(points.last!.y > points.first!.y)
        #expect(session.history.undoCount <= count + 2)
        session.undo()
        #expect(session.activeLayer?.liveText?.style.path == layer.liveText?.style.path)
    }

    @Test func deletingAPointLeavesTheTextAPath() throws {
        let session = makeSession()
        draw(session, .line, CGRect(x: 50, y: 200, width: 300, height: 0))
        _ = try type(session, "Two", near: CGPoint(x: 60, y: 200))
        session.selectTool(.pathSelection)
        session.pathSelectionMode = .direct
        let knots = try #require(session.pathKnotsInDocument?.first?.knots)
        session.beginPathDrag(at: knots[1].anchor, tolerance: 5, extend: false)
        session.endPathDrag()
        session.deleteSelectedPathKnots()
        #expect(session.activeLayer?.liveText?.style.path?.subpath.knots.count == 2, "a line's two ends are all it has")
    }

    @Test func savesAsVersion21AndReopens() async throws {
        let session = makeSession()
        draw(session, .ellipse, CGRect(x: 100, y: 100, width: 200, height: 200))
        let layer = try type(session, "Saved", near: CGPoint(x: 200, y: 100))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TextOnPathTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Path.pbox")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.version == 21)
        let saved = try #require(loaded.manifest.layers.first { $0.id == layer.id }?.text)
        // Knots are saved to a millionth, so they come back close rather than equal.
        let path = try #require(saved.path), original = try #require(layer.liveText?.style.path)
        #expect(path.subpath.knots.count == original.subpath.knots.count)
        #expect(zip(path.subpath.knots, original.subpath.knots).allSatisfy {
            hypot($0.anchor.x - $1.anchor.x, $0.anchor.y - $1.anchor.y) < 0.001
        })
        #expect(path.start == original.start)

        var older = loaded.manifest
        older.version = 20
        try JSONEncoder().encode(older).write(to: url.appendingPathComponent("manifest.json"))
        await #expect(throws: (any Error).self) { _ = try await ProjectStore.shared.load(from: url) }
    }
}
