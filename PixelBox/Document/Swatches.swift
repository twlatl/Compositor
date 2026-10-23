import Foundation
import CoreGraphics
import Observation

/// A named color kept in the Swatches palette. Saved with the project.
nonisolated struct Swatch: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    /// sRGB, 0–1.
    var red: Double
    var green: Double
    var blue: Double

    init(id: UUID = UUID(), name: String, color: PaletteColor) {
        self.id = id
        self.name = name
        red = Double(color.red); green = Double(color.green); blue = Double(color.blue)
    }
    var color: PaletteColor { PaletteColor(red: red, green: green, blue: blue) }
}

/// A folder of swatches in the Swatches palette, as Photoshop's swatch groups.
nonisolated struct SwatchGroup: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var swatches: [Swatch]

    init(id: UUID = UUID(), name: String, swatches: [Swatch] = []) {
        self.id = id
        self.name = name
        self.swatches = swatches
    }

    static let maxGroups = 1_000
    static let maxSwatches = 10_000
    static let maxNameBytes = 1_024

    /// What a project shows until its swatches are first changed. The same ids every time, so a swatch selected
    /// before the first edit is still selected after it.
    static let defaults = makeDefaults()

    /// The default folders with ids of their own, for Append Default Swatches.
    static func makeDefaults() -> [SwatchGroup] {
        func group(_ name: String, _ colors: [(String, String)]) -> SwatchGroup {
            SwatchGroup(name: name, swatches: colors.map { Swatch(name: $0.0, color: PaletteColor(hex: $0.1)!) })
        }
        return [
            group("RGB", [("RGB Red", "FF0000"), ("RGB Yellow", "FFFF00"), ("RGB Green", "00FF00"),
                          ("RGB Cyan", "00FFFF"), ("RGB Blue", "0000FF"), ("RGB Magenta", "FF00FF")]),
            group("CMYK", [("CMYK Red", "ED1C24"), ("CMYK Yellow", "FFF200"), ("CMYK Green", "00A651"),
                           ("CMYK Cyan", "00AEEF"), ("CMYK Blue", "2E3192"), ("CMYK Magenta", "EC008C")]),
            group("Grayscale", (0...10).map { step in
                let percent = 100 - step * 10
                let value = Int((Double(step) / 10 * 255).rounded())
                return ("\(percent)% Gray", String(format: "%02X%02X%02X", value, value, value))
            }),
            group("Pastel", [("Pastel Red", "F7977A"), ("Pastel Orange", "FDC68A"), ("Pastel Yellow", "FFF79A"),
                             ("Pastel Green", "A3D39C"), ("Pastel Cyan", "6DCFF6"), ("Pastel Blue", "8393CA"),
                             ("Pastel Violet", "A187BE"), ("Pastel Magenta", "F49AC2")]),
            group("Light", [("Light Red", "F26C4F"), ("Light Orange", "F68E55"), ("Light Yellow", "FFF467"),
                            ("Light Green", "7CC576"), ("Light Cyan", "00BFF3"), ("Light Blue", "5674B9"),
                            ("Light Violet", "855FA8"), ("Light Magenta", "F06EAA")]),
            group("Dark", [("Dark Red", "9E0B0F"), ("Dark Orange", "A0410D"), ("Dark Yellow", "ABA000"),
                           ("Dark Green", "197B30"), ("Dark Cyan", "0076A3"), ("Dark Blue", "21409A"),
                           ("Dark Violet", "440E62"), ("Dark Magenta", "9E005D")]),
        ]
    }

    /// Ids are unique, names fit, colors are finite and in range, and the counts are within the limits.
    static func isValid(_ groups: [SwatchGroup]) -> Bool {
        guard groups.count <= maxGroups, groups.reduce(0, { $0 + $1.swatches.count }) <= maxSwatches else { return false }
        var ids = Set<UUID>()
        for group in groups {
            guard ids.insert(group.id).inserted, group.name.utf8.count <= maxNameBytes else { return false }
            for swatch in group.swatches {
                guard ids.insert(swatch.id).inserted, swatch.name.utf8.count <= maxNameBytes,
                      [swatch.red, swatch.green, swatch.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return false }
            }
        }
        return true
    }
}

enum SwatchError: LocalizedError {
    case tooMany
    var errorDescription: String? {
        "A project holds at most \(SwatchGroup.maxSwatches.formatted()) swatches in \(SwatchGroup.maxGroups.formatted()) folders. The swatches have not been imported."
    }
}

extension EditorSession {
    /// The project's swatch folders: the defaults until they are first changed.
    var swatchGroups: [SwatchGroup] { document?.swatchGroups ?? SwatchGroup.defaults }
    var canEditSwatches: Bool { document != nil && canEditPalette }

    /// The folder holding `id`, which is a folder or a swatch.
    func swatchGroup(containing id: UUID) -> SwatchGroup? {
        swatchGroups.first { $0.id == id || $0.swatches.contains { $0.id == id } }
    }
    func swatch(_ id: UUID) -> Swatch? {
        swatchGroups.lazy.flatMap(\.swatches).first { $0.id == id }
    }

