import AppKit
import Testing
@testable import Pixegen

/// The app-wide color well and picker popover (PBX-12): live colors, Escape, both eyedroppers, swatches and recents.
@MainActor
@Suite(.serialized)
struct ColorWellTests {
    /// A 4 × 4 canvas: red in its top two rows, blue in the bottom two.
    private func session() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 4, height: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0, 0, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 2, width: 4, height: 2))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Split"))
        return session
    }
    private let red = PaletteColor(red: 1, green: 0, blue: 0)
    private let blue = PaletteColor(red: 0, green: 0, blue: 1)

    @Test func theSwatchFollowsThePickerLiveAndEscapePutsItBack() throws {
        let session = try session()
        session.openColorPicker(background: false)
        session.colorPicker?.hsb.setRGB(PaletteColor(red: 0, green: 1, blue: 0))
        session.previewPickerColor()
        #expect(session.foregroundColor.hex == "00FF00", "live, before the picker closes")
        session.closeColorPicker(commit: false)
        #expect(session.foregroundColor == .black)

        session.openColorPicker(background: true)
        session.colorPicker?.hsb.setRGB(red)
        session.previewPickerColor()
        session.closeColorPicker(commit: true)
        #expect(session.backgroundColor == red && session.foregroundColor == .black)
        #expect(RecentColors.shared.colors.first == red, "a color chosen joins the recent colors")
    }

    @Test func aWellsEyedropperPicksStraightIntoItWithoutAPopover() throws {
        let session = try session()
        let open = { session.openColorPicker(background: false) }
        session.beginEyedropper(intoPicker: false) { session.pickColor($0, opening: open) }
        #expect(session.eyedropper != nil)
        session.previewEyedropper(at: CGPoint(x: 1, y: 0))
        #expect(session.foregroundColor == .black, "nothing changes until the mouse is let go")
        session.finishEyedropper(commit: true)
        #expect(session.foregroundColor == red && session.colorPicker == nil && session.eyedropper == nil)

        session.beginEyedropper(intoPicker: false) { session.pickColor($0, opening: open) }
        session.previewEyedropper(at: CGPoint(x: 1, y: 3))
        session.finishEyedropper(commit: false)
        #expect(session.foregroundColor == red, "Escape picks nothing")
    }

    @Test func thePickersEyedropperSamplesIntoItAndLeavesItOpen() throws {
        let session = try session()
        session.openColorPicker(background: false)
        session.beginEyedropper(intoPicker: true)
        session.previewEyedropper(at: CGPoint(x: 2, y: 3))
        #expect(session.colorPicker?.color == blue && session.foregroundColor == blue)
        session.finishEyedropper(commit: true)
        #expect(session.colorPicker != nil, "still open")
        session.closeColorPicker(commit: false)
        #expect(session.foregroundColor == .black)
    }

    @Test func aShapesFillFollowsThePickerAsOneUndoStepThatEscapeTakesBack() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 80, emptyLayer: true)
        session.selectTool(.shape)
        session.foregroundColor = red
        session.beginShape(at: CGPoint(x: 10, y: 10))
        session.dragShape(to: CGPoint(x: 40, y: 30), square: false, fromCenter: false)
        session.finishShape()
        let count = session.history.undoCount
        session.openFillColorPicker()
        for color in [blue, PaletteColor(red: 0, green: 1, blue: 0), blue] {
            session.colorPicker?.hsb.setRGB(color)
            session.previewPickerColor()
        }
        #expect(session.activeLayer?.liveShape?.style.color == blue)
        #expect(session.history.undoCount == count + 1)
        session.closeColorPicker(commit: false)
        #expect(session.activeLayer?.liveShape?.style.color == red && session.history.undoCount == count)

        session.openFillColorPicker()
        session.colorPicker?.hsb.setRGB(blue)
        session.previewPickerColor()
        session.closeColorPicker(commit: true)
        #expect(session.activeLayer?.liveShape?.style.color == blue && session.history.undoCount == count + 1)
        #expect(session.foregroundColor == red, "a shape's fill is its own, not the foreground color")
    }

    @Test func theMagnifierShowsThePixelsAroundThePointer() throws {
        let session = try session()
        let patch = try #require(session.compositePatch(around: CGPoint(x: 1, y: 2)))
        let side = EditorSession.loupeRadius * 2 + 1
        #expect(patch.width == side && patch.height == side)
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(patch, in: CGRect(x: 0, y: 0, width: side, height: side))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let at = (y * side + x) * 4
            return (Int(bytes[at]), Int(bytes[at + 2]), Int(bytes[at + 3]))
        }
        let middle = EditorSession.loupeRadius
        #expect(pixel(middle, middle) == (0, 255, 255), "the pixel under the pointer, blue")
        #expect(pixel(middle, middle - 1) == (255, 0, 255), "the row above it, red")
        #expect(pixel(0, 0).2 == 0, "outside the canvas is clear")
    }

    @Test func recentColorsAreKeptAcrossLaunchesTwelveAtMostEachOnce() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Recent-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let recents = RecentColors(fileURL: url)
        #expect(recents.colors.isEmpty)
        for step in 0..<15 { recents.add(PaletteColor(red: CGFloat(step) / 20, green: 0, blue: 0)) }
        recents.add(PaletteColor(red: 10.0 / 20, green: 0, blue: 0))
        #expect(recents.colors.count == RecentColors.limit)
        #expect(recents.colors.first == PaletteColor(red: 10.0 / 20, green: 0, blue: 0), "a color chosen again moves to the front")
        #expect(Set(recents.colors.map(\.hex)).count == recents.colors.count, "each once")
        #expect(RecentColors(fileURL: url).colors == recents.colors)
    }

    @Test func thePopoversPlusAddsToTheProjectsSwatchesAsAnUndoableEdit() throws {
        let session = try session()
        let folder = try #require(session.swatchGroups.first)
        let count = session.history.undoCount
        let added = try #require(session.addSwatch(red, named: "", near: folder.id))
        #expect(session.swatchGroup(containing: added)?.id == folder.id && session.history.undoCount == count + 1)
        session.undo()
        #expect(session.swatch(added) == nil)
    }

    @Test func thePopoverPointsAtItsWellKeepsTheColorAndEscapeRevertsIt() throws {
        NSApp.activate(ignoringOtherApps: true)
        let session = try session()
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let anchor = NSView(frame: CGRect(x: 20, y: 20, width: 60, height: 20))
        window.contentView?.addSubview(anchor)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let controller = ColorPopoverController()
        session.colorPickerAnchor = anchor
        session.openColorPicker(background: false)
        controller.show(try #require(session.colorPicker), session: session)
        #expect(controller.isShown)
        session.colorPicker?.hsb.setRGB(blue)
        session.previewPickerColor()
        controller.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(!controller.isShown && session.colorPicker == nil && session.foregroundColor == .black)

        session.colorPickerAnchor = anchor
        session.openColorPicker(background: false)
        controller.show(try #require(session.colorPicker), session: session)
        session.colorPicker?.hsb.setRGB(blue)
        session.previewPickerColor()
        controller.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(session.colorPicker == nil && session.foregroundColor == blue, "closing keeps the color")
    }

    @Test func onlyItsWellOrEscapePutsThePickerAway() throws {
        let session = try session()
        let well = NSView(), other = NSView()
        session.clickColorWell(well) { session.openColorPicker(background: false) }
        #expect(session.colorPicker != nil && session.colorPickerAnchor === well)
        session.colorPicker?.hsb.setRGB(blue)
        session.previewPickerColor()
        session.clickColorWell(well) { session.openColorPicker(background: false) }
        #expect(session.colorPicker == nil && session.foregroundColor == blue, "a second click on its well: closed, keeping the color")

        // Another well, clicked while it's open, keeps the first one's color and opens its own picker.
        session.clickColorWell(well) { session.openColorPicker(background: false) }
        session.colorPicker?.hsb.setRGB(red)
        session.previewPickerColor()
        session.clickColorWell(other) { session.openColorPicker(background: true) }
        #expect(session.foregroundColor == red)
        #expect(session.colorPicker?.target == .palette(background: true) && session.colorPickerAnchor === other)

        session.colorPicker?.hsb.setRGB(blue)
        session.previewPickerColor()
        #expect(session.cancelColorPicker(), "Escape, from wherever the keys are")
        #expect(session.colorPicker == nil && session.backgroundColor == .white, "with the original color back")
        #expect(!session.cancelColorPicker(), "nothing to close")

        // A well that goes away takes its picker with it.
        session.clickColorWell(well) { session.openColorPicker(background: false) }
        session.wellDisappeared(other)
        #expect(session.colorPicker != nil, "not another well's")
        session.wellDisappeared(well)
        #expect(session.colorPicker == nil)
    }
}
