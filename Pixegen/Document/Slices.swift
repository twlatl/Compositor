import Foundation
import CoreGraphics

/// A file type a slice exports as.
nonisolated enum SliceFileType: String, Codable, CaseIterable, Sendable {
    case jpeg = "JPEG", png = "PNG", webP = "WebP", svg = "SVG", gif = "GIF", mp4 = "MP4"

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .webP: "webp"
        case .svg: "svg"
        case .gif: "gif"
        case .mp4: "mp4"
        }
    }
    /// JPEG and MP4 have no alpha: they're always flattened onto white.
    var supportsTransparency: Bool { self != .jpeg && self != .mp4 }
    /// The lossy formats, which get a quality slider.
    var hasQuality: Bool { self == .jpeg || self == .webP }
}

/// One file a slice exports: its type, size and the type's own options.
nonisolated struct SliceFormat: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var type: SliceFileType = .png
    /// The exported size against the slice's own: 0.5 for half, 2 for @2x.
    var scale: Double = 1
    /// Added to the slice's name in the file name, as "@2x" or "-thumb".
    var suffix = ""
    /// JPEG and WebP, 0–1.
    var quality: Double = 0.8
    /// Off, transparent pixels are flattened onto white. Ignored by JPEG and MP4, which are always flattened.
    var keepsTransparency = true
    /// On, the file is tagged sRGB; off, it carries no color profile.
    var convertsToSRGB = true
    /// PNG: filtered row by row and deflated at the highest level, for a smaller file that takes longer to write.
    var advancedCompression = false
    /// PNG: reduced to at most 256 colors, an indexed PNG.
    var limitedPalette = false

    static let scales: [Double] = [0.5, 1, 1.5, 2, 3, 4]
    /// The sizes Add Format offers next, most wanted first: retina copies before smaller ones.
    static let addedScales: [Double] = [1, 2, 3, 0.5, 1.5, 4]
    static let maxSuffixBytes = 256
    static let qualityLevels: [(name: String, value: Double)] = [("Low", 0.3), ("Medium", 0.6), ("High", 0.85), ("Maximum", 1)]

    init(type: SliceFileType = .png, scale: Double = 1, quality: Double = 0.8, limitedPalette: Bool = false) {
        self.type = type
        self.scale = scale
        self.quality = quality
        self.limitedPalette = limitedPalette
    }

    /// Fields left out (written by hand or by an agent) take their defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SliceFormat()
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try container.decodeIfPresent(SliceFileType.self, forKey: .type) ?? defaults.type
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? defaults.scale
        suffix = try container.decodeIfPresent(String.self, forKey: .suffix) ?? defaults.suffix
        quality = try container.decodeIfPresent(Double.self, forKey: .quality) ?? defaults.quality
        keepsTransparency = try container.decodeIfPresent(Bool.self, forKey: .keepsTransparency) ?? defaults.keepsTransparency
        convertsToSRGB = try container.decodeIfPresent(Bool.self, forKey: .convertsToSRGB) ?? defaults.convertsToSRGB
        advancedCompression = try container.decodeIfPresent(Bool.self, forKey: .advancedCompression) ?? defaults.advancedCompression
        limitedPalette = try container.decodeIfPresent(Bool.self, forKey: .limitedPalette) ?? defaults.limitedPalette
    }

    var isValid: Bool {
        scale.isFinite && (0.1...10).contains(scale) && quality.isFinite && (0...1).contains(quality)
            && suffix.utf8.count <= Self.maxSuffixBytes && !suffix.contains("/") && !suffix.contains(":")
    }
    /// "1x", "0.5x", "2x".
    static func scaleLabel(_ scale: Double) -> String { scale.formatted(.number.precision(.fractionLength(0...2))) + "x" }
    /// The quality slider's word for `quality`.
    static func qualityName(_ quality: Double) -> String {
        quality < 0.45 ? "Low" : quality < 0.75 ? "Medium" : quality < 0.95 ? "High" : "Maximum"
    }
    /// The pixel size this format writes a slice of `size` at. MP4 rounds to even sides, as H.264 needs.
    func outputSize(for size: CGSize) -> (width: Int, height: Int) {
        var width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        if type == .mp4 {
            width = max(2, width + width % 2)
            height = max(2, height + height % 2)
        }
        return (width, height)
    }
}

