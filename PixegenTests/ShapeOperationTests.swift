import AppKit
import Testing
@testable import Pixegen

@MainActor
struct ShapeOperationTests {
    private func makeSession() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 120, height: 100, emptyLayer: true)
        session.selectTool(.shape)
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        return session
    }
    @discardableResult
    private func draw(_ session: EditorSession, _ kind: ShapeKind = .rectangle, from start: CGPoint, to end: CGPoint) -> UUID {
        session.shapeKind = kind
        session.beginShape(at: start)
        session.dragShape(to: end, square: false, fromCenter: false)
        session.finishShape()
        return session.activeLayerID!
    }
    /// Two overlapping squares: the first (10,10)–(40,40) is active, the second (30,30)–(60,60) also selected.
    private func overlapping(_ session: EditorSession) -> (base: UUID, other: UUID) {
        let base = draw(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 40))
        let other = draw(session, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 60, y: 60))
        select(session, active: base, [base, other])
        return (base, other)
    }
    private func select(_ session: EditorSession, active: UUID, _ ids: Set<UUID>) {
        session.activeLayerID = active
        session.selectedLayerIDs = ids
    }
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

    @Test func theOperationsNeedTwoShapesWithTheActiveOneAmongThem() {
        let session = makeSession()
        let first = draw(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 40))
        #expect(!session.canApplyShapeOperation, "one shape")
        let second = draw(session, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 60, y: 60))
        let line = draw(session, .line, from: CGPoint(x: 0, y: 90), to: CGPoint(x: 100, y: 90))
        select(session, active: first, [first, second])
        #expect(session.canApplyShapeOperation)
        select(session, active: first, [first, line])
        #expect(!session.canApplyShapeOperation, "a line has no area to combine")
        let blank = session.document!.layers[0].id
        select(session, active: blank, [blank, first, second])
        #expect(!session.canApplyShapeOperation, "the active layer isn't a shape")
    }

    @Test func combineMakesOneShapeOfBothInOneStep() async throws {
        let session = makeSession()
        let (base, _) = overlapping(session)
        let layers = session.document?.layers.count ?? 0
        let count = session.history.undoCount
        session.applyShapeOperation(.combine)
        #expect(session.document?.layers.count == layers - 1)
        #expect(session.history.undoCount == count + 1)
        #expect(session.activeLayerID == base && session.activeLayer?.name == "Rectangle 1")
        #expect(session.activeLayer?.liveShape?.style.kind == .custom)
        #expect(session.activeLayer?.transform.origin == CGPoint(x: 10, y: 10))
        #expect(session.activeLayer?.transform.size == CGSize(width: 50, height: 50))
        #expect(try await covered(session, 15, 15))
        #expect(try await covered(session, 55, 55))
        #expect(try await !covered(session, 55, 15))
        session.undo()
        #expect(session.document?.layers.count == layers)
        #expect(session.activeLayer?.liveShape?.style.kind == .rectangle)
    }

    @Test func subtractCutsTheOthersOutOfTheActiveShape() async throws {
        let session = makeSession()
        overlapping(session)
        session.applyShapeOperation(.subtract)
        #expect(try await covered(session, 15, 15))
        #expect(try await !covered(session, 35, 35))
        #expect(try await !covered(session, 55, 55))
    }

    @Test func intersectKeepsOnlyWhereTheyOverlap() async throws {
        let session = makeSession()
        overlapping(session)
        session.applyShapeOperation(.intersect)
        #expect(session.activeLayer?.transform.origin == CGPoint(x: 30, y: 30))
        #expect(session.activeLayer?.transform.size == CGSize(width: 10, height: 10))
        #expect(try await covered(session, 35, 35))
        #expect(try await !covered(session, 15, 15))
    }

    @Test func excludeKeepsWhereTheyDontOverlap() async throws {
        let session = makeSession()
        overlapping(session)
        session.applyShapeOperation(.exclude)
        #expect(try await covered(session, 15, 15))
        #expect(try await covered(session, 55, 55))
        #expect(try await !covered(session, 35, 35))
    }

    @Test func shapesThatDontOverlapCantIntersect() {
        let session = makeSession()
        let base = draw(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 30))
        let other = draw(session, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 90, y: 90))
        select(session, active: base, [base, other])
        let layers = session.document?.layers.count
        let count = session.history.undoCount
        session.applyShapeOperation(.intersect)
        #expect(session.brushError != nil)
        #expect(session.document?.layers.count == layers)
        #expect(session.history.undoCount == count)
    }

    @Test func rotatedAndFlippedShapesCombineWhereTheyAreDrawn() async throws {
        let session = makeSession()
        let base = draw(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 40))
        let bar = draw(session, from: CGPoint(x: 30, y: 20), to: CGPoint(x: 70, y: 40))
        let triangle = draw(session, .triangle, from: CGPoint(x: 60, y: 50), to: CGPoint(x: 100, y: 90))
        let layers = try #require(session.document?.layers)
        // The bar stood on end about its center (50, 30), and the triangle upside down: its point at the bottom.
        session.document?.layers[layers.firstIndex { $0.id == bar }!].transform.rotation = 90
        session.document?.layers[layers.firstIndex { $0.id == triangle }!].transform.flipY = true
        select(session, active: base, [base, bar, triangle])
        session.applyShapeOperation(.combine)
        let result = try #require(session.activeLayer?.transform)
        #expect(result.rotation == 0 && !result.flipX && !result.flipY, "the result is upright")
        #expect(try await covered(session, 50, 12), "the bar on end reaches up to y 10")
        #expect(try await !covered(session, 65, 30), "and no longer reaches across to x 70")
        #expect(try await covered(session, 64, 54), "the flipped triangle is wide at its top")
        #expect(try await !covered(session, 64, 86), "and narrow at its bottom")
    }

    @Test func layersClippedToAShapeThatGoesClipToTheResult() throws {
        let session = makeSession()
        let (base, other) = overlapping(session)
        session.activeLayerID = other
        session.addBlankLayer()
        let clipped = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == clipped })
        session.document?.layers[index].maskSourceID = other
        select(session, active: base, [base, other])
        session.applyShapeOperation(.combine)
        #expect(session.document?.layers.first { $0.id == clipped }?.maskSourceID == base)
        #expect(session.document?.layers.contains { $0.id == other } == false)
    }

    @Test func aCombinedShapeSurvivesSavingAndReopening() async throws {
        let session = makeSession()
        overlapping(session)
        session.applyShapeOperation(.subtract)
        let outline = try #require(session.activeLayer?.liveShape?.style.outline)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Combine-\(UUID()).pbox")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let shape = try #require(loaded.manifest.layers.last?.shape)
        #expect(shape.kind == .custom)
        #expect(shape.outline?.subpaths.count == outline.subpaths.count)
    }
}
