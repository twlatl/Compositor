import CoreGraphics
import Foundation
import Testing
@testable import PixelBox

/// Photoshop custom shape files, built byte by byte the way Photoshop writes them.
struct CustomShapeFileTests {
    private struct Writer {
        var data = Data()
        mutating func u16(_ value: Int) { data.append(contentsOf: [UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]) }
        mutating func u32(_ value: Int) { data.append(contentsOf: (0..<4).map { UInt8(value >> (24 - $0 * 8) & 0xff) }) }
        mutating func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        mutating func unicode(_ text: String, terminated: Bool = false) {
            let units = Array(text.utf16) + (terminated ? [0] : [])
            u32(units.count)
            for unit in units { u16(Int(unit)) }
        }
        mutating func pad() { while data.count % 4 != 0 { data.append(0) } }
        /// A descriptor key or class: length 0 and four characters, or a length and the name.
        mutating func key(_ name: String) {
            if name.utf8.count == 4 { u32(0) } else { u32(name.utf8.count) }
            ascii(name)
        }
        /// An 8.24 fixed-point fraction.
        mutating func fixed(_ value: Double) { u32(Int(value * 0x1000000) & 0xffff_ffff) }
    }

    /// A shape whose outline is the given corners (fractions of its bounds), closed, with straight sides.
    private func shape(_ name: String, corners: [(x: Double, y: Double)], bounds: (top: Int, left: Int, bottom: Int, right: Int)) -> Data {
        var body = Writer()
        body.ascii("$" + UUID().uuidString.lowercased())
        for side in [bounds.top, bounds.left, bounds.bottom, bounds.right] { body.u32(side) }
        // A fill rule record, then the subpath's length record, then one record per knot.
        body.u16(6); body.data.append(Data(count: 24))
        body.u16(0); body.u16(corners.count); body.data.append(Data(count: 22))
        for corner in corners {
            body.u16(2)
            for _ in 0..<3 { body.fixed(corner.y); body.fixed(corner.x) }
        }
        body.pad()
        var record = Writer()
        record.unicode(name, terminated: true)
        record.pad()
        record.u32(1)
        record.u32(body.data.count)
        record.data.append(body.data)
        return record.data
    }

    private func file(folder: String?) -> Data {
        var file = Writer()
        file.ascii("cush"); file.u32(2); file.u32(2)
        file.data.append(shape("$$$/Presets/Shapes/Box=Box", corners: [(0, 0), (1, 0), (1, 1), (0, 1)], bounds: (100, 100, 150, 300)))
        file.data.append(shape("Wedge", corners: [(0.5, 0), (1, 1), (0, 1)], bounds: (0, 0, 80, 80)))
        guard let folder else { return file.data }
        // The first shape in a folder, the second loose.
        var descriptor = Writer()
        descriptor.u32(16); descriptor.unicode(""); descriptor.key("null"); descriptor.u32(1)
        descriptor.key("hierarchy"); descriptor.ascii("VlLs"); descriptor.u32(4)
        descriptor.ascii("Objc"); descriptor.unicode(""); descriptor.key("Grup"); descriptor.u32(1)
        descriptor.key("Nm  "); descriptor.ascii("TEXT"); descriptor.unicode("$$$/Presets/Groups/Folder=" + folder, terminated: true)
        descriptor.ascii("Objc"); descriptor.unicode(""); descriptor.key("preset"); descriptor.u32(0)
        descriptor.ascii("Objc"); descriptor.unicode(""); descriptor.key("groupEnd"); descriptor.u32(0)
        descriptor.ascii("Objc"); descriptor.unicode(""); descriptor.key("preset"); descriptor.u32(0)
        file.ascii("8BIMphry"); file.u32(descriptor.data.count); file.data.append(descriptor.data)
        return file.data
    }

    @Test func readsShapesWithTheirNamesAndProportions() throws {
        let read = try CustomShapeFile.read(file(folder: nil))
        #expect(read.count == 2 && read.groups.count == 1 && read.groups[0].name == nil)
        let shapes = read.groups[0].shapes
        #expect(shapes.map(\.name) == ["Box", "Wedge"], "the localization key is dropped")
        // The box's bounds are 200 wide and 50 tall, and its points are fractions of them.
        #expect(abs(shapes[0].outline.aspect - 4) < 0.0001)
        #expect(abs(shapes[1].outline.aspect - 1) < 0.0001)
        let wedge = shapes[1].outline.path(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(wedge.contains(CGPoint(x: 50, y: 90)) && !wedge.contains(CGPoint(x: 5, y: 10)))
    }

    @Test func readsFoldersFromTheHierarchyBlock() throws {
        let read = try CustomShapeFile.read(file(folder: "Things"))
        #expect(read.groups.map(\.name) == ["Things", nil])
        #expect(read.groups.map { $0.shapes.map(\.name) } == [["Box"], ["Wedge"]])
    }

    @Test func rejectsOtherFilesAndDamagedOnes() {
        #expect(throws: CustomShapeFile.ReadError.notShapes) { try CustomShapeFile.read(Data("8BPS".utf8)) }
        let whole = file(folder: nil)
        #expect(throws: CustomShapeFile.ReadError.damaged) { try CustomShapeFile.read(whole.prefix(40)) }
    }

    @Test @MainActor func importingAddsAFolderNamedAfterTheFileAndDeletingRemovesIt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Imported \(UUID()).csh")
        defer { try? FileManager.default.removeItem(at: url) }
        try file(folder: nil).write(to: url)
        let library = ShapeLibrary(fileURL: nil)
        #expect(library.groups.map(\.name) == [ShapeLibrary.defaultGroupName])
        #expect(try library.importShapes(from: url) == 2)
        let added = try #require(library.groups.last)
        #expect(added.name == url.deletingPathExtension().lastPathComponent)
        library.renameShape(added.shapes[0].id, to: "Brick")
        #expect(library.shape(added.shapes[0].id)?.name == "Brick")
        library.delete(added.id)
        library.delete(library.groups[0].id)
        #expect(library.groups.isEmpty && library.firstShape == nil)
        library.appendDefaultShapes()
        #expect(library.groups.first?.shapes.count == ShapeLibrary.defaultGroup().shapes.count)
    }

    @Test func outlinesSurviveEncodingCompactly() throws {
        let outline = try #require(ShapeLibrary.defaultGroup().shapes.first?.outline)
        let data = try JSONEncoder().encode(outline)
        let decoded = try JSONDecoder().decode(ShapeOutline.self, from: data)
        #expect(decoded.subpaths.count == outline.subpaths.count)
        #expect(decoded.subpaths[0].knots.count == outline.subpaths[0].knots.count)
        let anchor = outline.subpaths[0].knots[1].anchor, back = decoded.subpaths[0].knots[1].anchor
        #expect(abs(anchor.x - back.x) < 0.000002 && abs(anchor.y - back.y) < 0.000002)
    }
}