    /// One undoable change to the swatches. Saved with the project, so it marks it edited.
    private func changeSwatches(_ name: String, _ change: (inout [SwatchGroup]) throws -> Void) rethrows {
        guard canEditSwatches else { return }
        var groups = swatchGroups
        try change(&groups)
        guard groups != swatchGroups else { return }
        beginEdit(name)
        document?.swatchGroups = groups
        endEdit()
    }

    @discardableResult
    func addSwatchGroup(named name: String) -> UUID? {
        guard canEditSwatches, swatchGroups.count < SwatchGroup.maxGroups else { return nil }
        let group = SwatchGroup(name: Self.swatchName(name, fallback: "Untitled Folder"))
        changeSwatches("New Swatch Group") { $0.append(group) }
        return group.id
    }

    /// Adds a swatch to the folder of `near` (a folder, or a swatch it follows), else to the first folder, else
    /// to a new one.
    @discardableResult
    func addSwatch(_ color: PaletteColor, named name: String, near: UUID? = nil) -> UUID? {
        guard canEditSwatches, swatchGroups.reduce(0, { $0 + $1.swatches.count }) < SwatchGroup.maxSwatches else { return nil }
        let swatch = Swatch(name: Self.swatchName(name, fallback: color.quantized.hex), color: color.quantized)
        changeSwatches("New Swatch") { groups in
            if groups.isEmpty { groups.append(SwatchGroup(name: "Swatches")) }
            let target = near.flatMap { id in groups.firstIndex { $0.id == id || $0.swatches.contains { $0.id == id } } } ?? 0
            if let near, let after = groups[target].swatches.firstIndex(where: { $0.id == near }) {
                groups[target].swatches.insert(swatch, at: after + 1)
            } else {
                groups[target].swatches.append(swatch)
            }
        }
        return swatch.id
    }

    /// Renames a swatch or a folder. An empty name leaves it as it was.
    func renameSwatchItem(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= SwatchGroup.maxNameBytes else { return }
        changeSwatches(swatchGroups.contains { $0.id == id } ? "Rename Swatch Group" : "Rename Swatch") { groups in
            for g in groups.indices {
                if groups[g].id == id { groups[g].name = trimmed; return }
                if let s = groups[g].swatches.firstIndex(where: { $0.id == id }) { groups[g].swatches[s].name = trimmed; return }
            }
        }
    }

    /// Deletes a swatch, or a folder with everything in it.
    func deleteSwatchItem(_ id: UUID) {
        changeSwatches(swatchGroups.contains { $0.id == id } ? "Delete Swatch Group" : "Delete Swatch") { groups in
            groups.removeAll { $0.id == id }
            for g in groups.indices { groups[g].swatches.removeAll { $0.id == id } }
        }
    }

    func appendDefaultSwatches() {
        try? importSwatches(SwatchGroup.makeDefaults(), actionName: "Append Default Swatches")
    }

    /// Adds folders read from a swatch file, as one undoable step. Ids are made new, so importing the same file
    /// twice gives two copies rather than clashing.
    func importSwatches(_ incoming: [SwatchGroup], actionName: String = "Import Swatches") throws {
        let fresh = incoming.map { group in
            SwatchGroup(name: Self.swatchName(group.name, fallback: "Imported"),
                        swatches: group.swatches.map { Swatch(name: Self.swatchName($0.name, fallback: $0.color.quantized.hex), color: $0.color) })
        }
        let groups = swatchGroups
        guard groups.count + fresh.count <= SwatchGroup.maxGroups,
              (groups + fresh).reduce(0, { $0 + $1.swatches.count }) <= SwatchGroup.maxSwatches else { throw SwatchError.tooMany }
        changeSwatches(actionName) { $0.append(contentsOf: fresh) }
    }

    /// Reads a Photoshop swatch file (.aco, .ase, .act) or a web color file (.css, .html, .svg) into the project.
    func importSwatches(from url: URL) throws {
        let groups = try SwatchFile.read(Data(contentsOf: url), named: url.deletingPathExtension().lastPathComponent,
                                         extension: url.pathExtension)
        try importSwatches(groups)
    }

    private static func swatchName(_ name: String, fallback: String) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = fallback }
        while trimmed.utf8.count > SwatchGroup.maxNameBytes { trimmed.removeLast() }
        return trimmed
    }
}

/// The colors last chosen in the color picker, anywhere in the app, newest first: kept across launches in Application
/// Support for the whole app, unlike swatches, which belong to a project. Tests start empty and never touch the file.
@Observable
final class RecentColors {
    static let shared = RecentColors(fileURL: isTesting ? nil : defaultURL)
    static let limit = 12
    private static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private(set) var colors: [PaletteColor] { didSet { save() } }
    @ObservationIgnored private let fileURL: URL?

    /// Recent colors kept in `fileURL`, or only in memory when it is nil.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([PaletteColor].self, from: data) {
            colors = Array(saved.prefix(Self.limit))
        } else {
            colors = []
        }
    }

    private static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PixelBox", isDirectory: true).appendingPathComponent("Recent Colors.json")
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(colors) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    func add(_ color: PaletteColor) {
        var list = colors.filter { $0 != color }
        list.insert(color, at: 0)
        colors = Array(list.prefix(Self.limit))
    }
}
