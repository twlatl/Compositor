import SwiftUI
import CoreGraphics

/// File › Export for Web (⌘E): stands in for the Layers panel while it's open. The slices drawn on the canvas, each with
/// the formats it exports in, the selected one's formats to edit, and Export.
struct ExportPanel: View {
    @Bindable var session: EditorSession
    var width: CGFloat = 252
    let export: () -> Void
    @State private var preview = SliceExportPreview()
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool
    @State private var showsPresets = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Export for Web").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(session.document?.slices.count ?? 0)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }.padding(18)
            Divider()
            if let slices = session.document?.slices, !slices.isEmpty {
                sliceList(slices)
                Divider()
                if let slice = session.selectedSlice {
                    formatEditor(slice)
                } else {
                    Text("Select a slice to choose how it exports.")
                        .font(.caption).foregroundStyle(.secondary).padding(18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            } else {
                VStack(spacing: 10) {
                    SliceToolIcon().frame(width: 26, height: 26)
                    Text("No slices yet").font(.callout.weight(.medium))
                    Text("Drag across the canvas to slice out a region to export.")
                        .font(.caption).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary).padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 10) {
                Button { session.closeExportPanel() } label: { Text("Cancel").frame(maxWidth: .infinity) }
                    .accessibilityIdentifier("cancelExport")
                Button { export() } label: { Text("Export…").frame(maxWidth: .infinity) }
                    .disabled(session.document?.slices.isEmpty != false || session.showsBusy)
                    .accessibilityIdentifier("exportSlices")
            }
            .roundedControls()
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: width)
        .task(id: PreviewKey(revision: session.history.currentRevision, slices: session.document?.slices ?? [])) {
            await preview.refresh(session: session)
        }
    }

    // MARK: Slices

