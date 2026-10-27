import AppKit
import Testing
@testable import Pixegen

@MainActor
struct TextOutlineTests {
    /// A document with one text layer of `content`, 72 points in Helvetica, black unless `colors` paints runs.
    private func makeSession(_ content: String = "Pix", colors: [LayerTextColorRun]? = nil) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 400, height: 200, emptyLayer: false)
        session.selectTool(.type)
        session.beginText(at: CGPoint(x: 40, y: 120))
        var draft = try #require(session.textDraft)
        draft.style.content = content
        draft.style.red = 0; draft.style.green = 0; draft.style.blue = 0
        draft.style.colorRuns = colors
        #expect(session.applyText(draft))
        return session
    }
    /// The flattened document's coverage: whether each pixel is more than half opaque.
    private func coverage(_ session: EditorSession) async throws -> (width: Int, covered: [Bool]) {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (image.width, (0..<(image.width * image.height)).map { bytes[$0 * 4 + 3] > 128 })
    }
    /// How much two coverages agree: shared pixels over pixels either covers.
    private func overlap(_ a: [Bool], _ b: [Bool]) -> Double {
        let both = zip(a, b).filter { $0 && $1 }.count, either = zip(a, b).filter { $0 || $1 }.count
        return either == 0 ? 0 : Double(both) / Double(either)
    }

    @Test func textBecomesAShapeInItsPlaceAsOneStep() async throws {
        let session = try makeSession()
        let id = try #require(session.activeLayerID)
        session.selectTool(.move)
        #expect(session.canConvertTextToOutline)
        let before = try await coverage(session)
        let count = session.history.undoCount
        session.convertTextToOutline()
        let layer = try #require(session.document?.layers.first)
        #expect(layer.id == id, "the text layer itself becomes the shape")
        #expect(layer.liveText == nil)
        #expect(layer.liveShape?.style.kind == .custom)
        #expect(layer.liveShape?.style.color == PaletteColor(red: 0, green: 0, blue: 0))
        #expect(layer.name == "Pix")
        #expect(session.history.undoCount == count + 1)
        let after = try await coverage(session)
        #expect(overlap(before.covered, after.covered) > 0.9, "the letters land where the text drew them")
        session.undo()
        #expect(session.document?.layers.first?.liveText != nil)
    }

    @Test func turnedTextKeepsItsLook() async throws {
        let session = try makeSession()
        let index = try #require(session.document?.layers.indices.first)
        session.document?.layers[index].transform.rotation = 30
        session.document?.layers[index].transform.flipX = true
        let before = try await coverage(session)
        session.convertTextToOutline()
        #expect(session.document?.layers.first?.transform.rotation == 0)
        let after = try await coverage(session)
        #expect(overlap(before.covered, after.covered) > 0.85)
    }

    @Test func severalColorsMakeAFolderOfOneShapeEach() throws {
        let session = try makeSession("ABC", colors: [LayerTextColorRun(location: 1, length: 1, red: 1, green: 0, blue: 0)])
        let id = try #require(session.activeLayerID)
        session.convertTextToOutline()
        let layers = try #require(session.document?.layers)
        let folder = try #require(layers.first)
        #expect(folder.isGroup)
        #expect(folder.name == "ABC")
        #expect(folder.id != id)
        let shapes = layers.filter { $0.parentID == folder.id }
        #expect(shapes.map(\.name) == ["AC", "B"])
        #expect(shapes.map { $0.liveShape?.style.color } == [PaletteColor(red: 0, green: 0, blue: 0), PaletteColor(red: 1, green: 0, blue: 0)])
        #expect(session.activeLayerID == folder.id)
    }

    @Test func onlyTextCanBeConverted() throws {
        let session = try makeSession()
        session.document?.layers[0].text = nil
        #expect(!session.canConvertTextToOutline)
    }

    @Test func spacesAddNothingAndBlankTextHasNoOutline() {
        var style = LayerTextStyle()
        style.content = "A B"
        #expect(EditorSession.textOutlines(style).first?.letters == "AB")
        style.content = "   "
        #expect(EditorSession.textOutlines(style).isEmpty)
    }
}
