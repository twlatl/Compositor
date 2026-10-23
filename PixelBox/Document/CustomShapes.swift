import AppKit
import Observation

/// A custom shape's outline, scaled so its box is the unit square (control points may reach a little outside it).
/// Knots are Photoshop's: an anchor with the control points coming into and going out of it.
nonisolated struct ShapeOutline: Codable, Equatable, Sendable {
    struct Knot: Equatable, Sendable {
        var anchor: CGPoint
        var incoming: CGPoint
        var outgoing: CGPoint
        init(anchor: CGPoint, incoming: CGPoint? = nil, outgoing: CGPoint? = nil) {
            self.anchor = anchor
            self.incoming = incoming ?? anchor
            self.outgoing = outgoing ?? anchor
        }
    }
    /// Saved as a flat list of numbers, six to a knot (incoming, anchor, outgoing), to keep libraries and projects small.
    struct Subpath: Codable, Equatable, Sendable {
        var closed: Bool
        var knots: [Knot]
        init(closed: Bool, knots: [Knot]) { self.closed = closed; self.knots = knots }
        enum CodingKeys: String, CodingKey { case closed, points }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            closed = try container.decode(Bool.self, forKey: .closed)
            let points = try container.decode([CGFloat].self, forKey: .points)
            guard points.count % 6 == 0 else {
                throw DecodingError.dataCorruptedError(forKey: .points, in: container, debugDescription: "Six numbers to a knot")
            }
            // A step at a time: as one expression, Xcode 26.6's type checker gives up on it.
            var knots: [Knot] = []
            knots.reserveCapacity(points.count / 6)
            for start in stride(from: 0, to: points.count, by: 6) {
                let incoming = CGPoint(x: points[start], y: points[start + 1])
                let anchor = CGPoint(x: points[start + 2], y: points[start + 3])
                let outgoing = CGPoint(x: points[start + 4], y: points[start + 5])
                knots.append(Knot(anchor: anchor, incoming: incoming, outgoing: outgoing))
            }
            self.knots = knots
        }
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(closed, forKey: .closed)
            // Rounded to a millionth of the shape's box, far finer than any pixel it will be drawn at.
            func round(_ value: CGFloat) -> CGFloat { (value * 1_000_000).rounded() / 1_000_000 }
            try container.encode(knots.flatMap { [$0.incoming.x, $0.incoming.y, $0.anchor.x, $0.anchor.y, $0.outgoing.x, $0.outgoing.y].map(round) },
                                 forKey: .points)
        }
    }

    var subpaths: [Subpath]
    /// Width over height, which Shift keeps while dragging.
    var aspect: CGFloat

    static let maxKnots = 50_000

    init(subpaths: [Subpath], aspect: CGFloat) {
        self.subpaths = subpaths
        self.aspect = aspect
    }

    var isValid: Bool {
        guard aspect.isFinite, aspect > 0, !subpaths.isEmpty,
              subpaths.reduce(0, { $0 + $1.knots.count }) <= Self.maxKnots else { return false }
        func fine(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite && abs(point.x) <= 100 && abs(point.y) <= 100 }
        return subpaths.allSatisfy { $0.knots.allSatisfy { fine($0.anchor) && fine($0.incoming) && fine($0.outgoing) } }
    }

    /// The outline stretched to fill `rect`.
    func path(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        func place(_ point: CGPoint) -> CGPoint { CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height) }
        func segment(from: Knot, to: Knot) {
            if from.outgoing == from.anchor, to.incoming == to.anchor { path.addLine(to: place(to.anchor)) }
            else { path.addCurve(to: place(to.anchor), control1: place(from.outgoing), control2: place(to.incoming)) }
        }
        for subpath in subpaths {
            guard let first = subpath.knots.first else { continue }
            path.move(to: place(first.anchor))
            for (previous, knot) in zip(subpath.knots, subpath.knots.dropFirst()) { segment(from: previous, to: knot) }
            if subpath.closed {
                if let last = subpath.knots.last, subpath.knots.count > 1 { segment(from: last, to: first) }
                path.closeSubpath()
            }
        }
        return path
    }

    /// Subpaths in any coordinates, scaled so the outline's box is the unit square. Nil when they enclose nothing.
    static func normalized(_ subpaths: [Subpath]) -> ShapeOutline? {
        let kept = subpaths.filter { !$0.knots.isEmpty }
        let unscaled = ShapeOutline(subpaths: kept, aspect: 1).path(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let box = unscaled.boundingBoxOfPath
        guard !kept.isEmpty, box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { return nil }
        func unit(_ point: CGPoint) -> CGPoint { CGPoint(x: (point.x - box.minX) / box.width, y: (point.y - box.minY) / box.height) }
        let scaled = kept.map { subpath in
            Subpath(closed: subpath.closed, knots: subpath.knots.map { Knot(anchor: unit($0.anchor), incoming: unit($0.incoming), outgoing: unit($0.outgoing)) })
        }
        let outline = ShapeOutline(subpaths: scaled, aspect: box.width / box.height)
        return outline.isValid ? outline : nil
    }

    /// Any Core Graphics path, as knots.
    init?(path: CGPath) {
        guard let outline = Self.normalized(Self.subpaths(of: path)) else { return nil }
        self = outline
    }

    /// A Core Graphics path's knots, in the path's own coordinates.
    static func subpaths(of path: CGPath) -> [Subpath] {
        var subpaths: [Subpath] = []
        var current: Subpath?
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                if let open = current { subpaths.append(open) }
                current = Subpath(closed: false, knots: [Knot(anchor: element.points[0])])
            case .addLineToPoint:
                current?.knots.append(Knot(anchor: element.points[0]))
            case .addQuadCurveToPoint:
                guard var open = current, let last = open.knots.last?.anchor else { return }
                let control = element.points[0], end = element.points[1]
                open.knots[open.knots.count - 1].outgoing = CGPoint(x: last.x + (control.x - last.x) * 2 / 3, y: last.y + (control.y - last.y) * 2 / 3)
                open.knots.append(Knot(anchor: end, incoming: CGPoint(x: end.x + (control.x - end.x) * 2 / 3, y: end.y + (control.y - end.y) * 2 / 3)))
                current = open
            case .addCurveToPoint:
                guard var open = current, !open.knots.isEmpty else { return }
                open.knots[open.knots.count - 1].outgoing = element.points[0]
                open.knots.append(Knot(anchor: element.points[2], incoming: element.points[1]))
                current = open
            case .closeSubpath:
                guard var closing = current else { return }
                closing.closed = true
                // A last knot back on the first is the same knot: its incoming control belongs to the first.
                if closing.knots.count > 1, let last = closing.knots.last, last.anchor == closing.knots[0].anchor {
                    closing.knots[0].incoming = last.incoming
                    closing.knots.removeLast()
                }
                subpaths.append(closing)
                current = nil
            @unknown default: break
            }
        }
        if let open = current { subpaths.append(open) }
        return subpaths
    }

    /// The subpaths as a Core Graphics path, in their own coordinates.
    static func path(of subpaths: [Subpath]) -> CGPath {
        ShapeOutline(subpaths: subpaths, aspect: 1).path(in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

/// A shape in the library, which the Custom Shape tool draws.
nonisolated struct CustomShape: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var outline: ShapeOutline
}

/// A folder of shapes in the library: one imported file, or a group inside it.
nonisolated struct CustomShapeGroup: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var shapes: [CustomShape]
}