    private func sliceList(_ slices: [CanvasSlice]) -> some View {
        ScrollView {
            VStack(spacing: 2) {
                // Newest first, as layers are listed top first.
                ForEach(slices.reversed()) { slice in sliceRow(slice) }
            }.padding(8)
        }
        .frame(minHeight: 60, maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sliceRow(_ slice: CanvasSlice) -> some View {
        let selected = session.selectedSliceID == slice.id
        return HStack(spacing: 10) {
            ZStack {
                CheckerboardBackground()
                if let thumbnail = preview.thumbnails[slice.id] {
                    Image(decorative: thumbnail, scale: 2).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 36, height: 28).clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                if renamingID == slice.id {
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.plain).font(.system(size: 12, weight: .medium))
                        .focused($renameFocused)
                        .onSubmit { finishRename(commit: true) }
                        .onExitCommand { finishRename(commit: false) }
                        .onChange(of: renameFocused) { _, focused in if !focused { finishRename(commit: true) } }
                } else {
                    Text(slice.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                Text(detail(slice)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(selected ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginRename(slice) }
        .onTapGesture { session.selectedSliceID = slice.id }
        .contextMenu {
            Button("Rename") { beginRename(slice) }
            Button("Delete Slice") { session.deleteSlice(slice.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("slice-\(slice.name)")
    }

    /// "543 × 210, PNG, 10 KB": the slice's size, then its first format and that file's size.
    private func detail(_ slice: CanvasSlice) -> String {
        var parts = ["\(slice.width) × \(slice.height)"]
        if let format = slice.formats.first {
            parts.append(slice.formats.count > 1 ? "\(format.type.rawValue) +\(slice.formats.count - 1)" : format.type.rawValue)
            if let bytes = preview.sizes[format.id] { parts.append(Self.byteCount(bytes)) }
        }
        return parts.joined(separator: ", ")
    }

    private func beginRename(_ slice: CanvasSlice) {
        session.selectedSliceID = slice.id
        renameText = slice.name
        renamingID = slice.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func finishRename(commit: Bool) {
        guard let id = renamingID else { return }
        renamingID = nil
        if commit { session.renameSlice(id, to: renameText) }
        session.canvasFocusRequest += 1
    }

    // MARK: Formats

    private func formatEditor(_ slice: CanvasSlice) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Button { session.addSliceFormat(slice.id) } label: { Text("Add Format").frame(maxWidth: .infinity) }
                        .disabled(slice.formats.count >= CanvasSlice.maxFormats)
                        .accessibilityIdentifier("addSliceFormat")
                    Button { showsPresets.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.borderless).help("Presets").accessibilityLabel("Presets")
                        .popover(isPresented: $showsPresets, arrowEdge: .bottom) {
                            SlicePresetsPopover(session: session, sliceID: slice.id) { showsPresets = false }
                        }
                }
                .roundedControls()
                .padding(.horizontal, 18).padding(.vertical, 12)
                Divider()
                ForEach(slice.formats) { format in
                    SliceFormatEditor(session: session, slice: slice, format: format, bytes: preview.sizes[format.id])
                    Divider()
                }
            }
        }
    }

    nonisolated static func byteCount(_ bytes: Int) -> String { Int64(bytes).formatted(.byteCount(style: .file)) }
}

/// What the panel's previews are made from: the document as it stands, and its slices.
private struct PreviewKey: Equatable {
    let revision: UUID
    let slices: [CanvasSlice]
}

/// One of a slice's formats: its type, options, size and suffix, and the file size it comes to.
private struct SliceFormatEditor: View {
    let session: EditorSession
    let slice: CanvasSlice
    let format: SliceFormat
    let bytes: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Format", selection: binding(\.type, "Change Export Format")) {
                    ForEach(SliceFileType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(maxWidth: .infinity)
                Menu {
                    Toggle("Keep Transparency", isOn: binding(\.keepsTransparency, "Keep Transparency"))
                        .disabled(!format.type.supportsTransparency)
                    Toggle("Convert to sRGB", isOn: binding(\.convertsToSRGB, "Convert to sRGB"))
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Format options").accessibilityLabel("Format options")
                Text(bytes.map(ExportPanel.byteCount) ?? "—")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
                Button { session.removeSliceFormat(slice.id, format.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).disabled(slice.formats.count <= 1)
                    .help("Remove this format").accessibilityLabel("Remove format")
            }
            HStack(spacing: 8) {
                Picker("Size", selection: binding(\.scale, "Change Export Size")) {
                    ForEach(scales, id: \.self) { Text(SliceFormat.scaleLabel($0)).tag($0) }
                }
                .labelsHidden().frame(maxWidth: .infinity)
                TextField("Suffix", text: suffix).textFieldStyle(.roundedBorder)
                    .releasesFocusOnCommit(session)
                    .frame(maxWidth: .infinity)
            }
            if format.type.hasQuality {
                VStack(spacing: 4) {
                    HStack {
                        Menu("Quality (\(SliceFormat.qualityName(format.quality)))") {
                            ForEach(SliceFormat.qualityLevels, id: \.name) { level in
                                Button("\(level.name) (\(Int(level.value * 100))%)") { set(\.quality, level.value, "Change Export Quality") }
                            }
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        Spacer()
                        Text(format.quality, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 11).monospacedDigit())
                    }
                    Slider(value: Binding(get: { format.quality }, set: { set(\.quality, ($0 * 100).rounded() / 100, "Change Export Quality", coalescing: true) }),
                           in: 0...1)
                        .controlSize(.small)
                }
            }
            if format.type == .png {
                Toggle("Use advanced compression", isOn: binding(\.advancedCompression, "Use Advanced Compression"))
                Toggle("Use 256-color palette", isOn: binding(\.limitedPalette, "Use 256-Color Palette"))
            }
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .roundedControls()
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    /// The size menu's choices, with the format's own if a hand-written project gave it another.
    private var scales: [Double] {
        SliceFormat.scales.contains(format.scale) ? SliceFormat.scales : (SliceFormat.scales + [format.scale]).sorted()
    }

    private var suffix: Binding<String> {
        Binding(get: { format.suffix }, set: { set(\.suffix, $0, "Change Export Suffix", coalescing: true) })
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<SliceFormat, Value>, _ name: String) -> Binding<Value> {
        Binding(get: { format[keyPath: keyPath] }, set: { set(keyPath, $0, name) })
    }

    private func set<Value>(_ keyPath: WritableKeyPath<SliceFormat, Value>, _ value: Value, _ name: String, coalescing: Bool = false) {
        session.updateSliceFormat(slice.id, format.id, name, coalescing: coalescing) { $0[keyPath: keyPath] = value }
    }
}

/// The presets button's popover: each preset replaces the slice's formats; + keeps the slice's formats as a new one.
private struct SlicePresetsPopover: View {
    let session: EditorSession
    let sliceID: UUID
    let dismiss: () -> Void
    @State private var store = SlicePresetStore.shared
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Presets").font(.headline)
                Spacer()
                Button { naming.toggle(); name = "" } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("Save this slice's formats as a preset").accessibilityLabel("New preset")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if naming {
                HStack {
                    TextField("Preset Name", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
                    Button("Save", action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.all) { preset in
                    Button {
                        session.applySlicePreset(preset, to: sliceID)
                        dismiss()
                    } label: {
                        Text(preset.name).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(PresetRowStyle())
                    .contextMenu {
                        if store.custom.contains(where: { $0.id == preset.id }) {
                            Button("Delete Preset") { store.remove(preset.id) }
                        }
                    }
                }
            }.padding(.vertical, 6)
        }
        .frame(width: 240)
    }

    private func save() {
        guard let slice = session.document?.slices.first(where: { $0.id == sliceID }) else { return }
        store.add(name: name, formats: slice.formats)
        naming = false
    }
}

private struct PresetRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16).padding(.vertical, 4)
            .background(hovering || configuration.isPressed ? Color.accentColor.opacity(0.8) : .clear)
            .foregroundStyle(hovering || configuration.isPressed ? Color.white : Color.primary)
            .onHover { hovering = $0 }
    }
}

/// Gray checks behind a slice's thumbnail, so its transparent parts show as such.
private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 4
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.35)))
            var dark = Path()
            for row in 0..<Int(ceil(size.height / tile)) {
                for column in 0..<Int(ceil(size.width / tile)) where (row + column) % 2 == 0 {
                    dark.addRect(CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile))
                }
            }
            context.fill(dark, with: .color(Color(white: 0.28)))
        }
    }
}

