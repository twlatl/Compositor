import AppKit
import Testing
@testable import PixelBox

@MainActor
struct GradientTests {
    private func makeSession(width: Int = 101, height: Int = 4) -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: width, height: height)
        session.addBlankLayer()
        session.selectTool(.gradient)
        #expect(session.gradientSettings.style == .foregroundToTransparent)
        session.gradientSettings.style = .foregroundToBackground
        return session
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let index = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[index + $0]) }
    }
    private func render(_ session: EditorSession) async throws -> CGImage {
        try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
    }
    private func drag(_ session: EditorSession, from start: CGPoint, to end: CGPoint) {
        session.beginGradient(at: start)
        session.moveGradient(end: end)
        session.endGradientDrag()
    }
    // Core Graphics quantizes gradient ramps, so endpoints can land a few levels short.
    private func near(_ value: Int, _ target: Int, _ tolerance: Int = 3) -> Bool { abs(value - target) <= tolerance }
    private func near(_ value: [Int], _ target: [Int]) -> Bool { zip(value, target).allSatisfy { near($0, $1) } }

    @Test func foregroundToBackgroundFillsCanvasAndCommitsOneUndo() async throws {
        let session = makeSession()
        let count = session.history.undoCount
        drag(session, from: CGPoint(x: 0.5, y: 2), to: CGPoint(x: 100.5, y: 2))
        #expect(session.gradientEdit != nil)
        #expect(session.activeLayer?.asset == nil && session.history.undoCount == count)
        await session.commitGradient()
        #expect(session.gradientEdit == nil && session.brushError == nil)
        #expect(session.history.undoCount == count + 1)
        let result = try await render(session)
        #expect(near(try pixel(result, x: 0, y: 0), [0, 0, 0, 255]))
        #expect(near(try pixel(result, x: 100, y: 3), [255, 255, 255, 255]))
        let middle = try pixel(result, x: 50, y: 1)
        #expect(near(middle[0], 128) && middle[0] == middle[1] && middle[3] == 255)
        session.undo()
        #expect(session.activeLayer?.asset == nil)
    }

    @Test func radialSpreadsFromStartToRimInEveryDirection() async throws {
        let session = makeSession(width: 101, height: 101)
        session.gradientSettings.shape = .radial
        drag(session, from: CGPoint(x: 50.5, y: 50.5), to: CGPoint(x: 90.5, y: 50.5))
        await session.commitGradient()
        let result = try await render(session)
        #expect(near(try pixel(result, x: 50, y: 50), [0, 0, 0, 255]))
        // Equal distances in any direction get the same value; beyond the rim is background.
        let halfway = try [(70, 50), (30, 50), (50, 70), (50, 30)].map { try pixel(result, x: $0.0, y: $0.1)[0] }
        #expect(halfway.allSatisfy { near($0, 128, 5) && near($0, halfway[0], 1) }, "\(halfway)")
        #expect(near(try pixel(result, x: 100, y: 50), [255, 255, 255, 255]))
        #expect(near(try pixel(result, x: 0, y: 0), [255, 255, 255, 255]))
    }

    @Test func reverseOpacityAndDirectionFollowSettings() async throws {
        let session = makeSession()
        session.gradientSettings.reversed = true
        session.gradientSettings.opacity = 0.5
        drag(session, from: CGPoint(x: 0.5, y: 2), to: CGPoint(x: 100.5, y: 2))
        await session.commitGradient()
        let result = try await render(session)
        // White at the start with 50% alpha on a blank layer.
        let start = try pixel(result, x: 0, y: 2)
        #expect(near(start[3], 128) && near(start[0], start[3]))
        let end = try pixel(result, x: 100, y: 2)
        #expect(near(end[0], 0) && near(end[3], 128))
    }

    @Test func foregroundToTransparentPreservesUnderlyingPixelsAndAlpha() async throws {
        let session = makeSession()
        session.gradientSettings.style = .foregroundToBackground
        session.setPaletteColor(PaletteColor(red: 1, green: 0, blue: 0), background: false)
        // Everything before the start is foreground: a solid red layer.
        drag(session, from: CGPoint(x: 100.5, y: 2), to: CGPoint(x: 101, y: 2))
        await session.commitGradient()
        #expect(near(try pixel(try await render(session), x: 50, y: 2), [255, 0, 0, 255]))
        session.setPaletteColor(.black, background: false)
        session.gradientSettings.style = .foregroundToTransparent
        drag(session, from: CGPoint(x: 0.5, y: 2), to: CGPoint(x: 100.5, y: 2))
        await session.commitGradient()
        let result = try await render(session)
        #expect(near(try pixel(result, x: 0, y: 2), [0, 0, 0, 255]))
        #expect(near(try pixel(result, x: 100, y: 2), [255, 0, 0, 255]))
        let middle = try pixel(result, x: 50, y: 2)
        #expect(near(middle[0], 128) && middle[1] == 0 && middle[3] == 255)
    }

    @Test func cancelUndoAndClicksLeaveDocumentUntouched() async throws {
        let session = makeSession()
        let before = session.document
        session.beginGradient(at: CGPoint(x: 10, y: 2))
        session.endGradientDrag()
        #expect(session.gradientEdit == nil)
        drag(session, from: CGPoint(x: 0, y: 2), to: CGPoint(x: 100, y: 2))
        session.cancelGradient()
        #expect(session.gradientEdit == nil && session.document == before)
        drag(session, from: CGPoint(x: 0, y: 2), to: CGPoint(x: 100, y: 2))
        session.undo()
        #expect(session.gradientEdit == nil && session.document == before)
    }

    @Test func redraggingReplacesPendingLineWithoutAccumulating() async throws {
        let session = makeSession()
        drag(session, from: CGPoint(x: 0.5, y: 2), to: CGPoint(x: 100.5, y: 2))
        drag(session, from: CGPoint(x: 100.5, y: 2), to: CGPoint(x: 0.5, y: 2))
        await session.commitGradient()
        let result = try await render(session)
        #expect(near(try pixel(result, x: 0, y: 2), [255, 255, 255, 255]))
        #expect(near(try pixel(result, x: 100, y: 2), [0, 0, 0, 255]))
    }

    @Test func maskGradientWritesCoverageInsideLayerBounds() async throws {
        let session = makeSession()
        drag(session, from: CGPoint(x: 0, y: 2), to: CGPoint(x: 0.6, y: 2))
        await session.commitGradient() // Opaque black layer.
        session.addLayerMask(revealing: true)
        let id = try #require(session.activeLayerID)
        session.selectLayerTarget(id, mask: true)
        #expect(session.isMaskSelected)
        drag(session, from: CGPoint(x: 0.5, y: 2), to: CGPoint(x: 100.5, y: 2))
        await session.commitGradient()
        #expect(session.brushError == nil)
        let result = try await render(session)
        // Default mask palette paints black (hide) to white (reveal).
        #expect(near(try pixel(result, x: 0, y: 2)[3], 0))
        #expect(near(try pixel(result, x: 100, y: 2)[3], 255))
        #expect(near(try pixel(result, x: 50, y: 2)[3], 128))
    }

    @Test func paletteChangesUpdatePendingPreview() throws {
        let session = makeSession()
        drag(session, from: CGPoint(x: 0.5, y: 2), to: CGPoint(x: 100.5, y: 2))
        let revision = session.brushRevision
        session.swapPaletteColors()
        #expect(session.brushRevision > revision)
        #expect(session.gradientColors(mask: false).first.flatMap { $0.components?.first } == 1)
        session.cancelGradient()
    }

    // MARK: Stops and midpoints (PBX-13)

    private let red = PaletteColor(red: 1, green: 0, blue: 0)
    private let green = PaletteColor(red: 0, green: 1, blue: 0)
    private let blue = PaletteColor(red: 0, green: 0, blue: 1)
    private var threeColors: ColorGradient {
        ColorGradient(stops: [GradientStop(location: 0, color: red), GradientStop(location: 0.5, color: green),
                              GradientStop(location: 1, color: blue)])
    }

    @Test func aMidpointIsWhereTwoColorsBlendHalfAndHalf() {
        var gradient = ColorGradient(.black, .white)
        #expect(abs(gradient.value(at: 0.5).color.red - 0.5) < 0.001 && gradient.isSimple)
        gradient.stops[0].midpoint = 0.25
        #expect(abs(gradient.value(at: 0.25).color.red - 0.5) < 0.001, "half and half at the midpoint")
        #expect(gradient.value(at: 0.5).color.red > 0.7, "and further on past it")
        #expect(!gradient.isSimple && gradient.samples.count > 2, "Core Graphics gets the curve as extra stops")
        // Reversed, the same blend sits the same way between the same two colors.
        let reversed = gradient.reversed
        #expect(abs(reversed.value(at: 0.75).color.red - 0.5) < 0.001)
        #expect(reversed.sorted.first?.color == .white && reversed.reversed == gradient)
        #expect(!ColorGradient(stops: [GradientStop(location: 0, color: red)]).isValid, "at least two stops")
    }

    @Test func theToolDrawsEveryStopWithOpacity() async throws {
        let session = makeSession()
        var gradient = threeColors
        gradient.stops[2].opacity = 0
        session.gradientSettings.gradient = gradient
        #expect(session.gradientSettings.style == nil, "not one of the built-ins")
        drag(session, from: CGPoint(x: 0.5, y: 2), to: CGPoint(x: 100.5, y: 2))
        await session.commitGradient()
        let result = try await render(session)
        #expect(near(try pixel(result, x: 0, y: 1), [255, 0, 0, 255]))
        #expect(near(try pixel(result, x: 50, y: 1), [0, 255, 0, 255]), "the middle stop")
        #expect(try pixel(result, x: 100, y: 1)[3] <= 3, "the last stop is transparent")
        // The built-in gradients still follow the palette.
        session.gradientSettings.style = .foregroundToBackground
        session.foregroundColor = red
        #expect(session.gradientColors(mask: false).first?.components?.prefix(3).map { $0 } == [1, 0, 0])
    }

    @Test func gradientMapMapsTonesThroughEveryColor() throws {
        var settings = GradientMapSettings()
        settings.gradient = threeColors
        #expect(settings.stops != nil && settings.shadows == AdjustmentColor(red) && settings.highlights == AdjustmentColor(blue))
        let context = try #require(CGContext(data: nil, width: 3, height: 1, bitsPerComponent: 8, bytesPerRow: 12,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        for (x, gray) in [(0, 0.0), (1, 0.5), (2, 1.0)] {
            context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: 1))
        }
        let mapped = try settings.apply(try #require(context.makeImage()))
        #expect(near(try pixel(mapped, x: 0, y: 0), [255, 0, 0, 255]))
        #expect(near(try pixel(mapped, x: 1, y: 0), [0, 255, 0, 255]), "middle gray takes the middle color")
        #expect(near(try pixel(mapped, x: 2, y: 0), [0, 0, 255, 255]))
        // Two plain colors at the ends are saved the old way.
        settings.gradient = ColorGradient(red, blue)
        #expect(settings.stops == nil)
    }

    @Test func aGradientMapLayersStopsNeedVersion17() async throws {
        let session = EditorSession()
        session.createDocument(width: 8, height: 8)
        session.addAdjustment(.gradientMap)
        let index = try #require(session.document?.layers.firstIndex { $0.adjustment?.kind == .gradientMap })
        session.document?.layers[index].adjustment?.gradientMap.gradient = threeColors
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GradientMap-\(UUID()).pbox")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let saved = loaded.manifest.layers.compactMap { $0.adjustment?.gradientMapSettings?.stops }
        let stops = try #require(saved.first)
        #expect(stops == threeColors)
        var older = snapshot.manifest
        older.version = 16
        await #expect(throws: (any Error).self) {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: older, images: snapshot.images), to: url)
        }
    }

    @Test func theEditorChangesTheToolsGradientLiveAndEscapePutsItBack() throws {
        let session = makeSession()
        session.foregroundColor = red
        session.openGradientPicker(.tool)
        let picker = try #require(session.colorPicker)
        let first = try #require(picker.gradient?.sorted.first)
        #expect(first.role == .foreground && picker.color == red, "a stop that follows the palette shows its color")
        picker.colorChanged()
        #expect(picker.gradient?.sorted.first?.role == .foreground, "selecting it doesn't change it")
        picker.hsb.setRGB(green)
        picker.colorChanged()
        session.previewPickerColor()
        #expect(session.gradientSettings.gradient.sorted.first?.color == green && session.gradientSettings.gradient.sorted.first?.role == nil)
        session.closeColorPicker(commit: false)
        #expect(session.gradientSettings.style == .foregroundToBackground, "Escape puts it back")

        session.openGradientPicker(.tool)
        let saved = try #require(GradientLibrary.builtInSet().gradients.first { $0.name == "Spectrum" })
        session.colorPicker?.load(saved.gradient)
        session.previewPickerColor()
        session.closeColorPicker(commit: true)
        #expect(session.gradientSettings.gradient == saved.gradient, "a saved gradient, kept")
    }

    @Test func gradientSetsAreKeptAcrossLaunches() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Gradients-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let library = GradientLibrary(fileURL: url)
        #expect(library.selectedSet?.gradients.first?.gradient == .foregroundToBackground)
        let set = library.newSet(named: "Mine")
        library.addGradient(threeColors, to: set)
        let saved = try #require(library.selectedSet?.gradients.first)
        library.renameGradient(saved.id, to: "Traffic")
        let reopened = GradientLibrary(fileURL: url)
        #expect(reopened.selectedSet?.name == "Mine" && reopened.selectedSet?.gradients.first?.name == "Traffic")
        #expect(reopened.selectedSet?.gradients.first?.gradient == threeColors)
        reopened.deleteGradient(saved.id)
        for id in reopened.sets.map(\.id) { reopened.deleteSet(id) }
        #expect(reopened.sets.count == 1, "the last set stays")
    }
}
