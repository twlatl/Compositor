import Foundation
import Testing
@testable import Pixegen

@MainActor
struct SwatchTests {
    private func bigEndian(_ values: [UInt16]) -> Data {
        var data = Data()
        for value in values { data.append(UInt8(value >> 8)); data.append(UInt8(value & 0xFF)) }
        return data
    }
    private func utf16(_ text: String, lengthBytes: Int) -> Data {
        let units = Array(text.utf16) + [0]
        var data = lengthBytes == 4 ? bigEndian([0, UInt16(units.count)]) : bigEndian([UInt16(units.count)])
        data.append(bigEndian(units))
        return data
    }

    // MARK: Files

    @Test func acoPrefersNamedVersionTwo() throws {
        // Version 1: one RGB orange. Version 2: the same, named, plus an HSB blue and a 25% gray.
        var data = bigEndian([1, 1, 0, 0xFFFF, 0x8080, 0, 0])
        data.append(bigEndian([2, 3, 0, 0xFFFF, 0x8080, 0, 0]))
        data.append(utf16("Orange", lengthBytes: 4))
        data.append(bigEndian([1, 0xAAAA, 0xFFFF, 0xFFFF, 0]))
        data.append(utf16("Blue", lengthBytes: 4))
        data.append(bigEndian([8, 2500, 0, 0, 0]))
        data.append(utf16("", lengthBytes: 4))
        let swatches = try SwatchFile.readACO(data)
        #expect(swatches.map(\.name) == ["Orange", "Blue", "BFBFBF"])
        #expect(swatches[0].color.quantized.hex == "FF8000")
        #expect(swatches[1].color.quantized.hex == "0000FF")
        #expect(swatches[2].color.quantized.hex == "BFBFBF", "Grayscale is black ink: 25% is a light gray")
    }

    @Test func acoVersionOneOnlyNamesByHex() throws {
        let data = bigEndian([1, 2, 0, 0xFFFF, 0, 0, 0, 0, 0, 0xFFFF, 0, 0])
        let swatches = try SwatchFile.readACO(data)
        #expect(swatches.map(\.name) == ["FF0000", "00FF00"])
    }

    @Test func acoReadsCMYKAndLab() throws {
        // CMYK stores 0 for full ink: no ink is white. Lab L 100 is white as well.
        let data = bigEndian([1, 2, 2, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 7, 10000, 0, 0, 0])
        let swatches = try SwatchFile.readACO(data)
        #expect(swatches.count == 2)
        for swatch in swatches {
            #expect(swatch.color.red > 0.95 && swatch.color.green > 0.95 && swatch.color.blue > 0.95)
        }
    }

    @Test func truncatedACOIsDamaged() {
        #expect(throws: SwatchFile.ReadError.self) { try SwatchFile.readACO(bigEndian([1, 3, 0, 0xFFFF])) }
    }

    @Test func aseRoundTripsFoldersAndNames() throws {
        let groups = [
            SwatchGroup(name: "Brand", swatches: [Swatch(name: "Crimson", color: PaletteColor(hex: "C0102A")!),
                                                  Swatch(name: "Ink", color: PaletteColor(hex: "1A1A2E")!)]),
            SwatchGroup(name: "Ünïcode ✓", swatches: [Swatch(name: "Sky", color: PaletteColor(hex: "7EC8E3")!)]),
        ]
        let read = try SwatchFile.read(SwatchFile.writeASE(groups), named: "File", extension: "ase")
        #expect(read.map(\.name) == ["Brand", "Ünïcode ✓"])
        #expect(read.flatMap(\.swatches).map(\.name) == ["Crimson", "Ink", "Sky"])
        #expect(read.flatMap(\.swatches).map { $0.color.quantized.hex } == ["C0102A", "1A1A2E", "7EC8E3"])
    }