/// A region of the canvas exported on its own, in one or more formats: File › Export for Web.
nonisolated struct CanvasSlice: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    /// Document pixels, whole numbers, inside the canvas.
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var formats: [SliceFormat] = [SliceFormat()]

    static let maxSlices = 1_000
    static let maxFormats = 32
    static let maxNameBytes = 1_024

    init(id: UUID = UUID(), name: String, rect: CGRect, formats: [SliceFormat] = [SliceFormat()]) {
        self.id = id
        self.name = name
        x = Int(rect.minX.rounded())
        y = Int(rect.minY.rounded())
        width = max(1, Int(rect.width.rounded()))
        height = max(1, Int(rect.height.rounded()))
        self.formats = formats
    }

    /// An id or formats left out (written by hand or by an agent) are made up: a new id, and one PNG.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        x = try container.decode(Int.self, forKey: .x)
        y = try container.decode(Int.self, forKey: .y)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        formats = try container.decodeIfPresent([SliceFormat].self, forKey: .formats) ?? [SliceFormat()]
    }

    var rect: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = Int(newValue.minX.rounded())
            y = Int(newValue.minY.rounded())
            width = max(1, Int(newValue.width.rounded()))
            height = max(1, Int(newValue.height.rounded()))
        }
    }

    /// The slice with its rectangle put through `map` and cut to a canvas of `size`; nil once none of it is left.
    func transformed(in size: CGSize, _ map: (CGRect) -> CGRect) -> CanvasSlice? {
        let mapped = map(rect).standardized
        guard mapped.minX.isFinite, mapped.minY.isFinite, mapped.width.isFinite, mapped.height.isFinite else { return nil }
        let x = mapped.minX.rounded(), y = mapped.minY.rounded()
        let snapped = CGRect(x: x, y: y, width: mapped.maxX.rounded() - x, height: mapped.maxY.rounded() - y)
            .intersection(CGRect(origin: .zero, size: size))
        guard !snapped.isNull, snapped.width >= 1, snapped.height >= 1 else { return nil }
        var slice = self
        slice.rect = snapped
        return slice
    }

    /// The slice inside a canvas of `size`, with a valid name and formats.
    func isValid(in size: CGSize) -> Bool {
        x >= 0 && y >= 0 && width >= 1 && height >= 1 && CGFloat(x + width) <= size.width && CGFloat(y + height) <= size.height
            && !name.isEmpty && name.utf8.count <= Self.maxNameBytes
            && formats.count <= Self.maxFormats && formats.allSatisfy(\.isValid)
            && Set(formats.map(\.id)).count == formats.count
    }

    /// The file name for `format`, without its folder: the slice's name and the format's suffix, made safe to write.
    func fileName(for format: SliceFormat) -> String {
        let base = (name + format.suffix).map { "/:".contains($0) ? "-" : $0 }
        let trimmed = String(base).trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty || trimmed.hasPrefix(".") ? "Slice" + trimmed : trimmed) + "." + format.type.fileExtension
    }
}

/// A set of formats, offered in the Export panel's Presets to replace a slice's formats in one go.
nonisolated struct SliceFormatPreset: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var formats: [SliceFormat]

    static let builtIn: [SliceFormatPreset] = [
        SliceFormatPreset(name: "Photo 100% Quality", formats: [SliceFormat(type: .jpeg, quality: 1)]),
        SliceFormatPreset(name: "Photo 80% Quality", formats: [SliceFormat(type: .jpeg, quality: 0.8)]),
        SliceFormatPreset(name: "Web Graphics", formats: [SliceFormat(type: .png)]),
        SliceFormatPreset(name: "Web Compressed", formats: [SliceFormat(type: .webP, quality: 0.8)]),
        SliceFormatPreset(name: "Web Video", formats: [SliceFormat(type: .mp4)]),
        SliceFormatPreset(name: "Vector Graphics", formats: [SliceFormat(type: .svg)]),
    ]
}

