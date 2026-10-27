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
