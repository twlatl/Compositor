import CoreGraphics
import Foundation
import Observation

/// A stop that follows one of the palette's colors rather than keeping its own, as Photoshop's built-in gradients do.
nonisolated enum GradientStopRole: String, Codable, Sendable {
    case foreground, background
}

/// One color along a gradient.
nonisolated struct GradientStop: Codable, Identifiable, Sendable {
    var id = UUID()
    /// Where along the gradient, 0 at its start and 1 at its end.
    var location: CGFloat
    var color: PaletteColor
    var opacity: CGFloat = 1
    /// Where between this stop and the next their colors blend half and half, as a fraction of the way from this one;
    /// 0.5 blends evenly. Unused on the last stop.
    var midpoint: CGFloat = 0.5
    /// Set while the stop follows the foreground or background color; `color` is then only a fallback.
    var role: GradientStopRole? = nil
}

extension GradientStop: Equatable {
    /// The same stop wherever it was made: identity is only for picking one out while editing.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.location == rhs.location && lhs.color == rhs.color && lhs.opacity == rhs.opacity
            && lhs.midpoint == rhs.midpoint && lhs.role == rhs.role
    }
}

/// A gradient: colors and opacities at stops along it, blending between each pair of stops around their midpoint; and
/// how it's laid over what it paints: its shape, angle, direction and opacity. Gradient Map uses only the stops, and the
/// Gradient tool takes its angle from the line dragged.
nonisolated struct ColorGradient: Codable, Equatable, Sendable {
    var stops: [GradientStop]
    var shape = GradientShape.linear
    /// Degrees, counterclockwise from pointing right: the way a linear gradient runs, or where an angle one starts.
    var angle: CGFloat = 0
    /// Laid the other way: the last stop's color where the first's would be.
    var isReversed = false
    var opacity: CGFloat = 1

    static let midpointRange: ClosedRange<CGFloat> = 0.05...0.95
    static let maxStops = 64

    init(stops: [GradientStop]) { self.stops = stops }

    enum CodingKeys: String, CodingKey { case stops, shape, angle, reversed, opacity }
    /// Gradients saved before they had a shape, angle, direction and opacity are linear, at 0°, as they are, and opaque.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stops = try container.decode([GradientStop].self, forKey: .stops)
        shape = try container.decodeIfPresent(GradientShape.self, forKey: .shape) ?? .linear
        angle = try container.decodeIfPresent(CGFloat.self, forKey: .angle) ?? 0
        isReversed = try container.decodeIfPresent(Bool.self, forKey: .reversed) ?? false
        opacity = try container.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 1
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stops, forKey: .stops)
        try container.encode(shape, forKey: .shape)
        try container.encode(angle, forKey: .angle)
        try container.encode(isReversed, forKey: .reversed)
        try container.encode(opacity, forKey: .opacity)
    }

    /// The stops alone, laid linearly at 0°, the right way round and opaque: what Gradient Map and the Gradient tool keep.
    var stopsOnly: ColorGradient { ColorGradient(stops: stops) }

    /// Two stops, at each end.
    init(_ start: PaletteColor, _ end: PaletteColor, startOpacity: CGFloat = 1, endOpacity: CGFloat = 1) {
        stops = [GradientStop(location: 0, color: start, opacity: startOpacity), GradientStop(location: 1, color: end, opacity: endOpacity)]
    }

    /// Stops from start to end.
    var sorted: [GradientStop] { stops.sorted { $0.location < $1.location } }

    var isValid: Bool {
        func unit(_ value: CGFloat) -> Bool { value.isFinite && (0...1).contains(value) }
        return (2...Self.maxStops).contains(stops.count) && angle.isFinite && abs(angle) <= 100_000 && unit(opacity) && stops.allSatisfy {
            unit($0.location) && unit($0.opacity) && unit($0.color.red) && unit($0.color.green) && unit($0.color.blue)
                && $0.midpoint.isFinite && Self.midpointRange.contains($0.midpoint)
        }
    }

    /// Every stop keeping its own color, none following the palette.
    var withoutRoles: ColorGradient {
        var result = self
        for index in result.stops.indices { result.stops[index].role = nil }
        return result
    }

    /// Stops that follow the palette take its colors now.
    func resolved(foreground: PaletteColor, background: PaletteColor) -> ColorGradient {
        var result = self
        for index in result.stops.indices {
            switch result.stops[index].role {
            case .foreground: result.stops[index].color = foreground
            case .background: result.stops[index].color = background
            case nil: break
            }
        }
        return result
    }

    /// The same gradient end to end the other way: each midpoint keeps its place between the same two colors.
    var reversed: ColorGradient {
        let order = sorted
        var result = self
        result.stops = order.indices.reversed().map { index in
            var stop = order[index]
            stop.location = 1 - stop.location
            // The blend after this stop is now the one that came before it.
            stop.midpoint = index > 0 ? 1 - order[index - 1].midpoint : 0.5
            return stop
        }
        return result
    }

    /// The color and opacity at `t` along the gradient: those of the nearest stop beyond the ends.
    func value(at t: CGFloat) -> (color: PaletteColor, opacity: CGFloat) {
        let order = sorted
        guard let first = order.first, let last = order.last else { return (.black, 1) }
        if t <= first.location { return (first.color, first.opacity) }
        if t >= last.location { return (last.color, last.opacity) }
        let index = order.lastIndex { $0.location <= t } ?? 0
        let from = order[index], to = order[min(index + 1, order.count - 1)]
        let span = to.location - from.location
        let weight = span > 0 ? Self.blend((t - from.location) / span, midpoint: from.midpoint) : 1
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * weight }
        return (PaletteColor(red: mix(from.color.red, to.color.red), green: mix(from.color.green, to.color.green),
                             blue: mix(from.color.blue, to.color.blue)),
                mix(from.opacity, to.opacity))
    }

    /// How far into the next color a point `fraction` of the way between two stops is: half way at the midpoint, and
    /// a smooth curve either side of it.
    static func blend(_ fraction: CGFloat, midpoint: CGFloat) -> CGFloat {
        let fraction = min(1, max(0, fraction))
        guard abs(midpoint - 0.5) > 0.0001, fraction > 0 else { return fraction }
        return pow(fraction, log(0.5) / log(min(midpointRange.upperBound, max(midpointRange.lowerBound, midpoint))))
    }

    /// Locations and values to hand Core Graphics, which blends evenly between the stops it's given: a segment whose
    /// midpoint has moved gets extra stops along its curve.
    var samples: [(location: CGFloat, color: PaletteColor, opacity: CGFloat)] {
        let order = sorted
        var result: [(location: CGFloat, color: PaletteColor, opacity: CGFloat)] = []
        for (index, stop) in order.enumerated() {
            result.append((stop.location, stop.color, stop.opacity))
            guard index + 1 < order.count, abs(stop.midpoint - 0.5) > 0.0001 else { continue }
            let next = order[index + 1]
            for step in 1..<24 {
                let t = stop.location + (next.location - stop.location) * CGFloat(step) / 24
                let value = value(at: t)
                result.append((t, value.color, value.opacity))
            }
        }
        return result
    }

    /// Whether Core Image's two-color gradients can draw it: two stops, at the ends, blending evenly.
    var isSimple: Bool {
        let order = sorted
        return order.count == 2 && order[0].location == 0 && order[1].location == 1 && abs(order[0].midpoint - 0.5) <= 0.0001
    }

    /// The gradient as Core Graphics draws it, midpoints as extra stops. On a mask a color is its brightness.
    func cgStops(mask: Bool = false) -> (colors: [CGColor], locations: [CGFloat]) {
        let space = mask ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let samples = samples
        let colors = samples.map { sample -> CGColor in
            let value = sample.color
            let gray = 0.2126 * value.red + 0.7152 * value.green + 0.0722 * value.blue
            return CGColor(colorSpace: space, components: mask ? [gray, sample.opacity] : [value.red, value.green, value.blue, sample.opacity])!
        }
        return (colors, samples.map(\.location))
    }

    func cgGradient(mask: Bool = false) -> CGGradient? {
        let stops = cgStops(mask: mask)
        return CGGradient(colorsSpace: mask ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: stops.colors as CFArray, locations: stops.locations)
    }

    /// Paints the gradient over `bounds` (in whatever coordinates `context` is set up for, y down): linear across it at
    /// `angle`, radial out from its middle to its corners, or sweeping around its middle from `angle`; reversed if
    /// asked, at its opacity. On a mask a color is its brightness.
    func draw(across bounds: CGRect, mask: Bool = false, context: CGContext) {
        let oriented = isReversed ? reversed : self
        guard let shading = oriented.cgGradient(mask: mask) else { return }
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        context.saveGState()
        context.setAlpha(opacity)
        switch shape {
        case .linear:
            let line = Self.line(across: bounds, angle: angle)
            context.drawLinearGradient(shading, start: line.start, end: line.end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .radial:
            context.drawRadialGradient(shading, startCenter: middle, startRadius: 0, endCenter: middle,
                                       endRadius: hypot(bounds.width, bounds.height) / 2, options: [.drawsAfterEndLocation])
        case .angle:
            // Document y runs down, so counterclockwise on screen is the negative direction.
            oriented.sweep(around: middle, from: -angle * .pi / 180, radius: hypot(bounds.width, bounds.height), mask: mask, context: context)
        }
        context.restoreGState()
    }

    /// An angle gradient: around `center`, counterclockwise on screen from `start` (radians, in the context's own y-down
    /// terms), the first stop's color there and the last's when it comes back round. Core Graphics has no sweep of its
    /// own, so it's thin wedges, each in the color for its angle, close enough that the steps don't show.
    func sweep(around center: CGPoint, from start: CGFloat, radius: CGFloat, mask: Bool, context: CGContext) {
        let steps = 720
        let space = mask ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        context.saveGState()
        // Edges between wedges, unsmoothed, so neighbors don't double up where they meet.
        context.setShouldAntialias(false)
        for step in 0..<steps {
            let from = start - CGFloat(step) / CGFloat(steps) * 2 * .pi
            let to = start - CGFloat(step + 1) / CGFloat(steps) * 2 * .pi
            let value = value(at: (CGFloat(step) + 0.5) / CGFloat(steps))
            let gray = 0.2126 * value.color.red + 0.7152 * value.color.green + 0.0722 * value.color.blue
            context.setFillColor(CGColor(colorSpace: space, components: mask ? [gray, value.opacity]
                : [value.color.red, value.color.green, value.color.blue, value.opacity])!)
            context.move(to: center)
            context.addLine(to: CGPoint(x: center.x + cos(from) * radius, y: center.y + sin(from) * radius))
            context.addLine(to: CGPoint(x: center.x + cos(to) * radius, y: center.y + sin(to) * radius))
            context.closePath()
            context.fillPath()
        }
        context.restoreGState()
    }

    /// The line a linear gradient runs along to cross `bounds` exactly at `angle` degrees: through its middle, from the
    /// corner it starts at to the opposite one, as measured along the line. y runs down, so 90° is upward.
    static func line(across bounds: CGRect, angle: CGFloat) -> (start: CGPoint, end: CGPoint) {
        let radians = angle * .pi / 180
        let direction = CGPoint(x: cos(radians), y: -sin(radians))
        let reach = (bounds.width * abs(direction.x) + bounds.height * abs(direction.y)) / 2
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        return (CGPoint(x: middle.x - direction.x * reach, y: middle.y - direction.y * reach),
                CGPoint(x: middle.x + direction.x * reach, y: middle.y + direction.y * reach))
    }

    /// A stop added at `location`, in the color and opacity the gradient already has there.
    mutating func addStop(at location: CGFloat) -> UUID? {
        guard stops.count < Self.maxStops else { return nil }
        let location = min(1, max(0, location))
        let value = value(at: location)
        let stop = GradientStop(location: location, color: value.color, opacity: value.opacity)
        stops.append(stop)
        return stop.id
    }

    // The built-in gradients.
    static let foregroundToBackground = ColorGradient(stops: [
        GradientStop(location: 0, color: .black, role: .foreground), GradientStop(location: 1, color: .white, role: .background)])
    static let foregroundToTransparent = ColorGradient(stops: [
        GradientStop(location: 0, color: .black, role: .foreground), GradientStop(location: 1, color: .black, opacity: 0, role: .foreground)])
}

