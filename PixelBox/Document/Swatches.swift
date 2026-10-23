import Foundation
import Observation

/// A named color in a swatch set.
nonisolated struct Swatch: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var color: PaletteColor
}

nonisolated struct SwatchSet: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var swatches: [Swatch]
}

/// The color picker's swatch sets and recent colors, kept across launches in Application Support for the whole app,
/// not per document. Tests get the built-in sets and never touch the file.
@Observable
final class SwatchLibrary {
    static let shared = SwatchLibrary(fileURL: isTesting ? nil : defaultURL)
    static let recentLimit = 12
    private static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private struct Saved: Codable {
        var sets: [SwatchSet]
        var selectedSetID: UUID?
        var recents: [PaletteColor]
    }

    var sets: [SwatchSet] { didSet { save() } }
    /// The set the picker shows.
    var selectedSetID: UUID? { didSet { save() } }
    /// The colors last chosen anywhere in the app, newest first.
    private(set) var recents: [PaletteColor] { didSet { save() } }
    @ObservationIgnored private let fileURL: URL?

    /// A library kept in `fileURL`, or only in memory when it is nil.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Saved.self, from: data),
           !saved.sets.isEmpty {
            sets = saved.sets
            selectedSetID = saved.selectedSetID
            recents = Array(saved.recents.prefix(Self.recentLimit))
        } else {
            sets = Self.builtInSets()
            selectedSetID = nil
            recents = []
        }
    }

    private static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PixelBox", isDirectory: true).appendingPathComponent("Swatches.json")
    }

    private func save() {
        guard let fileURL,
              let data = try? JSONEncoder().encode(Saved(sets: sets, selectedSetID: selectedSetID, recents: recents)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The set shown: the one picked, or the first when that one has gone.
    var selectedSet: SwatchSet? { sets.first { $0.id == selectedSetID } ?? sets.first }

    func addRecent(_ color: PaletteColor) {
        var colors = recents.filter { $0 != color }
        colors.insert(color, at: 0)
        recents = Array(colors.prefix(Self.recentLimit))
    }

    @discardableResult
    func newSet(named name: String) -> UUID {
        let set = SwatchSet(name: Self.cleaned(name) ?? "Swatches", swatches: [])
        sets.append(set)
        selectedSetID = set.id
        return set.id
    }

    func renameSet(_ id: UUID, to name: String) {
        guard let name = Self.cleaned(name), let index = sets.firstIndex(where: { $0.id == id }) else { return }
        sets[index].name = name
    }

    /// Deletes a set; the last one left stays, so there is always somewhere to put a swatch.
    func deleteSet(_ id: UUID) {
        guard sets.count > 1 else { return }
        sets.removeAll { $0.id == id }
        if selectedSetID == id { selectedSetID = sets.first?.id }
    }

    /// Adds a color to a set, named by its hex value.
    func addSwatch(_ color: PaletteColor, to setID: UUID) {
        guard let index = sets.firstIndex(where: { $0.id == setID }) else { return }
        sets[index].swatches.append(Swatch(name: "#" + color.hex, color: color))
    }

    func renameSwatch(_ id: UUID, to name: String) {
        guard let name = Self.cleaned(name) else { return }
        for set in sets.indices {
            if let index = sets[set].swatches.firstIndex(where: { $0.id == id }) { sets[set].swatches[index].name = name; return }
        }
    }

    func deleteSwatch(_ id: UUID) {
        for set in sets.indices { sets[set].swatches.removeAll { $0.id == id } }
    }

    private static func cleaned(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(100))
    }

    /// "Basic": the primaries and secondaries, orange and purple, and a gray ramp. "Grays": black to white in tenths.
    static func builtInSets() -> [SwatchSet] {
        func swatch(_ name: String, _ hex: String) -> Swatch { Swatch(name: name, color: PaletteColor(hex: hex) ?? .black) }
        let basic = SwatchSet(name: "Basic", swatches: [
            swatch("Red", "FF0000"), swatch("Orange", "FF8000"), swatch("Yellow", "FFFF00"), swatch("Green", "00FF00"),
            swatch("Cyan", "00FFFF"), swatch("Blue", "0000FF"), swatch("Purple", "8000FF"), swatch("Magenta", "FF00FF"),
            swatch("White", "FFFFFF"), swatch("Light Gray", "BFBFBF"), swatch("Gray", "808080"), swatch("Dark Gray", "404040"),
            swatch("Black", "000000"),
        ])
        let grays = SwatchSet(name: "Grays", swatches: (0...10).map { step in
            let value = CGFloat(10 - step) / 10
            return Swatch(name: "\(step * 10)% Gray", color: PaletteColor(red: value, green: value, blue: value))
        })
        return [basic, grays]
    }
}
