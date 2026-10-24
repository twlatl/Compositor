import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The palette above Layers, after Photoshop's Color and Swatches panels: one tab picks the foreground color on a
/// saturation/brightness field and hue strip; the other keeps the project's swatches in folders. The menu at the top
/// right holds the swatch commands, importing Photoshop swatch files among them.
struct ColorSwatchesPanel: View {
    let session: EditorSession
    var width: CGFloat = 252
    static let height: CGFloat = 264

    enum Tab: String { case color, swatches }
    /// How swatches are drawn, as Photoshop's panel menu offers.
    enum Layout: String, CaseIterable {
        case tinyThumbnail = "Tiny Thumbnail", smallThumbnail = "Small Thumbnail", largeThumbnail = "Large Thumbnail"
        case smallList = "Small List", largeList = "Large List"
        var isList: Bool { self == .smallList || self == .largeList }
        var size: CGFloat {
            switch self {
            case .tinyThumbnail: 12
            case .smallThumbnail, .smallList: 16
            case .largeThumbnail, .largeList: 24
            }
        }
    }
    /// What the name prompt is for.
    private enum Naming: Equatable {
        case newSwatch, newGroup, rename(UUID)
    }

    @AppStorage("colorPalette.tab") private var tab = Tab.color
    @AppStorage("colorPalette.visible") private var isVisible = true
    @AppStorage("swatches.layout") private var layout = Layout.largeThumbnail
    @AppStorage("swatches.showsSearch") private var showsSearch = true
    @State private var hsb = PickerHSB(.black)
    /// The swatch or folder the menu's Rename, Delete and Export Selected act on.
    @State private var selection: UUID?
    @State private var expanded: Set<UUID> = []
    @State private var query = ""
    @State private var naming: Naming?
    @State private var nameDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch tab {
                case .color: colorTab
                case .swatches: swatchesTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: width, height: Self.height)
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("OK") { commitName() }
            Button("Cancel", role: .cancel) { naming = nil }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            tabButton("Color", .color)
            tabButton("Swatches", .swatches)
            Spacer()
            Menu { panelMenu } label: { Image(systemName: "line.3.horizontal") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Swatches options").accessibilityLabel("Swatches options")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func tabButton(_ title: String, _ value: Tab) -> some View {
        Button { tab = value } label: {
            Text(title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tab == value ? .primary : .tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }

    @ViewBuilder private var panelMenu: some View {
        Button("New Swatch…") { ask(.newSwatch) }.disabled(!session.canEditSwatches)
        Button("New Swatch Group…") { ask(.newGroup) }.disabled(!session.canEditSwatches)
        Divider()
        Button(isGroupSelected ? "Rename Swatch Group…" : "Rename Swatch…") { if let selection { ask(.rename(selection)) } }
            .disabled(!session.canEditSwatches || selectedItemName == nil)
        Button(isGroupSelected ? "Delete Swatch Group" : "Delete Swatch") { deleteSelection() }
            .disabled(!session.canEditSwatches || selectedItemName == nil)
        Divider()
        ForEach(Layout.allCases, id: \.self) { option in
            Toggle(option.rawValue, isOn: Binding(get: { layout == option }, set: { if $0 { layout = option; tab = .swatches } }))
        }
        Divider()
        Toggle("Show Search Bar", isOn: $showsSearch)
        Divider()
        Button("Append Default Swatches") { session.appendDefaultSwatches(); tab = .swatches }.disabled(!session.canEditSwatches)
        Button("Import Swatches…") { importSwatches() }.disabled(!session.canEditSwatches)
        Button("Export Selected Swatches…") { exportSwatches(selectedOnly: true) }.disabled(selectedItemName == nil)
        Button("Export Swatches for Exchange…") { exportSwatches(selectedOnly: false) }.disabled(session.swatchGroups.isEmpty)
        Divider()
        Button("Close") { isVisible = false }
    }

    // MARK: Color

    private var colorTab: some View {
        HStack(alignment: .top, spacing: 12) {
            ColorPaletteControls(session: session, hostsPicker: false)
            GeometryReader { proxy in
                SaturationBrightnessField(hsb: hsbBinding, size: proxy.size)
            }
            HueStrip(hue: hsbBinding.hue, height: Self.height - 76, stripWidth: 14)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .disabled(!session.canEditPalette || session.isMaskSelected)
        .onAppear { hsb.setRGB(session.foregroundColor) }
        .onChange(of: session.foregroundColor) { _, color in
            // Only a change from elsewhere: the field's own keeps the hue it was dragged to through grays.
            if hsb.rgb.quantized != color { hsb.setRGB(color) }
        }
    }

    /// Dragging in the field or the strip sets the foreground color as it goes.
    private var hsbBinding: Binding<PickerHSB> {
        Binding(get: { hsb }, set: { value in
            hsb = value
            session.setPaletteColor(value.rgb.quantized, background: false)
        })
    }

    // MARK: Swatches

    private var swatchesTab: some View {
        VStack(spacing: 0) {
            if showsSearch {
                TextField("Search Swatches", text: $query)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
            }
            let groups = visibleGroups
            if groups.isEmpty {
                Text(query.isEmpty ? "No swatches" : "No matching swatches")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in groupRow(group) }
                    }
                    .padding(.vertical, 4)
                }
            }
            Divider()
            HStack(spacing: 0) {
                Spacer()
                Button { ask(.newGroup) } label: { FooterIcon(systemName: "folder.badge.plus") }
                    .help("New swatch group").accessibilityLabel("New swatch group")
                Button { addForegroundSwatch() } label: { FooterIcon(systemName: "plus.square") }
                    .help("New swatch from the foreground color").accessibilityLabel("New swatch")
                Button { deleteSelection() } label: { FooterIcon(systemName: "trash") }
                    .help(isGroupSelected ? "Delete swatch group" : "Delete swatch").accessibilityLabel("Delete swatch")
                    .disabled(!session.canEditSwatches || selectedItemName == nil)
            }
            .disabled(!session.canEditSwatches)
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .padding(.horizontal, 8)
        }
    }

