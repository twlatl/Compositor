import SwiftUI
import UniformTypeIdentifiers

/// The projects tabbed together in this window, under the tool's bar: each a fixed width, its name cut short with "…"
/// before its zoom is, the close button on its left. The project whose view this is in is the active tab.
struct DocumentTabBar: View {
    static let height: CGFloat = 30
    static let tabWidth: CGFloat = 220
    /// A tab being dragged to a new place in the bar.
    static let tabType = "net.pixegen.pixegen.document-tab"
    let workspace: ProjectWorkspace
    let tab: ProjectTab

    var body: some View {
        let tabs = workspace.tabsGrouped(with: tab)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, item in
                        DocumentTabItem(workspace: workspace, tab: item, index: index, isActive: item === tab,
                                        isAlone: tabs.count == 1)
                        Divider()
                    }
                }
            }
            // The active tab kept in view, however many there are.
            .onAppear { proxy.scrollTo(tab.id) }
            .onChange(of: tabs.map(\.id)) { proxy.scrollTo(tab.id) }
        }
        .frame(height: Self.height)
        .accessibilityIdentifier("documentTabs")
    }
}

private struct DocumentTabItem: View {
    let workspace: ProjectWorkspace
    let tab: ProjectTab
    let index: Int
    let isActive: Bool
    let isAlone: Bool
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 6) {
            closeButton
            // The name gives way first, so the zoom always shows.
            Text(tab.title).lineLimit(1).truncationMode(.tail)
            if let zoom = tab.zoomLabel { Text(zoom).lineLimit(1).fixedSize() }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
        .foregroundStyle(isActive ? Color.white : Color.secondary)
        .padding(.horizontal, 8)
        .frame(width: DocumentTabBar.tabWidth, height: DocumentTabBar.height)
        .background(isActive ? Color.white.opacity(0.09) : hovering ? Color.white.opacity(0.04) : .clear)
        .overlay { if targeted { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2) } }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { workspace.select(tab.id) }
        .help(tab.title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
        .onDrag {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: DocumentTabBar.tabType, visibility: .ownProcess) { done in
                done(tab.id.uuidString.data(using: .utf8), nil); return nil
            }
            return provider
        }
        .onDrop(of: [DocumentTabBar.tabType, ProjectWorkspace.layerType, UTType.fileURL.identifier, UTType.image.identifier],
                delegate: DocumentTabDropDelegate(workspace: workspace, tab: tab, index: index, targeted: $targeted))
        .contextMenu {
            Button("Close") { Task { await workspace.close(tab.id) } }
            Button("Close Other Tabs") { Task { await workspace.closeOthers(tab.id) } }.disabled(isAlone)
            Divider()
            Button("Move Tab to New Window") { workspace.presenter?.moveToNewWindow(tab) }.disabled(isAlone)
        }
    }

    /// An ×, or, with changes unsaved, a dot until the pointer's over the tab.
    private var closeButton: some View {
        Button { Task { await workspace.close(tab.id) } } label: {
            Group {
                if tab.session.isModified, !hovering {
                    Circle().frame(width: 7, height: 7)
                } else {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close")
        .accessibilityLabel("Close \(tab.title)")
        .accessibilityIdentifier("closeTab")
    }
}

/// A tab dropped on a tab takes its place in the bar. Files, images and layers held over a tab for a moment bring it
/// to the front, as macOS's own tabs do, to be dropped on its canvas; dropped on the tab itself, they go in as dropped
/// on its canvas would, centered.
private struct DocumentTabDropDelegate: DropDelegate {
    let workspace: ProjectWorkspace
    let tab: ProjectTab
    let index: Int
    @Binding var targeted: Bool
    static let springDelay: Duration = .milliseconds(600)

    private func isTabDrag(_ info: DropInfo) -> Bool { info.hasItemsConforming(to: [DocumentTabBar.tabType]) }
    func validateDrop(info: DropInfo) -> Bool {
        if isTabDrag(info) { return true }
        return workspace.isIdle(tab) && workspace.canReceiveDrag(into: tab.id)
    }
    func dropEntered(info: DropInfo) {
        targeted = validateDrop(info: info)
        guard targeted, !isTabDrag(info) else { return }
        let id = tab.id
        Task { @MainActor in
            try? await Task.sleep(for: Self.springDelay)
            if targeted { workspace.select(id) }
        }
    }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: isTabDrag(info) ? .move : .copy)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard validateDrop(info: info) else { return false }
        if isTabDrag(info) {
            guard let provider = info.itemProviders(for: [DocumentTabBar.tabType]).first else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: DocumentTabBar.tabType) { data, _ in
                guard let data, let id = UUID(uuidString: String(decoding: data, as: UTF8.self)) else { return }
                Task { @MainActor in
                    // Only within the bar it came from: windows' groups are merged from the Window menu.
                    guard let moved = workspace.tabs.first(where: { $0.id == id }),
                          workspace.tabsGrouped(with: tab).contains(where: { $0 === moved }) else { return }
                    workspace.presenter?.move(moved, to: index)
                }
            }
            return true
        }
        let providers = info.itemProviders(for: [ProjectWorkspace.layerType, UTType.fileURL.identifier, UTType.image.identifier])
        Task { await workspace.receiveProviders(providers, into: tab.id) }
        return true
    }
}
