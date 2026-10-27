import AppKit
import Testing
@testable import Pixegen

@MainActor
struct TextAreaTests {
    private func makeSession() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 600, height: 400, emptyLayer: false)
        session.foregroundColor = PaletteColor(red: 0, green: 0, blue: 0)
        return session
    }
    private func draw(_ session: EditorSession, _ kind: ShapeKind, _ rect: CGRect) {
        session.selectTool(.shape)
        session.shapeKind = kind
        session.beginShape(at: rect.origin)
        session.dragShape(to: CGPoint(x: rect.maxX, y: rect.maxY), square: false, fromCenter: false)
        session.finishShape()
    }
    /// Text typed inside the shape under `point`, committed.
    private func type(_ session: EditorSession, _ content: String, in point: CGPoint, size: CGFloat = 24) throws -> ImageLayer {
        session.selectTool(.type)
        let shape = try #require(session.textAreaTarget(at: point))
        session.beginTextInShape(shape)
        var draft = try #require(session.textDraft)
        draft.style.content = content
        draft.style.fontSize = size
        #expect(session.applyText(draft))
        return try #require(session.activeLayer)
    }
    /// The document pixels the text layer paints more than half opaque.
    private func painted(_ layer: ImageLayer) throws -> [CGPoint] {
        let image = try #require(layer.liveText?.image)
        let context = try BrushRaster.copy(image)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let map = CGAffineTransform(scaleX: 1 / CGFloat(image.width), y: 1 / CGFloat(image.height))
            .concatenating(layer.transform.unitToDocument)
        var points: [CGPoint] = []
        for y in 0..<image.height {
            for x in 0..<image.width where bytes[(y * context.bytesPerRow / 4 + x) * 4 + 3] > 128 {
                points.append(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(map))
            }
        }
        return points
    }

    @Test func aClickInsideAClosedShapeFindsIt() {
        let session = makeSession()
        draw(session, .ellipse, CGRect(x: 100, y: 100, width: 200, height: 200))
        #expect(session.textAreaTarget(at: CGPoint(x: 200, y: 200)) != nil)
        #expect(session.textAreaTarget(at: CGPoint(x: 105, y: 105)) == nil, "the circle's box corner is outside it")
        draw(session, .line, CGRect(x: 350, y: 50, width: 200, height: 200))
        #expect(session.textAreaTarget(at: CGPoint(x: 450, y: 150)) == nil, "a line holds nothing")
    }

    @Test func textWrapsInsideTheShape() throws {
        let session = makeSession()
        draw(session, .ellipse, CGRect(x: 100, y: 100, width: 200, height: 200))
        let words = Array(repeating: "wrap", count: 30).joined(separator: " ")
        let layer = try type(session, words, in: CGPoint(x: 200, y: 200))
        #expect(layer.liveText?.style.area != nil)
        let points = try painted(layer)
        #expect(points.count > 500)
        // Every letter inside the circle, give or take antialiasing.
        let outside = points.filter { hypot($0.x - 200, $0.y - 200) > 101 }
        #expect(outside.isEmpty, "\(outside.count) pixels outside the circle")
        // Wrapping to the circle: the widest line is in the middle, and the top line is narrower.
        let rows = Dictionary(grouping: points) { Int($0.y / 20) }
        let widths = rows.mapValues { row in (row.map(\.x).max() ?? 0) - (row.map(\.x).min() ?? 0) }
        let top = try #require(widths.keys.min())
        let topWidth = try #require(widths[top]), middleWidth = try #require(widths[10])
        #expect(middleWidth > topWidth + 20)
    }

    @Test func textInAShapeConvertsToOutline() throws {
        let session = makeSession()
        draw(session, .rectangle, CGRect(x: 100, y: 100, width: 200, height: 100))
        let layer = try type(session, "Boxed in", in: CGPoint(x: 200, y: 150))
        session.selectTool(.move)
        session.convertTextToOutline()
        let shape = try #require(session.document?.layers.first { $0.id == layer.id })
        #expect(shape.liveShape != nil)
        #expect(shape.transform.origin.x >= 99 && shape.transform.origin.y >= 99)
    }

    @Test func theNextTextStartsAsPointText() throws {
        let session = makeSession()
        draw(session, .rectangle, CGRect(x: 100, y: 100, width: 200, height: 100))
        _ = try type(session, "Inside", in: CGPoint(x: 200, y: 150))
        session.beginText(at: CGPoint(x: 450, y: 350), newLayer: true)
        let draft = try #require(session.textDraft)
        #expect(draft.style.area == nil && draft.style.path == nil && draft.style.boxSize == nil)
    }

    @Test func savesAsVersion22AndReopens() async throws {
        let session = makeSession()
        draw(session, .ellipse, CGRect(x: 100, y: 100, width: 200, height: 200))
        let layer = try type(session, "Kept", in: CGPoint(x: 200, y: 200))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TextAreaTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Area.pbox")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.version == ProjectManifest.current)
        let saved = try #require(loaded.manifest.layers.first { $0.id == layer.id }?.text?.area)
        #expect(saved.subpaths.count == layer.liveText?.style.area?.subpaths.count)

        var older = loaded.manifest
        older.version = 21
        try JSONEncoder().encode(older).write(to: url.appendingPathComponent("manifest.json"))
        await #expect(throws: (any Error).self) { _ = try await ProjectStore.shared.load(from: url) }
    }
}