/// The Slice tool's icon: a craft knife, blade down to the left.
struct SliceToolIcon: View {
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 18
            context.scaleBy(x: s, y: s)
            var blade = Path()
            blade.move(to: CGPoint(x: 1.5, y: 16.5))
            blade.addLine(to: CGPoint(x: 8.5, y: 6.8))
            blade.addLine(to: CGPoint(x: 11.2, y: 9.5))
            blade.closeSubpath()
            var handle = Path()
            handle.move(to: CGPoint(x: 9.6, y: 5.7))
            handle.addLine(to: CGPoint(x: 14.2, y: 1.1))
            handle.addQuadCurve(to: CGPoint(x: 16.9, y: 3.8), control: CGPoint(x: 17.4, y: 0.6))
            handle.addLine(to: CGPoint(x: 12.3, y: 8.4))
            handle.closeSubpath()
            context.stroke(blade, with: .foreground, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
            context.fill(handle, with: .foreground)
        }
    }
}

/// Thumbnails and file sizes for the Export panel, worked out in the background as slices and the image change.
@Observable final class SliceExportPreview {
    var thumbnails: [UUID: CGImage] = [:]
    /// Each format's file size, by format id.
    var sizes: [UUID: Int] = [:]
    /// The flattened canvas the previews come from, and the layers it was flattened from.
    @ObservationIgnored private var composite: (layers: [ImageLayer], size: CGSize, image: CGImage)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var encodedSizes: [SizeKey: Int] = [:]
    @ObservationIgnored private var thumbnailRects: [UUID: CGRect] = [:]

    private struct SizeKey: Hashable {
        let generation: Int
        let rect: [Int]
        let format: SliceFormat
    }

    func refresh(session: EditorSession) async {
        // Waits for a drag or a run of typing to settle.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let document = session.document else { return }
        let slices = document.slices
        if composite.map({ $0.layers != document.layers || $0.size != document.size }) ?? true {
            guard let snapshot = session.projectSnapshot(),
                  let raster = try? await ImageExporter.shared.render(snapshot), !Task.isCancelled else { return }
            composite = (document.layers, document.size, raster.image)
            generation += 1
            encodedSizes = [:]
            thumbnailRects = [:]
        }
        guard let image = composite?.image else { return }
        for slice in slices {
            guard !Task.isCancelled else { return }
            if thumbnailRects[slice.id] != slice.rect,
               let thumbnail = try? await SliceExporter.shared.thumbnail(of: slice.rect, in: image, side: 72) {
                thumbnails[slice.id] = thumbnail
                thumbnailRects[slice.id] = slice.rect
            }
            for format in slice.formats {
                guard !Task.isCancelled else { return }
                var plain = format
                plain.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
                let key = SizeKey(generation: generation, rect: [slice.x, slice.y, slice.width, slice.height], format: plain)
                if let known = encodedSizes[key] { sizes[format.id] = known; continue }
                guard let data = try? await SliceExporter.shared.data(for: slice, format: format, composite: image) else { continue }
                encodedSizes[key] = data.count
                sizes[format.id] = data.count
            }
        }
    }
}
