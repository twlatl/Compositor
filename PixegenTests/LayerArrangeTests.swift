import AppKit
import Testing
@testable import Pixegen

@MainActor
struct LayerArrangeTests {
    /// A document of four shapes, A at the bottom to D at the top.
    private func makeSession() -> (EditorSession, [UUID]) {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100, emptyLayer: false)
        session.selectTool(.shape)
        session.shapeKind = .rectangle
        let ids = (0..<4).map { i -> UUID in
            session.beginShape(at: CGPoint(x: 10 * i, y: 10))
            session.dragShape(to: CGPoint(x: 10 * i + 20, y: 40), square: false, fromCenter: false)
            session.finishShape()
            return session.activeLayerID!
        }
        return (session, ids)
    }
    private func select(_ session: EditorSession, _ ids: [UUID]) {
        session.activeLayerID = ids.first
        session.selectedLayerIDs = Set(ids)
    }
    private func stack(_ session: EditorSession, _ ids: [UUID]) -> [Int] {
        session.document!.layers.compactMap { layer in ids.firstIndex(of: layer.id) }
    }

    @Test func theOrdersAsInPhotoshop() {
        #expect(LayerArrangement.front.order([false, true, false, true]) == [0, 2, 1, 3])
        #expect(LayerArrangement.back.order([false, true, false, true]) == [1, 3, 0, 2])
        #expect(LayerArrangement.forward.order([true, true, false]) == [2, 0, 1], "a run moves up together")
        #expect(LayerArrangement.backward.order([false, true, true]) == [1, 2, 0])
        #expect(LayerArrangement.forward.order([false, false, true]) == [0, 1, 2], "already at the top")
    }

    @Test func frontAndBackMoveTheSelectionAsOneStep() {
        let (session, ids) = makeSession()
        select(session, [ids[1]])
        let count = session.history.undoCount
        session.arrange(.front)
        #expect(stack(session, ids) == [0, 2, 3, 1])
        #expect(session.history.undoCount == count + 1)
        #expect(!session.canArrange(.front))
        #expect(!session.canArrange(.forward))
        session.arrange(.back)
        #expect(stack(session, ids) == [1, 0, 2, 3])
        session.undo()
        #expect(stack(session, ids) == [0, 2, 3, 1])
    }

    @Test func forwardAndBackwardStepOnePlace() {
        let (session, ids) = makeSession()
        select(session, [ids[0], ids[2]])
        session.arrange(.forward)
        #expect(stack(session, ids) == [1, 0, 3, 2])
        session.arrange(.backward)
        #expect(stack(session, ids) == [0, 1, 2, 3])
    }

    @Test func clippedLayersTravelWithTheirBase() {
        let (session, ids) = makeSession()
        // B clipped to A.
        session.toggleClippingMask(ids[1])
        #expect(session.document!.layers.first { $0.id == ids[1] }?.maskSourceID == ids[0])
        select(session, [ids[0]])
        session.arrange(.forward)
        #expect(stack(session, ids) == [2, 0, 1, 3])
        #expect(session.document!.layers.first { $0.id == ids[1] }?.maskSourceID == ids[0], "still clipped")
    }

    @Test func aLayerStaysInItsFolder() throws {
        let (session, ids) = makeSession()
        select(session, [ids[1], ids[2]])
        session.groupSelectedLayers()
        let folder = try #require(session.activeLayerID)
        select(session, [ids[1]])
        session.arrange(.front)
        let layer = try #require(session.document!.layers.first { $0.id == ids[1] })
        #expect(layer.parentID == folder)
        let inFolder = session.document!.layers.filter { $0.parentID == folder }.map(\.id)
        #expect(inFolder == [ids[2], ids[1]])
        #expect(!session.canArrange(.front), "already the top of its folder")
    }
}
