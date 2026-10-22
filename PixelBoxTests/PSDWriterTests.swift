import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import PixelBox

/// Projects saved as Photoshop files, read back through PixelBox's own importer.
@MainActor
struct PSDWriterTests {
    private func colorImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// White on the left half, black on the right.
    private func halfMask(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return try #require(context.makeImage())
    }

    private func asset(_ image: CGImage, _ name: String) -> ImportedImage {
        ImportedImage(image: image, thumbnail: image, name: name)
    }

    private func rgba(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        let context = try BrushRaster.copy(image)
        let bytes = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        let offset = y * context.bytesPerRow + x * 4
        return (0..<4).map { Int(bytes[offset + $0]) }
    }

    private func gray(_ image: CGImage, x: Int, y: Int) throws -> Int {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: true)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: true, context: context)
        let bytes = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        return Int(bytes[y * context.bytesPerRow + x])
    }

    private func encode(_ snapshot: ProjectSnapshot) throws -> PSDWriter.Output {
        let composite = try colorImage(width: snapshot.manifest.width, height: snapshot.manifest.height, red: 1, green: 1, blue: 1)
        return try PSDWriter.encode(snapshot, composite: composite)
    }

    @Test func layersFoldersMasksAndClippingReadBack() throws {
        let folderID = UUID(), baseID = UUID(), clippedID = UUID(), topID = UUID()
        let canvas = LayerTransform(origin: .zero, size: CGSize(width: 8, height: 6))
        let layers = [
            ProjectLayerRecord(id: folderID, name: "Folder", isVisible: true, transform: canvas, imageFile: nil,
                               isGroup: true, opacity: 0.5),
            ProjectLayerRecord(id: baseID, name: "Base", isVisible: true,
                               transform: LayerTransform(origin: CGPoint(x: 2, y: 1), size: CGSize(width: 4, height: 2)),
                               imageFile: "base.png", parentID: folderID, blendMode: .multiply, maskFile: "base-mask.png"),
            ProjectLayerRecord(id: clippedID, name: "Clipped", isVisible: true,
                               transform: LayerTransform(origin: CGPoint(x: 2, y: 1), size: CGSize(width: 4, height: 2)),
                               imageFile: "clipped.png", parentID: folderID, maskSourceID: baseID),
            ProjectLayerRecord(id: topID, name: "Über", isVisible: false,
                               transform: LayerTransform(origin: CGPoint(x: 0, y: 4), size: CGSize(width: 2, height: 2)),
                               imageFile: "top.png", opacity: 0.25, blendMode: .screen),
        ]
        let manifest = ProjectManifest(resolution: 144, documentID: UUID(), width: 8, height: 6, activeLayerID: baseID, layers: layers)
        let snapshot = ProjectSnapshot(manifest: manifest, images: [
            baseID: asset(try colorImage(width: 4, height: 2, red: 1, green: 0, blue: 0), "Base"),
            clippedID: asset(try colorImage(width: 4, height: 2, red: 0, green: 1, blue: 0), "Clipped"),
            topID: asset(try colorImage(width: 2, height: 2, red: 0, green: 0, blue: 1), "Über"),
        ], masks: [baseID: asset(try halfMask(width: 4, height: 2), "Mask")])
        let output = try encode(snapshot)
        #expect(output.conversions.isEmpty)
        let document = try PSDReader.read(output.data)
        #expect(document.width == 8 && document.height == 6)
        #expect(document.resolution == 144)
        // The reader lists a folder after what's in it, as Photoshop's file does.
        #expect(document.layers.map(\.name) == ["Base", "Clipped", "Folder", "Über"])
        let byName = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.name, $0) })
        let folder = try #require(byName["Folder"]), base = try #require(byName["Base"])
        let clipped = try #require(byName["Clipped"]), top = try #require(byName["Über"])
        #expect(folder.isGroup && abs(folder.opacity - 0.5) < 0.01)
        #expect(base.parentID == folder.id && clipped.parentID == folder.id && top.parentID == nil)
        #expect(base.bounds == CGRect(x: 2, y: 1, width: 4, height: 2))
        #expect(base.blendKey == "mul ")
        #expect(try rgba(try #require(base.image), x: 0, y: 0) == [255, 0, 0, 255])
        #expect(clipped.clipping)
        #expect(!top.isVisible && abs(top.opacity - 0.25) < 0.01 && top.blendKey == "scrn")
        let mask = try #require(base.mask)
        #expect(base.maskBounds == CGRect(x: 2, y: 1, width: 4, height: 2))
        #expect(try gray(mask, x: 0, y: 0) == 255)
        #expect(try gray(mask, x: 3, y: 0) == 0)

        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(imported.conversions.isEmpty)
        let importedBase = try #require(imported.layers.first { $0.name == "Base" })
        #expect(imported.layers.first { $0.name == "Clipped" }?.maskSourceID == importedBase.id)
        #expect(importedBase.mask != nil)
    }

    @Test func adjustmentLayersReadBack() throws {
        let levelsID = UUID(), curvesID = UUID(), hueID = UUID(), exposureID = UUID()
        let canvas = LayerTransform(origin: .zero, size: CGSize(width: 4, height: 4))
        var levels = LevelsSettings()
        levels.ranges[0] = LevelRange(black: 10, gamma: 1.5, white: 240, outputBlack: 5, outputWhite: 250)
        var curves = CurvesSettings()
        curves.channels[0] = [CurvePoint(x: 0, y: 0), CurvePoint(x: 128, y: 160), CurvePoint(x: 255, y: 255)]
        curves.channels[2] = [CurvePoint(x: 0, y: 20), CurvePoint(x: 255, y: 235)]
        var hue = HueSaturationSettings(colorize: false)
        hue.adjustments[.master] = RangeAdjustment(hue: 30, saturation: -20, lightness: 10)
        hue.adjustments[.blues] = RangeAdjustment(hue: -15, saturation: 40, lightness: 0)
        let layers = [
            ProjectLayerRecord(id: levelsID, name: "Levels", isVisible: true, transform: canvas, imageFile: nil,
                               adjustment: LayerAdjustment(kind: .levels, levels: levels)),
            ProjectLayerRecord(id: curvesID, name: "Curves", isVisible: true, transform: canvas, imageFile: nil,
                               adjustment: LayerAdjustment(kind: .curves, curves: curves)),
            ProjectLayerRecord(id: hueID, name: "Hue", isVisible: true, transform: canvas, imageFile: nil, opacity: 0.6,
                               adjustment: LayerAdjustment(kind: .hsv, hsvSettings: hue)),
            ProjectLayerRecord(id: exposureID, name: "Exposure", isVisible: true, transform: canvas, imageFile: nil,
                               adjustment: LayerAdjustment(kind: .exposure)),
        ]
        let manifest = ProjectManifest(documentID: UUID(), width: 4, height: 4, activeLayerID: nil, layers: layers)
        let output = try encode(ProjectSnapshot(manifest: manifest, images: [:]))
        #expect(output.conversions.map(\.layerName) == ["Exposure"])
        let document = try PSDReader.read(output.data)
        let byName = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.name, $0) })
        let readLevels = try #require(byName["Levels"]?.adjustment)
        #expect(readLevels.kind == .levels && readLevels.levels.ranges[0] == levels.ranges[0])
        let readCurves = try #require(byName["Curves"]?.adjustment)
        #expect(readCurves.kind == .curves && readCurves.curves.channels[0] == curves.channels[0])
        #expect(readCurves.curves.channels[2] == curves.channels[2])
        let readHue = try #require(byName["Hue"]?.adjustment)
        #expect(readHue.kind == .hsv)
        #expect(readHue.resolvedHSV.adjustments[.master] == hue.adjustments[.master])
        #expect(readHue.resolvedHSV.adjustments[.blues] == hue.adjustments[.blues])
        #expect(abs((byName["Hue"]?.opacity ?? 0) - 0.6) < 0.01)
        // Photoshop has no Exposure adjustment layer PixelBox's matches, so it's left out, hidden.
        #expect(byName["Exposure"]?.isVisible == false)
    }

    @Test func rotatedLayerIsDrawnWhereItSits() throws {
        let id = UUID()
        var transform = LayerTransform(origin: CGPoint(x: 4, y: 4), size: CGSize(width: 8, height: 2))
        transform.rotation = 90
        let manifest = ProjectManifest(documentID: UUID(), width: 16, height: 16, activeLayerID: id, layers: [
            ProjectLayerRecord(id: id, name: "Bar", isVisible: true, transform: transform, imageFile: "bar.png"),
        ])
        let output = try encode(ProjectSnapshot(manifest: manifest, images: [
            id: asset(try colorImage(width: 8, height: 2, red: 1, green: 1, blue: 0), "Bar"),
        ]))
        let layer = try #require(try PSDReader.read(output.data).layers.first)
        // Turned a quarter, the 8 × 2 bar stands 2 wide and 8 tall about the same center (8, 5).
        #expect(layer.bounds == CGRect(x: 7, y: 1, width: 2, height: 8))
    }

    @Test func mergedImageIsReadableByImageIO() throws {
        let id = UUID()
        let manifest = ProjectManifest(documentID: UUID(), width: 5, height: 3, activeLayerID: id, layers: [
            ProjectLayerRecord(id: id, name: "Fill", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 5, height: 3)), imageFile: "fill.png"),
        ])
        let fill = try colorImage(width: 5, height: 3, red: 0, green: 0, blue: 1)
        let snapshot = ProjectSnapshot(manifest: manifest, images: [id: asset(fill, "Fill")])
        let output = try PSDWriter.encode(snapshot, composite: fill)
        let source = try #require(CGImageSourceCreateWithData(output.data as CFData, nil))
        let merged = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(merged.width == 5 && merged.height == 3)
        let pixel = try rgba(merged, x: 2, y: 1)
        #expect(pixel == [0, 0, 255, 255])
    }
}
