import AppKit
import Testing
@testable import PixelBox

@MainActor
struct ShapeToolTests {
    private func makeSession() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 100, height: 80, emptyLayer: true)
        session.selectTool(.shape)
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        return session
    }
    private func drag(_ session: EditorSession, from start: CGPoint, to end: CGPoint, square: Bool = false, fromCenter: Bool = false) {
        session.beginShape(at: start)
        session.dragShape(to: end, square: square, fromCenter: fromCenter)
        session.finishShape()
    }
    /// The flattened document as RGBA bytes, and a reader for one pixel's red and alpha.
    private func pixels(_ session: EditorSession) async throws -> (Int, Int) -> (red: Int, alpha: Int) {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                              count: image.width * image.height * 4))
        let width = image.width
        return { x, y in (Int(bytes[(y * width + x) * 4]), Int(bytes[(y * width + x) * 4 + 3])) }
    }

    @Test func rectangleFillsANewLayerWithTheForegroundColorAsOneUndoStep() async throws {
        let session = makeSession()
        session.selectAll()
        let count = session.history.undoCount
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 30))
        let document = try #require(session.document)
        #expect(document.layers.map(\.name) == ["Layer 1", "Rectangle 1"])
        #expect(session.activeLayer?.name == "Rectangle 1" && session.history.undoCount == count + 1)
        #expect(session.activeLayer?.transform.origin == CGPoint(x: 10, y: 10)
                && session.activeLayer?.transform.size == CGSize(width: 30, height: 20))
        #expect(session.selection != nil) // unlike Paste, drawing a shape keeps the selection
        let pixel = try await pixels(session)
        #expect(pixel(25, 20) == (255, 255) && pixel(10, 10) == (255, 255) && pixel(39, 29) == (255, 255))
        #expect(pixel(9, 20).alpha == 0 && pixel(40, 20).alpha == 0 && pixel(25, 30).alpha == 0)

        drag(session, from: CGPoint(x: 60, y: 10), to: CGPoint(x: 70, y: 20))
        #expect(session.activeLayer?.name == "Rectangle 2")
        session.undo()
        session.undo()
        #expect(session.document?.layers.map(\.name) == ["Layer 1"])
    }

    @Test func ellipseLeavesItsCornersClearWithShiftCircleAndOptionFromCenter() async throws {
        let session = makeSession()
        session.toggleShapeKind()
        #expect(session.shapeKind == .ellipse)
        drag(session, from: CGPoint(x: 50, y: 40), to: CGPoint(x: 60, y: 45), square: true, fromCenter: true)
        #expect(session.activeLayer?.name == "Ellipse 1")
        #expect(session.activeLayer?.transform.origin == CGPoint(x: 40, y: 30)
                && session.activeLayer?.transform.size == CGSize(width: 20, height: 20))
        let pixel = try await pixels(session)
        #expect(pixel(50, 40) == (255, 255) && pixel(41, 40).alpha > 0 && pixel(50, 31).alpha > 0)
        #expect(pixel(40, 30).alpha == 0 && pixel(59, 49).alpha == 0) // outside the circle, inside its box
    }

    @Test func aClickEscapeOrToolSwitchMakesNoLayer() {
        let session = makeSession()
        let count = session.history.undoCount
        session.beginShape(at: CGPoint(x: 20, y: 20))
        session.finishShape()
        session.beginShape(at: CGPoint(x: 20, y: 20))
        session.dragShape(to: CGPoint(x: 50, y: 50), square: false, fromCenter: false)
        #expect(session.shapeDraft?.rect == CGRect(x: 20, y: 20, width: 30, height: 30))
        session.cancelShape()
        session.beginShape(at: CGPoint(x: 20, y: 20))
        session.dragShape(to: CGPoint(x: 50, y: 50), square: false, fromCenter: false)
        session.selectTool(.brush)
        #expect(session.shapeDraft == nil && session.history.undoCount == count)
        #expect(session.document?.layers.count == 1)
    }

    /// A corner radius cuts the rectangle's corners; one larger than half the shorter side makes a pill.
    @Test func roundedRectanglesFollowTheRadiusAndClampToAPill() async throws {
        let session = makeSession()
        session.shapeCornerRadius = 8
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 40)) // 40 × 30
        session.shapeCornerRadius = 500
        drag(session, from: CGPoint(x: 55, y: 50), to: CGPoint(x: 95, y: 70)) // 40 × 20: radius 10
        let pixel = try await pixels(session)
        #expect(pixel(10, 10).alpha == 0, "the corner is cut away")
        #expect(pixel(11, 11).alpha == 0)
        #expect(pixel(13, 13).alpha == 255, "inside the rounded corner")
        #expect(pixel(30, 10).alpha == 255, "straight edges stay full")
        #expect(pixel(30, 25) == (255, 255))
        #expect(pixel(55, 50).alpha == 0, "the pill's corner is round")
        #expect(pixel(75, 60) == (255, 255))
        #expect(session.document?.layers.count == 3)

        session.toggleShapeKind()
        session.beginShape(at: CGPoint(x: 5, y: 5))
        #expect(session.shapeDraft?.cornerRadius == 0, "ellipses take no radius")
        session.cancelShape()
    }

    @Test func smoothingUsesSixtyPercentCornersAndStaysInsideTheBox() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 80)
        let path = ShapeKind.rectangle.path(in: rect, cornerRadius: 20, smoothing: true)
        let ordinary = ShapeKind.rectangle.path(in: rect, cornerRadius: 20)
        let bounds = path.boundingBoxOfPath
        #expect(abs(bounds.minX - rect.minX) < 0.000001 && abs(bounds.minY - rect.minY) < 0.000001)
        #expect(abs(bounds.maxX - rect.maxX) < 0.000001 && abs(bounds.maxY - rect.maxY) < 0.000001)
        // At 60%, the transition reaches 32 px along each edge instead of the circular corner's 20.
        #expect(!path.contains(CGPoint(x: 35, y: 20.01)))
        #expect(ordinary.contains(CGPoint(x: 35, y: 20.01)))
        #expect(path.contains(CGPoint(x: 43, y: 20.01)))
        #expect(path.contains(CGPoint(x: 60, y: 60)))
        #expect(!path.contains(CGPoint(x: 11, y: 21)))
        for x in stride(from: CGFloat(0.5), to: rect.width, by: 2) {
            for y in stride(from: CGFloat(0.5), to: rect.height, by: 2) {
                let inside = path.contains(CGPoint(x: rect.minX + x, y: rect.minY + y))
                #expect(inside == path.contains(CGPoint(x: rect.maxX - x, y: rect.minY + y)))
                #expect(inside == path.contains(CGPoint(x: rect.minX + x, y: rect.maxY - y)))
            }
        }
        #expect(ShapeKind.rectangle.path(in: rect, smoothing: true) == ShapeKind.rectangle.path(in: rect))
        #expect(ShapeKind.rectangle.path(in: rect, cornerRadius: 500, smoothing: true)
                == ShapeKind.rectangle.path(in: rect, cornerRadius: 500))
        #expect(ShapeKind.ellipse.path(in: rect, cornerRadius: 20, smoothing: true)
                == ShapeKind.ellipse.path(in: rect))
    }

    @Test func smoothingSurvivesSavingAndMatchesTheResizePreview() async throws {
        let session = makeSession()
        session.shapeCornerRadius = 10
        session.shapeSmoothing = true
        session.beginShape(at: CGPoint(x: 10, y: 10))
        #expect(session.shapeDraft?.smoothing == true)
        session.shapeSmoothing = false // the draft keeps the choice made at the start of the drag
        session.dragShape(to: CGPoint(x: 70, y: 60), square: false, fromCenter: false)
        session.finishShape()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Smoothing-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.layers.last?.shape?.smoothing == true)
        let reopened = makeSession()
        reopened.installProject(loaded, from: url)
        reopened.beginTransform()
        var transform = try #require(reopened.transformEdit?.draft)
        transform.size = CGSize(width: 80, height: 60)
        let layer = try #require(reopened.activeLayer)
        let preview = try #require(reopened.shapeTransformPreview(for: layer, transform: transform))
        reopened.previewTransform(transform)
        reopened.commitTransform()
        let image = try #require(reopened.activeLayer?.liveShape?.image)
        let reference = try EditorSession.shapeImage(.rectangle, size: transform.size, color: session.foregroundColor,
                                                    cornerRadius: 10, smoothing: true)
        #expect(image.width == 80 && image.height == 60)
        #expect(image.dataProvider?.data == reference.dataProvider?.data)
        #expect(preview.dataProvider?.data == reference.dataProvider?.data)

        let oldStyle = LayerShapeStyle(kind: .rectangle, red: 1, green: 0, blue: 0, cornerRadius: 10)
        let decoded = try JSONDecoder().decode(LayerShapeStyle.self, from: JSONEncoder().encode(oldStyle))
        #expect(decoded.smoothing == nil, "older shapes keep their circular corners")
        var older = snapshot.manifest
        older.version = 13
        await #expect(throws: (any Error).self) {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: older, images: snapshot.images), to: url)
        }
    }


    @Test func shiftUStepsThroughEveryShapeInTheFlyoutsOrder() {
        let session = makeSession()
        var seen: [ShapeKind] = [session.shapeKind]
        for _ in 1..<ShapeKind.allCases.count { session.toggleShapeKind(); seen.append(session.shapeKind) }
        #expect(seen == [.rectangle, .ellipse, .triangle, .polygon, .star, .line, .custom])
        session.toggleShapeKind()
        #expect(session.shapeKind == .rectangle)
    }

    /// Polygons and stars put their first point at the top and are stretched to fill the box they're dragged out to.
    @Test func trianglesPolygonsAndStarsFillTheirBox() {
        let rect = CGRect(x: 10, y: 20, width: 90, height: 60)
        func corners(_ path: CGPath) -> Int {
            var count = 0
            path.applyWithBlock { if $0.pointee.type == .addLineToPoint || $0.pointee.type == .moveToPoint { count += 1 } }
            return count
        }
        for kind in [ShapeKind.triangle, .polygon, .star] {
            let bounds = kind.path(in: rect, sides: 7).boundingBoxOfPath
            #expect(abs(bounds.minX - rect.minX) < 0.001 && abs(bounds.maxX - rect.maxX) < 0.001, "\(kind) fills the width")
            #expect(abs(bounds.minY - rect.minY) < 0.001 && abs(bounds.maxY - rect.maxY) < 0.001, "\(kind) fills the height")
        }
        #expect(corners(ShapeKind.triangle.path(in: rect)) == 3)
        #expect(corners(ShapeKind.polygon.path(in: rect, sides: 7)) == 7)
        #expect(corners(ShapeKind.star.path(in: rect, sides: 5)) == 10)
        #expect(corners(ShapeKind.polygon.path(in: rect, sides: 1)) == 3, "fewer than three sides is clamped")
        // The star's inner corners are at half its reach, so its middle is filled but between two points is not.
        let star = ShapeKind.star.path(in: CGRect(x: 0, y: 0, width: 100, height: 100), sides: 5)
        #expect(star.contains(CGPoint(x: 50, y: 50)) && !star.contains(CGPoint(x: 80, y: 15)))
        // A radius rounds the triangle's corners, so its tip is cut away.
        let rounded = ShapeKind.triangle.path(in: CGRect(x: 0, y: 0, width: 100, height: 100), cornerRadius: 10)
        #expect(!rounded.contains(CGPoint(x: 50, y: 1)) && rounded.contains(CGPoint(x: 50, y: 50)))
    }

    @Test func aStrokeGrowsTheLayerAndKeepsItsWidthWhenScaled() async throws {
        let session = makeSession()
        session.shapeStrokeEnabled = true
        session.shapeStrokeColor = PaletteColor(red: 0, green: 0, blue: 1)
        session.shapeStrokeWidth = 4
        session.shapeStrokeOptions.join = .round
        session.shapeFilled = false
        drag(session, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 60, y: 50))
        let layer = try #require(session.activeLayer)
        // Half the stroke reaches outside the 40 × 30 box on every side.
        #expect(layer.transform.origin == CGPoint(x: 18, y: 18) && layer.transform.size == CGSize(width: 44, height: 34))
        let style = try #require(layer.liveShape?.style)
        #expect(style.stroke?.width == 4 && style.filled == false && style.needsVersion17)
        let pixel = try await pixels(session)
        #expect(pixel(20, 35).alpha == 255 && pixel(20, 35).red == 0, "the blue stroke sits on the outline")
        #expect(pixel(40, 35).alpha == 0, "no fill inside")

        session.beginTransform()
        var transform = try #require(session.transformEdit?.draft)
        transform.size = CGSize(width: 88, height: 34)
        session.previewTransform(transform)
        session.commitTransform()
        let image = try #require(session.activeLayer?.liveShape?.image)
        let reference = try EditorSession.shapeImage(style, size: CGSize(width: 88, height: 34))
        #expect(image.dataProvider?.data == reference.dataProvider?.data, "redrawn at the new size, not stretched")
    }

    @Test func pixelsModePaintsIntoTheActiveLayerAsOneUndoStep() async throws {
        let session = makeSession()
        session.shapeMode = .pixels
        let count = session.history.undoCount
        let layers = session.document?.layers.map(\.id)
        session.beginShape(at: CGPoint(x: 10, y: 10))
        session.dragShape(to: CGPoint(x: 30, y: 30), square: false, fromCenter: false)
        session.finishShape()
        for _ in 0..<200 where session.history.undoCount == count { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.document?.layers.map(\.id) == layers, "no new layer")
        #expect(session.history.undoCount == count + 1)
        #expect(session.activeLayer?.liveShape == nil)
        let pixel = try await pixels(session)
        #expect(pixel(20, 20) == (255, 255) && pixel(35, 35).alpha == 0)
    }

    @Test func pathModeDrawsAWorkPathThatBecomesTheSelection() {
        let session = makeSession()
        session.shapeMode = .path
        session.shapeKind = .ellipse
        let count = session.history.undoCount
        drag(session, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 60, y: 60))
        #expect(session.document?.layers.count == 1 && session.history.undoCount == count, "a path is not a layer")
        let path = try? #require(session.workPath)
        #expect(path?.boundingBoxOfPath == CGRect(x: 20, y: 20, width: 40, height: 40))
        session.makeSelectionFromWorkPath()
        #expect(session.selection?.path.contains(CGPoint(x: 40, y: 40)) == true)
        #expect(session.selection?.path.contains(CGPoint(x: 21, y: 21)) == false, "the ellipse, not its box")
        #expect(session.history.undoCount == count + 1)
        session.shapeMode = .shape
        #expect(session.workPath == nil, "leaving Path mode drops the work path")
    }

    @Test func customShapesKeepTheirProportionsWithShiftAndTheirNameOnTheLayer() async throws {
        let session = makeSession()
        session.shapeKind = .custom
        let heart = try #require(ShapeLibrary.defaultGroup().shapes.first { $0.name == "Heart" })
        session.customShape = heart
        session.beginShape(at: CGPoint(x: 10, y: 10))
        session.dragShape(to: CGPoint(x: 70, y: 20), square: true, fromCenter: false)
        let rect = try #require(session.shapeDraft?.rect)
        #expect(abs(rect.width / rect.height - heart.outline.aspect) < 0.05)
        session.finishShape()
        #expect(session.activeLayer?.name == "Heart 1")
        #expect(session.activeLayer?.liveShape?.style.outline == heart.outline)
    }

    @Test func newShapeOptionsSurviveSavingAndNeedVersion17() async throws {
        let session = makeSession()
        session.shapeKind = .star
        session.shapeSides = 7
        session.shapeStrokeEnabled = true
        session.shapeStrokeOptions = ShapeStrokeOptions(dash: .dashed, cap: .round, join: .bevel)
        drag(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 60))
        session.shapeKind = .custom
        session.customShape = ShapeLibrary.defaultGroup().shapes.first
        drag(session, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 40, y: 40))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Shapes-\(UUID()).pbox")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let shapes = loaded.manifest.layers.compactMap(\.shape)
        #expect(shapes.count == 2)
        #expect(shapes.first?.kind == .star && shapes.first?.sides == 7 && shapes.first?.stroke?.options.dash == .dashed)
        // Saved outlines are rounded to a millionth of the shape's box.
        let outline = try #require(snapshot.manifest.layers.last?.shape?.outline)
        let rounded = try JSONDecoder().decode(ShapeOutline.self, from: JSONEncoder().encode(outline))
        #expect(shapes.last?.kind == .custom && shapes.last?.outline == rounded)
        var older = snapshot.manifest
        older.version = 16
        await #expect(throws: (any Error).self) {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: older, images: snapshot.images), to: url)
        }
    }
}