/// The presets added with the Presets popover's +, kept across launches and projects.
@Observable final class SlicePresetStore {
    static let shared = SlicePresetStore()
    private static let key = "export.slicePresets"
    private(set) var custom: [SliceFormatPreset]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        custom = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([SliceFormatPreset].self, from: $0) } ?? []
    }
    var all: [SliceFormatPreset] { SliceFormatPreset.builtIn + custom }

    func add(name: String, formats: [SliceFormat]) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !formats.isEmpty else { return }
        custom.append(SliceFormatPreset(name: String(name.prefix(200)), formats: formats))
        save()
    }
    func remove(_ id: UUID) {
        custom.removeAll { $0.id == id }
        save()
    }
    private func save() {
        if let data = try? JSONEncoder().encode(custom) { defaults.set(data, forKey: Self.key) }
    }
}

extension EditorSession {
    /// Slices as currently shown, including a drag in progress.
    var displayedSlices: [CanvasSlice] {
        var slices = document?.slices ?? []
        guard let draft = sliceDraft else { return slices }
        if let id = draft.id, let index = slices.firstIndex(where: { $0.id == id }) {
            slices[index].rect = draft.rect
        } else if draft.id == nil {
            slices.append(CanvasSlice(name: nextSliceName(), rect: draft.rect))
        }
        return slices
    }
    var selectedSlice: CanvasSlice? { document?.slices.first { $0.id == selectedSliceID } }
    var canEditSlices: Bool {
        _ = showsBusy
        return document != nil && !isProjectBusy && !isImporting && !showsNewDocument && levels == nil
            && hueSaturation == nil && filterEdit == nil && renamingLayerID == nil
    }

    /// File › Export for Web (⌘E): the Export panel takes the Layers panel's place, and the Slice tool the pointer.
    func openExportPanel() {
        guard document != nil else { return }
        selectTool(.slice)
    }
    /// Cancel, or after Export: the Layers panel comes back, with the tool used before.
    func closeExportPanel() {
        sliceDraft = nil
        let previous = toolBeforeExport ?? .move
        exportPanelOpen = false
        if tool == .slice { selectTool(previous) }
        toolBeforeExport = nil
    }
    /// Called as the tool changes: the Slice tool opens the panel, and the tools for looking around (Hand, Zoom) keep
    /// it open; any other closes it.
    func updateExportPanel(from previous: NavigationTool, to tool: NavigationTool) {
        if tool == .slice {
            if !exportPanelOpen {
                exportPanelOpen = true
                toolBeforeExport = previous == .slice ? nil : previous
            }
            if selectedSliceID == nil || selectedSlice == nil { selectedSliceID = document?.slices.last?.id }
        } else if tool != .hand && tool != .zoom, exportPanelOpen {
            exportPanelOpen = false
            sliceDraft = nil
            toolBeforeExport = nil
        }
    }

    /// "Slice" followed by one more than the highest number any slice named that way has.
    func nextSliceName() -> String {
        let numbers = (document?.slices ?? []).compactMap { slice -> Int? in
            guard slice.name.hasPrefix("Slice ") else { return nil }
            return Int(slice.name.dropFirst(6))
        }
        return "Slice \((numbers.max() ?? 0) + 1)"
    }

    /// `rect` kept inside the canvas, in whole pixels; nil when nothing of it is on the canvas.
    func clampedSliceRect(_ rect: CGRect) -> CGRect? {
        guard let document else { return nil }
        let snapped = CropGeometry.snapped(rect)
        let clamped = snapped.intersection(CGRect(origin: .zero, size: document.size))
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return clamped
    }
    /// A slice moved to `rect` keeps its size, sliding back inside the canvas where it would leave it.
    func movedSliceRect(_ rect: CGRect) -> CGRect? {
        guard let document else { return nil }
        var rect = CropGeometry.snapped(rect)
        rect.size.width = min(rect.width, document.size.width)
        rect.size.height = min(rect.height, document.size.height)
        rect.origin.x = min(max(0, rect.minX), document.size.width - rect.width)
        rect.origin.y = min(max(0, rect.minY), document.size.height - rect.height)
        return rect
    }