    @Test func aseSwatchesOutsideFoldersGoInOneNamedForTheFile() throws {
        var body = utf16("Loose", lengthBytes: 2)
        body.append(Data("Gray".utf8))
        body.append(bigEndian([0x3F00, 0])) // 0.5 as a float.
        body.append(bigEndian([2]))
        var data = Data("ASEF".utf8)
        data.append(bigEndian([1, 0, 0, 1, 1]))
        data.append(bigEndian([0, UInt16(body.count)]))
        data.append(body)
        let groups = try SwatchFile.read(data, named: "Loose Colors", extension: "ASE")
        #expect(groups.map(\.name) == ["Loose Colors"])
        #expect(groups[0].swatches.first?.color.quantized.hex == "808080")
    }

    @Test func actHonorsCountAndTransparentIndex() throws {
        var bytes = [UInt8](repeating: 0, count: 768)
        bytes[0...2] = [255, 0, 0]
        bytes[3...5] = [0, 255, 0]
        bytes[6...8] = [0, 0, 255]
        var data = Data(bytes)
        data.append(bigEndian([3, 1])) // Three colors, the second transparent.
        let swatches = try SwatchFile.readACT(data)
        #expect(swatches.map(\.name) == ["FF0000", "0000FF"])
        #expect(try SwatchFile.readACT(Data(bytes)).count == 256)
        #expect(throws: SwatchFile.ReadError.self) { try SwatchFile.readACT(Data(count: 100)) }
    }

    @Test func webColorsReadHexAndRGBOnceEach() throws {
        let css = """
        :root { --brand-red: #c00; --paper: #FFFFFFAA; }
        .a { color: rgb(0, 128, 255); background: #cc0000; border-color: rgba(10%, 20%, 30%, 0.5); }
        .b { color: rgb(0 128 255 / 50%); fill: #12345; }
        """
        let swatches = try SwatchFile.read(Data(css.utf8), named: "site", extension: "css").first?.swatches ?? []
        #expect(swatches.map(\.name) == ["brand-red", "paper", "#0080FF", "#1A334D"])
        #expect(swatches.map { $0.color.hex } == ["CC0000", "FFFFFF", "0080FF", "1A334D"])

        let svg = ##"<svg><rect fill="#336699"/><circle stroke="#369"/></svg>"##
        #expect(try SwatchFile.read(Data(svg.utf8), named: "icon", extension: "svg").first?.swatches.count == 1)
        #expect(throws: SwatchFile.ReadError.self) { try SwatchFile.read(Data("<p>no colors</p>".utf8), named: "x", extension: "html") }
        #expect(throws: SwatchFile.ReadError.self) { try SwatchFile.read(Data(), named: "x", extension: "gpl") }
    }

    // MARK: Project

    @Test func projectShowsDefaultsUntilEdited() {
        let session = EditorSession()
        session.createDocument(width: 40, height: 40)
        #expect(session.document?.swatchGroups == nil)
        #expect(session.swatchGroups == SwatchGroup.defaults)
        #expect(session.swatchGroups.map(\.name) == ["RGB", "CMYK", "Grayscale", "Pastel", "Light", "Dark"])
        #expect(session.projectSnapshot()?.manifest.swatchGroups == nil, "Untouched defaults aren't written")
    }