/// The custom shapes the Shape tool offers, kept across launches in Application Support. Tests get the defaults and
/// never touch the file.
@Observable
final class ShapeLibrary {
    static let shared = ShapeLibrary(fileURL: isTesting ? nil : defaultURL)
    static let defaultGroupName = "Default Shapes"
    private static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var groups: [CustomShapeGroup] { didSet { save() } }
    @ObservationIgnored private let fileURL: URL?

    /// A library kept in `fileURL`, or only in memory when it is nil.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([CustomShapeGroup].self, from: data) {
            groups = saved
        } else {
            groups = [Self.defaultGroup()]
        }
    }

    private static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PixelBox", isDirectory: true).appendingPathComponent("Custom Shapes.json")
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(groups) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    var firstShape: CustomShape? { groups.lazy.flatMap(\.shapes).first }

    func shape(_ id: UUID) -> CustomShape? { groups.lazy.flatMap(\.shapes).first { $0.id == id } }

    /// Adds the shapes in a Photoshop `.csh` file, in its own folders, or in one named after the file when it has none.
    /// Returns how many shapes were added.
    @discardableResult
    func importShapes(from url: URL) throws -> Int {
        let file = try CustomShapeFile.read(try Data(contentsOf: url, options: .mappedIfSafe))
        let fallback = url.deletingPathExtension().lastPathComponent
        let added = file.groups.map { CustomShapeGroup(name: $0.name ?? fallback, shapes: $0.shapes) }
        groups.append(contentsOf: added)
        return added.reduce(0) { $0 + $1.shapes.count }
    }

    /// Puts the built-in shapes back, when their folder has been deleted.
    func appendDefaultShapes() {
        guard !groups.contains(where: { $0.name == Self.defaultGroupName }) else { return }
        groups.insert(Self.defaultGroup(), at: 0)
    }

    func renameShape(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        for group in groups.indices {
            if let index = groups[group].shapes.firstIndex(where: { $0.id == id }) { groups[group].shapes[index].name = name; return }
        }
        if let group = groups.firstIndex(where: { $0.id == id }) { groups[group].name = name }
    }

    /// Deletes a shape, or a whole folder of them.
    func delete(_ id: UUID) {
        if let group = groups.firstIndex(where: { $0.id == id }) { groups.remove(at: group); return }
        for group in groups.indices { groups[group].shapes.removeAll { $0.id == id } }
    }

    /// Simple shapes drawn in a 100-pixel box, so the tool has something to draw before anything is imported.
    static func defaultGroup() -> CustomShapeGroup {
        func polygon(_ points: [(CGFloat, CGFloat)]) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
            path.closeSubpath()
            return path
        }
        let heart = CGMutablePath()
        heart.move(to: CGPoint(x: 50, y: 95))
        heart.addCurve(to: CGPoint(x: 0, y: 32), control1: CGPoint(x: 22, y: 72), control2: CGPoint(x: 0, y: 55))
        heart.addCurve(to: CGPoint(x: 50, y: 20), control1: CGPoint(x: 0, y: 2), control2: CGPoint(x: 38, y: -4))
        heart.addCurve(to: CGPoint(x: 100, y: 32), control1: CGPoint(x: 62, y: -4), control2: CGPoint(x: 100, y: 2))
        heart.addCurve(to: CGPoint(x: 50, y: 95), control1: CGPoint(x: 100, y: 55), control2: CGPoint(x: 78, y: 72))
        heart.closeSubpath()
        let bubble = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 70), cornerWidth: 16, cornerHeight: 16, transform: nil)
            .union(polygon([(22, 60), (44, 60), (14, 96)]))
        let crescent = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil)
            .subtracting(CGPath(ellipseIn: CGRect(x: 30, y: -8, width: 92, height: 92), transform: nil))
        let drop = CGMutablePath()
        drop.move(to: CGPoint(x: 50, y: 0))
        drop.addCurve(to: CGPoint(x: 86, y: 66), control1: CGPoint(x: 62, y: 22), control2: CGPoint(x: 86, y: 40))
        drop.addCurve(to: CGPoint(x: 14, y: 66), control1: CGPoint(x: 86, y: 114), control2: CGPoint(x: 14, y: 114))
        drop.addCurve(to: CGPoint(x: 50, y: 0), control1: CGPoint(x: 14, y: 40), control2: CGPoint(x: 38, y: 22))
        drop.closeSubpath()
        let shapes: [(String, CGPath)] = [
            ("Heart", heart),
            ("Arrow", polygon([(0, 35), (58, 35), (58, 8), (100, 50), (58, 92), (58, 65), (0, 65)])),
            ("Check Mark", polygon([(0, 55), (15, 40), (38, 62), (85, 10), (100, 25), (38, 92)])),
            ("Speech Bubble", bubble),
            ("Lightning", polygon([(58, 0), (14, 58), (46, 58), (34, 100), (86, 38), (54, 38), (72, 0)])),
            ("Plus", polygon([(35, 0), (65, 0), (65, 35), (100, 35), (100, 65), (65, 65), (65, 100), (35, 100), (35, 65), (0, 65), (0, 35), (35, 35)])),
            ("Crescent", crescent),
            ("Raindrop", drop),
        ]
        return CustomShapeGroup(name: defaultGroupName, shapes: shapes.compactMap { name, path in
            ShapeOutline(path: path).map { CustomShape(name: name, outline: $0) }
        })
    }
}