    /// Ends a slice drag: a new slice, or one moved or resized, as one undo step.
    func finishSliceDraft() {
        guard let draft = sliceDraft else { return }
        sliceDraft = nil
        guard canEditSlices else { return }
        if let id = draft.id {
            guard let index = document?.slices.firstIndex(where: { $0.id == id }), document?.slices[index].rect != draft.rect else { return }
            beginEdit(document?.slices[index].rect.size == draft.rect.size ? "Move Slice" : "Resize Slice")
            document?.slices[index].rect = draft.rect
            endEdit()
        } else {
            guard (document?.slices.count ?? 0) < CanvasSlice.maxSlices else { return }
            let slice = CanvasSlice(name: nextSliceName(), rect: draft.rect, formats: lastSliceFormats)
            beginEdit("New Slice")
            document?.slices.append(slice)
            endEdit()
            selectedSliceID = slice.id
        }
    }

    /// The formats a new slice starts with: the last slice's, which is usually what the next one wants too.
    private var lastSliceFormats: [SliceFormat] {
        (document?.slices.last?.formats ?? [SliceFormat()]).map { format in
            var copy = format
            copy.id = UUID()
            return copy
        }
    }

    /// The topmost slice under a document point: the newest, as it is drawn last.
    func slice(at point: CGPoint) -> CanvasSlice? {
        document?.slices.last { $0.rect.contains(point) }
    }

    /// Changes one slice as an undo step named `name`. With `coalescing`, repeated changes of the same kind (a slider
    /// dragged, a suffix typed) are one step.
    func updateSlice(_ id: UUID, _ name: String, coalescing: Bool = false, _ change: (inout CanvasSlice) -> Void) {
        guard canEditSlices, let index = document?.slices.firstIndex(where: { $0.id == id }), let original = document?.slices[index] else { return }
        var slice = original
        change(&slice)
        guard slice != original, let document, slice.isValid(in: document.size) else { return }
        let continuing = coalescing && lastSliceEdit.map { $0.id == id && $0.name == name && Date().timeIntervalSince($0.time) < 1.5 } == true
            && history.canAmendLast(name)
        if !continuing { beginEdit(name) }
        self.document?.slices[index] = slice
        if continuing { history.amendLast(document: self.document, selection: activeLayerID) } else { endEdit() }
        lastSliceEdit = coalescing ? (id, name, Date()) : nil
    }

    func renameSlice(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var fitted = name
        while fitted.utf8.count > CanvasSlice.maxNameBytes { fitted.removeLast() }
        updateSlice(id, "Rename Slice") { $0.name = fitted }
    }

    func deleteSlice(_ id: UUID) {
        guard canEditSlices, let index = document?.slices.firstIndex(where: { $0.id == id }) else { return }
        beginEdit("Delete Slice")
        document?.slices.remove(at: index)
        endEdit()
        if selectedSliceID == id { selectedSliceID = document?.slices.last?.id }
    }

    func updateSliceFormat(_ sliceID: UUID, _ formatID: UUID, _ name: String = "Change Export Format", coalescing: Bool = false,
                           _ change: (inout SliceFormat) -> Void) {
        updateSlice(sliceID, name, coalescing: coalescing) { slice in
            guard let index = slice.formats.firstIndex(where: { $0.id == formatID }) else { return }
            change(&slice.formats[index])
        }
    }

    /// Add Format: another file for the slice, the last format's type at the next size up, so the usual @2x copy is
    /// one click.
    func addSliceFormat(_ sliceID: UUID) {
        updateSlice(sliceID, "Add Export Format") { slice in
            guard slice.formats.count < CanvasSlice.maxFormats else { return }
            var format = slice.formats.last ?? SliceFormat()
            format.id = UUID()
            let used = Set(slice.formats.filter { $0.type == format.type }.map(\.scale))
            if let next = SliceFormat.addedScales.first(where: { !used.contains($0) }) {
                format.scale = next
                format.suffix = next == 1 ? "" : "@" + SliceFormat.scaleLabel(next)
            } else {
                format.suffix += "-\(slice.formats.count + 1)"
            }
            slice.formats.append(format)
        }
    }

    func removeSliceFormat(_ sliceID: UUID, _ formatID: UUID) {
        updateSlice(sliceID, "Remove Export Format") { slice in
            guard slice.formats.count > 1 else { return }
            slice.formats.removeAll { $0.id == formatID }
        }
    }

    func applySlicePreset(_ preset: SliceFormatPreset, to sliceID: UUID) {
        updateSlice(sliceID, "Apply Export Preset") { slice in
            slice.formats = preset.formats.map { format in
                var copy = format
                copy.id = UUID()
                return copy
            }
        }
    }
}