    @Test func editsAreUndoableAndMarkTheProjectEdited() throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 40)
        session.history.markSaved()
        let folder = try #require(session.addSwatchGroup(named: "  Brand  "))
        #expect(session.history.isModified)
        #expect(session.swatchGroups.last?.name == "Brand")
        let red = try #require(session.addSwatch(PaletteColor(hex: "CC0000")!, named: "", near: folder))
        let blue = try #require(session.addSwatch(PaletteColor(hex: "0000CC")!, named: "Blue", near: folder))
        let green = try #require(session.addSwatch(PaletteColor(hex: "00CC00")!, named: "Green", near: red))
        #expect(session.swatchGroup(containing: folder)?.swatches.map(\.name) == ["CC0000", "Green", "Blue"],
                "A swatch added near another follows it")
        session.renameSwatchItem(red, to: "Red")
        session.renameSwatchItem(red, to: "   ")
        #expect(session.swatch(red)?.name == "Red")
        session.deleteSwatchItem(green)
        #expect(session.swatch(green) == nil)
        session.undo()
        #expect(session.swatch(green)?.name == "Green")
        session.deleteSwatchItem(folder)
        #expect(session.swatch(blue) == nil && !session.swatchGroups.contains { $0.id == folder })
        session.undo()
        #expect(session.swatch(blue) != nil)
    }

    @Test func swatchesNeedADocument() {
        let session = EditorSession()
        #expect(session.addSwatchGroup(named: "Nope") == nil)
        #expect(session.swatchGroups == SwatchGroup.defaults)
    }

    @Test func importGivesFreshIdsAndRespectsLimits() throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 40)
        session.appendDefaultSwatches()
        #expect(session.swatchGroups.count == SwatchGroup.defaults.count * 2)
        #expect(SwatchGroup.isValid(session.swatchGroups), "Appended defaults don't reuse ids")
        session.undo()
        #expect(session.swatchGroups == SwatchGroup.defaults)

        let tooMany = [SwatchGroup(name: "Big", swatches: (0..<SwatchGroup.maxSwatches).map { _ in Swatch(name: "x", color: .black) })]
        #expect(throws: SwatchError.self) { try session.importSwatches(tooMany) }
        #expect(session.swatchGroups == SwatchGroup.defaults)
    }

    @Test func importsAFileIntoTheProject() throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 40)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Palette-\(UUID()).ase")
        defer { try? FileManager.default.removeItem(at: url) }
        try SwatchFile.writeASE([SwatchGroup(name: "Imported Folder", swatches: [Swatch(name: "Teal", color: PaletteColor(hex: "008080")!)])])
            .write(to: url)
        try session.importSwatches(from: url)
        #expect(session.swatchGroups.last?.name == "Imported Folder")
        #expect(session.swatchGroups.last?.swatches.first?.color.hex == "008080")
    }

    @Test func projectRoundTripAndLegacyRejection() async throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 40)
        let folder = try #require(session.addSwatchGroup(named: "Saved"))
        session.addSwatch(PaletteColor(hex: "336699")!, named: "Slate", near: folder)
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == ProjectManifest.current)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Swatches-\(UUID()).pbox")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: url), from: url)
        #expect(reopened.swatchGroups == session.swatchGroups)

        var legacy = snapshot.manifest
        legacy.version = 15
        try JSONEncoder().encode(legacy).write(to: url.appendingPathComponent("manifest.json"))
        do {
            _ = try await ProjectStore.shared.load(from: url)
            Issue.record("Version 15 with swatches should be rejected")
        } catch ProjectError.invalid {}

        var duplicated = snapshot.manifest
        duplicated.swatchGroups = [SwatchGroup(id: folder, name: "A"), SwatchGroup(id: folder, name: "B")]
        try JSONEncoder().encode(duplicated).write(to: url.appendingPathComponent("manifest.json"))
        do {
            _ = try await ProjectStore.shared.load(from: url)
            Issue.record("Duplicate swatch ids should be rejected")
        } catch ProjectError.invalid {}
    }

    @Test func canvasEditsKeepSwatches() async throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        session.addSwatchGroup(named: "Kept")
        let groups = session.swatchGroups
        let source = try #require(session.projectSnapshot())
        #expect(try await CanvasResizer.shared.resize(source, to: CanvasSizeOptions(width: 60, height: 30, anchor: 4)).manifest.swatchGroups == groups)
        #expect(try await ImageResizer.shared.resize(source, to: ImageSizeOptions(width: 80, height: 40, resolution: 72)).manifest.swatchGroups == groups)
        session.rotateCanvas(clockwise: true)
        #expect(session.swatchGroups == groups)
    }
}