    /// The folders, narrowed to swatches whose name or hex matches the search.
    private var visibleGroups: [SwatchGroup] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return session.swatchGroups }
        let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
        return session.swatchGroups.compactMap { group in
            var match = group
            match.swatches = group.swatches.filter {
                $0.name.localizedCaseInsensitiveContains(text) || $0.color.quantized.hex.localizedCaseInsensitiveContains(hex)
            }
            return match.swatches.isEmpty ? nil : match
        }
    }

    private func groupRow(_ group: SwatchGroup) -> some View {
        let open = expanded.contains(group.id) || !query.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                selection = group.id
                if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
                    Image(systemName: "folder.fill").foregroundStyle(.secondary)
                    Text(group.name).lineLimit(1)
                    Spacer()
                }
                .font(.system(size: 12))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(selection == group.id ? Color.accentColor.opacity(0.25) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { itemMenu(group.id) }
            .accessibilityLabel("\(group.name) folder")
            if open {
                if layout.isList {
                    ForEach(group.swatches) { swatch in listRow(swatch) }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: layout.size, maximum: layout.size), spacing: 3)], alignment: .leading, spacing: 3) {
                        ForEach(group.swatches) { swatch in thumbnail(swatch) }
                    }
                    .padding(.leading, 28).padding(.trailing, 12).padding(.vertical, 4)
                }
            }
        }
    }

    private func thumbnail(_ swatch: Swatch) -> some View {
        Button { choose(swatch) } label: { chip(swatch, size: layout.size) }
            .buttonStyle(.plain)
            .help(swatch.name)
            .contextMenu { itemMenu(swatch.id) }
            .accessibilityLabel(swatch.name)
    }

    private func listRow(_ swatch: Swatch) -> some View {
        Button { choose(swatch) } label: {
            HStack(spacing: 8) {
                chip(swatch, size: layout.size)
                Text(swatch.name).font(.system(size: layout == .smallList ? 11 : 12)).lineLimit(1)
                Spacer()
            }
            .padding(.leading, 28).padding(.trailing, 12).padding(.vertical, 2)
            .background(selection == swatch.id ? Color.accentColor.opacity(0.25) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { itemMenu(swatch.id) }
        .accessibilityLabel(swatch.name)
    }

    private func chip(_ swatch: Swatch, size: CGFloat) -> some View {
        Rectangle().fill(swatch.color.swiftUI)
            .overlay { Rectangle().strokeBorder(selection == swatch.id ? Color.accentColor : .black.opacity(0.4),
                                                lineWidth: selection == swatch.id ? 2 : 1) }
            .frame(width: size, height: size)
    }

    @ViewBuilder private func itemMenu(_ id: UUID) -> some View {
        Button("Rename…") { selection = id; ask(.rename(id)) }.disabled(!session.canEditSwatches)
        Button("Delete") { selection = id; deleteSelection() }.disabled(!session.canEditSwatches)
    }

    // MARK: Actions

    /// Click: the foreground color. Option-click: the background color, as in Photoshop.
    private func choose(_ swatch: Swatch) {
        selection = swatch.id
        guard !session.isMaskSelected else { return }
        session.setPaletteColor(swatch.color, background: NSEvent.modifierFlags.contains(.option))
    }

    private var isGroupSelected: Bool { session.swatchGroups.contains { $0.id == selection } }
    private var selectedItemName: String? {
        guard let selection else { return nil }
        return session.swatchGroups.first { $0.id == selection }?.name ?? session.swatch(selection)?.name
    }

    private func addForegroundSwatch() {
        let color = session.foregroundColor.quantized
        if let id = session.addSwatch(color, named: color.hex, near: selection) { reveal(id) }
    }

    private func deleteSelection() {
        guard let selection else { return }
        session.deleteSwatchItem(selection)
        self.selection = nil
    }

    /// Opens the folder holding a new swatch and selects it.
    private func reveal(_ id: UUID) {
        tab = .swatches
        selection = id
        if let group = session.swatchGroup(containing: id) { expanded.insert(group.id) }
    }

    private var namingTitle: String {
        switch naming {
        case .newSwatch: "New Swatch"
        case .newGroup: "New Swatch Group"
        case .rename(let id): session.swatchGroups.contains { $0.id == id } ? "Rename Swatch Group" : "Rename Swatch"
        case nil: ""
        }
    }

    private func ask(_ purpose: Naming) {
        switch purpose {
        case .newSwatch: nameDraft = session.foregroundColor.quantized.hex
        case .newGroup: nameDraft = "Untitled Folder"
        case .rename: nameDraft = selectedItemName ?? ""
        }
        naming = purpose
    }

    private func commitName() {
        switch naming {
        case .newSwatch:
            if let id = session.addSwatch(session.foregroundColor, named: nameDraft, near: selection) { reveal(id) }
        case .newGroup:
            if let id = session.addSwatchGroup(named: nameDraft) { reveal(id) }
        case .rename(let id): session.renameSwatchItem(id, to: nameDraft)
        case nil: break
        }
        naming = nil
    }

    private func importSwatches() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SwatchFile.contentTypes
        panel.allowsMultipleSelection = true
        panel.message = "Choose swatches to add to the project: .aco, .ase or .act from Photoshop, or a .css, .html or .svg file"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let before = Set(session.swatchGroups.map(\.id))
            do { try session.importSwatches(from: url) }
            catch {
                session.importError = "“\(url.lastPathComponent)” couldn't be imported. \(error.localizedDescription)"
                return
            }
            if let added = session.swatchGroups.first(where: { !before.contains($0.id) }) { reveal(added.id) }
        }
    }

    private func exportSwatches(selectedOnly: Bool) {
        var groups = session.swatchGroups
        if selectedOnly, let selection {
            if let group = groups.first(where: { $0.id == selection }) { groups = [group] }
            else if let swatch = session.swatch(selection), var group = session.swatchGroup(containing: selection) {
                group.swatches = [swatch]
                groups = [group]
            } else { return }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ase") ?? .data]
        panel.nameFieldStringValue = (selectedOnly ? selectedItemName ?? "Swatches" : "Swatches") + ".ase"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try SwatchFile.writeASE(groups).write(to: url, options: .atomic) }
        catch { session.importError = error.localizedDescription }
    }
}
