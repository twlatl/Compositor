import AppKit
import Testing
@testable import Pixegen

@MainActor
struct LayerAlignmentTests {
    private func makeSession() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 200, height: 100, emptyLayer: true)
        session.selectTool(.shape)
        return session
    }
    @discardableResult
    private func draw(_ session: EditorSession, _ rect: CGRect) -> UUID {
        session.shapeKind = .rectangle
        session.beginShape(at: rect.origin)
        session.dragShape(to: CGPoint(x: rect.maxX, y: rect.maxY), square: false, fromCenter: false)
        session.finishShape()
        return session.activeLayerID!
    }
    private func select(_ session: EditorSession, _ ids: [UUID]) {
        session.activeLayerID = ids.first
        session.selectedLayerIDs = Set(ids)
    }
    private func box(_ session: EditorSession, _ id: UUID) -> CGRect {
        EditorSession.alignmentBox(of: [session.document!.layers.first { $0.id == id }!])!
    }

    @Test func alignLeftLinesUpWithTheLeftmostAsOneStep() {
        let session = makeSession()
        let a = draw(session, CGRect(x: 10, y: 10, width: 20, height: 20))
        let b = draw(session, CGRect(x: 50, y: 40, width: 30, height: 20))
        select(session, [a, b])
        let count = session.history.undoCount
        session.align(.left)
        #expect(box(session, a).minX == box(session, b).minX)
        #expect(box(session, a).minY != box(session, b).minY, "only across")
        #expect(session.history.undoCount == count + 1)
        session.undo()
        #expect(box(session, b).minX > box(session, a).minX)
    }

    @Test func oneLayerAlignsToTheCanvas() {
        let session = makeSession()
        let a = draw(session, CGRect(x: 10, y: 10, width: 20, height: 20))
        select(session, [a])
        session.align(.right)
        #expect(box(session, a).maxX == 200)
        session.align(.verticalCenter)
        #expect(box(session, a).midY == 50)
    }

    @Test func canvasTargetAlignsEveryLayerToTheCanvas() {
        let session = makeSession()
        let a = draw(session, CGRect(x: 10, y: 10, width: 20, height: 20))
        let b = draw(session, CGRect(x: 50, y: 40, width: 30, height: 20))
        select(session, [a, b])
        session.alignmentTarget = .canvas
        session.align(.bottom)
        #expect(box(session, a).maxY == 100)
        #expect(box(session, b).maxY == 100)
    }

    @Test func distributingTakesThreeAndKeepsTheOutermostInPlace() {
        let session = makeSession()
        let a = draw(session, CGRect(x: 10, y: 10, width: 20, height: 20))
        let b = draw(session, CGRect(x: 40, y: 10, width: 20, height: 20))
        select(session, [a, b])
        #expect(!session.canAlign(.distributeHorizontalCenter))
        #expect(!session.canAlign(.spaceHorizontally))
        let c = draw(session, CGRect(x: 150, y: 10, width: 20, height: 20))
        select(session, [a, b, c])
        #expect(session.canAlign(.distributeHorizontalCenter))
        let left = box(session, a), right = box(session, c)
        session.align(.distributeHorizontalCenter)
        #expect(box(session, a) == left)
        #expect(box(session, c) == right)
        #expect(box(session, b).midX == (left.midX + right.midX) / 2)
    }

    @Test func distributeSpacingLeavesEqualGaps() {
        let session = makeSession()
        let a = draw(session, CGRect(x: 0, y: 10, width: 20, height: 20))
        let b = draw(session, CGRect(x: 30, y: 10, width: 60, height: 20))
        let c = draw(session, CGRect(x: 160, y: 10, width: 20, height: 20))
        select(session, [a, b, c])
        session.align(.spaceHorizontally)
        let first = box(session, b).minX - box(session, a).maxX
        let second = box(session, c).minX - box(session, b).maxX
        #expect(abs(first - second) <= 1)
    }

    @Test func aSelectedFolderMovesAsOnePiece() throws {
        let session = makeSession()
        let a = draw(session, CGRect(x: 10, y: 10, width: 20, height: 20))
        let b = draw(session, CGRect(x: 40, y: 10, width: 20, height: 20))
        let c = draw(session, CGRect(x: 150, y: 60, width: 20, height: 20))
        select(session, [a, b])
        session.groupSelectedLayers()
        let folder = try #require(session.activeLayerID)
        select(session, [folder, c])
        #expect(session.alignmentItems.count == 2)
        let gap = box(session, b).minX - box(session, a).minX
        session.align(.right)
        #expect(box(session, b).maxX == box(session, c).maxX)
        #expect(box(session, b).minX - box(session, a).minX == gap, "the folder's layers keep their places in it")
    }

    @Test func offsetsRoundToWholePixels() {
        let offsets = LayerAlignment.horizontalCenter.offsets(
            for: [CGRect(x: 0, y: 0, width: 3, height: 3)], reference: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(offsets == [CGSize(width: 4, height: 0)])
    }
}