/// A gradient saved in the library, by name.
nonisolated struct SavedGradient: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var gradient: ColorGradient
}

nonisolated struct GradientSet: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var gradients: [SavedGradient]
}

/// The gradient sets the picker offers, kept across launches in Application Support for the whole app, as swatch sets
/// are. Tests get the built-in set and never touch the file.
@Observable
final class GradientLibrary {
    static let shared = GradientLibrary(fileURL: isTesting ? nil : defaultURL)
    private static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private struct Saved: Codable {
        var sets: [GradientSet]
        var selectedSetID: UUID?
    }

    var sets: [GradientSet] { didSet { save() } }
    var selectedSetID: UUID? { didSet { save() } }
    @ObservationIgnored private let fileURL: URL?

    /// A library kept in `fileURL`, or only in memory when it is nil.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Saved.self, from: data),
           !saved.sets.isEmpty {
            sets = saved.sets
            selectedSetID = saved.selectedSetID
        } else {
            sets = [Self.builtInSet()]
            selectedSetID = nil
        }
    }

    private static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Pixegen", isDirectory: true).appendingPathComponent("Gradients.json")
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(Saved(sets: sets, selectedSetID: selectedSetID)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    var selectedSet: GradientSet? { sets.first { $0.id == selectedSetID } ?? sets.first }

    @discardableResult
    func newSet(named name: String) -> UUID {
        let set = GradientSet(name: Self.cleaned(name) ?? "Gradients", gradients: [])
        sets.append(set)
        selectedSetID = set.id
        return set.id
    }

    func renameSet(_ id: UUID, to name: String) {
        guard let name = Self.cleaned(name), let index = sets.firstIndex(where: { $0.id == id }) else { return }
        sets[index].name = name
    }

    /// Deletes a set; the last one left stays.
    func deleteSet(_ id: UUID) {
        guard sets.count > 1 else { return }
        sets.removeAll { $0.id == id }
        if selectedSetID == id { selectedSetID = sets.first?.id }
    }

    func addGradient(_ gradient: ColorGradient, to setID: UUID) {
        guard gradient.isValid, let index = sets.firstIndex(where: { $0.id == setID }) else { return }
        sets[index].gradients.append(SavedGradient(name: "Gradient \(sets[index].gradients.count + 1)", gradient: gradient))
    }

    func renameGradient(_ id: UUID, to name: String) {
        guard let name = Self.cleaned(name) else { return }
        for set in sets.indices {
            if let index = sets[set].gradients.firstIndex(where: { $0.id == id }) { sets[set].gradients[index].name = name; return }
        }
    }

    func deleteGradient(_ id: UUID) {
        for set in sets.indices { sets[set].gradients.removeAll { $0.id == id } }
    }

    private static func cleaned(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(100))
    }

    /// "Basic": the two that follow the palette, black to white, and a few in color.
    static func builtInSet() -> GradientSet {
        func color(_ hex: String) -> PaletteColor { PaletteColor(hex: hex) ?? .black }
        func even(_ hexes: [String]) -> ColorGradient {
            ColorGradient(stops: hexes.enumerated().map { GradientStop(location: CGFloat($0.offset) / CGFloat(hexes.count - 1), color: color($0.element)) })
        }
        return GradientSet(name: "Basic", gradients: [
            SavedGradient(name: "Foreground to Background", gradient: .foregroundToBackground),
            SavedGradient(name: "Foreground to Transparent", gradient: .foregroundToTransparent),
            SavedGradient(name: "Black to White", gradient: ColorGradient(.black, .white)),
            SavedGradient(name: "Spectrum", gradient: even(["FF0000", "FFFF00", "00FF00", "00FFFF", "0000FF", "FF00FF", "FF0000"])),
            SavedGradient(name: "Sunset", gradient: even(["2B1055", "D53A9D", "FF8A3D", "FFE29A"])),
            SavedGradient(name: "Ocean", gradient: even(["03045E", "0077B6", "48CAE4", "CAF0F8"])),
            SavedGradient(name: "Copper", gradient: even(["5B2C0E", "B86B3A", "F2C49B", "8A4B24"])),
        ])
    }
}
