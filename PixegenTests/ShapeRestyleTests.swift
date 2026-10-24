import AppKit
import Testing
@testable import Pixegen

/// A shape layer's fill, stroke and other settings changed after it's drawn, from the tool bar.
@MainActor
struct ShapeRestyleTests {
    private func makeSession() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 100, height: 80, emptyLayer: true)
        session.selectTool(.shape)
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        return session
    }
    private func draw(_ session: EditorSession, _ kind: ShapeKind, from start: CGPoint, to end: CGPoint) {
        session.shapeKind = kind
        session.beginShape(at: start)
        session.dragShape(to: end, square: false, fromCenter: false)
        session.finishShape()
    }
    private func anchors(_ session: EditorSession) -> [CGPoint] {
        session.pathKnotsInDocument?.flatMap { $0.knots.map(\.anchor) } ?? []
    }
    private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) <= 0.5 }
    private func pixel(_ session: EditorSession, _ x: Int, _ y: Int) async throws -> (red: Int, green: Int, blue: Int, alpha: Int) {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let at = (y * image.width + x) * 4
        return (Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2]), Int(bytes[at + 3]))
    }

    @Test func theBarEditsTheSelectedShapeOnlyWithTheShapeOrPathSelectionTool() {
        let session = makeSession()
        draw(session, .rectangle, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 30))
        #expect(session.shapeBarLayer?.id == session.activeLayerID)
        session.selectTool(.pathSelection)
        #expect(session.shapeBarLayer != nil)
        session.selectTool(.brush)
        #expect(session.shapeBarLayer == nil)
        session.restyleShape("Fill") { $0.filled = false }
        #expect(session.activeLayer?.liveShape?.style.filled == nil, "nothing to edit with another tool")
    }

    @Test func changingTheFillColorRedrawsTheShapeAsOneUndoStep() async throws {
        let session = makeSession()
        draw(session, .rectangle, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 30))
        let count = session.history.undoCount
        session.restyleShape("Fill Color") { $0.red = 0; $0.green = 0; $0.blue = 1 }
        #expect(session.history.undoCount == count + 1)
        let blue = try await pixel(session, 25, 20)
        #expect(blue.red == 0 && blue.blue == 255 && blue.alpha == 255)
        #expect(session.activeLayer?.liveShape != nil, "still a shape")
        session.undo()
        #expect(try await pixel(session, 25, 20).red == 255)
    }

    @Test func turningOnAStrokeGrowsTheLayerAroundAnOutlineThatStaysPut() async throws {
        let session = makeSession()
        draw(session, .rectangle, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 30))
        let before = anchors(session)
        session.restyleShape("Stroke") { $0.stroke = ShapeStroke(color: PaletteColor(red: 0, green: 0, blue: 1), width: 4,
                                                                 options: ShapeStrokeOptions(join: .round)) }
        #expect(session.activeLayer?.transform.origin == CGPoint(x: 8, y: 8)
                && session.activeLayer?.transform.size == CGSize(width: 34, height: 24))
        for (old, new) in zip(before, anchors(session)) { #expect(near(old, new)) }
        #expect(try await pixel(session, 9, 20).blue == 255, "the stroke straddles the edge")
        session.restyleShape("Stroke") { $0.stroke = nil }
        #expect(session.activeLayer?.transform.size == CGSize(width: 30, height: 20))
    }

    @Test func changingOneValueAgainAndAgainIsOneUndoStep() {
        let session = makeSession()
        draw(session, .rectangle, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 30))
        session.restyleShape("Stroke") { $0.stroke = ShapeStroke(color: .black, width: 2) }
        let count = session.history.undoCount
        for width in [3, 4, 5, 6] as [CGFloat] { session.restyleShape("Stroke Width") { $0.stroke?.width = width } }
        #expect(session.history.undoCount == count + 1, "dragging the width is one step")
        session.restyleShape("Corner Radius") { $0.cornerRadius = 4 }
        #expect(session.history.undoCount == count + 2, "another setting is another step")
        session.undo()
        session.undo()
        #expect(session.activeLayer?.liveShape?.style.stroke?.width == 2)
    }

    @Test func aPolygonTakesNewSidesAndALineANewWeightWithItsEndsInPlace() {
        let session = makeSession()
        draw(session, .polygon, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 50))
        session.restyleShape("Sides") { $0.sides = 8 }
        #expect(anchors(session).count == 8)
        draw(session, .line, from: CGPoint(x: 20, y: 60), to: CGPoint(x: 80, y: 70))
        let ends = anchors(session)
        session.restyleShape("Line Weight") { $0.lineWidth = 12 }
        #expect(session.activeLayer?.liveShape?.style.lineWidth == 12)
        for (old, new) in zip(ends, anchors(session)) { #expect(near(old, new)) }
    }

    @Test func aRotatedShapesStrokeKeepsItsOutlineWhereItIs() throws {
        let session = makeSession()
        draw(session, .rectangle, from: CGPoint(x: 30, y: 20), to: CGPoint(x: 70, y: 50))
        let index = try #require(session.document?.layers.firstIndex { $0.id == session.activeLayerID })
        session.document?.layers[index].transform.rotation = 30
        let before = anchors(session)
        session.restyleShape("Stroke") { $0.stroke = ShapeStroke(color: .black, width: 6) }
        for (old, new) in zip(before, anchors(session)) { #expect(near(old, new)) }
        #expect(abs((session.activeLayer?.transform.rotation ?? 0) - 30) < 0.001)
    }

    @Test func aSelectedCustomShapeTakesAnotherFromTheLibrary() throws {
        let session = makeSession()
        let shapes = ShapeLibrary.defaultGroup().shapes
        session.customShape = shapes[0]
        draw(session, .custom, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 50))
        session.restyleShape("Custom Shape") { $0.outline = shapes[1].outline; $0.customName = shapes[1].name }
        #expect(session.activeLayer?.liveShape?.style.customName == shapes[1].name)
        #expect(session.activeLayer?.transform.size == CGSize(width: 40, height: 40), "in the box it had")
    }
}
