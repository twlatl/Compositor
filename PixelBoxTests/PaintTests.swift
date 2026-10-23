import AppKit
import Testing
@testable import PixelBox

/// Painting with a color or a gradient: shape layers' fills and strokes, and filling a selection.
@MainActor
struct PaintTests {
    private let red = PaletteColor(red: 1, green: 0, blue: 0)
    private let blue = PaletteColor(red: 0, green: 0, blue: 1)

    private func shapeSession() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 100, height: 40, emptyLayer: true)
        session.selectTool(.shape)
        session.foregroundColor = red
        return session
    }
    private func draw(_ session: EditorSession, _ kind: ShapeKind = .rectangle, from start: CGPoint, to end: CGPoint) {
        session.shapeKind = kind
        session.beginShape(at: start)
        session.dragShape(to: end, square: false, fromCenter: false)
        session.finishShape()
    }
    /// The flattened document's RGBA at a pixel.
    private func pixel(_ session: EditorSession, _ x: Int, _ y: Int) async throws -> [Int] {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let at = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[at + $0]) }
    }
    private func near(_ a: [Int], _ b: [Int], _ tolerance: Int = 8) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= tolerance } }

    @Test func onlyShapesAndSelectionsOfferAGradient() {
        let session = shapeSession()
        session.openColorPicker(background: false)
        #expect(session.colorPicker?.allowsGradient == false, "the foreground color is only ever a color")
        session.closeColorPicker(commit: false)
        session.openFillColorPicker()
        #expect(session.colorPicker?.allowsGradient == true)
        session.closeColorPicker(commit: false)
        session.openDialogPaintPicker(title: "Fill", paint: .color(red)) { _ in }
        #expect(session.colorPicker?.allowsGradient == true)
        session.closeColorPicker(commit: false)
    }

    @Test func switchingBackFindsWhatWasThere() throws {
        let state = ColorPickerState(target: .shapeFill, color: red, gradient: nil, allowsGradient: true, foreground: red, background: .white)
        state.switchTo(gradient: true)
        #expect(state.paint == .gradient(ColorGradient(red, .white)), "a new gradient runs from the color to the background")
        let stop = try #require(state.gradient?.sorted.last)
        state.selectStop(stop.id)
        state.hsb.setRGB(blue)
        state.colorChanged()
        let edited = state.paint
        state.switchTo(gradient: false)
        #expect(state.paint == .color(red))
        state.switchTo(gradient: true)
        #expect(state.paint == edited, "the gradient as it was left")
    }

    @Test func aShapesFillBecomesAGradientAsOneStepThatEscapeTakesBack() async throws {
        let session = shapeSession()
        draw(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 30))
        let count = session.history.undoCount
        session.openFillColorPicker()
        let picker = try #require(session.colorPicker)
        picker.switchTo(gradient: true)
        session.previewPickerColor()
        #expect(session.activeLayer?.liveShape?.style.fillGradient == ColorGradient(red, .white))
        #expect(session.history.undoCount == count + 1)
        #expect(near(try await pixel(session, 11, 20), [255, 0, 0, 255]), "red at the left")
        #expect(near(try await pixel(session, 88, 20), [255, 255, 255, 255], 12), "white at the right")
        session.closeColorPicker(commit: false)
        #expect(session.activeLayer?.liveShape?.style.fillGradient == nil && session.history.undoCount == count)

        session.openFillColorPicker()
        session.colorPicker?.switchTo(gradient: true)
        session.previewPickerColor()
        session.closeColorPicker(commit: true)
        #expect(session.activeLayer?.liveShape?.style.fillGradient != nil)
        session.openFillColorPicker()
        #expect(session.colorPicker?.gradient != nil, "the well opens on the gradient it holds")
        session.colorPicker?.switchTo(gradient: false)
        session.previewPickerColor()
        session.closeColorPicker(commit: true)
        #expect(session.activeLayer?.liveShape?.style.fillGradient == nil, "and back to a color")
    }

    @Test func strokesAndLinesTakeGradientsAndNeedVersion19() async throws {
        let session = shapeSession()
        session.shapeFilled = false
        session.shapeStrokeEnabled = true
        session.shapeStrokeWidth = 4
        session.shapeStrokeGradient = ColorGradient(red, blue)
        draw(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 30))
        #expect(session.activeLayer?.liveShape?.style.stroke?.gradient == ColorGradient(red, blue))
        #expect(near(try await pixel(session, 10, 20), [255, 0, 0, 255], 20), "the left edge red")
        #expect(near(try await pixel(session, 90, 20), [0, 0, 255, 255], 20), "the right edge blue")
        #expect(try await pixel(session, 50, 20)[3] == 0, "nothing inside")

        session.shapeFillGradient = ColorGradient(red, blue)
        session.shapeLineWidth = 6
        draw(session, .line, from: CGPoint(x: 10, y: 36), to: CGPoint(x: 90, y: 36))
        // A line's gradient runs from its start to its end.
        #expect(near(try await pixel(session, 12, 36), [255, 0, 0, 255], 20))
        #expect(near(try await pixel(session, 88, 36), [0, 0, 255, 255], 20))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Paint-\(UUID()).pbox")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let styles = loaded.manifest.layers.compactMap(\.shape)
        #expect(styles.first?.stroke?.gradient == ColorGradient(red, blue) && styles.last?.fillGradient == ColorGradient(red, blue))
        var older = snapshot.manifest
        older.version = 18
        await #expect(throws: (any Error).self) {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: older, images: snapshot.images), to: url)
        }
    }

    @Test func fillPaintsTheSelectionWithAColorOrAGradient() async throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 40, emptyLayer: true)
        session.applySelection(CGPath(rect: CGRect(x: 0, y: 0, width: 50, height: 40), transform: nil), mode: .replace, name: "Select")
        let count = session.history.undoCount
        await session.fillSelection(with: .gradient(ColorGradient(red, blue)))
        #expect(session.history.undoCount == count + 1)
        #expect(near(try await pixel(session, 0, 20), [255, 0, 0, 255], 12))
        #expect(near(try await pixel(session, 49, 20), [0, 0, 255, 255], 12), "across the selection, not the canvas")
        #expect(try await pixel(session, 60, 20)[3] == 0, "outside the selection untouched")
        await session.fillSelection(with: .color(blue))
        #expect(near(try await pixel(session, 25, 20), [0, 0, 255, 255], 0))

        // 90° runs bottom to top.
        let line = EditorSession.gradientLine(across: CGRect(x: 0, y: 0, width: 100, height: 40), angle: 90)
        #expect(abs(line.start.y - 40) < 0.001 && abs(line.end.y) < 0.001 && abs(line.start.x - 50) < 0.001)
    }

    @Test func aDialogsPickerReportsTheColorOrGradientChosen() {
        let session = shapeSession()
        var reported: Paint?
        session.openDialogPaintPicker(title: "Fill", paint: .color(red)) { reported = $0 }
        session.colorPicker?.switchTo(gradient: true)
        session.previewPickerColor()
        #expect(reported == .gradient(ColorGradient(red, .white)), "live")
        session.closeColorPicker(commit: false)
        #expect(reported == .color(red), "Escape reports the original")
        session.openDialogPaintPicker(title: "Fill", paint: .color(red)) { reported = $0 }
        session.colorPicker?.switchTo(gradient: true)
        session.closeColorPicker(commit: true)
        #expect(reported == .gradient(ColorGradient(red, .white)))
    }

    // MARK: Shape, angle, direction and opacity

    /// A 100 × 100 canvas filled with `gradient`, and its RGBA at a pixel.
    private func filled(_ gradient: ColorGradient) async throws -> (Int, Int) async throws -> [Int] {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100, emptyLayer: true)
        await session.fillSelection(with: .gradient(gradient))
        return { x, y in try await self.pixel(session, x, y) }
    }

    @Test func gradientsLieLinearRadialOrAngleAtTheirAngleAndOpacity() async throws {
        var gradient = ColorGradient(red, blue)
        gradient.angle = 90
        var at = try await filled(gradient)
        // 90° runs bottom to top.
        #expect(near(try await at(50, 99), [255, 0, 0, 255], 12))
        #expect(near(try await at(50, 0), [0, 0, 255, 255], 12))

        gradient.isReversed = true
        at = try await filled(gradient)
        #expect(near(try await at(50, 99), [0, 0, 255, 255], 12), "swapped")

        gradient = ColorGradient(red, blue)
        gradient.shape = .radial
        at = try await filled(gradient)
        // Out from the middle.
        #expect(near(try await at(50, 50), [255, 0, 0, 255], 12))
        #expect(near(try await at(0, 0), [0, 0, 255, 255], 20))

        gradient.shape = .angle
        at = try await filled(gradient)
        // Counterclockwise from 0°, pointing right: just above that line it begins, just below it ends.
        #expect(near(try await at(95, 47), [255, 0, 0, 255], 30), "starting at 0°, pointing right")
        let left = try await at(5, 50)
        #expect(left[0] < 200 && left[2] < 200, "half way round by the left: neither end's color")
        #expect(near(try await at(95, 53), [0, 0, 255, 255], 30), "and back round to the end just below the start")

        gradient = ColorGradient(red, red)
        gradient.opacity = 0.5
        at = try await filled(gradient)
        #expect(abs(try await at(50, 50)[3] - 128) <= 2, "at its opacity")
    }

    @Test func gradientsSavedBeforeTheyHadAShapeStillLoad() throws {
        let json = #"{"stops":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","location":0,"color":{"red":1,"green":0,"blue":0},"opacity":1,"midpoint":0.5},{"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","location":1,"color":{"red":0,"green":0,"blue":1},"opacity":1,"midpoint":0.5}]}"#
        let gradient = try JSONDecoder().decode(ColorGradient.self, from: Data(json.utf8))
        #expect(gradient.shape == .linear && gradient.angle == 0 && !gradient.isReversed && gradient.opacity == 1)
        #expect(gradient == ColorGradient(red, blue))
    }

    @Test func theToolsEditorSetsItsShapeDirectionAndOpacity() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 40, emptyLayer: true)
        session.selectTool(.gradient)
        session.gradientSettings.reversed = true
        session.openGradientPicker(.tool)
        let picker = try #require(session.colorPicker)
        #expect(picker.gradient?.isReversed == true && picker.gradient?.shape == .linear)
        picker.gradient?.shape = .angle
        picker.gradient?.opacity = 0.4
        session.previewPickerColor()
        #expect(session.gradientSettings.shape == .angle && session.gradientSettings.opacity == 0.4 && session.gradientSettings.reversed)
        #expect(session.gradientSettings.style == .foregroundToTransparent, "the stops alone stay with the gradient")
        session.closeColorPicker(commit: false)
        #expect(session.gradientSettings.shape == .linear && session.gradientSettings.opacity == 1)
    }

    @Test func theToolSweepsAnAngleGradientAroundWhereTheDragStarts() async throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100, emptyLayer: true)
        session.selectTool(.gradient)
        session.gradientSettings.gradient = ColorGradient(red, blue)
        session.gradientSettings.shape = .angle
        session.beginGradient(at: CGPoint(x: 50, y: 50))
        session.moveGradient(end: CGPoint(x: 90, y: 50))
        session.endGradientDrag()
        await session.commitGradient()
        #expect(near(try await pixel(session, 95, 47), [255, 0, 0, 255], 30), "the first color toward where it was dragged")
        #expect(near(try await pixel(session, 95, 53), [0, 0, 255, 255], 30), "the last just past it, all the way round")
        #expect(try await pixel(session, 5, 50)[3] == 255)
    }

    @Test func aStopsOpacityIsItsOwnAndSwapTurnsTheStopsRound() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 40, emptyLayer: true)
        session.selectTool(.gradient)
        session.gradientSettings.gradient = ColorGradient(red, blue)
        session.gradientSettings.opacity = 0.8
        session.openGradientPicker(.tool)
        let picker = try #require(session.colorPicker)
        let right = try #require(picker.gradient?.sorted.last)
        picker.selectStop(right.id)
        let index = try #require(picker.gradient?.stops.firstIndex { $0.id == right.id })
        picker.gradient?.stops[index].opacity = 0.25
        session.previewPickerColor()
        #expect(session.gradientSettings.gradient.sorted.last?.opacity == 0.25, "the right-hand stop's opacity")
        #expect(session.gradientSettings.opacity == 0.8, "the tool bar's overall opacity is a different value")

        picker.gradient = picker.gradient?.reversed
        session.previewPickerColor()
        let swapped = session.gradientSettings.gradient.sorted
        #expect(swapped.first?.color == blue && swapped.first?.opacity == 0.25 && swapped.last?.color == red, "left to right")
        #expect(picker.selectedStop?.id == right.id, "the same stop stays selected, now on the left")
        #expect(!session.gradientSettings.reversed, "the stops themselves turned, not a flag")
        session.closeColorPicker(commit: true)
    }
}
