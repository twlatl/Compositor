import AppKit
import Testing
@testable import Pixegen

@MainActor
struct RulerOriginTests {
    /// A session with View › Snap To on or off for the test, put back as it was afterward: the setting is saved.
    private func withSnapping(_ enabled: Bool, _ body: (EditorSession) async throws -> Void) async rethrows {
        let session = EditorSession()
        session.createDocument(width: 400, height: 300)
        let saved = (session.snapEnabled, session.snapToDocumentBounds)
        session.snapEnabled = enabled
        session.snapToDocumentBounds = true
        defer { session.snapEnabled = saved.0; session.snapToDocumentBounds = saved.1 }
        try await body(session)
    }

    @Test func draggingOutOfTheCornerMovesTheZeroPointOnRelease() async {
        await withSnapping(false) { session in
            #expect(session.rulerZero == .zero)
            session.beginRulerOriginDrag(at: CGPoint(x: 10.4, y: 20.6))
            session.moveRulerOriginDrag(to: CGPoint(x: 120.3, y: 80.7))
            #expect(session.rulerOriginDrag == CGPoint(x: 120, y: 81), "the crosshair sits on whole pixels")
            #expect(session.rulerZero == .zero, "the rulers keep counting from the old zero until release")
            session.finishRulerOriginDrag(cancel: false)
            #expect(session.rulerZero == CGPoint(x: 120, y: 81))
            #expect(session.rulerOriginDrag == nil)
        }
    }

    /// A plain click in the corner, a drag let go back over the rulers, or Escape leaves the zero point alone.
    @Test func aCancelledDragLeavesTheZeroPointWhereItWas() async {
        await withSnapping(false) { session in
            session.setRulerZero(CGPoint(x: 50, y: 40))
            session.beginRulerOriginDrag(at: CGPoint(x: 200, y: 200))
            session.moveRulerOriginDrag(to: CGPoint(x: 220, y: 210))
            session.finishRulerOriginDrag(cancel: true)
            #expect(session.rulerZero == CGPoint(x: 50, y: 40) && session.rulerOriginDrag == nil)
        }
    }

    @Test func theZeroPointSnapsLikeAGuide() async {
        await withSnapping(true) { session in
            let tolerance = TransformSnap.distance / max(session.viewport.pointsPerPixel, 0.0001)
            // Just off the canvas's middle and its top edge, well inside the snap distance.
            session.beginRulerOriginDrag(at: CGPoint(x: 200 + tolerance / 2, y: tolerance / 2))
            #expect(session.rulerOriginDrag == CGPoint(x: 200, y: 0))
            session.finishRulerOriginDrag(cancel: false)
            #expect(session.rulerZero == CGPoint(x: 200, y: 0))
        }
    }

    @Test func doubleClickingTheCornerPutsZeroBackOnTheTopLeft() async {
        await withSnapping(false) { session in
            session.setRulerZero(CGPoint(x: 75, y: 25))
            session.resetRulerOrigin()
            #expect(session.rulerZero == .zero && session.rulerOrigin == nil)
        }
    }

    /// The zero point belongs to the canvas it was set on: a new size or a new document counts from the corner
    /// again, and undoing the size change brings it back.
    @Test func aNewCanvasCountsFromItsCornerAgain() async throws {
        try await withSnapping(false) { session in
            session.setRulerZero(CGPoint(x: 100, y: 60))
            let resized = try await CanvasResizer.shared.resize(try #require(session.projectSnapshot()),
                                                                 to: CanvasSizeOptions(width: 500, height: 300))
            session.applyDocumentSize(resized, actionName: "Canvas Size")
            #expect(session.document?.size == CGSize(width: 500, height: 300))
            #expect(session.rulerZero == .zero)
            session.undo()
            #expect(session.rulerZero == CGPoint(x: 100, y: 60))

            session.createDocument(width: 400, height: 300)
            #expect(session.rulerZero == .zero, "a new document, even at the same size")
        }
    }

