import AppKit
import Testing
@testable import Pixegen

@MainActor
struct PenToolTests {
    private func makeSession(_ mode: PenMode = .pen) -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 120, height: 100, emptyLayer: true)
        session.selectTool(.pen)
        session.penMode = mode
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        return session
    }
    private func click(_ session: EditorSession, _ point: CGPoint, count: Int = 1) {
        session.beginPen(at: point, tolerance: 3, constrain: false, clickCount: count)
        session.endPen(tolerance: 1)
    }
    private func drag(_ session: EditorSession, from start: CGPoint, to end: CGPoint, breaksHandle: Bool = false) {
        session.beginPen(at: start, tolerance: 3, constrain: false, clickCount: 1)
        session.dragPen(to: end, constrain: false, breaksHandle: breaksHandle, threshold: 1, spacing: 1)
        session.endPen(tolerance: 1)
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
    private func triangle(_ session: EditorSession) {
        click(session, CGPoint(x: 10, y: 10))
        click(session, CGPoint(x: 50, y: 10))
        click(session, CGPoint(x: 30, y: 40))
        click(session, CGPoint(x: 10, y: 10))
    }

    // MARK: Pen

    @Test func clickingCornersAndTheFirstPointAgainMakesAShapeLayerInOneStep() async throws {
        let session = makeSession()
        let layers = session.document?.layers.count ?? 0
        let count = session.history.undoCount
        triangle(session)
        #expect(session.penDraft == nil, "clicking the first point finishes the path")
        #expect(session.document?.layers.count == layers + 1)
        #expect(session.history.undoCount == count + 1)
        #expect(session.activeLayer?.name == "Shape 1")
        let style = try #require(session.activeLayer?.liveShape?.style)
        #expect(style.kind == .custom && style.customName == nil)
        #expect(style.outline?.subpaths.first?.closed == true)
        let points = anchors(session)
        #expect(points.count == 3)
        for corner in [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10), CGPoint(x: 30, y: 40)] {
            #expect(points.contains { near($0, corner) }, "a corner at \(corner)")
        }
        #expect(try await covered(session, 30, 20))
        #expect(try await !covered(session, 12, 35))
    }

    @Test func draggingMakesASmoothPointAndOptionBreaksItsHandle() throws {
        let session = makeSession()
        click(session, CGPoint(x: 10, y: 50))
        drag(session, from: CGPoint(x: 50, y: 20), to: CGPoint(x: 70, y: 20))
        var knot = try #require(session.penDraft?.knots.last)
        #expect(knot.outgoing == CGPoint(x: 70, y: 20))
        #expect(knot.incoming == CGPoint(x: 30, y: 20), "the incoming handle mirrors the one dragged")
        session.beginPen(at: CGPoint(x: 90, y: 50), tolerance: 3, constrain: false, clickCount: 1)
        session.dragPen(to: CGPoint(x: 100, y: 60), constrain: false, breaksHandle: false, threshold: 1, spacing: 1)
        session.dragPen(to: CGPoint(x: 90, y: 80), constrain: false, breaksHandle: true, threshold: 1, spacing: 1)
        session.endPen(tolerance: 1)
        knot = try #require(session.penDraft?.knots.last)
        #expect(knot.outgoing == CGPoint(x: 90, y: 80))
        #expect(knot.incoming == CGPoint(x: 80, y: 40), "Option leaves the incoming handle where it was")
    }

    @Test func aClickWithALittleWobbleIsStillACorner() throws {
        let session = makeSession()
        click(session, CGPoint(x: 10, y: 10))
        session.beginPen(at: CGPoint(x: 40, y: 10), tolerance: 3, constrain: false, clickCount: 1)
        session.dragPen(to: CGPoint(x: 40.5, y: 10.5), constrain: false, breaksHandle: false, threshold: 2, spacing: 1)
        session.endPen(tolerance: 1)
        let knot = try #require(session.penDraft?.knots.last)
        #expect(knot.outgoing == knot.anchor && knot.incoming == knot.anchor)
    }

    @Test func shiftKeepsSegmentsToEighthsOfATurn() throws {
        let session = makeSession()
        click(session, CGPoint(x: 10, y: 10))
        session.beginPen(at: CGPoint(x: 50, y: 14), tolerance: 3, constrain: true, clickCount: 1)
        session.endPen(tolerance: 1)
        let point = try #require(session.penDraft?.knots.last?.anchor)
        #expect(abs(point.y - 10) < 0.001, "flat, not 4 pixels down")
    }

    @Test func returnLeavesThePathOpenAndDeleteTakesBackThePoint() throws {
        let session = makeSession()
        click(session, CGPoint(x: 10, y: 10))
        click(session, CGPoint(x: 50, y: 10))
        click(session, CGPoint(x: 99, y: 99))
        session.removeLastPenPoint()
        #expect(session.penDraft?.knots.count == 2)
        click(session, CGPoint(x: 30, y: 40))
        session.finishPen()
        #expect(session.penDraft == nil)
        let outline = try #require(session.activeLayer?.liveShape?.style.outline)
        #expect(outline.subpaths.first?.closed == false)
        #expect(anchors(session).count == 3, "an open path is filled across its gap, and keeps three points")
    }

    @Test func escapeAndDeletingEveryPointLeaveNothing() {
        let session = makeSession()
        let layers = session.document?.layers.count ?? 0
        click(session, CGPoint(x: 10, y: 10))
        click(session, CGPoint(x: 50, y: 10))
        session.cancelPen()
        #expect(session.penDraft == nil)
        click(session, CGPoint(x: 10, y: 10))
        session.removeLastPenPoint()
        #expect(session.penDraft == nil)
        #expect(session.document?.layers.count == layers)
    }

    @Test func pathModeMakesTheWorkPathNotALayer() {
        let session = makeSession()
        session.penOutput = .path
        let layers = session.document?.layers.count ?? 0
        triangle(session)
        #expect(session.document?.layers.count == layers)
        let box = session.workPath?.boundingBoxOfPath
        #expect(box == CGRect(x: 10, y: 10, width: 40, height: 30))
    }

    @Test func aPathWithNoFillAndNoStrokeIsRefused() {
        let session = makeSession()
        session.shapeFilled = false
        session.shapeStrokeEnabled = false
        let layers = session.document?.layers.count ?? 0
        triangle(session)
        #expect(session.document?.layers.count == layers)
        #expect(session.brushError != nil)
    }

    @Test func shiftPStepsThroughTheModes() {
        let session = makeSession()
        var seen = [session.penMode]
        for _ in 1..<PenMode.allCases.count { session.cyclePenMode(); seen.append(session.penMode) }
        #expect(seen == PenMode.allCases)
        session.cyclePenMode()
        #expect(session.penMode == .pen)
    }

    // MARK: Curvature

    @Test func theCurvaturePenRunsSmoothlyThroughEveryPointClicked() throws {
        let points = [CGPoint(x: 10, y: 50), CGPoint(x: 40, y: 20), CGPoint(x: 80, y: 30), CGPoint(x: 100, y: 70)]
        let knots = PenGeometry.curvatureKnots(points, corners: [], closed: false)
        #expect(knots.map(\.anchor) == points)
        #expect(knots.first?.incoming == points[0] && knots.last?.outgoing == points[3], "an open path's ends have no handles")
        for knot in knots.dropFirst().dropLast() { #expect(EditorSession.isSmooth(knot)) }
        let cornered = PenGeometry.curvatureKnots(points, corners: [1], closed: false)
        #expect(cornered[1].incoming == points[1] && cornered[1].outgoing == points[1])
        let closed = PenGeometry.curvatureKnots(points, corners: [], closed: true)
        #expect(closed.allSatisfy(EditorSession.isSmooth), "a closed path is smooth all the way round")
    }

    @Test func doubleClickingACurvaturePointMakesItACorner() throws {
        let session = makeSession(.curvature)
        click(session, CGPoint(x: 10, y: 50))
        click(session, CGPoint(x: 40, y: 20))
        click(session, CGPoint(x: 40, y: 20), count: 2)
        click(session, CGPoint(x: 80, y: 50))
        #expect(session.penDraft?.knots.count == 3, "the double-click's second click adds nothing")
        #expect(session.penDraft?.corners == [1])
        click(session, CGPoint(x: 10, y: 50))
        let knots = try #require(session.activeLayer?.liveShape?.style.outline?.subpaths.first)
        #expect(knots.closed && knots.knots.count == 3)
    }

    // MARK: Freeform

    @Test func freeformFollowsTheDragWithAFewCurves() throws {
        let center = CGPoint(x: 60, y: 50)
        let samples = stride(from: 0.0, through: 360.0, by: 2.0).map { degrees -> CGPoint in
            let angle = degrees * .pi / 180
            return CGPoint(x: center.x + 30 * cos(angle), y: center.y + 30 * sin(angle))
        }
        let knots = PenGeometry.fitted(samples, tolerance: 0.5, closed: true)
        #expect(knots.count < 16, "\(knots.count) knots for a circle")
        let path = [ShapeOutline.Subpath(closed: true, knots: knots)]
        for sample in samples { #expect(PenGeometry.nearestSegment(path, to: sample, tolerance: 0.6) != nil, "\(sample) strays") }
        #expect(EditorSession.isSmooth(knots[0]), "the join is smooth")
    }

    @Test func aFreeformDragEndingAtItsStartMakesAClosedShape() async throws {
        let session = makeSession(.freeform)
        let samples = stride(from: 0.0, through: 360.0, by: 3.0).map { degrees -> CGPoint in
            let angle = degrees * .pi / 180
            return CGPoint(x: 60 + 30 * cos(angle), y: 50 + 25 * sin(angle))
        }
        session.beginPen(at: samples[0], tolerance: 3, constrain: false, clickCount: 1)
        for sample in samples.dropFirst() {
            session.dragPen(to: sample, constrain: false, breaksHandle: false, threshold: 1, spacing: 0.5)
        }
        session.endPen(tolerance: 0.5)
        let subpath = try #require(session.activeLayer?.liveShape?.style.outline?.subpaths.first)
        #expect(subpath.closed)
        #expect(subpath.knots.count < 20)
        #expect(try await covered(session, 60, 50))
    }

    // MARK: Add and Delete Anchor Point

    @Test func splittingACurveLeavesItsOutlineAsItWas() throws {
        let subpath = ShapeOutline.Subpath(closed: false, knots: [
            ShapeOutline.Knot(anchor: CGPoint(x: 0, y: 0), outgoing: CGPoint(x: 10, y: 30)),
            ShapeOutline.Knot(anchor: CGPoint(x: 60, y: 0), incoming: CGPoint(x: 50, y: 40)),
        ])
        let curve = PenGeometry.curve(subpath, segment: 0)
        let split = try #require(PenGeometry.splitting([subpath], at: PenGeometry.SegmentHit(subpath: 0, segment: 0, t: 0.3, distance: 0)))
        #expect(split.added == PathKnot(subpath: 0, knot: 1))
        let result = split.subpaths[0]
        #expect(result.knots.count == 3)
        let left = PenGeometry.curve(result, segment: 0), right = PenGeometry.curve(result, segment: 1)
        for step in 0...10 {
            let t = CGFloat(step) / 10
            #expect(near(PenGeometry.value(left, at: t), PenGeometry.value(curve, at: t * 0.3), within: 0.001))
            #expect(near(PenGeometry.value(right, at: t), PenGeometry.value(curve, at: 0.3 + t * 0.7), within: 0.001))
        }
    }

    @Test func addAnchorPointGivesARectangleAFifthPointAndDragsIt() async throws {
        let session = makeSession()
        session.selectTool(.shape)
        session.shapeKind = .rectangle
        session.beginShape(at: CGPoint(x: 10, y: 10))
        session.dragShape(to: CGPoint(x: 50, y: 40), square: false, fromCenter: false)
        session.finishShape()
        session.selectTool(.pen)
        session.penMode = .addAnchor
        let count = session.history.undoCount
        #expect(session.penHover(at: CGPoint(x: 30, y: 10.5), tolerance: 3) == .add)
        #expect(session.penHover(at: CGPoint(x: 30, y: 25), tolerance: 3) == .none, "inside, away from the outline")
        session.beginPen(at: CGPoint(x: 30, y: 10), tolerance: 3, constrain: false, clickCount: 1)
        #expect(session.activeLayer?.liveShape?.style.kind == .custom)
        #expect(anchors(session).count == 5)
        #expect(try await !covered(session, 30, 6))
        // The new point follows the drag, as part of the same step.
        session.dragPath(to: CGPoint(x: 30, y: 2), breaksHandle: false)
        session.endPathDrag()
        #expect(session.history.undoCount == count + 1)
        #expect(anchors(session).contains { near($0, CGPoint(x: 30, y: 2)) })
        #expect(try await covered(session, 30, 6))
        session.undo()
        #expect(session.activeLayer?.liveShape?.style.kind == .rectangle)
    }

    @Test func deleteAnchorPointRemovesOneButNeverLeavesTooFew() throws {
        let session = makeSession()
        click(session, CGPoint(x: 10, y: 10))
        click(session, CGPoint(x: 50, y: 10))
        click(session, CGPoint(x: 60, y: 40))
        click(session, CGPoint(x: 10, y: 40))
        click(session, CGPoint(x: 10, y: 10))
        session.penMode = .deleteAnchor
        #expect(session.penHover(at: CGPoint(x: 60, y: 40), tolerance: 3) == .delete)
        let count = session.history.undoCount
        click(session, CGPoint(x: 60, y: 40))
        #expect(session.history.undoCount == count + 1)
        #expect(anchors(session).count == 3)
        #expect(!anchors(session).contains { near($0, CGPoint(x: 60, y: 40)) })
        let layers = session.document?.layers.count
        click(session, CGPoint(x: 50, y: 10))
        #expect(anchors(session).count == 3, "a triangle keeps its three points")
        #expect(session.history.undoCount == count + 1)
        #expect(session.document?.layers.count == layers)
        #expect(PenGeometry.removing(PathKnot(subpath: 0, knot: 0), from: [ShapeOutline.Subpath(closed: false, knots: [
            ShapeOutline.Knot(anchor: .zero), ShapeOutline.Knot(anchor: CGPoint(x: 1, y: 1))])]) == nil)
    }

    // MARK: Saving

    @Test func aPenShapeSurvivesSavingAndReopening() async throws {
        let session = makeSession()
        click(session, CGPoint(x: 10, y: 50))
        drag(session, from: CGPoint(x: 50, y: 10), to: CGPoint(x: 70, y: 10))
        click(session, CGPoint(x: 90, y: 60))
        click(session, CGPoint(x: 10, y: 50))
        let outline = try #require(session.activeLayer?.liveShape?.style.outline)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pen-\(UUID()).pbox")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let saved = try #require(loaded.manifest.layers.last?.shape)
        #expect(saved.kind == .custom && saved.customName == nil)
        let reloaded = try #require(saved.outline)
        #expect(reloaded.subpaths.count == outline.subpaths.count)
        for (a, b) in zip(reloaded.subpaths[0].knots, outline.subpaths[0].knots) {
            #expect(near(a.anchor, b.anchor, within: 0.00001) && near(a.outgoing, b.outgoing, within: 0.00001))
        }
        let reopened = EditorSession()
        reopened.installProject(loaded, from: url)
        #expect(reopened.activeLayer?.liveShape?.style.kind == .custom, "it reopens as a shape, not just pixels")
    }
}
