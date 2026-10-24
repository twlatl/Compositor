import AppKit
import Testing
@testable import Pixegen

@MainActor
struct PathSelectionTests {
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
    private func drag(_ session: EditorSession, from start: CGPoint, to end: CGPoint, extend: Bool = false, breaksHandle: Bool = false) {
        session.beginPathDrag(at: start, tolerance: 3, extend: extend)
        session.dragPath(to: end, breaksHandle: breaksHandle)
        session.endPathDrag()
    }
    private func anchors(_ session: EditorSession) -> [CGPoint] {
        session.pathKnotsInDocument?.flatMap { $0.knots.map(\.anchor) } ?? []
    }
    private func near(_ a: CGPoint, _ b: CGPoint, within tolerance: CGFloat = 0.5) -> Bool { hypot(a.x - b.x, a.y - b.y) <= tolerance }
    /// Whether the flattened document has a visible pixel at a point.
    private func covered(_ session: EditorSession, _ x: Int, _ y: Int) async throws -> Bool {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return bytes[(y * image.width + x) * 4 + 3] > 128
    }

    @Test func aRectanglesPathIsItsFourCorners() {
        let session = makeSession()
        draw(session, .rectangle, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 30))
        session.selectTool(.pathSelection)
        let points = anchors(session)
        #expect(points.count == 4)
        for corner in [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 10), CGPoint(x: 40, y: 30), CGPoint(x: 10, y: 30)] {
            #expect(points.contains { near($0, corner) }, "a corner at \(corner)")
        }
        #expect(session.shownPathKnots.count == 4, "Path Selection selects the whole path")
    }

    @Test func directSelectionMovesOneCornerAsOneUndoStep() async throws {
        let session = makeSession()
        draw(session, .rectangle, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 30))
        session.selectTool(.pathSelection)
        session.pathSelectionMode = .direct
        let count = session.history.undoCount
        #expect(try await !covered(session, 44, 34))
        drag(session, from: CGPoint(x: 40, y: 30), to: CGPoint(x: 50, y: 40))
        #expect(session.history.undoCount == count + 1)
        let style = try #require(session.activeLayer?.liveShape?.style)
        #expect(style.kind == .custom, "a rectangle with a moved corner is a path")
        #expect(session.activeLayer?.transform.origin == CGPoint(x: 10, y: 10)
                && session.activeLayer?.transform.size == CGSize(width: 40, height: 30))
        let points = anchors(session)
        #expect(points.contains { near($0, CGPoint(x: 50, y: 40)) } && points.contains { near($0, CGPoint(x: 10, y: 10)) })
        #expect(try await covered(session, 44, 34))
        session.undo()
        #expect(session.activeLayer?.liveShape?.style.kind == .rectangle)
    }

    @Test func pathSelectionDragsTheWholeShapeAndClickingAnotherSelectsIt() {
        let session = makeSession()
        draw(session, .rectangle, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 30))
        let first = session.activeLayerID
        draw(session, .ellipse, from: CGPoint(x: 60, y: 40), to: CGPoint(x: 90, y: 70))
        session.selectTool(.pathSelection)
        drag(session, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 25, y: 22))
        #expect(session.activeLayerID == first, "clicking a shape selects its layer")
        #expect(session.activeLayer?.transform.origin == CGPoint(x: 15, y: 12))
        #expect(session.activeLayer?.liveShape?.style.kind == .rectangle, "moving keeps it a rectangle")
        session.beginPathDrag(at: CGPoint(x: 50, y: 5), tolerance: 3, extend: false)
        #expect(session.pathDrag == nil, "nothing there")
    }

    @Test func aSmoothPointsHandlesTurnTogetherUnlessOptionBreaksThem() throws {
        let session = makeSession()
        draw(session, .ellipse, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 60, y: 60))
        session.selectTool(.pathSelection)
        session.pathSelectionMode = .direct
        let knots = try #require(session.pathKnotsInDocument)
        let index = try #require(knots[0].knots.firstIndex { near($0.anchor, CGPoint(x: 40, y: 20)) })
        let top = knots[0].knots[index]
        session.beginPathDrag(at: top.anchor, tolerance: 3, extend: false)
        session.endPathDrag()
        #expect(session.selectedPathKnots == [PathKnot(subpath: 0, knot: index)])
        drag(session, from: top.outgoing, to: CGPoint(x: top.outgoing.x, y: top.outgoing.y - 8))
        let turned = try #require(session.pathKnotsInDocument?[0].knots[index])
        #expect(EditorSession.isSmooth(turned), "the other handle follows")
        #expect(near(turned.anchor, top.anchor))
        let before = turned.incoming
        drag(session, from: turned.outgoing, to: CGPoint(x: turned.outgoing.x, y: turned.outgoing.y + 16), breaksHandle: true)
        let broken = try #require(session.pathKnotsInDocument?[0].knots[index])
        #expect(near(broken.incoming, before), "Option leaves the other handle where it was")
        #expect(!EditorSession.isSmooth(broken))
    }

    @Test func deletingAPointLeavesTheRest() {
        let session = makeSession()
        draw(session, .rectangle, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 30))
        session.selectTool(.pathSelection)
        session.pathSelectionMode = .direct
        session.beginPathDrag(at: CGPoint(x: 40, y: 30), tolerance: 3, extend: false)
        session.endPathDrag()
        session.deleteSelectedPathKnots()
        #expect(anchors(session).count == 3)
        #expect(session.activeLayer?.transform.size == CGSize(width: 30, height: 20), "the triangle left fills the same box")
    }

    @Test func aLineKeepsBeingALineThroughItsMovedEnd() throws {
        let session = makeSession()
        session.shapeLineWidth = 4
        draw(session, .line, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 10))
        session.selectTool(.pathSelection)
        session.pathSelectionMode = .direct
        #expect(anchors(session).count == 2)
        drag(session, from: CGPoint(x: 50, y: 10), to: CGPoint(x: 50, y: 40))
        #expect(session.activeLayer?.liveShape?.style.kind == .line)
        let points = anchors(session)
        #expect(near(points[0], CGPoint(x: 10, y: 10)) && near(points[1], CGPoint(x: 50, y: 40)))
    }

    @Test func movingAPointOfARotatedShapeLeavesTheOthersWhereTheyAre() throws {
        let session = makeSession()
        draw(session, .rectangle, from: CGPoint(x: 30, y: 20), to: CGPoint(x: 70, y: 50))
        let index = try #require(session.document?.layers.firstIndex { $0.id == session.activeLayerID })
        session.document?.layers[index].transform.rotation = 30
        session.selectTool(.pathSelection)
        session.pathSelectionMode = .direct
        let before = anchors(session)
        let moved = before[2]
        drag(session, from: moved, to: CGPoint(x: moved.x + 6, y: moved.y + 4))
        let after = anchors(session)
        #expect(after.count == 4)
        for (old, new) in zip(before, after) where old != moved { #expect(near(old, new), "\(old) stays put") }
        #expect(near(after[2], CGPoint(x: moved.x + 6, y: moved.y + 4)))
        #expect(abs((session.activeLayer?.transform.rotation ?? 0) - 30) < 0.001, "still turned as it was")
    }

    @Test func aWithShiftSwitchesModesAndPathSelectionOwnsA() {
        let session = makeSession()
        session.selectTool(.pathSelection)
        #expect(session.pathSelectionMode == .path)
        session.togglePathSelectionMode()
        #expect(session.pathSelectionMode == .direct)
        session.cycleToolMode()
        #expect(session.pathSelectionMode == .path)
    }
}