    /// A shown grid, snapping to it alone, with the person's grid settings put back afterward: they are saved.
    private func withGrid(_ grid: LayoutGrid, _ body: (EditorSession) async throws -> Void) async rethrows {
        try await withSnapping(true) { session in
            let saved = (session.layoutGrid, session.showsGrid, session.snapToGrid, session.snapToGuides,
                         session.snapToLayers, session.snapToDocumentBounds)
            session.layoutGrid = grid
            session.showsGrid = true
            session.snapToGrid = true
            session.snapToGuides = false
            session.snapToLayers = false
            session.snapToDocumentBounds = false
            defer {
                session.layoutGrid = saved.0
                session.showsGrid = saved.1
                session.snapToGrid = saved.2
                session.snapToGuides = saved.3
                session.snapToLayers = saved.4
                session.snapToDocumentBounds = saved.5
            }
            try await body(session)
        }
    }

    /// Moving the zero point moves the grid, and snapping to the grid snaps to where it's drawn.
    @Test func theGridFollowsTheZeroPoint() async {
        await withGrid(LayoutGrid(spacing: 100, subdivisions: 2)) { session in
            #expect(Set(session.cropSnapTargets().xs) == Set<CGFloat>([0, 50, 100, 150, 200, 250, 300, 350, 400]))
            session.setRulerZero(CGPoint(x: 120, y: 81))
            #expect(Set(session.cropSnapTargets().xs) == Set<CGFloat>([20, 70, 120, 170, 220, 270, 320, 370]))
            #expect(Set(session.cropSnapTargets().ys) == Set<CGFloat>([31, 81, 131, 181, 231, 281]))
            #expect(session.snappedGuidePosition(52, axis: .vertical, excluding: nil) == 52, "the old line is gone")
            #expect(session.snappedGuidePosition(72, axis: .vertical, excluding: nil) == 70)
            #expect(session.snappedGuidePosition(129, axis: .horizontal, excluding: nil) == 131)

            // Double-clicking the corner puts the grid back on the top-left too.
            session.resetRulerOrigin()
            #expect(Set(session.cropSnapTargets().xs) == Set<CGFloat>([0, 50, 100, 150, 200, 250, 300, 350, 400]))
            #expect(session.snappedGuidePosition(52, axis: .vertical, excluding: nil) == 50)
        }
    }

    /// A zero point off the canvas, or between pixels, still lays the grid out from it, on whole pixels.
    @Test func theGridFollowsANegativeOrFractionalZeroPoint() async {
        await withGrid(LayoutGrid(spacing: 100, subdivisions: 4)) { session in
            session.setRulerZero(CGPoint(x: -10, y: 30.6))
            #expect(session.cropSnapTargets().xs.first == 15 && session.cropSnapTargets().xs.last == 390)
            #expect(session.cropSnapTargets().xs.filter { session.layoutGrid.isMajor($0, from: -10) } == [90, 190, 290, 390])
            #expect(session.cropSnapTargets().ys == [6, 31, 56, 81, 106, 131, 156, 181, 206, 231, 256, 281])
            #expect(session.snappedGuidePosition(-12, axis: .vertical, excluding: nil) == -12,
                    "lines before the canvas aren't snapped to")
            #expect(session.snappedGuidePosition(33, axis: .horizontal, excluding: nil) == 31)
        }
    }

    /// Dragging the zero point onto a grid line lines the grid up with itself; it snaps to the grid as it was.
    @Test func theZeroPointSnapsToTheGridItMoves() async {
        await withGrid(LayoutGrid(spacing: 100, subdivisions: 2)) { session in
            session.beginRulerOriginDrag(at: CGPoint(x: 148, y: 103))
            #expect(session.rulerOriginDrag == CGPoint(x: 150, y: 100))
            session.finishRulerOriginDrag(cancel: false)
            #expect(Set(session.cropSnapTargets().xs) == Set<CGFloat>([0, 50, 100, 150, 200, 250, 300, 350, 400]))
        }
    }

    /// The numbers before the zero point count backwards from it.
    @Test func rulerTicksCountBackwardsBeforeTheZeroPoint() {
        #expect(CanvasRulerNSView.ticks(from: 0, to: 300, zero: 0, minor: 100) == [0, 100, 200, 300])
        #expect(CanvasRulerNSView.ticks(from: 0, to: 300, zero: 120, minor: 40) == [-120, -80, -40, 0, 40, 80, 120, 160, 200])
        // Labels carry no sign: before zero they count up away from it, as after it.
        #expect(CanvasRulerNSView.label(-120) == "120" && CanvasRulerNSView.label(120) == "120")
        #expect(CanvasRulerNSView.label(-0.2) == "0")
    }
}
