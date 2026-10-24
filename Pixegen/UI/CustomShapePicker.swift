import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// How the shape picker lists shapes, as in Photoshop's gear menu.
enum CustomShapeView: String, CaseIterable {
    case textOnly = "Text Only"
    case smallThumbnail = "Small Thumbnail"
    case largeThumbnail = "Large Thumbnail"
    case smallList = "Small List"
    case largeList = "Large List"
    var isGrid: Bool { self == .smallThumbnail || self == .largeThumbnail }
    var thumbnail: CGFloat { self == .largeThumbnail ? 56 : self == .smallThumbnail ? 32 : self == .largeList ? 36 : 18 }
}

/// The Custom Shape tool's library, attached to its button in the tool bar: folders of shapes to pick from, and a gear
/// menu to rename, delete and import them.
struct CustomShapePicker: View {
    @Bindable var session: EditorSession
    @Bindable var library: ShapeLibrary
    @AppStorage("customShapes.view") private var viewMode = CustomShapeView.smallThumbnail
    @State private var expanded: Set<UUID> = []
    /// The shape or folder the gear menu's Rename and Delete act on.
    @State private var selection: UUID?
    @State private var renaming: UUID?
    @State private var newName = ""
    @State private var confirmsDelete = false
    @State private var importError: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(library.groups) { group in folder(group) }
                }
                .padding(6)
            }
            .frame(width: 300, height: 260)
            .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            gearMenu
        }
        .padding(12)
        .onAppear {
            selection = session.customShape?.id
            if let id = session.customShape?.id, let group = library.groups.first(where: { $0.shapes.contains { $0.id == id } }) {
                expanded.insert(group.id)
            } else if let first = library.groups.first {
                expanded.insert(first.id)
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("OK") {
                if let renaming { library.renameShape(renaming, to: newName) }
                syncChosenShape()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete the folder “\(library.groups.first { $0.id == selection }?.name ?? "")” and every shape in it?",
                            isPresented: $confirmsDelete) {
            Button("Delete Folder", role: .destructive) { deleteSelection() }
        }
        .alert("Couldn’t Import Shapes", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importError ?? "") }
    }

    private func folder(_ group: CustomShapeGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
                selection = group.id
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded.contains(group.id) ? 90 : 0))
                        .frame(width: 12)
                    Image(systemName: "folder.fill").foregroundStyle(.secondary)
                    Text(group.name).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6).padding(.vertical, 5)
                .background(selection == group.id ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.name), \(group.shapes.count) shapes")
            if expanded.contains(group.id) {
                if viewMode.isGrid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: viewMode.thumbnail + 8), spacing: 4)], alignment: .leading, spacing: 4) {
                        ForEach(group.shapes) { shape in tile(shape) }
                    }
                    .padding(.leading, 20)
                } else {
                    ForEach(group.shapes) { shape in row(shape) }
                }
            }
        }
    }

    private func tile(_ shape: CustomShape) -> some View {
        Button { choose(shape) } label: {
            OutlineShape(outline: shape.outline).fill(.primary, style: FillStyle(eoFill: true))
                .padding(4)
                .frame(width: viewMode.thumbnail + 8, height: viewMode.thumbnail + 8)
                .background(chosen(shape) ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(shape.name)
        .accessibilityLabel(shape.name)
        .accessibilityAddTraits(chosen(shape) ? .isSelected : [])
    }

    private func row(_ shape: CustomShape) -> some View {
        Button { choose(shape) } label: {
            HStack(spacing: 8) {
                if viewMode != .textOnly {
                    OutlineShape(outline: shape.outline).fill(.primary, style: FillStyle(eoFill: true))
                        .frame(width: viewMode.thumbnail, height: viewMode.thumbnail)
                }
                Text(shape.name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 26).padding(.trailing, 6).padding(.vertical, 3)
            .background(chosen(shape) ? Color.accentColor.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(shape.name)
        .accessibilityAddTraits(chosen(shape) ? .isSelected : [])
    }

    private var gearMenu: some View {
        Menu {
            Button("Rename \(selectionIsFolder ? "Folder" : "Shape")…") {
                newName = selectionName ?? ""
                renaming = selection
            }
            .disabled(selectionName == nil)
            Button("Delete \(selectionIsFolder ? "Folder" : "Shape")") {
                if selectionIsFolder { confirmsDelete = true } else { deleteSelection() }
            }
            .disabled(selectionName == nil)
            Divider()
            Picker("View", selection: $viewMode) {
                ForEach(CustomShapeView.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline).labelsHidden()
            Divider()
            Button("Append Default Shapes") { library.appendDefaultShapes(); syncChosenShape() }
                .disabled(library.groups.contains { $0.name == ShapeLibrary.defaultGroupName })
            Button("Import Shapes…") { importShapes() }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("Shape library options")
    }

    private var selectionIsFolder: Bool { library.groups.contains { $0.id == selection } }
    private var selectionName: String? {
        guard let selection else { return nil }
        return library.groups.first { $0.id == selection }?.name ?? library.shape(selection)?.name
    }

    private func choose(_ shape: CustomShape) {
        selection = shape.id
        session.cancelShape()
        session.customShape = shape
        // A selected custom shape layer takes the new shape, in the box it already has.
        if session.shapeBarLayer?.liveShape?.style.customName != nil {
            session.restyleShape("Custom Shape") { $0.outline = shape.outline; $0.customName = shape.name }
        } else {
            session.shapeKind = .custom
        }
    }
    private func chosen(_ shape: CustomShape) -> Bool {
        if let target = session.shapeBarLayer?.liveShape?.style, target.customName != nil { return target.outline == shape.outline }
        return session.customShape?.id == shape.id
    }

    private func deleteSelection() {
        guard let selection else { return }
        library.delete(selection)
        self.selection = nil
        syncChosenShape()
    }

    /// The tool keeps drawing the shape it had, as it now is in the library, or the first shape if it was deleted.
    private func syncChosenShape() {
        if let id = session.customShape?.id, let current = library.shape(id) { session.customShape = current }
        else { session.customShape = library.firstShape }
    }

    private func importShapes() {
        let panel = NSOpenPanel()
        panel.title = "Import Shapes"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "csh") ?? .data]
        guard panel.runModal() == .OK else { return }
        var failures: [String] = []
        for url in panel.urls {
            let before = library.groups.count
            do {
                try library.importShapes(from: url)
                // Open the first folder the file added, so its shapes are in view.
                if let added = library.groups.dropFirst(before).first { expanded.insert(added.id) }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if session.customShape == nil { session.customShape = library.firstShape }
        if !failures.isEmpty { importError = failures.joined(separator: "\n") }
    }
}
