import CoreGraphics
import Testing
@testable import Pixegen

@MainActor struct NewCanvasUnitTests {
    /// Print sizes turn into pixels at the DPI: US Letter at 300 DPI is 2550 × 3300.
    @Test func printSizesBecomePixelsAtTheDPI() {
        #expect(NewCanvasUnit.inches.pixels("8.5", resolution: 300) == 2550)
        #expect(NewCanvasUnit.inches.pixels("11", resolution: 300) == 3300)
        #expect(NewCanvasUnit.millimeters.pixels("210", resolution: 300) == 2480, "A4's width")
        #expect(NewCanvasUnit.centimeters.pixels("2,54", resolution: 72) == 72, "a comma works as the decimal point")
        #expect(NewCanvasUnit.pixels.pixels("1920", resolution: 300) == 1920, "pixels ignore the DPI")
        #expect(NewCanvasUnit.pixels.pixels("19.5", resolution: 72) == nil, "pixels are whole")
        #expect(NewCanvasUnit.inches.pixels("200", resolution: 300) == nil, "60,000 pixels is past the side limit")
        #expect(NewCanvasUnit.inches.pixels("0", resolution: 300) == nil)
    }

    /// Switching units writes the same canvas another way, and the pill steps px → in → cm → mm → px.
    @Test func unitsRoundTripAndCycle() {
        #expect(NewCanvasUnit.inches.text(1920, resolution: 72) == "26.67")
        #expect(NewCanvasUnit.inches.text(2550, resolution: 300) == "8.5")
        #expect(NewCanvasUnit.millimeters.text(2480, resolution: 300) == "209.97")
        for unit in NewCanvasUnit.allCases where unit != .pixels {
            #expect(unit.pixels(unit.text(2550, resolution: 300), resolution: 300) == 2550, "\(unit)")
        }
        #expect(NewCanvasUnit.allCases.map(\.next) == [.inches, .centimeters, .millimeters, .pixels])
    }

    /// Resolution is typed in pixels per inch or per centimeter and kept per inch: 72 per inch is 28.35 per cm.
    @Test func resolutionConvertsBetweenInchesAndCentimeters() {
        #expect(ResolutionUnit.perInch.pixelsPerInch("72") == 72)
        #expect(ResolutionUnit.perCentimeter.text(72) == "28.35")
        #expect(ResolutionUnit.perInch.text(300) == "300")
        #expect(abs((ResolutionUnit.perCentimeter.pixelsPerInch("118,11") ?? 0) - 300) < 0.01, "a comma works as the decimal point")
        #expect(ResolutionUnit.perInch.pixelsPerInch("0") == nil)
        #expect(ResolutionUnit.perInch.pixelsPerInch("9601") == nil)
        #expect(ResolutionUnit.perCentimeter.pixelsPerInch("3780") == nil, "past 9,600 per inch")
        #expect(ResolutionUnit.perCentimeter.pixelsPerInch("0.4") != nil && ResolutionUnit.perCentimeter.pixelsPerInch("3779") != nil,
                "the limits the message gives are allowed")
    }

    /// App icon sizes come last, in a group of their own.
    @Test func macIconPresetsComeLast() {
        #expect(CanvasPreset.groups.last?.map(\.title) == ["Mac Icon 1024px", "Mac Icon 512px", "Mac Icon 256px"])
        #expect(CanvasPreset.groups.last?.allSatisfy { $0.width == $0.height } == true)
    }

    /// The chosen DPI is the document's, and goes into the saved project and exports.
    @Test func newProjectKeepsItsResolution() throws {
        let session = EditorSession()
        session.createNewProject(width: 2550, height: 3300, resolution: 300)
        #expect(session.document?.resolution == 300)
        #expect(try #require(session.projectSnapshot()).manifest.resolution == 300)
    }

    /// White and black start the canvas with a Background layer of that color, in full-size pixels; transparent with an
    /// empty layer. The pill steps transparent → white → black.
    @Test func backgroundFillsTheFirstLayer() throws {
        #expect(NewCanvasBackground.allCases.map(\.next) == [.white, .black, .transparent])
        for (background, value) in [(NewCanvasBackground.white, UInt8(255)), (.black, 0)] {
            let session = EditorSession()
            session.createNewProject(width: 40, height: 30, background: background.color)
            let layer = try #require(session.document?.layers.first)
            #expect(layer.name == "Background")
            let image = try #require(layer.asset?.image)
            #expect(image.width == 40 && image.height == 30)
            let pixels = try BrushRaster.copy(image)
            let data = try #require(pixels.data).assumingMemoryBound(to: UInt8.self)
            #expect(data[0] == value && data[3] == 255 && data[(29 * pixels.bytesPerRow) + 39 * 4] == value)
        }
        let session = EditorSession()
        session.createNewProject(width: 40, height: 30, background: NewCanvasBackground.transparent.color)
        #expect(session.document?.layers.first?.asset == nil, "an empty layer, with no pixels until painted")
    }
}
