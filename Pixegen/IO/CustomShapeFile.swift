import CoreGraphics
import Foundation

/// Reads Photoshop custom shape files (`.csh`). Adobe doesn't publish the format; this follows Photoshop's own files:
///
/// - `cush`, then the version (2) and the number of shapes, all big-endian.
/// - Per shape: the name as a length-prefixed UTF-16 string (Adobe's own carry a `$$$/Presets/…=` localization key
///   before the name), padded to 4 bytes; a 4-byte 1; the length of the shape's data; the data, padded to 4 bytes.
/// - A shape's data: a 37-byte ID (`$` and a UUID), its bounds as four 4-byte integers (top, left, bottom, right), then
///   26-byte path records, as in a Photoshop vector mask, whose points are fractions of those bounds.
/// - Optionally, an `8BIMphry` block whose descriptor lists the folders: a `Grup` (named by `Nm  `) opens one, each
///   `preset` takes the next shape, and `groupEnd` closes it.
nonisolated enum CustomShapeFile {
    struct Group {
        /// Nil for shapes outside any folder.
        var name: String?
        var shapes: [CustomShape]
    }

    enum ReadError: LocalizedError {
        case notShapes, damaged
        var errorDescription: String? {
            switch self {
            case .notShapes: "That file isn’t a Photoshop custom shapes file (.csh)."
            case .damaged: "That custom shapes file is damaged and couldn’t be read."
            }
        }
    }

    static let maxShapes = 10_000

    static func read(_ data: Data) throws -> (groups: [Group], count: Int) {
        var reader = PSDDescriptorReader(data: data)
        guard reader.fourCC() == "cush" else { throw ReadError.notShapes }
        guard let version = reader.u32(), version == 2, let count = reader.u32(), count <= maxShapes else { throw ReadError.damaged }
        var shapes: [CustomShape?] = []
        for _ in 0..<Int(count) {
            guard let length = reader.u32(), length <= 10_000, let raw = reader.bytes(Int(length) * 2) else { throw ReadError.damaged }
            pad(&reader)
            guard reader.u32() != nil, let size = reader.u32(), let body = reader.bytes(Int(size)) else { throw ReadError.damaged }
            pad(&reader)
            let name = displayName(String(data: raw, encoding: .utf16BigEndian) ?? "")
            // A shape whose outline can't be made is skipped rather than failing the whole file.
            shapes.append(outline(body).map { CustomShape(name: name.isEmpty ? "Shape" : name, outline: $0) })
        }
        let groups = hierarchy(after: reader, shapes: shapes)
            ?? [Group(name: nil, shapes: shapes.compactMap { $0 })]
        let kept = groups.filter { !$0.shapes.isEmpty }
        let total = kept.reduce(0) { $0 + $1.shapes.count }
        guard total > 0 else { throw ReadError.damaged }
        return (kept, total)
    }

    private static func pad(_ reader: inout PSDDescriptorReader) {
        let extra = (4 - reader.offset % 4) % 4
        if extra > 0, reader.remaining >= extra { _ = reader.bytes(extra) }
    }

    /// "$$$/Presets/Shapes/Tiger=Tiger" is shown as "Tiger".
    static func displayName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
        if name.hasPrefix("$$$/"), let equals = name.firstIndex(of: "=") { name = String(name[name.index(after: equals)...]) }
        return String(name.prefix(256))
    }

    /// The path records after a shape's ID and bounds, as an outline with the bounds' proportions.
    private static func outline(_ body: Data) -> ShapeOutline? {
        var reader = PSDDescriptorReader(data: body)
        guard reader.bytes(37) != nil, let top = reader.i32(), let left = reader.i32(),
              let bottom = reader.i32(), let right = reader.i32() else { return nil }
        let width = CGFloat(right) - CGFloat(left), height = CGFloat(bottom) - CGFloat(top)
        guard width > 0, height > 0 else { return nil }
        var subpaths: [ShapeOutline.Subpath] = []
        var current: ShapeOutline.Subpath?
        var remaining = 0
        func point(_ reader: inout PSDDescriptorReader) -> CGPoint? {
            guard let y = reader.i32(), let x = reader.i32() else { return nil }
            return CGPoint(x: CGFloat(x) / 0x1000000 * width, y: CGFloat(y) / 0x1000000 * height)
        }
        while reader.remaining >= 26, let type = reader.u16(), let record = reader.bytes(24) {
            var fields = PSDDescriptorReader(data: record)
            switch type {
            case 0, 3:
                if let finished = current { subpaths.append(finished) }
                remaining = Int(fields.u16() ?? 0)
                current = ShapeOutline.Subpath(closed: type == 0, knots: [])
            case 1, 2, 4, 5:
                guard remaining > 0, let incoming = point(&fields), let anchor = point(&fields), let outgoing = point(&fields) else { continue }
                remaining -= 1
                current?.knots.append(ShapeOutline.Knot(anchor: anchor, incoming: incoming, outgoing: outgoing))
            default:
                continue
            }
        }
        if let finished = current { subpaths.append(finished) }
        return ShapeOutline.normalized(subpaths)
    }

    /// The folders the `phry` block lists, the shapes dealt into them in order. Nil when the file has none, or they
    /// can't be read; shapes the folders don't account for go in a group of their own.
    private static func hierarchy(after shapesEnd: PSDDescriptorReader, shapes: [CustomShape?]) -> [Group]? {
        var reader = shapesEnd
        while reader.remaining >= 12 {
            guard reader.fourCC() == "8BIM", let key = reader.fourCC(), let length = reader.u32(),
                  let block = reader.bytes(Int(length)) else { return nil }
            pad(&reader)
            guard key == "phry" else { continue }
            var descriptor = PSDDescriptorReader(data: block)
            guard descriptor.u32() == 16, descriptor.unicode() != nil, descriptor.identifier() != nil,
                  let count = descriptor.u32() else { return nil }
            for _ in 0..<Int(count) {
                guard let item = descriptor.identifier(), let type = descriptor.fourCC() else { return nil }
                guard item == "hierarchy", type == "VlLs" else {
                    guard descriptor.value(type) != nil else { return nil }
                    continue
                }
                guard let entries = descriptor.u32(), entries <= 100_000 else { return nil }
                // Folders in the order they open; nested ones are flattened into the library's single level, each
                // under its own name. `open` holds the indexes of those not yet closed.
                var groups: [Group] = []
                var open: [Int] = []
                var next = 0
                for _ in 0..<Int(entries) {
                    guard descriptor.fourCC() == "Objc", let object = descriptor.classedDescriptor(versioned: false) else { return nil }
                    switch object.classID {
                    case "Grup":
                        var name: String?
                        if case .text(let text) = object.items["Nm  "] { name = displayName(text) }
                        open.append(groups.count)
                        groups.append(Group(name: name ?? "Shapes", shapes: []))
                    case "groupEnd":
                        _ = open.popLast()
                    case "preset":
                        if next < shapes.count, let shape = shapes[next] {
                            if let index = open.last { groups[index].shapes.append(shape) }
                            // Loose shapes in a row share one group, named after the file.
                            else if let last = groups.last, last.name == nil { groups[groups.count - 1].shapes.append(shape) }
                            else { groups.append(Group(name: nil, shapes: [shape])) }
                        }
                        next += 1
                    default:
                        continue
                    }
                }
                if next < shapes.count { groups.append(Group(name: nil, shapes: shapes[next...].compactMap { $0 })) }
                return groups.isEmpty ? nil : groups
            }
            return nil
        }
        return nil
    }
}
