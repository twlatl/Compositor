import AppKit
import AVFoundation
import ImageIO
import Testing
@testable import Pixegen

@MainActor
struct SliceTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PixegenSliceTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// A session with a canvas of `width` × `height` and the Export panel open.
    private func session(width: Int = 200, height: Int = 100) -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: width, height: height, emptyLayer: true, background: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        session.openExportPanel()
        return session
    }

    private func draw(_ rect: CGRect, in session: EditorSession) {
        session.sliceDraft = (nil, rect)
        session.finishSliceDraft()
    }

    /// Left half opaque red, right half clear: 4 × 2.
    private func composite() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try #require(context.makeImage())
    }

    private func decoded(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    // MARK: Editing

    @Test func exportPanelOpensWithTheSliceToolAndRestoresTheToolOnCancel() {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        session.selectTool(.brush)
        session.openExportPanel()
        #expect(session.exportPanelOpen && session.tool == .slice)
        session.selectTool(.hand)
        #expect(session.exportPanelOpen, "looking around keeps the panel")
        session.selectTool(.slice)
        session.closeExportPanel()
        #expect(!session.exportPanelOpen && session.tool == .brush)
        session.openExportPanel()
        session.selectTool(.marquee)
        #expect(!session.exportPanelOpen, "another tool closes it")
    }

    @Test func drawnSlicesAreNumberedSelectedAndUndoable() {
        let session = session()
        draw(CGRect(x: 10, y: 10, width: 50, height: 40), in: session)
        draw(CGRect(x: 100, y: 20, width: 30, height: 30), in: session)
        let slices = session.document?.slices ?? []
        #expect(slices.map(\.name) == ["Slice 1", "Slice 2"])
        #expect(slices[0].rect == CGRect(x: 10, y: 10, width: 50, height: 40))
        #expect(session.selectedSliceID == slices[1].id)
        #expect(slices[0].formats.map(\.type) == [.png])
        session.undo()
        #expect(session.document?.slices.count == 1)
        session.redo()
        session.deleteSlice(slices[0].id)
        #expect(session.document?.slices.map(\.name) == ["Slice 2"])
        draw(CGRect(x: 0, y: 0, width: 5, height: 5), in: session)
        #expect(session.document?.slices.last?.name == "Slice 3", "numbering carries on past the highest")
    }

    @Test func slicesStayInsideTheCanvas() {
        let session = session()
        #expect(session.clampedSliceRect(CGRect(x: -20, y: 90, width: 50, height: 50)) == CGRect(x: 0, y: 90, width: 30, height: 10))
        #expect(session.clampedSliceRect(CGRect(x: 300, y: 0, width: 10, height: 10)) == nil)
        #expect(session.movedSliceRect(CGRect(x: 180, y: -5, width: 40, height: 20)) == CGRect(x: 160, y: 0, width: 40, height: 20))
    }

    @Test func formatsCanBeAddedChangedRenamedAndRemoved() throws {
        let session = session()
        draw(CGRect(x: 0, y: 0, width: 20, height: 10), in: session)
        let id = try #require(session.selectedSliceID)
        session.addSliceFormat(id)
        var slice = try #require(session.selectedSlice)
        #expect(slice.formats.map(\.scale) == [1, 2] && slice.formats[1].suffix == "@2x")
        session.updateSliceFormat(id, slice.formats[0].id) { $0.type = .jpeg }
        session.updateSliceFormat(id, slice.formats[0].id, "Change Export Quality", coalescing: true) { $0.quality = 0.5 }
        session.updateSliceFormat(id, slice.formats[0].id, "Change Export Quality", coalescing: true) { $0.quality = 0.6 }
        slice = try #require(session.selectedSlice)
        #expect(slice.formats[0].type == .jpeg && slice.formats[0].quality == 0.6)
        session.undo()
        #expect(session.selectedSlice?.formats[0].quality == 0.8, "a dragged quality is one undo step")
        session.removeSliceFormat(id, slice.formats[1].id)
        session.removeSliceFormat(id, slice.formats[0].id)
        #expect(session.selectedSlice?.formats.count == 1, "the last format stays")
        session.renameSlice(id, to: "  Hero  ")
        #expect(session.selectedSlice?.name == "Hero")
        session.applySlicePreset(SliceFormatPreset.builtIn[0], to: id)
        #expect(session.selectedSlice?.formats.map(\.type) == [.jpeg] && session.selectedSlice?.formats[0].quality == 1)
    }

    @Test func cropAndRotationCarrySlicesWithTheImage() async throws {
        let session = session()
        draw(CGRect(x: 10, y: 10, width: 50, height: 40), in: session)
        session.rotateCanvas(clockwise: true)
        #expect(session.document?.slices.first?.rect == CGRect(x: 50, y: 10, width: 40, height: 50))
        session.rotateCanvas(clockwise: false)
        #expect(session.document?.slices.first?.rect == CGRect(x: 10, y: 10, width: 50, height: 40))
        session.flipCanvas(horizontally: true)
        #expect(session.document?.slices.first?.rect == CGRect(x: 140, y: 10, width: 50, height: 40))
        session.flipCanvas(horizontally: true)
        session.closeExportPanel()
        session.selectTool(.crop)
        session.cropRect = CGRect(x: 20, y: 0, width: 100, height: 100)
        await session.commitCrop()
        #expect(session.document?.slices.first?.rect == CGRect(x: 0, y: 10, width: 40, height: 40))
    }

    // MARK: Saving

    @Test func slicesSaveAndLoad() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = session()
        draw(CGRect(x: 10, y: 10, width: 50, height: 40), in: session)
        let id = try #require(session.selectedSliceID)
        session.addSliceFormat(id)
        let snapshot = try #require(session.projectSnapshot())
        let url = root.appendingPathComponent("Sliced.pbox")
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.version == ProjectManifest.current)
        #expect(loaded.manifest.slices == session.document?.slices)

        // Hand-written slices may leave out every option.
        let text = try String(contentsOf: url.appendingPathComponent("manifest.json"), encoding: .utf8)
        var json = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        json["slices"] = [["name": "Banner", "x": 0, "y": 0, "width": 20, "height": 10, "formats": [["type": "WebP"]]]]
        try JSONSerialization.data(withJSONObject: json).write(to: url.appendingPathComponent("manifest.json"))
        let written = try await ProjectStore.shared.load(from: url)
        #expect(written.manifest.slices?.first?.formats.first?.type == .webP)
        #expect(written.manifest.slices?.first?.formats.first?.quality == 0.8)
    }

    @Test func invalidSlicesAreRejected() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = session()
        let snapshot = try #require(session.projectSnapshot())
        let url = root.appendingPathComponent("Bad.pbox")
        try await ProjectStore.shared.save(snapshot, to: url)
        let metadata = url.appendingPathComponent("manifest.json")
        for (slice, version) in [
            (CanvasSlice(name: "Outside", rect: CGRect(x: 190, y: 0, width: 20, height: 10)), ProjectManifest.current),
            (CanvasSlice(name: "", rect: CGRect(x: 0, y: 0, width: 20, height: 10)), ProjectManifest.current),
            (CanvasSlice(name: "Early", rect: CGRect(x: 0, y: 0, width: 20, height: 10)), 20),
        ] {
            var manifest = snapshot.manifest
            manifest.slices = [slice]
            manifest.version = version
            try JSONEncoder().encode(manifest).write(to: metadata)
            await #expect(throws: (any Error).self) { try await ProjectStore.shared.load(from: url) }
        }
    }

    // MARK: Encoding

    @Test func everyFormatWritesAFileOfTheRightSize() async throws {
        let image = try composite()
        let slice = CanvasSlice(name: "All", rect: CGRect(x: 0, y: 0, width: 4, height: 2))
        for type in SliceFileType.allCases where type != .mp4 && type != .svg {
            var format = SliceFormat(type: type, scale: 2)
            format.quality = 0.9
            let data = try await SliceExporter.shared.data(for: slice, format: format, composite: image)
            let decoded = try decoded(data)
            #expect(decoded.width == 8 && decoded.height == 4, "\(type.rawValue)")
            let bitmap = NSBitmapImageRep(cgImage: decoded)
            #expect(try #require(bitmap.colorAt(x: 1, y: 1)).redComponent > 0.9, "\(type.rawValue)")
            let clear = try #require(bitmap.colorAt(x: 7, y: 3))
            if type.supportsTransparency { #expect(clear.alphaComponent < 0.1, "\(type.rawValue) keeps transparency") }
            else { #expect(clear.alphaComponent == 1 && clear.greenComponent > 0.9, "\(type.rawValue) is flattened onto white") }
        }
    }

    @Test func transparencyCanBeFlattened() async throws {
        var format = SliceFormat(type: .png)
        format.keepsTransparency = false
        let data = try await SliceExporter.shared.data(for: CanvasSlice(name: "A", rect: CGRect(x: 0, y: 0, width: 4, height: 2)),
                                                       format: format, composite: composite())
        let clear = try #require(NSBitmapImageRep(cgImage: decoded(data)).colorAt(x: 3, y: 0))
        #expect(clear.alphaComponent == 1 && clear.redComponent > 0.99 && clear.greenComponent > 0.99 && clear.blueComponent > 0.99)
    }

    @Test func palettedAndAdvancedPNGsKeepTheirPixels() async throws {
        // A gradient with partly clear pixels, more colors than a palette holds.
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in 0..<64 {
            for x in 0..<64 {
                context.setFillColor(CGColor(red: CGFloat(x) / 63, green: CGFloat(y) / 63, blue: 0.5, alpha: y < 8 ? 0 : 1))
                context.fill(CGRect(x: x, y: 63 - y, width: 1, height: 1))
            }
        }
        let image = try #require(context.makeImage())
        let slice = CanvasSlice(name: "G", rect: CGRect(x: 0, y: 0, width: 64, height: 64))
        let plain = try await SliceExporter.shared.data(for: slice, format: SliceFormat(type: .png), composite: image)
        var advanced = SliceFormat(type: .png)
        advanced.advancedCompression = true
        let small = try await SliceExporter.shared.data(for: slice, format: advanced, composite: image)
        let original = NSBitmapImageRep(cgImage: try decoded(plain))
        let smaller = NSBitmapImageRep(cgImage: try decoded(small))
        for (x, y) in [(0, 0), (10, 20), (63, 63), (40, 9)] {
            #expect(original.colorAt(x: x, y: y) == smaller.colorAt(x: x, y: y), "advanced compression is lossless")
        }
        var paletted = SliceFormat(type: .png)
        paletted.limitedPalette = true
        let indexed = try decoded(try await SliceExporter.shared.data(for: slice, format: paletted, composite: image))
        let bitmap = NSBitmapImageRep(cgImage: indexed)
        #expect(try #require(bitmap.colorAt(x: 5, y: 2)).alphaComponent == 0)
        let sample = try #require(bitmap.colorAt(x: 32, y: 40)), expected = try #require(original.colorAt(x: 32, y: 40))
        #expect(abs(sample.redComponent - expected.redComponent) < 0.06 && abs(sample.greenComponent - expected.greenComponent) < 0.06)
    }

    @Test func svgEmbedsThePNG() async throws {
        let data = try await SliceExporter.shared.data(for: CanvasSlice(name: "V", rect: CGRect(x: 0, y: 0, width: 4, height: 2)),
                                                       format: SliceFormat(type: .svg, scale: 3), composite: composite())
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("width=\"12\" height=\"6\"") && text.contains("data:image/png;base64,"))
    }

    @Test func mp4IsAOneSecondEvenSizedVideo() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let slice = CanvasSlice(name: "Clip", rect: CGRect(x: 0, y: 0, width: 3, height: 2))
        let data = try await SliceExporter.shared.data(for: slice, format: SliceFormat(type: .mp4, scale: 11), composite: composite())
        let url = folder.appendingPathComponent("clip.mp4")
        try data.write(to: url)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 1) < 0.05)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 34, height: 22))
    }

    @Test func exportWritesEveryFormatWithoutNameClashes() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var hero = CanvasSlice(name: "Hero", rect: CGRect(x: 0, y: 0, width: 4, height: 2))
        hero.formats = [SliceFormat(type: .png), SliceFormat(type: .png, scale: 2), SliceFormat(type: .jpeg)]
        hero.formats[1].suffix = "@2x"
        let twin = CanvasSlice(name: "hero", rect: CGRect(x: 0, y: 0, width: 2, height: 2))
        let urls = try await SliceExporter.shared.export([hero, twin], composite: composite(), to: folder)
        #expect(urls.map(\.lastPathComponent) == ["Hero.png", "Hero@2x.png", "Hero.jpg", "hero 2.png"])
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(CanvasSlice(name: "a/b", rect: .zero).fileName(for: SliceFormat()) == "a-b.png")
    }
}
